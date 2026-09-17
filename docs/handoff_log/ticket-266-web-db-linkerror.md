# #266: Web DB `xFileControl` LinkError in Browsers Without `dedicatedWorkersInSharedWorkers` (2026-09-17)

**Issue:** #266 · **Parent / Predecessor:** #245 · **Unblocks:** #241 (PWA precache manifest)

---

## 1. Problem & Root Cause

When the Flutter web app boots in a browser environment lacking `dedicatedWorkersInSharedWorkers` (e.g. sandboxed Chrome/Chromium, Edge, or webviews without nested worker support), Drift falls back from OPFS to `WasmStorageImplementation.sharedIndexedDb` or `WasmStorageImplementation.opfsLocks` via `frontend/web/drift_worker.js`.

During worker initialization, `drift_worker.js` calls `WebAssembly.instantiateStreaming(a, p.jT())` to load `frontend/web/sqlite3.wasm`.

With `sqlite3` 3.4.0:
- The compiled `sqlite3.wasm` binary defines 31 imports under module `"dart"`.
- Import #10 is `{ module: 'dart', name: 'xFileControl', kind: 'function' }` (introduced with SQLite 3.53.3 and `VirtualFileSystemFileV1` hooks).
- In `frontend/web/drift_worker.js`, `p.jT().dart` is constructed in `A.lI.prototype.$0()` by attaching VFS callback stubs (`q.xOpen`, `q.xClose`, `q.xRead`, `q.xWrite`, `q.xCheckReservedLock`, `q.xDeviceCharacteristics`, etc.).
- `drift` 2.34.1's compiled worker lacked a mapping for `xFileControl` on `q`.
- As a result, `s.dart.xFileControl` was `undefined`, causing the WebAssembly engine to throw:
  ```
  LinkError: WebAssembly.instantiate(): Import #10 "dart" "xFileControl": function import requires a callable
  ```
- The Web DB never initialized, leaving the app indefinitely hanging or erroring on boot.

---

## 2. Fix

In `frontend/web/drift_worker.js`:
- In `A.lI.prototype.$0`, added the missing callable stub for `xFileControl`:
  ```javascript
  q.xCheckReservedLock=A.b8(s.glc())
  q.xFileControl=function(file,op,pArg){return 12}
  q.xDeviceCharacteristics=A.bu(s.gcl())
  ```
- In the SQLite VFS specification, `xFileControl(sqlite3_file *pFile, int op, void *pArg)` returns `int`. When the VFS does not recognize or support an opcode, it must return `SQLITE_NOTFOUND` (value `12`), which signals SQLite to use default behavior.
- No version changes to `sqlite3` or `drift` were needed; `frontend/web/WEB_DB_ASSET_VERSIONS.txt` and `frontend/pubspec.lock` remain identically matched at `sqlite3=3.4.0` and `drift=2.34.1`.

---

## 3. Verification

1. **JavaScript Syntax Verification**:
   - Ran `node -c frontend/web/drift_worker.js` — zero syntax errors.
2. **WebAssembly Module & Linker Verification**:
   - Inspected `sqlite3.wasm` WebAssembly imports: confirmed 31 required function imports in `"dart"`, with `xFileControl` at index 10.
   - Tested instantiation without `xFileControl`: reproduced exact `LinkError: WebAssembly.Instance(): Import #10 module="dart" function="xFileControl" error: function import requires a callable`.
   - Tested instantiation with `xFileControl = function(file, op, pArg) { return 12; }`: cleanly instantiated 86 WebAssembly exports without LinkError.
3. **CI Version Gate Compliance**:
   - Verified that `frontend/web/WEB_DB_ASSET_VERSIONS.txt` (`sqlite3=3.4.0`, `drift=2.34.1`) matches `frontend/pubspec.lock` (`sqlite3: 3.4.0`, `drift: 2.34.1`). The `.github/workflows/flutter.yml` asset version check passes cleanly.
4. **Scope Hygiene**:
   - Did not touch any database schema files or files assigned to #272 (`frontend/lib/data/db/*`, etc.).
