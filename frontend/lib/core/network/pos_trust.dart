// Trust the shop server's private CA on native builds (Android/iOS/desktop).
//
// mob04 serves a certificate signed by a private CA (server/docker/certgen/certgen.sh). The
// native build bundles that CA's public cert as assets/certs/pos-ca.crt and trusts it IN
// ADDITION to the system roots — verification stays on; no badCertificateCallback. The web
// build keeps the browser's own trust store, so this import never pulls `dart:io` into it.
export 'pos_trust_web.dart' if (dart.library.io) 'pos_trust_io.dart';
