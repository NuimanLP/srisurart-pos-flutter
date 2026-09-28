// Custom bootstrap: load() is called WITHOUT serviceWorkerSettings on purpose.
// Flutter's default template passes them, which makes the loader register the
// deprecated flutter_service_worker.js at our scope; that worker replaces sw.js
// (index.html, 08 §4 item 6), unregisters itself on activate and navigates every
// tab — the POS reloaded 4 times per open and never kept sw.js installed.
{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load();
