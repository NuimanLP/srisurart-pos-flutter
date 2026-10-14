// PaymentAccountsRepository — the shop's QR payment accounts (owner request
// 2026-10-10, contract `qr-accounts-contract.md` §4/§5).
//
// At most [maxPaymentAccounts] accounts. Two kinds: `promptpay` (checkout
// generates a dynamic QR with the bill total, `core/utils/promptpay.dart`) and
// `image` (an uploaded static QR). One may be the default; checkout falls back
// to the first account when none is ([defaultPaymentAccount]).
//
// This class is the Drift build's whole implementation (local CRUD). On the
// API build `ApiPaymentAccountsRepository` replaces every write with an
// online-only request and keeps the reads here.

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show protected;

import '../../core/errors/pos_exception.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/promptpay.dart';
import '../db/database.dart';

/// The shared bank list (contract §4). No logos (trademarks): screens show the
/// Thai name with a neutral dot.
const paymentAccountBanks = <String, String>{
  'SCB': 'ไทยพาณิชย์',
  'KBANK': 'กสิกรไทย',
  'BBL': 'กรุงเทพ',
  'KTB': 'กรุงไทย',
  'BAY': 'กรุงศรีอยุธยา',
  'TTB': 'ทีเอ็มบีธนชาต',
  'GSB': 'ออมสิน',
  'BAAC': 'ธ.ก.ส.',
  'GHB': 'อาคารสงเคราะห์',
  'KKP': 'เกียรตินาคินภัทร',
  'CIMBT': 'ซีไอเอ็มบี ไทย',
  'UOBT': 'ยูโอบี',
  'LHB': 'แลนด์ แอนด์ เฮ้าส์',
  'TISCO': 'ทิสโก้',
  'ICBCT': 'ไอซีบีซี (ไทย)',
  'OTHER': 'อื่น ๆ',
};

/// Thai bank name for [code]; an unknown code reads as itself.
String bankName(String code) => paymentAccountBanks[code] ?? code;

/// Owner decision 2026-10-10: at most 5 active accounts per shop.
const maxPaymentAccounts = 5;

/// The decoded image limit: 300,000 bytes. The server allows 300 × 1024;
/// the client stays under the round figure so a file it accepts can never be
/// one the server refuses (server lane, 2026-10-10).
const maxQrImageBytes = 300000;

/// `409 PAYMENT_ACCOUNT_LIMIT` — the same words on both builds.
const paymentAccountLimitMessage =
    'บันทึกบัญชีรับเงินได้สูงสุด 5 บัญชี'; // เจ้าของรับรอง 2026-10-10 (contract §2)

/// Why a non-owner sees the section read-only, and `403 OWNER_ONLY`.
const paymentAccountOwnerOnlyMessage =
    'เฉพาะเจ้าของร้านเท่านั้นที่แก้ไขบัญชีรับเงินได้'; // เจ้าของรับรอง 2026-10-10 (contract §2)

/// A write refused while Degraded — accounts are online-only on the API build.
const paymentAccountsOfflineRefusal =
    'ระบบอยู่ในสถานะออฟไลน์ ไม่สามารถบันทึกบัญชีรับเงินได้'; // เจ้าของรับรอง 2026-10-10

/// What a new account is created from (the add dialog's fields).
class PaymentAccountInput {
  const PaymentAccountInput({
    required this.nickname,
    required this.bankCode,
    required this.kind,
    this.promptpayId,
    this.image,
    this.imageMime,
    this.isDefault = false,
  });

  final String nickname;
  final String bankCode;

  /// `promptpay` | `image`.
  final String kind;
  final String? promptpayId;
  final Uint8List? image;
  final String? imageMime;
  final bool isDefault;
}

/// The Thai reason [nickname] … [imageMime] cannot be saved, or null. The
/// server checks the same rules (contract §2); this is the dialog's and the
/// Drift build's copy, so a bad value never needs a round trip.
String? paymentAccountError({
  required String nickname,
  required String bankCode,
  required String kind,
  String? promptpayId,
  Uint8List? image,
  String? imageMime,
}) {
  final n = nickname.trim();
  if (n.isEmpty || n.length > 40) {
    return 'กรุณากรอกชื่อเล่นบัญชี (ไม่เกิน 40 ตัวอักษร)'; // เจ้าของรับรอง 2026-10-10
  }
  if (!paymentAccountBanks.containsKey(bankCode)) {
    return 'กรุณาเลือกธนาคาร'; // เจ้าของรับรอง 2026-10-10
  }
  if (kind == 'promptpay') {
    if (promptpayId == null || !isValidPromptPayId(promptpayId)) {
      // เจ้าของรับรอง 2026-10-10
      return 'หมายเลขพร้อมเพย์ต้องเป็นเบอร์มือถือ 10 หลัก เลขประจำตัว 13 หลัก หรือ e-Wallet 15 หลัก';
    }
    return null;
  }
  if (kind == 'image') {
    if (image == null || image.isEmpty || imageMime == null) {
      return 'กรุณาเลือกรูป QR'; // เจ้าของรับรอง 2026-10-10
    }
    if (image.length > maxQrImageBytes) {
      return 'รูป QR ใหญ่เกิน 300 KB กรุณาเลือกรูปอื่น'; // เจ้าของรับรอง 2026-10-10
    }
    return null;
  }
  return 'ชนิดบัญชีไม่ถูกต้อง'; // เจ้าของรับรอง 2026-10-10
}

/// The account checkout shows first: the default, else the first one.
PaymentAccountRow? defaultPaymentAccount(List<PaymentAccountRow> accounts) =>
    accounts.where((a) => a.isDefault).firstOrNull ?? accounts.firstOrNull;

