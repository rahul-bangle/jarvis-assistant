class JarvisConfig {
  // Keep network config in one place so the phone app does not drift.
  static const String host = '192.168.29.68';
  static const int port = 10532;
  static const String baseUrl = 'http://$host:$port';
  static const String voiceStreamUrl = 'ws://$host:$port/voice/stream';
}
