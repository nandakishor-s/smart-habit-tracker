import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the AI API keys in Android Keystore-backed secure storage.
/// The key never goes into Hive, source code or git.
class SecureKeyStore {
  static const _geminiKey = 'gemini_api_key';
  static const _groqKey = 'groq_api_key';

  final FlutterSecureStorage _storage;

  SecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> readGeminiKey() => _storage.read(key: _geminiKey);

  Future<void> saveGeminiKey(String key) =>
      _storage.write(key: _geminiKey, value: key.trim());

  Future<void> deleteGeminiKey() => _storage.delete(key: _geminiKey);

  Future<String?> readGroqKey() => _storage.read(key: _groqKey);

  Future<void> saveGroqKey(String key) => _storage.write(key: _groqKey, value: key.trim());

  Future<void> deleteGroqKey() => _storage.delete(key: _groqKey);
}
