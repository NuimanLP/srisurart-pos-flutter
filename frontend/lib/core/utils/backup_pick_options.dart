// The WebOptions the backup-restore file pick passes to file_picker. Split
// because FilePickerWebOptions (file_picker_web) imports dart:js_interop.
export 'backup_pick_options_io.dart'
    if (dart.library.js_interop) 'backup_pick_options_web.dart';
