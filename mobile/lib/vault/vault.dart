import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/gateway_error.dart';

abstract interface class Vault {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> delete(String key);
}

class DeviceVault implements Vault {
  DeviceVault({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
            ),
            aOptions: AndroidOptions(),
          );
  final FlutterSecureStorage _storage;
  String _key(String key) => 'agent_gateway.v1.$key';
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    try {
      final value = await _storage.read(key: _key(key));
      if (value == null) return null;
      final decoded = jsonDecode(value) as Map<String, dynamic>;
      if (decoded['version'] != 1) throw const GatewayError('vault_version');
      return decoded['data'] as Map<String, dynamic>;
    } catch (_) {
      throw const GatewayError('vault_unavailable');
    }
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    try {
      final encoded = jsonEncode({'version': 1, 'data': value});
      if (encoded.length > 100000) throw const GatewayError('vault_capacity');
      await _storage.write(key: _key(key), value: encoded);
    } catch (_) {
      throw const GatewayError('vault_unavailable');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: _key(key));
    } catch (_) {
      throw const GatewayError('vault_unavailable');
    }
  }
}
