import 'package:flutter/material.dart';

import 'domain/gateway_configuration.dart';
import 'screens/gateway_controller.dart';
import 'screens/gateway_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const GatewayApp(configuration: GatewayConfiguration.fromEnvironment()),
  );
}

class GatewayApp extends StatefulWidget {
  const GatewayApp({super.key, required this.configuration, this.controller});
  final GatewayConfiguration configuration;
  final GatewayController? controller;
  @override
  State<GatewayApp> createState() => _GatewayAppState();
}

class _GatewayAppState extends State<GatewayApp> {
  late final GatewayController _controller =
      widget.controller ?? GatewayController.device(widget.configuration);
  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Agent Gateway',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF245C4B)),
    home: GatewayHome(
      configuration: widget.configuration,
      controller: _controller,
    ),
  );
}
