import 'dart:convert';
import 'package:http/http.dart' as http;
import 'jarvis_config.dart';

class BrainService {
  static const String _baseUrl = JarvisConfig.baseUrl;

  Future<String> queryBrain(String prompt) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/chat/completions'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'opencode/big-pickle', // Matching the verified Python brain
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['choices'][0]['message']['content'];
      } else {
        return 'Error: Server returned ${response.statusCode}\n${response.body}';
      }
    } catch (e) {
      return 'Error connecting to PC: $e\n\nMake sure your PC is at ${JarvisConfig.host} and the proxy is running on port ${JarvisConfig.port}.';
    }
  }

  Future<bool> checkConnection() async {
    try {
      final response = await http.get(Uri.parse(_baseUrl)).timeout(const Duration(seconds: 3));
      // Even a 404 or something means the server is UP
      return response.statusCode != 0; 
    } catch (_) {
      return false;
    }
  }
}
