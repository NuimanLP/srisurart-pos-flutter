# Research: PWA offline shell for the Flutter Web client

Ticket: [#241](https://github.com/NuimanLP/srisurart-pos-flutter/issues/241) (map: #243, owner decisions: #240 D2/D10).
Question: how does the Flutter Web POS client open and reload with **no network**, served by our own
nginx, precaching the app shell + `sqlite3.wasm` + `drift_worker.js` + CanvasKit/fonts, with a safe
update strategy and a single-writer guarantee (Web Locks)?

Grounded against this repo at commit `8e873cd` (2026-09-15):
`frontend/pubspec.yaml` (Flutter env `^3.12.2` SDK constraint; CI pins **Flutter 3.44.3**,
`.github/workflows/flutter.yml`), `frontend/web/` (`index.html`, `manifest.json`, `sqlite3.wasm`,
`drift_worker.js` — no service worker file committed), `frontend/lib/data/db/database.dart`
(`AppDatabase.open()` / `DriftWebOptions`), `server/docker/nginx/nginx.conf`, `deploy/web.Dockerfile`.
Locally built `frontend/build/web/` (already present in the working tree, not committed) was also
inspected directly — it is the most concrete evidence available, since it is *this* app's own Flutter
3.44.3 output, not a blog post's.

## 1. Flutter Web's built-in service worker is gone, not merely deprecated

Flutter's own `flutter_service_worker.js` generation ended; the file the toolchain now emits is a
**self-unregistering tombstone**, not a cache. Verified two ways:

- **Primary source, official docs**: `docs.flutter.dev/platform-integration/web/initialization` states
  plainly: *"Flutter no longer generates a service worker by default; see the [Web FAQ]"* — and the FAQ's
  answer is: *"If your application requires offline support or advanced caching, you need to configure a
  service worker yourself using standard web tooling or third-party solutions such as Workbox."*
  (https://docs.flutter.dev/platform-integration/web/initialization,
  https://docs.flutter.dev/platform-integration/web/faq)
- **Primary source, engine issue**: `flutter/flutter#156910` *"[web] Deprecate and remove
  `flutter_service_worker.js`"* — the plan was a two-step migration: ship a "cleanup" service worker that
  unregisters itself on activate, then stop generating any service worker at all.
  (https://github.com/flutter/flutter/issues/156910;
  design doc referenced there: `flutter.dev/go/web-cleanup-service-worker`)
- **Empirical, this repo's own build**: `frontend/build/web/flutter_service_worker.js` (built locally with
  the pinned Flutter 3.44.3) is exactly the tombstone — 31 lines, `self.skipWaiting()` on install, then on
  activate it calls `self.registration.unregister()` and navigates every open client. No `RESOURCES`
  manifest, no `caches.open`, no `fetch` handler. **This confirms the repo's pinned Flutter version is
  already past the removal — there is nothing to "turn on"; a PWA shell must be built from scratch.**

**Conclusion for #241**: we are not configuring `--pwa-strategy` (that flag controlled the *old* default
worker's behavior and is moot now that the worker does nothing). We must write and own a custom service
worker, registered by our own script, exactly as `docs.flutter.dev`'s FAQ says.

## 2. What must be precached, and a CDN trap that affects this app specifically

`_flutter.loader.load()` is the modern bootstrap entry point (`flutter_bootstrap.js`, replacing the
deprecated `loadEntrypoint()` / `serviceWorkerVersion` global) — confirmed on
`docs.flutter.dev/platform-integration/web/initialization`.

Precache candidates, confirmed against this repo's actual build output:

| Asset | Where it lives today | Notes |
|---|---|---|
| App shell (`index.html`, `flutter.js`, `flutter_bootstrap.js`, `main.dart.js`, `assets/`) | `frontend/build/web/` | Standard Flutter output |
| `sqlite3.wasm`, `drift_worker.js` | `frontend/web/` (committed), copied into `build/web/` | drift's own docs: *"Web browsers don't have builtin access to the sqlite3 library... You can grab a prebuilt `sqlite3.wasm` file from drift releases on GitHub, or compile it yourself... put into the `web/` directory"* and *"Drift on the web requires you to include a portion of drift as a web worker... used to host your database in a background thread... also responsible for sharing your database between different tabs"* (https://drift.simonbinder.eu/platforms/web/). 🔴 **Version-pinned, not evergreen** — CLAUDE.md already warns these two files must match the resolved `drift`/`sqlite3` pub versions or the web DB fails at boot with no visible error. `pubspec.lock` currently resolves `sqlite3: 3.4.0` / `drift: 2.34.1`; CLAUDE.md's migration-status note says the committed `sqlite3.wasm` matches pub `3.3.3` — **that note may already be stale relative to `pubspec.lock`** (out of scope here; flagging as an open question below since a PWA precache manifest that hashes a mismatched asset makes the mismatch silent for even longer). |
| CanvasKit / Skwasm (`canvaskit/*.wasm`, `*.js`) | `frontend/build/web/canvaskit/` **is built locally**, but `flutter_bootstrap.js` and `flutter.js` still hard-code `https://www.gstatic.com/flutter-canvaskit` as the default `canvasKitBaseUrl` (confirmed by grepping the built `flutter_bootstrap.js`: `...e.engineRevision&&!e.useLocalCanvasKit?I("https://www.gstatic.com/flutter-canvaskit",...)`). 🔴 **This is a real offline-breaker for the current build command.** `flutter build web --no-tree-shake-icons` (the command in CLAUDE.md and CI) does **not** disable the CDN. The flag needed is `--no-web-resources-cdn` (default: on) — a maintainer-authored PR description states it *"will use the locally built CanvasKit instead of using the CDN"* and community docs describe it as `flutter build web --no-web-resources-cdn ...` pulling CanvasKit "from the /canvaskit directory" (https://github.com/flutter/flutter/pull/122772; corroborated by `flutter/flutter#148713` "ignores the `-no-web-resources-cdn` config" — a regression report, meaning the flag is real and has had reliability issues across Flutter versions, so it must be verified against 3.44.3 specifically, not assumed from older threads). |
| Fonts (`google_fonts` runtime fetch) | Not bundled — CLAUDE.md's own backlog already flags this: *"bundle Sarabun/Barlow fonts as assets (currently `google_fonts` runtime fetch...)"* | 🔴 **`--no-web-resources-cdn` does not fix this.** `flutter/flutter#163554` *"Flutter web still loads fonts.gstatic.com with `--no-web-resources-cdn`"* (open, P2, reproduced on Flutter 3.29/3.30) is a **different code path**: `google_fonts` is a Dart package that makes its own `http` calls to `fonts.googleapis.com`/`fonts.gstatic.com` at runtime, independent of the engine's CanvasKit-CDN logic that the build flag controls. A service worker can be taught to cache those specific cross-origin responses after a first successful online load (a `StaleWhileRevalidate`/`CacheFirst` route keyed to the Google Fonts origins), but that is strictly worse than what CLAUDE.md already recommends: **bundling Sarabun/Barlow as local `pubspec.yaml` font assets** removes the network dependency (and the CORS/opaque-response complexity of cross-origin caching) entirely. This ticket should treat "bundle fonts locally" as a **prerequisite** for a true no-network PWA shell, not an optional Phase 8a nice-to-have. |

**Minimal safe build command for a genuinely offline-capable web build**, based on the above:
`flutter build web --no-tree-shake-icons --no-web-resources-cdn` (still needs verification against
3.44.3 in CI — see Open Questions).

## 3. Update strategy — versioning, `skipWaiting`, prompt-to-reload

The current shop deployment model (per CLAUDE.md/CI) is: a green `main` push builds `build/web`, packages
it into the `srisurart-pos-web` GHCR image, and (per the pending Ansible work, #65) that image's contents
land in the nginx-served volume. A stale cached shell talking to a newer API is a real risk once a service
worker is introduced (it wasn't previously, because there was no caching at all).

Primary-source guidance on the update lifecycle, from Chrome's own Workbox documentation
(https://developer.chrome.com/docs/workbox/service-worker-lifecycle):

- *"You can speed up activation of updated service workers by calling `self.skipWaiting`, but this may be
  a bad idea"* — an old worker may still be answering requests for already-open tabs' subresources while a
  new one takes over, which can break in-flight loads. The article's own recommended default is to let a
  new worker sit in `waiting` until every tab controlled by the old one closes.
- For a long-lived single-page app (which the POS is — the cashier does not close the tab all shift), the
  doc's alternative is **explicit, user-visible prompting**: detect the `waiting` worker (via the
  registration's `updatefound`/`statechange` events), show a "รุ่นใหม่พร้อมแล้ว — โหลดใหม่?" banner, and only
  call `skipWaiting` (via `postMessage`) when the person acts, followed by a `controllerchange`-triggered
  `location.reload()`. This is the standard "prompt to update" pattern implemented by tools like
  `workbox-window`'s `Workbox.messageSkipWaiting()` + `waiting` event, and is the safer fit for a
  till that must not silently reload mid-sale.
- **Versioning the cache**: every release must use a **content-hashed or build-`sha`-keyed cache name**
  (e.g. `srisurart-shell-<git-sha>`) so `activate` can enumerate and delete old cache names — this is
  standard Workbox/`sw-precache` practice, not something Flutter or drift prescribes; CI already has a
  natural version key (`github.sha`, already used for the GHCR image tag), which the build step can inject
  into the service worker as a precache-manifest version.
- **HTTP caching of `sw.js` itself must not fight the update check.** Chrome for Developers:
  *"Starting in Chrome 68, HTTP requests that check for updates to the service worker script will no
  longer be fulfilled by the HTTP cache by default"* (https://developer.chrome.com/blog/fresher-sw) — so
  Chrome already bypasses the disk cache for the *byte-diff* check every ~24h/on navigation. Community and
  MDN guidance is still to be explicit and set `Cache-Control: no-cache` (or `max-age=0`) on `sw.js` at the
  server, because (a) other browsers and proxies are not guaranteed to match Chrome's special-case, and
  (b) it makes an update visible immediately on the next load rather than waiting for Chrome's internal
  24-hour re-check window.

## 4. `navigator.storage.persist()` and eviction risk

MDN, `Storage_API/Storage_quotas_and_eviction_criteria` (https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria):

- Chrome's default storage is **"best-effort"**: subject to **LRU eviction** under two conditions — global
  disk pressure (Chrome caps itself at **~80% of total disk size** across all origins) or, less commonly,
  an individual origin's own quota.
- **`navigator.storage.persist()`** (MDN, `StorageManager/persist`) moves the origin's storage bucket to
  **"persistent" mode, which is exempt from that automatic LRU eviction** — it is then deleted only by an
  explicit user action (clearing site data) or the user running out of disk entirely.
- For a daily-used, single-origin shop-PC deployment this matters concretely: the Drift SQLite database
  lives in OPFS/IndexedDB per `AppDatabase.open()`'s `DriftWebOptions`, and losing it silently to LRU
  eviction (e.g., because the browser profile also visits many other sites, or disk fills up) would be a
  **data-loss event indistinguishable from corruption** unless the app calls `persist()` at first run and
  ideally surfaces `navigator.storage.persisted()`'s answer somewhere (or logs it) so a "not persisted" shop
  PC is a known, fixable state rather than a silent risk.
- Chrome does **not** prompt the user for `persist()` on most heuristics (unlike Firefox, which shows a
  permission prompt) — Chrome grants it based on site-engagement heuristics; a PWA that's been
  **installed** (added to home screen / launched from an OS shortcut) is one of the strongest signals
  Chrome uses. This is a second reason installability (`manifest.json`, already present in this repo)
  matters for the offline-shell ticket, beyond the "opens with no network" requirement itself — it's also
  what makes `persist()` reliably succeed.

## 5. Web Locks API for a single outbox writer (decision D10)

MDN, `Web_Locks_API` (https://developer.mozilla.org/en-US/docs/Web/API/Web_Locks_API) and
`Lock`/`LockManager` pages:

- **Baseline / widely available** — supported across browsers since March 2022; requires a secure context
  (HTTPS), which the demo VM already has (nginx TLS termination, `server/docker/nginx/nginx.conf`).
- The **leader-election pattern is the documented, canonical use case**: *"if a web app running in multiple
  tabs wants to ensure that only one tab is syncing data between the network and IndexedDB, each tab could
  try to acquire a `my_net_db_sync` lock, but only one tab will succeed."*
- API shape: `navigator.locks.request("name", async lock => { ...work... })` — the lock auto-releases when
  the async callback returns; a second tab's `request()` call for the same name simply queues (or, in
  non-blocking mode via `{ ifAvailable: true }`, returns immediately with `lock === null` if unavailable —
  this is the primitive for "other tabs show 'already open'" from D10, rather than making them wait
  forever).
- **Scope**: locks are per-origin, so this composes cleanly with same-origin serving (nginx serves both API
  and web client at the same origin per `nginx.conf`'s comment *"same origin as the API, so no CORS at
  q1"*) — no cross-origin lock coordination is needed.
- **Caveat for Flutter specifically**: this is a raw Web API with no first-party Flutter/Dart wrapper in
  this repo's dependencies today; it would be called via `dart:js_interop` (`package:web`, already a
  dependency — `web: ^1.1.1` in `pubspec.yaml` — bindings for `Navigator.locks` should be checked against
  that package's current coverage before committing to an approach; not verified in this research pass).
  A lock held by a closed/crashed tab is released automatically by the browser (this is inherent to the
  Web Locks spec design — the lock lives with the browsing context, not a JS-level heartbeat) so D10's
  "single tab" does not need a manual liveness/heartbeat protocol on top.

## 6. nginx configuration implications

Cross-referencing `server/docker/nginx/nginx.conf` (already read) against the primary sources above:

- **`sw.js` must be served with `Cache-Control: no-cache` (or `max-age=0`)** — not currently addressed by
  `nginx.conf`'s `location /` block (`try_files $uri $uri/ /index.html;`, no per-file cache headers at
  all). A location block specifically for the service-worker script is needed.
- **`Service-Worker-Allowed` header is only needed if the service worker's scope must be broader than its
  own directory** (MDN, `Service-Worker-Allowed`). Since this app serves everything from `/` already
  (`nginx.conf`'s `location /` root is `/usr/share/nginx/html`, i.e. the web client owns the whole path
  space at that origin — API traffic is carved out under `/api/`), a service worker script placed at
  `/sw.js` registered with `{ scope: '/' }` gets the widest scope **by default**, matching its own
  directory — so `Service-Worker-Allowed` is **not needed** for this app's topology (it would only become
  necessary if the SW script were nested under a subpath but still needed to control `/`).
- **HTTPS is required** — service workers (and the Web Locks API, per MDN) are both gated on a **secure
  context**. `nginx.conf` already terminates TLS (`listen 443 ssl`) and redirects HTTP → HTTPS
  (`return 301 https://$host$request_uri`), so this requirement is already satisfied by the existing
  compose stack. The self-signed cert on the demo VM (CLAUDE.md/07_CICD_DEPLOY.md territory, not re-verified
  here) needs to be trusted by the shop PC's browser for `navigator.serviceWorker.register()` to succeed at
  all — an untrusted cert fails TLS before the service worker registration is even attempted, which is a
  deployment prerequisite, not a code change.
- **MIME types** — `nginx.conf` already includes `/etc/nginx/mime.types` with a comment explaining this was
  added specifically because `.js`/`.wasm` need correct types to boot at all; the same block already covers
  a service worker script (`.js`) and any `.wasm` it might reference.

## Recommendation

1. Write a **hand-authored service worker** (no Workbox build-step dependency required, but Workbox's
   `workbox-window` client-side helper is worth using for the update-prompt plumbing — it's a small,
   well-documented library and the official FAQ names it as the intended replacement path). It precaches:
   the Flutter app shell (`index.html`, `flutter.js`, `flutter_bootstrap.js`, `main.dart.js`, `assets/**`),
   `sqlite3.wasm`, `drift_worker.js`, and the local `canvaskit/**` files — **contingent on confirming
   `--no-web-resources-cdn` actually stops the CDN reference in Flutter 3.44.3** (see Open Questions).
2. **Bundle Sarabun/Barlow as local font assets** (CLAUDE.md Phase 8a item) as a prerequisite, not a
   parallel task — it's the only clean fix for the `google_fonts` runtime-fetch offline gap; caching
   Google's font CDN via the service worker is a strictly worse fallback.
3. Build the update flow as: cache **versioned by `github.sha`** → new worker installs and precaches →
   waits → **client shows a "โหลดเวอร์ชันใหม่?" banner** → user-triggered `skipWaiting` +
   `controllerchange` → `location.reload()`. Never auto-`skipWaiting` on install for this app (till mid-sale
   risk).
4. Call `navigator.storage.persist()` on first successful boot (ties into PWA installability, which also
   improves the odds Chrome grants it) and log/surface `navigator.storage.persisted()` so a non-persisted
   shop PC is diagnosable.
5. Implement D10's single-tab rule with `navigator.locks.request('srisurart-outbox-writer', {ifAvailable:
   true}, cb)` — non-blocking so a second tab can detect "already open" immediately instead of hanging.
6. Add nginx `location = /sw.js { add_header Cache-Control "no-cache"; ... }` (or equivalent) to
   `server/docker/nginx/nginx.conf`. `Service-Worker-Allowed` is not needed given this app's `/`-scoped
   topology.

### Minimal file list to add/change (not implemented here)

- `frontend/web/sw.js` — new, hand-authored service worker (precache list + versioned cache name + message
  handler for `SKIP_WAITING`).
- `frontend/web/index.html` — register the worker (small inline script or via `flutter_bootstrap.js`
  customization per `docs.flutter.dev/platform-integration/web/initialization`'s documented extension
  points).
- `frontend/lib/` — a small Dart/JS-interop wrapper: (a) update-available banner state (Cubit, matching this
  repo's existing `flutter_bloc` architecture), (b) `navigator.storage.persist()` call at boot, (c) the
  Web Locks single-tab check (D10), (d) local Sarabun/Barlow font assets wired into `pubspec.yaml`
  (replacing the `google_fonts` runtime fetch — or gating it as a fallback only).
- `frontend/pubspec.yaml` — add local font asset declarations; audit `google_fonts` usage.
- `.github/workflows/flutter.yml` — `build-web` step: add `--no-web-resources-cdn` to the `flutter build
  web` invocation, and extend the existing "check web DB assets shipped" step to also assert `sw.js` and
  `canvaskit/` are present in `build/web` (mirroring the existing `sqlite3.wasm`/`drift_worker.js` check).
- `server/docker/nginx/nginx.conf` — add the `sw.js` `Cache-Control` header block.

## Risks

1. **`--no-web-resources-cdn` reliability is not yet verified against Flutter 3.44.3 specifically.**
   `flutter/flutter#148713` documents a past regression where the flag was silently ignored after a
   version bump (3.22). The flag's effect must be checked empirically (grep the built `flutter_bootstrap.js`
   for `gstatic.com`, exactly as done in this research pass) as part of implementation, not assumed to work
   from the flag's existence alone.
2. **`google_fonts` runtime fetch is an orthogonal, currently-open gap** (`flutter/flutter#163554`, still
   open/unfixed as of this research) that the CDN flag does not close. If font-bundling isn't done first,
   the PWA "opens with no network" requirement is not actually met on first offline load after any font
   change, and is fragile even after a successful online load (depends on the SW's cross-origin runtime-cache
   route working correctly, including CORS behavior for opaque responses).
3. **Cache/version skew between the precached asset manifest and the actual served build.** This app
   already has one historical instance of this exact failure mode (CLAUDE.md flags `sqlite3.wasm`/
   `drift_worker.js` needing to be re-downloaded on every `drift`/`sqlite3` pub bump, "a version skew breaks
   the web DB at boot" with no visible error) — a PWA service worker adds a *second* layer where a stale
   cache can serve an old `main.dart.js` against a new API contract, compounding rather than replacing that
   risk unless cache versioning is tied to the same release identity (`github.sha`) as the image tag.

## Open questions for the owner

1. Should the service worker ship inside `deploy/web.Dockerfile`'s static artifact (built by `flutter
   build web`, so it's versioned with everything else), or is it maintained by hand outside the Flutter
   build pipeline? (Recommendation above assumes it's a static file dropped into `frontend/web/`, built as
   part of the normal `flutter build web` step — no separate pipeline.)
2. Confirm scope: should `navigator.storage.persist()` / the update-prompt banner / Web Locks be one
   ticket or three? They're independent enough to parallelize but the update-prompt banner needs the Thai
   wording the CLAUDE.md backlog already says is still owed by the shop ("queued/sending, red banner,
   degraded banner..." — this ticket adds "โหลดเวอร์ชันใหม่หรือไม่?" or equivalent to that list).
3. Is bundling Sarabun/Barlow as local assets (this doc's recommendation #2) accepted as an explicit
   **prerequisite** for #241/#243, or should the offline shell ship first with a known gap (fonts still
   require one successful online load) and fonts tracked separately as Phase 8a already has it?
4. `sqlite3.wasm`'s pinned-version note in CLAUDE.md (pub `3.3.3`) versus `pubspec.lock`'s currently
   resolved `sqlite3: 3.4.0` — is that already a drift (no pun intended) that predates this ticket and needs
   its own fix, or was the CLAUDE.md note simply never updated after a later bump? Worth confirming before
   the PWA precache manifest locks in whichever `sqlite3.wasm` is currently committed.

## Sources

- https://docs.flutter.dev/platform-integration/web/initialization
- https://docs.flutter.dev/platform-integration/web/faq
- https://github.com/flutter/flutter/issues/156910
- https://drift.simonbinder.eu/platforms/web/
- https://github.com/flutter/flutter/pull/122772
- https://github.com/flutter/flutter/issues/148713
- https://github.com/flutter/flutter/issues/163554
- https://developer.chrome.com/docs/workbox/service-worker-lifecycle
- https://developer.chrome.com/blog/fresher-sw
- https://developer.mozilla.org/en-US/docs/Web/API/Web_Locks_API
- https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria
- https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/persist
- https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Service-Worker-Allowed
- Empirical: `frontend/build/web/flutter_service_worker.js`, `frontend/build/web/flutter_bootstrap.js`,
  `frontend/build/web/canvaskit/` (this repo's own Flutter 3.44.3 output, inspected directly in this
  research pass)
