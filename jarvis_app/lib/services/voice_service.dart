import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vosk_flutter_2/vosk_flutter_2.dart';
import 'action_manager.dart';
import 'foreground_service_manager.dart';
import 'jarvis_config.dart';

class VoiceService {
  static const Duration _minimumRecordingDuration = Duration(milliseconds: 500);

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  
  // Vosk objects for partial feedback
  Model? _voskModel;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  StreamSubscription? _voskSubscription;
  StreamSubscription<Uint8List>? _streamRecordingSubscription;
  StreamSubscription? _streamSocketSubscription;
  WebSocket? _streamSocket;
  Completer<void>? _streamCommitCompleter;
  String _latestPartialTranscript = "";
  String _finalizedTranscriptBuffer = ""; // New buffer for multi-segment sentences
  bool _useStreamingMode = false;
  String? _legacyRecordingPath;
  
  // Track the brain's response received via WebSocket
  String? _lastBrainResponseText;
  Completer<String?>? _brainResponseCompleter;

  static const String _baseUrl = JarvisConfig.baseUrl;

  bool _isListening = false;
  DateTime? _listeningStartedAt;
  bool get isListening => _isListening;

  // Callback to update UI with partial transcription
  Function(String)? onPartialTranscription;

  VoiceService() {
    _initVosk();
  }

  Future<void> _initVosk() async {
    try {
      final modelLoader = ModelLoader();
      final modelPath = await modelLoader.loadFromAssets(
        'assets/models/vosk-model-small-en-us-0.15.zip'
      );
      _voskModel = await _vosk.createModel(modelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _voskModel!, 
        sampleRate: 16000,
      );
      print("VoiceService: Vosk Local Feedback Ready.");
    } catch (e) {
      print("VoiceService: Vosk Init Error: $e");
    }
  }

