// The native build trusts the shop server's private CA next to the system roots, and nothing
// else: a cert that CA signed for a different IP, or a cert from any other CA, is still refused.
// The certificates are made per run with the `openssl` CLI (never committed: no private key in
// git), the same way server/docker/certgen/certgen.sh makes mob04's.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:srisurart_pos/core/network/pos_trust_io.dart';

void main() {
  late Directory dir;
  // Skip, not fail, where the CLI is absent (e.g. Windows PowerShell); CI's ubuntu has it.
  final String? opensslMissing = () {
    try {
      Process.runSync('openssl', ['version']);
      return null;
    } on ProcessException {
      return 'openssl CLI not on PATH';
    }
  }();

  Future<void> openssl(List<String> args) async {
    final r = await Process.run('openssl', args, workingDirectory: dir.path);
    if (r.exitCode != 0) throw StateError('openssl ${args.first}: ${r.stderr}');
  }

  /// A leaf for [san] signed by the CA in ca.key/ca.crt, written as [name].crt / [name].key.
  Future<void> leaf(String name, String san) async {
    File('${dir.path}/$name.ext').writeAsStringSync(
        'basicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=$san\n');
    await openssl(['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
      '-keyout', '$name.key', '-out', '$name.csr']);
    await openssl(['x509', '-req', '-days', '1', '-in', '$name.csr', '-CA', 'ca.crt',
      '-CAkey', 'ca.key', '-set_serial', '0x${DateTime.now().microsecondsSinceEpoch}',
      '-extfile', '$name.ext', '-out', '$name.crt']);
  }

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('pos_trust_test');
    if (opensslMissing != null) return;
    await openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=test CA', '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign', '-keyout', 'ca.key', '-out', 'ca.crt']);
    await leaf('good', 'IP:127.0.0.1');
    await leaf('wrongip', 'DNS:localhost,IP:10.9.9.9');
    await openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
      '-keyout', 'stranger.key', '-out', 'stranger.crt']);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  /// GETs https://127.0.0.1 from a server presenting [name].crt, through a plain
  /// `package:http` Client() created under [PosTrustOverrides] — the app's own path.
  Future<int> getFrom(String name) async {
    final serverCtx = SecurityContext()
      ..useCertificateChain('${dir.path}/$name.crt')
      ..usePrivateKey('${dir.path}/$name.key');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverCtx);
    server.listen((req) => req.response
      ..write('ok')
      ..close());
    final ca = File('${dir.path}/ca.crt').readAsStringSync();
    try {
      return await HttpOverrides.runWithHttpOverrides(() async {
        final client = http.Client();
        try {
          return (await client.get(Uri.parse('https://127.0.0.1:${server.port}/'))).statusCode;
        } finally {
          client.close();
        }
      }, PosTrustOverrides(posTrustContext(ca)));
    } finally {
      await server.close(force: true);
    }
  }

  // A raw HandshakeException (an IOException), which isTransportFailure counts as no answer.
  // The reason text is the TLS backend's and differs by OS: Linux names the failure ([specific]);
  // macOS only says "CERTIFICATE_VERIFY_FAILED: application verification failure". Accept exactly
  // those known texts, so any other handshake error (protocol, connection) still fails the test.
  Matcher refused(String specific) => isA<HandshakeException>().having(
      (e) => e.osError?.message ?? '',
      'osError',
      anyOf(contains(specific), contains('application verification failure')));

  test('trusts a cert the bundled CA signed for the IP being dialled', () async {
    expect(await getFrom('good'), 200);
  }, skip: opensslMissing);

  test('refuses a cert the same CA signed for a different IP (IP SAN is checked)', () async {
    // Linux names the IP check; macOS only says verification failed. The first test (same CA,
    // matching IP => 200) shows the CA is trusted, so this refusal comes from the IP SAN check.
    await expectLater(getFrom('wrongip'), throwsA(refused('IP address mismatch')));
  }, skip: opensslMissing);

  test('refuses a self-signed cert from any other issuer', () async {
    await expectLater(getFrom('stranger'), throwsA(refused('self signed certificate')));
  }, skip: opensslMissing);

  // The app must still start (offline till) whatever the asset holds.
  for (final (name, text) in [
    ('a malformed PEM', '-----BEGIN CERTIFICATE-----\nnot a cert\n-----END CERTIFICATE-----\n'),
    ('an asset that cannot be loaded (zero-byte on some platforms)', null),
    ('an empty asset', ''),
  ]) {
    test('installPosTrust survives $name and keeps the system roots', () async {
      HttpOverrides.global = null;
      await installPosTrust(bundle: _FakeBundle(text)); // must not throw
      expect(HttpOverrides.current, isNull);
    });
  }

  test('installPosTrust installs the overrides only when the asset holds a cert', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final pem = await rootBundle.loadString(posCaAsset); // throws if the asset is not bundled
    await installPosTrust();
    expect(HttpOverrides.current is PosTrustOverrides, pem.trim().isNotEmpty);
  });
}

/// [text] null = the asset cannot be loaded at all.
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.text);

  final String? text;

  @override
  Future<ByteData> load(String key) async {
    if (text == null) throw FlutterError('Unable to load asset: "$key".');
    return ByteData.sublistView(utf8.encode(text!));
  }
}
