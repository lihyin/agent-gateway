class GatewayConfiguration {
  const GatewayConfiguration({
    required this.environment,
    required this.revision,
    required this.relayUrl,
    this.googleIosClientId = '',
  });

  const GatewayConfiguration.fromEnvironment()
    : environment = const String.fromEnvironment(
        'ENVIRONMENT',
        defaultValue: 'local',
      ),
      revision = const String.fromEnvironment(
        'RELEASE_SHA',
        defaultValue: 'local',
      ),
      relayUrl = const String.fromEnvironment('RELAY_URL'),
      googleIosClientId = const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  final String environment;
  final String revision;
  final String relayUrl;
  final String googleIosClientId;

  // Enabling private-data access requires the later domain security pipeline.
  bool get sourceAccessEnabled => false;
}
