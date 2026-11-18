import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API Key 安全存储封装（§12）：明文只在这里与 secure storage 之间流动。
class KeyVault {
  KeyVault();

  static const String _prefix = 'apikey.';

  /// v11 起 Android 默认加密存储，无需额外选项。
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String refFor(String keyId) => '$_prefix$keyId';

  Future<void> write(String keyId, String secret) async {
    await _storage.write(key: refFor(keyId), value: secret);
  }

  Future<String?> read(String keyId) async {
    return _storage.read(key: refFor(keyId));
  }

  Future<void> delete(String keyId) async {
    await _storage.delete(key: refFor(keyId));
  }
}