  Future<void> startListening() async {
    if (await _recorder.hasPermission()) {
      _latestPartialTranscript = "";
      _finalizedTranscriptBuffer = "";
      _legacyRecordingPath = null;
      _isListening = true;
      _listeningStartedAt = DateTime.now();

      // Trigger start in parallel without blocking the UI
      _startStreamingCapture();

      print("Jarvis is listening (Zero-Latency Mode Active)...");
    }
  }
  }

  Future<String?> stopListeningAndProcess() async {
    final startedAt = _listeningStartedAt;
    if (startedAt != null) {
      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed < _minimumRecordingDuration) {
        await Future.delayed(_minimumRecordingDuration - elapsed);
      }
    }

    _isListening = false;
    _listeningStartedAt = null;
    
    // 1. Stop Vosk (UI Feedback)
    await _stopPartialFeedback();

    if (_useStreamingMode) {
      _lastBrainResponseText = null;
      _brainResponseCompleter = Completer<String?>();
      
      final transcript = await _stopStreamingCaptureAndCollectTranscript();
      if (transcript == null || transcript.trim().isEmpty) {
        return "I could not catch that clearly. Please speak a little longer and try again.";
      }
      
      print("Waiting for Jarvis response via WebSocket...");
      // Wait for the final_response message to be processed by _handleStreamSocketMessage
      return await _brainResponseCompleter?.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => "Response timed out. Check server logs.",
      );
    }

    // Legacy fallback path if streaming setup failed.
    final path = await _recorder.stop();
    if (path != null) {
      return await _uploadAndProcess(path);
    }

    return null;
  }

  Future<void> _startStreamingCapture() async {
    try {
      _useStreamingMode = true;
      
      // Parallelize WebSocket connection and Recorder stream start
      final results = await Future.wait([
        WebSocket.connect(JarvisConfig.voiceStreamUrl),
        _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            streamBufferSize: 4096,
          ),
        ),
      ]);

      final socket = results[0] as WebSocket;
      final stream = results[1] as Stream<Uint8List>;

      _streamSocket = socket;
      _streamSocketSubscription = socket.listen(
        _handleStreamSocketMessage,
        onError: (err) => print("VoiceService: socket error: $err"),
        onDone: () => _streamCommitCompleter?.complete(),
      );

      _streamRecordingSubscription = stream.listen((chunk) {
        _streamSocket?.add(chunk);
      });
    } catch (e) {
      print("VoiceService: streaming capture unavailable, falling back: $e");
      await _streamRecordingSubscription?.cancel();
      await _streamSocketSubscription?.cancel();
      await _streamSocket?.close();
      _streamRecordingSubscription = null;
      _streamSocketSubscription = null;
      _streamSocket = null;
      _useStreamingMode = false;

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/input.wav';
      _legacyRecordingPath = path;
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _isListening = true;
      _listeningStartedAt = DateTime.now();

      if (_recognizer != null) {
        try {
          await _stopPartialFeedback();
          _speechService ??= await _vosk.initSpeechService(_recognizer!);
          _voskSubscription = _speechService!.onPartial().listen((data) {
            final map = jsonDecode(data);
            if (onPartialTranscription != null) {
              onPartialTranscription!(map['partial'] ?? "");
            }
          });
          await _speechService!.start();
        } catch (inner) {
          print("VoiceService: Vosk Runtime Error: $inner");
        }
      }
    }
  }

  Future<String?> _stopStreamingCaptureAndCollectTranscript() async {
    await _streamRecordingSubscription?.cancel();
    _streamRecordingSubscription = null;
    await _recorder.stop();

    final completer = Completer<void>();
    _streamCommitCompleter = completer;
    _streamSocket?.add(jsonEncode({'type': 'commit'}));

    try {
      await completer.future.timeout(const Duration(seconds: 4));
    } catch (_) {
      // Continue with the latest transcript we have.
    }

    await _streamSocketSubscription?.cancel();
    _streamSocketSubscription = null;
    await _streamSocket?.close();
    _streamSocket = null;
    _streamCommitCompleter = null;

    final fullTranscript = "$_finalizedTranscriptBuffer $_latestPartialTranscript".trim();
    return fullTranscript;
  }

  void _handleStreamSocketMessage(dynamic data) {
    if (data is! String) {
      return;
    }

    final payload = jsonDecode(data);
    final type = payload['type'];

    if (type == 'transcript') {
      final text = (payload['text'] ?? '').toString();
      final isFinal = payload['is_final'] == true;
      if (text.isEmpty) {
        return;
      }

      if (isFinal) {
        _finalizedTranscriptBuffer += " $text";
        _latestPartialTranscript = ""; // Clear partial as it's now final
      } else {
        _latestPartialTranscript = text;
      }

      final displayText = "$_finalizedTranscriptBuffer $_latestPartialTranscript".trim();
      if (onPartialTranscription != null) {
        onPartialTranscription!(displayText);
      }
      return;
    }

    if (type == 'commit_complete') {
      _streamCommitCompleter?.complete();
    }

    if (type == 'final_response') {
      final String text = payload['text'] ?? "";
      final String audioB64 = payload['audio'] ?? "";
      final List<dynamic> actions = payload['actions'] ?? const [];

      print("Jarvis Final Response: $text");

      if (audioB64.isNotEmpty) {
        final audioBytes = base64Decode(audioB64);
        _player.play(BytesSource(audioBytes));
      }

      ActionManager.processActionList(actions);
      
      _lastBrainResponseText = text;
      if (_brainResponseCompleter?.isCompleted == false) {
        _brainResponseCompleter?.complete(text);
      }
    }
  }

  Future<String?> _sendTranscriptAndRespond(String transcript) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/voice/respond'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'transcript': transcript}),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String text = data['text'] ?? "";
        final String audioB64 = data['audio'] ?? "";
        final List<dynamic> actions = data['actions'] ?? const [];

        print("Jarvis Transcript: $transcript");
        print("Jarvis Response: $text");

        if (audioB64.isNotEmpty) {
          final audioBytes = base64Decode(audioB64);
          await _player.play(BytesSource(audioBytes));
        }

        await ActionManager.processActionList(actions);
        return text;
      }
      return "Error: ${response.statusCode}";
    } catch (e) {
      return "Connection failed. Check PC IP.";
    }
  }

  Future<String?> _uploadAndProcess(String path) async {
    print("Sending audio to Jarvis Brain for Groq/Whisper Processing...");
    
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/voice/process'));
      request.files.add(await http.MultipartFile.fromPath('audio', path));
      
      var streamedResponse = await request.send().timeout(const Duration(seconds: 15));
      var response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String text = data['text'] ?? "";
        final String audioB64 = data['audio'] ?? "";
        final List<dynamic> actions = data['actions'] ?? const [];
        
        print("Jarvis Response: $text");
        
        // Play TTS
        if (audioB64.isNotEmpty) {
          final audioBytes = base64Decode(audioB64);
          await _player.play(BytesSource(audioBytes));
        }
        
        // Execute only server-approved actions.
        await ActionManager.processActionList(actions);
        
        return text;
      } else {
        return "Error: ${response.statusCode}";
      }
    } catch (e) {
      return "Connection failed. Check PC IP.";
    }
  }

  void dispose() {
    _stopPartialFeedback();
    _streamRecordingSubscription?.cancel();
    _streamSocketSubscription?.cancel();
    _streamSocket?.close();
    _recorder.dispose();
    _player.dispose();
    _recognizer?.dispose();
    _voskModel?.dispose();
  }

  Future<void> _stopPartialFeedback() async {
    await _voskSubscription?.cancel();
    _voskSubscription = null;

    try {
      await _speechService?.stop();
    } catch (_) {
      // Native Vosk service can already be stopped after hot restart/rebuild.
    }
  }
}
