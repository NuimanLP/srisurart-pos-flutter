// Schema v13 → v14 migration test (QR accounts, owner 2026-10-10).
//
// v14 adds the payment_accounts table and sales.payment_account_id, so a v13
// file is a fresh v14 file with both dropped and user_version set back to 13.
// Opening it must create the table empty and add the column as NULL on a bill
// that already existed.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:srisurart_pos/data/db/database.dart';

void main() {
  test('v13 → v14 creates payment_accounts and keeps old bills with a NULL account',
      () async {
    final rawDb = raw.sqlite3.openInMemory();
    final seed = AppDatabase(
      NativeDatabase.opened(rawDb, closeUnderlyingOnClose: false),
    );
    await seed.customSelect('SELECT 1').get(); // run onCreate
    await seed.close();
    rawDb.execute('DROP TABLE payment_accounts');
    rawDb.execute('ALTER TABLE sales DROP COLUMN payment_account_id');
    rawDb.execute(
      "INSERT INTO sales (id, receipt_no, subtotal, discount, total, "
      "payment_method, points_granted, date, voided, sold_offline) VALUES "
      "('s-old', 'RC-1', 100, 0, 100, 'โอน/QR', 10, 0, 0, 0)",
    );
    rawDb.execute('PRAGMA user_version = 13');

    final db = AppDatabase(NativeDatabase.opened(rawDb));
    addTearDown(db.close);

    final version = await db
        .customSelect('PRAGMA user_version')
        .map((r) => r.data.values.first as int)
        .getSingle();
    expect(version, 14);
    expect(await db.select(db.paymentAccounts).get(), isEmpty);
    final old = await db.select(db.sales).getSingle();
    expect(old.id, 's-old');
    expect(old.paymentAccountId, isNull);

    await db.into(db.paymentAccounts).insert(PaymentAccountsCompanion.insert(
          id: 'a1',
          nickname: 'บัญชีร้าน',
          bankCode: 'KBANK',
          kind: 'promptpay',
        ));
    expect(await db.select(db.paymentAccounts).get(), hasLength(1));
  });
}
