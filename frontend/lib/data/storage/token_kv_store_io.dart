// Non-web: no dedicated token store; SharedPreferences stays the home of the
// refresh and device tokens — see token_kv_store.dart.
import 'token_kv_store.dart';

TokenKvStore? createPlatformTokenKvStore() => null;
