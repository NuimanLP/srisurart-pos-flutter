// Authentication models, token containers, and client JWT decoding.

import 'dart:convert';
import 'package:equatable/equatable.dart';

class AuthUser extends Equatable {
  const AuthUser({
    required this.id,
    required this.username,
    required this.role,
    this.displayName,
  });

  final String id;
  final String username;
  final String role;
  final String? displayName;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      username: json['username'] as String,
      role: json['role'] as String,
      displayName: json['displayName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'role': role,
        if (displayName != null) 'displayName': displayName,
      };

  AuthUser copyWith({
    String? id,
    String? username,
    String? role,
    String? displayName,
  }) {
    return AuthUser(
      id: id ?? this.id,
      username: username ?? this.username,
      role: role ?? this.role,
      displayName: displayName ?? this.displayName,
    );
  }

  @override
  List<Object?> get props => [id, username, role, displayName];
}

class AuthTokens extends Equatable {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String refreshToken;

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
      };

  @override
  List<Object?> get props => [accessToken, refreshToken];
}

/// Helper to inspect decoded claims from a JWT token on the client.
class JwtClaims {
  const JwtClaims({
    required this.rawPayload,
    this.sub,
    this.tid,
    this.did,
    this.drole,
    this.role,
    this.exp,
  });

  final Map<String, dynamic> rawPayload;
  final String? sub;
  final String? tid;
  final String? did;
  final String? drole;
  final String? role;
  final int? exp;

  /// Returns true if the token contains an exp claim and it has already passed.
  bool get isExpired {
    if (exp == null) return false;
    final expMs = exp! * 1000;
    return DateTime.now().millisecondsSinceEpoch >= expMs;
  }

  /// Parses claims from a raw JWT token string (`header.payload.signature`).
  static JwtClaims? tryParse(String? token) {
    if (token == null || token.isEmpty) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;

    try {
      final payloadBase64 = _normalizeBase64(parts[1]);
      final payloadString = utf8.decode(base64Url.decode(payloadBase64));
      final jsonMap = jsonDecode(payloadString) as Map<String, dynamic>;

      return JwtClaims(
        rawPayload: jsonMap,
        sub: jsonMap['sub'] as String?,
        tid: jsonMap['tid'] as String?,
        did: jsonMap['did'] as String?,
        drole: jsonMap['drole'] as String?,
        role: jsonMap['role'] as String?,
        exp: (jsonMap['exp'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  static String _normalizeBase64(String input) {
    var output = input.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        throw Exception('Illegal base64url string!');
    }
    return output;
  }
}
