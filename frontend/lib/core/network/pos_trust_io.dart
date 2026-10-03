// Native (dart:io) implementation of [installPosTrust] — see pos_trust.dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// The private CA's public cert, PEM. Committed empty: a build made before the owner copies the
/// real one off mob04 (07_CICD_DEPLOY.md "TLS") trusts only the system roots.
const posCaAsset = 'assets/certs/pos-ca.crt';

/// Makes every `HttpClient` the app creates — and so every `package:http` `Client()`, which
/// wraps one — trust the bundled CA next to the system roots. No-op when the asset is empty.
Future<void> installPosTrust() async {
  final pem = await rootBundle.loadString(posCaAsset);
  if (pem.trim().isEmpty) return;
  HttpOverrides.global = PosTrustOverrides(posTrustContext(pem));
}

/// System roots plus [caPem]. Hostname/IP checking is unchanged: a cert this CA signed is
/// still refused for a host its SAN does not name.
SecurityContext posTrustContext(String caPem) =>
    SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(utf8.encode(caPem));

class PosTrustOverrides extends HttpOverrides {
  PosTrustOverrides(this._context);

  final SecurityContext _context;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? _context);
}
