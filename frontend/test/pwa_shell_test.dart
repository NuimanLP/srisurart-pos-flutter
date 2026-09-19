// Test for Issue #273: PWA shell, service worker, persistent storage, and single-tab lock
// Reference: docs/Backend_design/08_PHASE2_SPEC.md §4 (all 11 items, D2, D10, F8)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PWA Manifest (web/manifest.json)', () {
    late File manifestFile;
    late Map<String, dynamic> manifest;

    setUpAll(() {
      manifestFile = File('web/manifest.json');
      expect(manifestFile.existsSync(), isTrue, reason: 'web/manifest.json must exist');
      manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    });

    test('display is standalone', () {
      expect(manifest['display'], 'standalone');
    });

    test('colors match brand navy palette (#0B2444)', () {
      expect(manifest['background_color'], '#0B2444');
      expect(manifest['theme_color'], '#0B2444');
    });

    test('icons are declared and point to existing files', () {
      final icons = manifest['icons'] as List<dynamic>;
      expect(icons, isNotEmpty);
      for (final icon in icons) {
        final iconMap = icon as Map<String, dynamic>;
        final src = iconMap['src'] as String;
        final iconFile = File('web/$src');
        expect(iconFile.existsSync(), isTrue, reason: 'Icon file web/$src must exist');
      }
    });
  });

  group('Service Worker (web/sw.js)', () {
    late File swFile;
    late String swContent;

    setUpAll(() {
      swFile = File('web/sw.js');
      expect(swFile.existsSync(), isTrue, reason: 'web/sw.js must exist');
      swContent = swFile.readAsStringSync();
    });

    test('declares cache name keyed with version prefix', () {
      expect(swContent, contains('const CACHE_NAME ='));
      expect(swContent, contains('srisurart-pos-'));
    });

    test('precaches required app shell assets', () {
      const requiredAssets = [
        'index.html',
        'manifest.json',
        'favicon.png',
        'sqlite3.wasm',
        'drift_worker.js',
        'flutter_bootstrap.js',
        'main.dart.js',
        'icons/Icon-192.png',
        'icons/Icon-512.png',
        'icons/Icon-maskable-192.png',
        'icons/Icon-maskable-512.png',
        'assets/fonts/Sarabun-Regular.ttf',
        'assets/fonts/BarlowCondensed-Bold.ttf',
      ];

      for (final asset in requiredAssets) {
        expect(
          swContent,
          contains(asset),
          reason: 'web/sw.js must include $asset in precache list',
        );
      }
    });

    test('STRICT INVARIANT: does NOT call skipWaiting() automatically on install', () {
      // Find the install event block
      final installIndex = swContent.indexOf("addEventListener('install'");
      expect(installIndex, isNot(-1));

      final activateIndex = swContent.indexOf("addEventListener('activate'");
      expect(activateIndex, isNot(-1));

      final installBlock = swContent.substring(installIndex, activateIndex);

      // Must NOT contain self.skipWaiting() or skipWaiting() call inside install block
      // (comments explaining the invariant are fine, but no code call)
      final lines = installBlock.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('//') || trimmed.startsWith('/*') || trimmed.startsWith('*')) {
          continue;
        }
        expect(
          trimmed.contains('skipWaiting()'),
          isFalse,
          reason: 'install handler must NOT execute skipWaiting() automatically ($line)',
        );
      }
    });

    test('clears obsolete caches on activate', () {
      expect(swContent, contains("addEventListener('activate'"));
      expect(swContent, contains('caches.delete('));
      expect(swContent, contains('clients.claim()'));
    });

    test('bypasses API endpoints in fetch handler', () {
      expect(swContent, contains("addEventListener('fetch'"));
      expect(swContent, contains('/api/'));
    });

    test('handles skipWaiting only upon explicit client message', () {
      expect(swContent, contains("addEventListener('message'"));
      expect(swContent, contains('skipWaiting'));
      expect(swContent, contains('self.skipWaiting()'));
    });
  });

  group('Web Shell & Single-Tab Lock (web/index.html)', () {
    late File indexFile;
    late String indexContent;

    setUpAll(() {
      indexFile = File('web/index.html');
      expect(indexFile.existsSync(), isTrue, reason: 'web/index.html must exist');
      indexContent = indexFile.readAsStringSync();
    });

    test('registers service worker and wires update notification prompt', () {
      expect(indexContent, contains("navigator.serviceWorker.register('sw.js')"));
      expect(indexContent, contains('controllerchange'));
      expect(indexContent, contains('skipWaiting'));
      expect(indexContent, contains('มีแอปพลิเคชันเวอร์ชันใหม่ ต้องการอัปเดตหรือไม่?'));
      expect(indexContent, contains('อัปเดตเลย'));
      expect(indexContent, contains('ไว้ก่อน'));
    });

    test('requests persistent storage on boot (F8)', () {
      expect(indexContent, contains('navigator.storage.persist'));
      expect(indexContent, contains('navigator.storage.persisted'));
    });

    test('acquires single-tab lock with ifAvailable and retry duration (D10)', () {
      expect(indexContent, contains("navigator.locks.request('srisurart-pos-writer'"));
      expect(indexContent, contains('ifAvailable: true'));
      // Verifies retry loop timeout is around 2 seconds
      expect(indexContent, contains('2000'));
    });

    test('displays styled already-open screen with exact required Thai text if lock denied', () {
      const requiredThaiText =
          'แอปเปิดใช้งานอยู่ในแท็บอื่นแล้ว (เครื่อง POS รองรับการทำงานแท็บเดียวเพื่อความปลอดภัยของข้อมูล)';
      expect(
        indexContent,
        contains(requiredThaiText),
        reason: 'Must contain exact Thai sentence for single-tab restriction',
      );
      expect(indexContent, contains('pwa-lock-screen'));
      expect(indexContent, contains('ลองเปิดใหม่อีกครั้ง'));
      expect(indexContent, contains('window.location.reload()'));
    });

    test('boots Flutter dynamically only when lock is acquired', () {
      expect(indexContent, contains('bootFlutter'));
      expect(indexContent, contains('flutter_bootstrap.js'));
    });
  });
}
