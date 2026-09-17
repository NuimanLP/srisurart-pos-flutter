import 'package:flutter_test/flutter_test.dart';
import 'package:srisurart_pos/data/sync/sync_facade.dart';
import '../support/fake_sync_facade.dart';

void main() {
  group('NullSyncFacade', () {
    const facade = NullSyncFacade();

    test('status stream emits SyncStatus.online', () async {
      expect(await facade.status.first, equals(SyncStatus.online));
    });

    test('stream instances are stable across getter calls', () {
      expect(identical(facade.status, facade.status), isTrue);
      expect(identical(facade.needsOwner, facade.needsOwner), isTrue);
      expect(identical(facade.outboxRemaining, facade.outboxRemaining), isTrue);
    });

    test('multiple listeners can receive status', () async {
      final first = await facade.status.first;
      final second = await facade.status.first;
      expect(first, equals(SyncStatus.online));
      expect(second, equals(SyncStatus.online));
    });

    test('needsOwner stream emits empty list', () async {
      expect(await facade.needsOwner.first, isEmpty);
    });

    test('outboxRemaining stream emits 0', () async {
      expect(await facade.outboxRemaining.first, equals(0));
    });

    test('resend throws UnsupportedError with Thai message', () async {
      expect(
        () => facade.resend('op_test'),
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('ยังไม่พร้อม'),
        )),
      );
    });

    test('discard throws UnsupportedError with Thai message', () async {
      expect(
        () => facade.discard('op_test', 'test note'),
        throwsA(isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('ยังไม่พร้อม'),
        )),
      );
    });
  });

  group('FakeSyncFacade', () {
    late FakeSyncFacade facade;

    setUp(() {
      facade = FakeSyncFacade();
    });

    tearDown(() {
      facade.dispose();
    });

    test('stream instances are stable across getter calls', () {
      expect(identical(facade.status, facade.status), isTrue);
      expect(identical(facade.needsOwner, facade.needsOwner), isTrue);
      expect(identical(facade.outboxRemaining, facade.outboxRemaining), isTrue);
    });

    test('emits status updates', () async {
      expect(facade.currentStatus, equals(SyncStatus.online));
      expect(await facade.status.first, equals(SyncStatus.online));

      facade.emitStatus(SyncStatus.degraded);
      expect(facade.currentStatus, equals(SyncStatus.degraded));
      expect(await facade.status.first, equals(SyncStatus.degraded));
    });

    test('emits needsOwner updates', () async {
      expect(facade.currentNeedsOwner, isEmpty);

      final op = OutboxOpView(
        opId: 'op_1',
        type: 'sale.create',
        status: OutboxOpStatus.rejected,
        attempts: 1,
        lastCode: 'INSUFFICIENT_STOCK',
        lastMessage: 'สต็อกไม่พอ',
        payload: const {'id': 's_1'},
        createdAt: DateTime.now(),
      );

      facade.emitNeedsOwner([op]);
      expect(facade.currentNeedsOwner, hasLength(1));
      expect(facade.currentNeedsOwner.first.opId, equals('op_1'));
    });

    test('emits outboxRemaining updates', () async {
      expect(facade.currentOutboxRemaining, equals(0));

      facade.emitOutboxRemaining(5);
      expect(facade.currentOutboxRemaining, equals(5));
    });

    test('records resend calls and handles configured error', () async {
      await facade.resend('op_100');
      expect(facade.resendCalls, equals(['op_100']));

      facade.nextResendError = Exception('network failure');
      expect(() => facade.resend('op_101'), throwsA(isA<Exception>()));
      expect(facade.resendCalls, equals(['op_100', 'op_101']));
    });

    test('records discard calls and returns configured result', () async {
      facade.nextDiscardResult = const DiscardResult(serverHasRow: true);

      final result = await facade.discard('op_200', 'หมายเหตุทิ้งรายการ');
      expect(result.serverHasRow, isTrue);
      expect(facade.discardCalls, hasLength(1));
      expect(facade.discardCalls.first.opId, equals('op_200'));
      expect(facade.discardCalls.first.note, equals('หมายเหตุทิ้งรายการ'));

      facade.nextDiscardError = StateError('cannot discard');
      expect(
        () => facade.discard('op_201', 'note'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
