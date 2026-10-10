class GatewayError implements Exception {
  const GatewayError(this.code);
  final String code;
  @override
  String toString() => 'GatewayError($code)';
}

class SerialExecutor {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
