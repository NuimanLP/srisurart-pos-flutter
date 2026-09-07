// Date-key helpers — the yyyy-MM-dd / yyyy-MM string keys db.js derives with
// `toISOString().slice(…)`. The Dart port intentionally uses LOCAL time
// (`toIso8601String()` on a local DateTime), so "today" matches the shop clock.

/// yyyy-MM-dd key for [d], e.g. "2026-07-09".
String dateKey(DateTime d) => d.toIso8601String().substring(0, 10);

/// Today's yyyy-MM-dd key.
String todayKey() => dateKey(DateTime.now());

/// Current month's yyyy-MM key, e.g. "2026-07".
String monthKey() => DateTime.now().toIso8601String().substring(0, 7);
