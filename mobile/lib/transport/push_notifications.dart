import 'package:flutter/services.dart';

import 'dart:convert';

class PushAction {
  const PushAction(this.requestId, this.action, this.encoded);
  final String requestId, action, encoded;
}

abstract class PushNotifications {
  Future<String> register();
  Future<List<String>> pending();
  Future<void> acknowledge(String envelope);
  Future<List<PushAction>> actions();
  Future<void> acknowledgeAction(PushAction action);
  Future<void> setBadgeCount(int count);
}

class NativePushNotifications implements PushNotifications {
  NativePushNotifications() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tokenChanged') onTokenChanged?.call();
      if (call.method == 'actionReceived') onAction?.call();
    });
  }
  void Function()? onTokenChanged;
  void Function()? onAction;
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

  @override
  Future<List<PushAction>> actions() async {
    final values = await _channel.invokeListMethod<String>('actions') ?? [];
    return values.map((encoded) {
      final value = jsonDecode(encoded) as Map<String, dynamic>;
      return PushAction(
        value['requestId'] as String,
        value['action'] as String,
        encoded,
      );
    }).toList();
  }

  @override
  Future<void> acknowledgeAction(PushAction action) =>
      _channel.invokeMethod<void>('acknowledgeAction', action.encoded);

  @override
  Future<void> setBadgeCount(int count) =>
      _channel.invokeMethod<void>('setBadgeCount', count);
}
