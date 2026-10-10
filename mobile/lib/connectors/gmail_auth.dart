import 'dart:io';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;

import '../domain/gateway_error.dart';
import '../vault/vault.dart';

const gmailReadScope = 'https://www.googleapis.com/auth/gmail.readonly';

class GmailOAuthConfiguration {
  const GmailOAuthConfiguration(this.clientId);
  final String clientId;
  bool get isValid =>
      RegExp(r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$')
          .hasMatch(clientId);
  String get redirectScheme => clientId.split('.').reversed.join('.');
  String get redirectUri => '$redirectScheme:/oauthredirect';
}

class GmailTokens {
  const GmailTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scopes,
  });
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final List<String> scopes;
  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'scopes': scopes,
  };
  factory GmailTokens.fromJson(Map<String, dynamic> json) => GmailTokens(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String,
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    scopes: List<String>.from(json['scopes'] as List),
  );
  @override
  String toString() => 'GmailTokens(redacted)';
}

abstract interface class GmailOAuthProvider {
  Future<GmailTokens> authorize();
  Future<GmailTokens> refresh(GmailTokens current);
  Future<void> revoke(GmailTokens current);
}

class NativeGmailOAuth implements GmailOAuthProvider {
  NativeGmailOAuth(
    this.configuration, {
    FlutterAppAuth? appAuth,
    http.Client? client,
  }) : _appAuth = appAuth ?? const FlutterAppAuth(),
       _client = client ?? http.Client();
  final GmailOAuthConfiguration configuration;
  final FlutterAppAuth _appAuth;
  final http.Client _client;
  static const _endpoints = AuthorizationServiceConfiguration(
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
  );
  void _check() {
    if (!Platform.isIOS || !configuration.isValid) {
      throw const GatewayError('gmail_configuration_required');
    }
  }

  GmailTokens _tokens(
    TokenResponse response, {
    String? previousRefresh,
    List<String>? previousScopes,
  }) {
    final access = response.accessToken;
    final refresh = response.refreshToken ?? previousRefresh;
    final expiry = response.accessTokenExpirationDateTime;
    final scopes = response.scopes ?? previousScopes;
    if (access == null ||
        access.isEmpty ||
        refresh == null ||
        refresh.isEmpty ||
        expiry == null ||
        scopes == null ||
        !scopes.contains(gmailReadScope)) {
      throw const GatewayError('gmail_grant_incomplete');
    }
    return GmailTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiry,
      scopes: scopes,
    );
  }

  @override
  Future<GmailTokens> authorize() async {
    _check();
    try {
      // Native AppAuth owns a fresh PKCE verifier, OAuth state, and exact redirect validation.
      final response = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          configuration.clientId,
          configuration.redirectUri,
          serviceConfiguration: _endpoints,
          scopes: [gmailReadScope],
          promptValues: ['consent'],
          additionalParameters: {'access_type': 'offline'},
        ),
      );
      return _tokens(response);
    } on FlutterAppAuthUserCancelledException {
      throw const GatewayError('gmail_cancelled');
    } catch (_) {
      throw const GatewayError('gmail_sign_in_failed');
    }
  }

  @override
  Future<GmailTokens> refresh(GmailTokens current) async {
    _check();
    try {
      return _tokens(
        await _appAuth.token(
          TokenRequest(
            configuration.clientId,
            configuration.redirectUri,
            refreshToken: current.refreshToken,
            serviceConfiguration: _endpoints,
            scopes: [gmailReadScope],
          ),
        ),
        previousRefresh: current.refreshToken,
        previousScopes: current.scopes,
      );
    } catch (_) {
      throw const GatewayError('gmail_reconnect_required');
    }
  }

  @override
  Future<void> revoke(GmailTokens current) async {
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse('https://oauth2.googleapis.com/revoke'),
            )
            ..followRedirects = false
            ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
            ..body = 'token=${Uri.encodeQueryComponent(current.refreshToken)}';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      await response.stream.drain<void>().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 && response.statusCode != 400) {
        throw const GatewayError('gmail_revocation_pending');
      }
    } catch (_) {
      throw const GatewayError('gmail_revocation_pending');
    }
  }
}

class GmailSession {
  GmailSession(this.vault, this.provider, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final Vault vault;
  final GmailOAuthProvider provider;
  final DateTime Function() clock;
  final _serial = SerialExecutor();
  int _generation = 0;
  bool _blocked = false;
  int get generation => _generation;
  Future<bool> isConnected() async =>
      !_blocked && await vault.read('gmail.tokens') != null;
  Future<void> connect() => _serial.run(() async {
    final generation = _generation;
    final tokens = await provider.authorize();
    if (generation != _generation) {
      await provider.revoke(tokens);
      throw const GatewayError('gmail_disconnected');
    }
    if (!tokens.scopes.contains(gmailReadScope)) {
      throw const GatewayError('gmail_grant_incomplete');
    }
    await vault.write('gmail.tokens', tokens.toJson());
    _blocked = false;
  });
  Future<String> accessToken() => _serial.run(() async {
    if (_blocked) throw const GatewayError('gmail_disconnected');
    final generation = _generation;
    final stored = await vault.read('gmail.tokens');
    if (stored == null) throw const GatewayError('gmail_disconnected');
    var tokens = GmailTokens.fromJson(stored);
    if (!tokens.scopes.contains(gmailReadScope)) {
      throw const GatewayError('gmail_grant_incomplete');
    }
    if (!tokens.expiresAt.isAfter(clock().add(const Duration(seconds: 60)))) {
      try {
        tokens = await provider.refresh(tokens);
        if (generation != _generation || _blocked) {
          throw const GatewayError('gmail_disconnected');
        }
        if (!tokens.scopes.contains(gmailReadScope) ||
            !tokens.expiresAt.isAfter(clock())) {
          throw const GatewayError('gmail_grant_incomplete');
        }
        await vault.write('gmail.tokens', tokens.toJson());
      } catch (_) {
        _blocked = true;
        await vault.delete('gmail.tokens');
        throw const GatewayError('gmail_reconnect_required');
      }
    }
    if (generation != _generation || _blocked) {
      throw const GatewayError('gmail_disconnected');
    }
    return tokens.accessToken;
  });
  Future<void> disconnect() {
    _generation++;
    _blocked = true;
    return _serial.run(() async {
      final stored = await vault.read('gmail.tokens');
      await vault.delete('gmail.tokens');
      await vault.delete('review.state');
      if (stored != null) await provider.revoke(GmailTokens.fromJson(stored));
    });
  }
}
