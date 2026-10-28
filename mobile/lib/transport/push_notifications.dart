import 'package:flutter/services.dart';

abstract class PushNotifications {
  Future<String> register();
  Future<List<String>> pending();
  Future<void> acknowledge(String envelope);
}

class NativePushNotifications implements PushNotifications {
  NativePushNotifications() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tokenChanged') onTokenChanged?.call();
    });
  }
  void Function()? onTokenChanged;
  static const _channel = MethodChannel('agent_gateway/push');
  @override
  Future<String> register() async =>
      (await _channel.invokeMethod<String>('register'))!;
  @override
  Future<List<String>> pending() async => List<String>.from(
    await _channel.invokeMethod<List<dynamic>>('pending') ?? [],
  );
  @override
  Future<void> acknowledge(String envelope) =>
      _channel.invokeMethod<void>('acknowledge', envelope);
}
