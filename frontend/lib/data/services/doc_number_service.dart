// DocNumberService — local document numbering for pos device (#274, ADR-0007).
//
// In phase 2, the `pos` device issues RC/CN document numbers itself from the
// local `DocCounters` table, both online and offline (D4, E8, C2, C16).
//
// Format: `{prefix}{deviceNo:02d}-{period}-{seq:04d}`
//   e.g. `RC01-2569-09-0001` for sales (docType: 'receipt', prefix 'RC')
//        `CN01-2569-09-0001` for returns (docType: 'cn', prefix 'CN')
//
// Rules:
// - Period is derived strictly from device local clock: Buddhist Era year
//   (`year + 543`) + month zero-padded 2 digits (`YYYY-MM`), e.g. `2569-09` (C2).
// - If offline advances into a new month (new period), sequence starts at `0001` (E8).
// - Sequence reaches 9999 -> throws `DOC_NUMBER_EXHAUSTED` (never wraps to 0000 or 0001).
// - A number is committed/consumed when write succeeds (2xx) or enters outbox queue (C8).
//   If a write fails with 4xx online, the same number is reused on resend
//   (does not burn/exhaust numbers on 4xx).

import 'package:drift/drift.dart';

import '../db/database.dart';

class DocNumberException implements Exception {
  const DocNumberException(this.code, [this.message]);
  final String code;
  final String? message;

  @override
  String toString() => message ?? code;
}

class DocNumberExhaustedException extends DocNumberException {
  const DocNumberExhaustedException([String? message])
      : super('DOC_NUMBER_EXHAUSTED', message ?? 'เลขเอกสารเต็มโควตา');
}

class OfflineSeedRequiredException extends DocNumberException {
  const OfflineSeedRequiredException([String? message])
      : super(
          'OFFLINE_SEED_REQUIRED',
          message ??
              'ต้องเชื่อมต่ออินเทอร์เน็ตหนึ่งครั้งเพื่อเตรียมเลขเอกสารก่อนใช้งานออฟไลน์',
        );
}

typedef SeedMarkerMissingException = OfflineSeedRequiredException;

class ParsedDocNo {
  const ParsedDocNo({
    required this.prefix,
    required this.docType,
    required this.deviceNo,
    required this.period,
    required this.seq,
  });

  final String prefix;
  final String docType;
  final int deviceNo;
  final String period;
  final int seq;

  String get formatted =>
      '$prefix${deviceNo.toString().padLeft(2, '0')}-$period-${seq.toString().padLeft(4, '0')}';
}

class DocNumberService {
  DocNumberService({
    required this.db,
    this.clock = DateTime.now,
  });

  final AppDatabase db;
  final DateTime Function() clock;

  static const Map<String, String> _docTypeToPrefix = {
    'receipt': 'RC',
    'cn': 'CN',
    'po': 'PO',
    'quote': 'QT',
    'cp': 'CP',
  };

  static const Map<String, String> _prefixToDocType = {
    'RC': 'receipt',
    'CN': 'cn',
    'PO': 'po',
    'QT': 'quote',
    'CP': 'cp',
  };

  static final RegExp _docNoPattern =
      RegExp(r'^([A-Z]{2})(\d{2})-(\d{4}-\d{2})-(\d{4})$');

  /// Maps docType (e.g. 'receipt', 'cn') or uppercase prefix ('RC', 'CN')
  /// to uppercase 2-letter prefix ('RC', 'CN').
  static String prefixForDocType(String docType) {
    final lower = docType.toLowerCase();
    if (_docTypeToPrefix.containsKey(lower)) {
      return _docTypeToPrefix[lower]!;
    }
    final upper = docType.toUpperCase();
    if (_prefixToDocType.containsKey(upper)) {
      return upper;
    }
    throw ArgumentError('Unsupported docType: $docType');
  }

  /// Maps docType or prefix to canonical database doc_type ('receipt', 'cn', etc.).
  static String normalizeDocType(String docType) {
    final lower = docType.toLowerCase();
    if (_docTypeToPrefix.containsKey(lower)) {
      return lower;
    }
    final upper = docType.toUpperCase();
    if (_prefixToDocType.containsKey(upper)) {
      return _prefixToDocType[upper]!;
    }
    throw ArgumentError('Unsupported docType: $docType');
  }

