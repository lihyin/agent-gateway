import 'package:local_auth/local_auth.dart';

abstract interface class LocalConfirmation {
  Future<bool> confirm(String reason);
}

class DeviceConfirmation implements LocalConfirmation {
  DeviceConfirmation({LocalAuthentication? authentication})
    : _authentication = authentication ?? LocalAuthentication();
  final LocalAuthentication _authentication;
  @override
  Future<bool> confirm(String reason) async {
    try {
      return await _authentication.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}
