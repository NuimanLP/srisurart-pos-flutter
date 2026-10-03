// Native (dart:io) implementation of [installPosTrust] — see pos_trust.dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// The private CA's public cert, PEM. Committed empty: a build made before the owner copies the
/// real one off mob04 (07_CICD_DEPLOY.md "TLS") trusts only the system roots.
const posCaAsset = 'assets/certs/pos-ca.crt';

/// Makes every `HttpClient` the app creates — and so every `package:http` `Client()`, which
/// wraps one — trust the bundled CA next to the system roots.
///
/// Never throws: an empty, missing or malformed asset leaves the system roots alone and only
/// logs, so a bad cert file can cost the server connection but never the app's start-up (the
/// offline till must still open). [bundle] is for tests.
Future<void> installPosTrust({AssetBundle? bundle}) async {
  try {
    final pem = await (bundle ?? rootBundle).loadString(posCaAsset);
    if (pem.trim().isNotEmpty) {
      HttpOverrides.global = PosTrustOverrides(posTrustContext(pem));
      return;
    }
  } catch (e) {
    debugPrint('pos_trust: $posCaAsset not loaded, using system roots only: $e');
  }
  if (const bool.fromEnvironment('USE_API_WRITES')) {
    debugPrint('pos_trust: API build without the server CA — an https server with a '
        'private-CA certificate (mob04) will be refused. See 07_CICD_DEPLOY.md "TLS".');
  }
}

/// System roots plus [caPem]. Hostname/IP checking is unchanged: a cert this CA signed is
/// still refused for a host its SAN does not name. Throws [TlsException] on a malformed PEM.
SecurityContext posTrustContext(String caPem) =>
    SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(utf8.encode(caPem));

class PosTrustOverrides extends HttpOverrides {
  PosTrustOverrides(this._context);

  final SecurityContext _context;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? _context);
}