  /// Formats the local clock [dt] into Buddhist Era year-month: `YYYY-MM`.
  ///
  /// Period is derived strictly from device local clock: Buddhist Era year
  /// (`year + 543`) + month zero-padded to 2 digits (e.g. `2569-09`).
  static String formatPeriod(DateTime dt) {
    final local = dt.toLocal();
    final beYear = local.year + 543;
    final month = local.month.toString().padLeft(2, '0');
    return '$beYear-$month';
  }

  /// Parses a formatted document number string (e.g. `RC01-2569-09-0042`).
  static ParsedDocNo parseDocNo(String docNo) {
    final match = _docNoPattern.firstMatch(docNo);
    if (match == null) {
      throw FormatException('Invalid document number format: $docNo');
    }
    final prefix = match.group(1)!;
    final deviceNo = int.parse(match.group(2)!);
    final period = match.group(3)!;
    final seq = int.parse(match.group(4)!);

    if (deviceNo < 1 || deviceNo > 99) {
      throw FormatException('deviceNo in docNo must be 01..99: $docNo');
    }
    if (seq < 1 || seq > 9999) {
      throw FormatException('seq in docNo must be 0001..9999: $docNo');
    }

    final docType = _prefixToDocType[prefix] ?? prefix.toLowerCase();
    return ParsedDocNo(
      prefix: prefix,
      docType: docType,
      deviceNo: deviceNo,
      period: period,
      seq: seq,
    );
  }

  /// Checks whether a valid seed record exists in [DocCounterSeeds] for [deviceId]
  /// and optionally [period].
  ///
  /// If [period] is omitted, checks if at least one seed record exists for [deviceId].
  Future<bool> hasSeedMarker({
    required String deviceId,
    String? period,
  }) async {
    final query = db.select(db.docCounterSeeds)
      ..where((t) {
        final matchDevice = t.deviceId.equals(deviceId);
        if (period != null) {
          return matchDevice & t.period.equals(period);
        }
        return matchDevice;
      })
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row != null;
  }

  /// Asserts that a valid seed record exists in [DocCounterSeeds] for [deviceId]
  /// and [period] (#189).
  ///
  /// Throws [OfflineSeedRequiredException] if no seed marker exists for the period.
  Future<void> ensureSeedMarker({
    required String deviceId,
    String? period,
    DateTime? now,
  }) async {
    final p = period ?? formatPeriod(now ?? clock());
    final seeded = await hasSeedMarker(deviceId: deviceId, period: p);
    if (!seeded) {
      throw const OfflineSeedRequiredException();
    }
  }

  /// Records a seed marker in [DocCounterSeeds] for [deviceId] and [period].
  Future<void> recordSeedMarker({
    required String deviceId,
    required String period,
    DateTime? seededAt,
  }) async {
    await db.into(db.docCounterSeeds).insertOnConflictUpdate(
          DocCounterSeedsCompanion.insert(
            deviceId: deviceId,
            period: period,
            seededAt: seededAt ?? clock(),
          ),
        );
  }

  /// Deletes seed markers for [deviceId], or all markers if [deviceId] is null.
  Future<void> clearSeedMarkers({String? deviceId}) async {
    if (deviceId != null) {
      await (db.delete(db.docCounterSeeds)
            ..where((t) => t.deviceId.equals(deviceId)))
          .go();
    } else {
      await db.delete(db.docCounterSeeds).go();
    }
  }

