// Port of csvSafe from pos/db.js (SEC-002 — CSV formula injection).
//
// JS source:
//   const csvSafe = (v) => {
//     let s = String(v == null ? '' : v);
//     if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
//     return s;
//   };
//
// Prefixes a single quote when the stringified value starts with one of
// = + - @ TAB CR so Excel/Sheets treat it as text, not a formula.
// Every CSV exporter MUST run values through this before quote-escaping.

const _triggers = {'=', '+', '-', '@', '\t', '\r'};

String csvSafe(Object? v) {
  final s = v == null ? '' : v.toString();
  if (s.isNotEmpty && _triggers.contains(s[0])) {
    return "'$s";
  }
  return s;
}
