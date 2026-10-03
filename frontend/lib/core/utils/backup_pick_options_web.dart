// Web half of backup_pick_options.dart. file_picker_web imports dart:js_interop,
// so it may only be reached through the conditional export in
// backup_pick_options.dart.
import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';

// withData (default true) keeps the picked bytes in memory. No window-blur
// cancel: its focus heuristic can drop a slow (iCloud) pick as a cancel.
const WebOptions backupPickWebOptions = FilePickerWebOptions(
  cancelUploadOnWindowBlur: false,
);
