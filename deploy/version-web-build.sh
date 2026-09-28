#!/bin/sh
# Give a Flutter web build a per-release entry point (07_CICD_DEPLOY.md §6, web-sync).
#
#   version-web-build.sh <build/web dir> <release id, e.g. the short commit SHA>
#
# Flutter names its output `main.dart.js` in every release, so a page load that spans a
# web-sync swap can run release A's flutter_bootstrap.js against release B's main.dart.js.
# This renames it `main.<release>.dart.js` and rewrites the two files that name it:
#   - flutter_bootstrap.js  `_flutter.buildConfig` → `"mainJsPath":"main.<release>.dart.js"`
#   - sw.js                 the precache entry, and CACHE_NAME → `srisurart-pos-<release>`
#                           (a byte change is what makes browsers install the new worker;
#                           an unchanged CACHE_NAME would keep serving the old release)
# Every rewrite must hit exactly once — a Flutter upgrade that changes the bootstrap's shape
# fails the build here instead of shipping an app that loads a file that is not there.
set -eu

dir=${1:?usage: version-web-build.sh <build/web dir> <release id>}
rel=${2:?usage: version-web-build.sh <build/web dir> <release id>}
case $rel in *[!0-9a-z]*) echo "::error::release id must be [0-9a-z]: $rel" >&2; exit 1 ;; esac

main="main.$rel.dart.js"

# replace_once <file> <literal old> <literal new>
replace_once() {
  n=$(grep -cF -- "$2" "$1" || true)
  [ "$n" = 1 ] || { echo "::error::$1: expected exactly 1 line with $2, found $n" >&2; exit 1; }
  awk -v old="$2" -v new="$3" '{ i = index($0, old); if (i) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); print }' \
    "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

cd "$dir"
[ -f main.dart.js ] || { echo "::error::$dir/main.dart.js missing — already versioned?" >&2; exit 1; }
mv main.dart.js "$main"
replace_once flutter_bootstrap.js '"mainJsPath":"main.dart.js"' "\"mainJsPath\":\"$main\""
replace_once sw.js "'main.dart.js'," "'$main',"
replace_once sw.js "const CACHE_NAME = 'srisurart-pos-v1';" "const CACHE_NAME = 'srisurart-pos-$rel';"

# The file the new bootstrap names must be the file that ships.
grep -qF "\"mainJsPath\":\"$main\"" flutter_bootstrap.js && [ -f "$main" ] ||
  { echo "::error::flutter_bootstrap.js does not name an existing $main" >&2; exit 1; }
echo "web build versioned as $main"
