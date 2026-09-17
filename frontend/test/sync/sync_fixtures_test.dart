import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Sync Push Fixtures Contract', () {
    final fixturesDir = Directory(
      '../docs/Backend_design/fixtures/sync-push',
    );

    const expectedFixtures = [
      'sale-create.applied.json',
      'sale-create.rejected-stock.json',
      'sale-create.replay-by-key.json',
      'sale-create.replay-by-id.json',
      'sale-create.client-id-reused.json',
      'return-create.applied.json',
      'return-create.rejected-price.json',
      'drawer-entry.applied.json',
      'shift-open.applied.json',
      'shift-open.archived-previous.json',
      'credit-payment.applied.json',
      'credit-payment.rejected-overpayment.json',
      'customer-create.applied.json',
      'customer-update.applied.json',
      'sale-void-offline.applied.json',
      'sale-void-offline.rejected-online-bill.json',
      'batch.stop-at-retry.json',
      'batch.no-active-user-403.json',
    ];

    test('all 18 fixture files exist', () {
      expect(fixturesDir.existsSync(), isTrue, reason: 'fixtures directory should exist');
      for (final filename in expectedFixtures) {
        final file = File('${fixturesDir.path}/$filename');
        expect(file.existsSync(), isTrue, reason: '$filename should exist');
      }
    });

    for (final filename in expectedFixtures) {
      test('fixture $filename has valid schema and format', () {
        final file = File('${fixturesDir.path}/$filename');
        final content = file.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;

        expect(json.containsKey('name'), isTrue);
        expect(json.containsKey('description'), isTrue);
        expect(json.containsKey('request'), isTrue);
        expect(json.containsKey('response'), isTrue);

        final request = json['request'] as Map<String, dynamic>;
        expect(request.containsKey('body'), isTrue);
        final reqBody = request['body'] as Map<String, dynamic>;
        expect(reqBody['outboxRemaining'], isA<int>());
        expect(reqBody['ops'], isA<List>());

        final response = json['response'] as Map<String, dynamic>;
        expect(response.containsKey('status'), isTrue);
        final statusCode = response['status'] as int;
        expect([200, 403], contains(statusCode));

        final respBody = response['body'] as Map<String, dynamic>;
        if (statusCode == 200) {
          expect(respBody['status'], equals('success'));
          expect(respBody.containsKey('data'), isTrue);
          final data = respBody['data'] as Map<String, dynamic>;
          expect(data.containsKey('results'), isTrue);
          final results = data['results'] as List;
          expect(results, isNotEmpty);
          for (final result in results) {
            final r = result as Map<String, dynamic>;
            expect(r.containsKey('opId'), isTrue);
            expect(r.containsKey('status'), isTrue);
            expect(['applied', 'rejected', 'retry'], contains(r['status']));
            if (r['status'] == 'applied') {
              expect(r.containsKey('response'), isTrue);
            } else if (r['status'] == 'rejected') {
              expect(r.containsKey('code'), isTrue);
              expect(r.containsKey('message'), isTrue);
            }
          }
        } else if (statusCode == 403) {
          expect(respBody['status'], equals('error'));
          expect(respBody.containsKey('error'), isTrue);
          final error = respBody['error'] as Map<String, dynamic>;
          expect(error.containsKey('code'), isTrue);
          expect(error.containsKey('message'), isTrue);
        }
      });
    }
  });
}