  /// Calculates the next candidate document number for the device and docType
  /// based on local clock and [DocCounters].
  ///
  /// If [isOffline] is true, verifies that a seed marker exists in [DocCounterSeeds]
  /// for `(deviceId, period)` (#189), throwing [OfflineSeedRequiredException] if absent.
  ///
  /// 🔴 Does NOT write or consume the number in the database:
  /// A document number is committed/consumed only when write succeeds (2xx)
  /// or enters outbox queue (C8). If a write fails with 4xx online, the same
  /// number is reused on resend (does not burn/exhaust numbers on 4xx).
  ///
  /// Throws [DocNumberExhaustedException] (`DOC_NUMBER_EXHAUSTED`) when sequence
  /// reaches 9999 (i.e. `lastNo >= 9999`), never wrapping around to 0000 or 0001.
  Future<String> generateNextDocNo({
    required String deviceId,
    required int deviceNo,
    required String docType,
    DateTime? now,
    bool isOffline = false,
  }) async {
    if (deviceNo < 1 || deviceNo > 99) {
      throw ArgumentError('deviceNo must be between 1 and 99, got $deviceNo');
    }
    final normalizedType = normalizeDocType(docType);
    final prefix = prefixForDocType(docType);
    final dt = now ?? clock();
    final period = formatPeriod(dt);

    if (isOffline) {
      await ensureSeedMarker(deviceId: deviceId, period: period);
    }

    final row = await (db.select(db.docCounters)
          ..where((t) =>
              t.deviceId.equals(deviceId) &
              t.docType.equals(normalizedType) &
              t.period.equals(period)))
        .getSingleOrNull();

    final lastNo = row?.lastNo ?? 0;
    if (lastNo >= 9999) {
      throw const DocNumberExhaustedException();
    }

    final seq = lastNo + 1;
    final devStr = deviceNo.toString().padLeft(2, '0');
    final seqStr = seq.toString().padLeft(4, '0');
    return '$prefix$devStr-$period-$seqStr';
  }

  /// Commits a sequence number into [DocCounters] for `(deviceId, docType, period)`.
  ///
  /// Uses SQLite `ON CONFLICT ... DO UPDATE SET last_no = MAX(last_no, excluded.last_no)`
  /// to ensure the high-water mark monotonically advances.
  Future<void> commitDocNo({
    required String deviceId,
    required int deviceNo,
    required String docType,
    required String period,
    required int seq,
  }) async {
    if (deviceNo < 1 || deviceNo > 99) {
      throw ArgumentError('deviceNo must be between 1 and 99, got $deviceNo');
    }
    if (seq < 1 || seq > 9999) {
      throw ArgumentError('seq must be between 1 and 9999, got $seq');
    }
    final normalizedType = normalizeDocType(docType);

    await db.customInsert(
      'INSERT INTO doc_counters '
      '(device_id, device_no, doc_type, period, last_no) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT (device_id, doc_type, period) '
      'DO UPDATE SET last_no = MAX(last_no, excluded.last_no)',
      variables: [
        Variable.withString(deviceId),
        Variable.withInt(deviceNo),
        Variable.withString(normalizedType),
        Variable.withString(period),
        Variable.withInt(seq),
      ],
      updates: {db.docCounters},
    );
  }

  /// Commits a formatted document number string (e.g. `RC01-2569-09-0001`).
  Future<void> commitDocNoString({
    required String deviceId,
    required String docNo,
    int? deviceNo,
    String? docType,
  }) async {
    final parsed = parseDocNo(docNo);
    await commitDocNo(
      deviceId: deviceId,
      deviceNo: deviceNo ?? parsed.deviceNo,
      docType: docType ?? parsed.docType,
      period: parsed.period,
      seq: parsed.seq,
    );
  }

  /// Generates the next candidate document number and commits it immediately.
  /// Used when queueing directly into offline outbox.
  Future<String> issueAndCommit({
    required String deviceId,
    required int deviceNo,
    required String docType,
    DateTime? now,
    bool isOffline = false,
  }) async {
    final docNo = await generateNextDocNo(
      deviceId: deviceId,
      deviceNo: deviceNo,
      docType: docType,
      now: now,
      isOffline: isOffline,
    );
    final parsed = parseDocNo(docNo);
    await commitDocNo(
      deviceId: deviceId,
      deviceNo: deviceNo,
      docType: docType,
      period: parsed.period,
      seq: parsed.seq,
    );
    return docNo;
  }

  /// Returns the current lastNo recorded in [DocCounters] for `(deviceId, docType, period)`.
  /// Returns 0 if no counter row exists.
  Future<int> getLastNo({
    required String deviceId,
    required String docType,
    String? period,
    DateTime? now,
  }) async {
    final normalizedType = normalizeDocType(docType);
    final p = period ?? formatPeriod(now ?? clock());
    final row = await (db.select(db.docCounters)
          ..where((t) =>
              t.deviceId.equals(deviceId) &
              t.docType.equals(normalizedType) &
              t.period.equals(p)))
        .getSingleOrNull();
    return row?.lastNo ?? 0;
  }
}
