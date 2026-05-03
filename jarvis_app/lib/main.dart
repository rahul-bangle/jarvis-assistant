import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/voice_service.dart';
import 'services/foreground_service_manager.dart';
import 'package:optimize_battery/optimize_battery.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ForegroundServiceManager.init();
  runApp(const JarvisApp());
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis Voice Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.cyanAccent,
        useMaterial3: true,
      ),
      home: const JarvisHUD(),
    );
  }
}

class JarvisHUD extends StatefulWidget {
  const JarvisHUD({super.key});

  @override
  State<JarvisHUD> createState() => _JarvisHUDState();
}

class _JarvisHUDState extends State<JarvisHUD> with SingleTickerProviderStateMixin {
  final VoiceService _voiceService = VoiceService();
  
  String _status = "Tap to Command";
  String _partialText = "";
  String _lastResponse = "";
  bool _isListening = false;
  bool _isThinking = false;
  bool _isOptimized = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndBattery();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    // Setup real-time feedback
    _voiceService.onPartialTranscription = (text) {
      setState(() {
        _partialText = text;
      });
    };
  }

  Future<void> _checkPermissionsAndBattery() async {
    await [
      Permission.microphone,
      Permission.bluetoothConnect,
      Permission.notification,
    ].request();

    // Zero-Latency: Pre-warm the system
    await ForegroundServiceManager.configureAudioSession();
    await ForegroundServiceManager.start();

    final isIgnoring = await OptimizeBattery.isIgnoringBatteryOptimizations();
    setState(() {
      _isOptimized = isIgnoring;
    });
  }

  Future<void> _handleInteraction() async {
    if (_isListening) {
      await _stopAndProcess();
    } else {
      if (!_isThinking) await _startListening();
    }
  }

  Future<void> _startListening() async {
    setState(() {
      _isListening = true;
      _partialText = "";
      _status = "Listening...";
    });
    
    await _voiceService.startListening();
  }

  Future<void> _stopAndProcess() async {
    setState(() {
      _isListening = false;
      _isThinking = true;
      _status = "Thinking...";
    });

    final result = await _voiceService.stopListeningAndProcess();
    
    setState(() {
      _isThinking = false;
      _status = "Tap to Command";
      if (result != null) _lastResponse = result;
      _partialText = "";
    });
  }

  void _openBatterySettings() {
    OptimizeBattery.stopOptimizingBatteryUsage();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background Glow effect
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 0.8,
                  colors: [
                    Colors.cyan.withOpacity(0.05),
                    Colors.black,
                  ],
                ),
              ),
            ),
          ),
          
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Glowing Core / Button
                GestureDetector(
                  onTap: _handleInteraction,
                  child: ScaleTransition(
                    scale: Tween(begin: 1.0, end: 1.1).animate(
                      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
                    ),
                    child: Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _isThinking ? Colors.white : (_isListening ? Colors.blueAccent : Colors.cyanAccent),
                            (_isListening ? Colors.blue : Colors.cyan).withOpacity(0.5),
                            Colors.transparent,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (_isListening ? Colors.blueAccent : Colors.cyanAccent).withOpacity(0.6),
                            blurRadius: _isListening ? 60 : 30,
                            spreadRadius: _isListening ? 15 : 5,
                          )
                        ],
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        _isThinking ? Icons.hourglass_empty : (_isListening ? Icons.stop : Icons.mic),
                        size: 70, 
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(height: 50),
                
                // Status Text
                Text(
                  _status,
                  style: TextStyle(
                    color: Colors.cyanAccent.withOpacity(0.8),
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 3,
                    shadows: const [Shadow(color: Colors.cyan, blurRadius: 15)],
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // Partial Feedback (Real-time)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  height: 40,
                  child: Text(
                    _partialText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 18,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // Last Full Response
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    _lastResponse,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white, 
                      fontSize: 16, 
                      height: 1.5,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Battery Optimization Toggle
          if (!_isOptimized)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: TextButton.icon(
                  onPressed: _openBatterySettings,
                  icon: const Icon(Icons.battery_alert, color: Colors.amber),
                  label: const Text(
                    "MIUI: Disable Battery Optimization for stability",
                    style: TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
// End of file