class PaymentAccountsRepository {
  PaymentAccountsRepository(this.db);

  final AppDatabase db;

  /// Whether only `role='owner'` may edit (the API build). The Drift build has
  /// no sign-in at all, so whoever runs it is the shop.
  bool get ownerOnly => false;

  /// The accounts in display order: `sortOrder`, then id (UUIDv7 = creation
  /// order, the server's `created_at` tie-break). Local only — never waits on
  /// the network, so checkout can read it offline.
  Future<List<PaymentAccountRow>> getAccounts() => _ordered();

  Future<List<PaymentAccountRow>> _ordered() => (db.select(db.paymentAccounts)
        ..orderBy([
          (t) => OrderingTerm.asc(t.sortOrder),
          (t) => OrderingTerm.asc(t.id),
        ]))
      .get();

  /// Fires after this repository changed the cache: a pull on login /
  /// reconnect, [getLatestAccounts], or an edit in Settings. Checkout re-reads
  /// [getAccounts] on it. A plain broadcast stream, not a Drift `watch()`,
  /// whose cancel leaves a timer pending in widget tests.
  Stream<void> get changes => _changes.stream;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @protected
  void notifyChanged() => _changes.add(null);

  /// [getAccounts] after bringing the cache up to date — for a screen that
  /// can wait on the network (Settings). The Drift build has nothing to pull.
  Future<List<PaymentAccountRow>> getLatestAccounts() => getAccounts();

  Future<PaymentAccountRow> addAccount(PaymentAccountInput input) async {
    final row = await db.transaction(() async {
        final existing = await getAccounts();
        if (existing.length >= maxPaymentAccounts) {
          throw const PosException(
            'PAYMENT_ACCOUNT_LIMIT',
            paymentAccountLimitMessage,
          );
        }
        checkPaymentAccountInput(input);
        if (input.isDefault) await _clearDefaults();
        final row = PaymentAccountRow(
          id: newUuid(),
          nickname: input.nickname.trim(),
          bankCode: input.bankCode,
          kind: input.kind,
          promptpayId: input.kind == 'promptpay' ? input.promptpayId : null,
          image: input.kind == 'image' ? input.image : null,
          imageMime: input.kind == 'image' ? input.imageMime : null,
          isDefault: input.isDefault,
          sortOrder: existing.fold<int>(-1, (m, a) => a.sortOrder > m ? a.sortOrder : m) + 1,
          updatedAt: DateTime.now(),
        );
        await db.into(db.paymentAccounts).insert(row);
        return row;
      });
    notifyChanged();
    return row;
  }

  /// Patch an account: `nickname`, `bankCode`, `promptpayId`, `image` +
  /// `imageMime`, `isDefault`, `sortOrder`. `kind` cannot change (contract §2 —
  /// delete and add again); a `kind` in [patch] is ignored. `isDefault: true`
  /// clears every other account's default.
  Future<void> updateAccount(String id, PaymentAccountsCompanion patch) async {
    await db.transaction(() async {
        final current = await (db.select(db.paymentAccounts)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (current == null) {
          throw const PosException('PAYMENT_ACCOUNT_NOT_FOUND', paymentAccountNotFoundMessage);
        }
        final merged = current.copyWithCompanion(patch.copyWith(kind: const Value.absent()));
        final error = paymentAccountError(
          nickname: merged.nickname,
          bankCode: merged.bankCode,
          kind: merged.kind,
          promptpayId: merged.promptpayId,
          image: merged.image,
          imageMime: merged.imageMime,
        );
        if (error != null) throw PosException('VALIDATION', error);
        if (merged.isDefault && !current.isDefault) await _clearDefaults();
        await (db.update(db.paymentAccounts)..where((t) => t.id.equals(id))).write(
          patch.copyWith(
            kind: const Value.absent(),
            nickname: patch.nickname.present
                ? Value(patch.nickname.value.trim())
                : const Value.absent(),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    notifyChanged();
  }

  Future<void> setDefault(String id) =>
      updateAccount(id, const PaymentAccountsCompanion(isDefault: Value(true)));

  /// Removes the account. Bills that named it keep the id; the closing report
  /// reads it as `บัญชีที่ลบแล้ว`. Deleting the default leaves no default.
  Future<void> deleteAccount(String id) async {
    await (db.delete(db.paymentAccounts)..where((t) => t.id.equals(id))).go();
    notifyChanged();
  }

  Future<void> _clearDefaults() => (db.update(db.paymentAccounts)
        ..where((t) => t.isDefault.equals(true)))
      .write(const PaymentAccountsCompanion(isDefault: Value(false)));
}

/// `400 PAYMENT_ACCOUNT_NOT_FOUND` (contract §2), also the Drift build's
/// "no such account" on an edit.
const paymentAccountNotFoundMessage =
    'ไม่พบบัญชีรับเงินที่เลือก กรุณาเลือกบัญชีใหม่'; // เจ้าของรับรอง 2026-10-10 (contract §2)

/// `404 NOT_FOUND` on an account write — the account was deleted (by another
/// device) after this screen read the list.
const paymentAccountGoneMessage =
    'ไม่พบบัญชีรับเงินนี้ อาจถูกลบไปแล้ว'; // เจ้าของรับรอง 2026-10-10

/// Throws the [paymentAccountError] for [input] as a `PosException`.
void checkPaymentAccountInput(PaymentAccountInput input) {
  final error = paymentAccountError(
    nickname: input.nickname,
    bankCode: input.bankCode,
    kind: input.kind,
    promptpayId: input.promptpayId,
    image: input.image,
    imageMime: input.imageMime,
  );
  if (error != null) throw PosException('VALIDATION', error);
}
