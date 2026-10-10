// Product pictures load through the same private-CA trust as ApiClient
// (contract §5, Android TLS). `ProductImage` uses plain `Image.network`, whose
// `NetworkImage` fetches with `HttpClient()` — so the `PosTrustOverrides` that
// `installPosTrust()` installs is what verifies mob04's certificate. No
// badCertificateCallback anywhere: a cert from another issuer is still
// refused and the card keeps its placeholder.
//
// Certificates are made per run with the `openssl` CLI, as in
// pos_trust_test.dart (skipped where it is absent).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/core/network/pos_trust_io.dart';
import 'package:srisurart_pos/presentation/widgets/product_image.dart';

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  late Directory dir;
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

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('product_image_trust');
    if (opensslMissing != null) return;
    await openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=test CA', '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign', '-keyout', 'ca.key', '-out', 'ca.crt']);
    File('${dir.path}/good.ext').writeAsStringSync(
        'basicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n');
    await openssl(['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
      '-keyout', 'good.key', '-out', 'good.csr']);
    await openssl(['x509', '-req', '-days', '1', '-in', 'good.csr', '-CA', 'ca.crt',
      '-CAkey', 'ca.key', '-set_serial', '0x${DateTime.now().microsecondsSinceEpoch}',
      '-extfile', 'good.ext', '-out', 'good.crt']);
    await openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
      '-keyout', 'stranger.key', '-out', 'stranger.crt']);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  final placeholder = find.byKey(const Key('product-image-placeholder'));

  /// Pumps a ProductImage for an https URL served with [name].crt, under the
  /// app's trust (the CA in ca.crt), and waits for the load to settle.
  Future<void> pumpFrom(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain('${dir.path}/$name.crt')
          ..usePrivateKey('${dir.path}/$name.key'),
      );
      server.listen((req) {
        req.response.headers.contentType = ContentType('image', 'png');
        req.response
          ..add(_png)
          ..close();
      }, onError: (_) {});
      final ca = File('${dir.path}/ca.crt').readAsStringSync();
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          await tester.pumpWidget(MaterialApp(
            home: Center(
              child: SizedBox(
                width: 80,
                height: 80,
                child: ProductImage(
                  url: 'https://127.0.0.1:${server.port}/img/$name.png',
                ),
              ),
            ),
          ));
          for (var i = 0; i < 100 && placeholder.evaluate().isNotEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await tester.pump();
          }
        }, PosTrustOverrides(posTrustContext(ca)));
      } finally {
        await server.close(force: true);
      }
    });
  }

  // Order matters: NetworkImage keeps one shared HttpClient per isolate, made
  // under the first test's overrides — the second test reuses that very client.
  testWidgets('a picture signed by the bundled CA loads (placeholder replaced)',
      (tester) async {
    await pumpFrom(tester, 'good');
    expect(placeholder, findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  }, skip: opensslMissing != null);

  testWidgets('a picture from another issuer is refused: placeholder, no error',
      (tester) async {
    await pumpFrom(tester, 'stranger');
    expect(placeholder, findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: opensslMissing != null);
}
