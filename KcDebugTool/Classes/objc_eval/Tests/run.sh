#!/bin/sh
# macOS arm64 self-check. Build outputs live in /private/tmp, outside the repo.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=/private/tmp/kc_objc_eval_test
cache=/private/tmp/kc_objc_eval_modules

xcrun swiftc -module-cache-path "$cache/swift" -emit-library \
  -module-name KCSwiftFixture "$root/Tests/SwiftFixture.swift" \
  -o /private/tmp/libKCSwiftFixture.dylib
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$cache/clang" \
  -c "$root/KCObjCEval.m" -o "$out-eval.o"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$cache/clang" \
  -c "$root/KCObjCEvalSwiftSymbols.m" -o "$out-symbols.o"
xcrun clang -c "$root/KCObjCEvalSwiftCallArm64.S" -o "$out-call.o"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$cache/clang" \
  -c "$root/Tests/main.m" -o "$out-main.o"
xcrun swiftc -parse-as-library -module-cache-path "$cache/swift" \
  "$root/KCObjCEvalSwiftStringBridge.swift" \
  "$out-eval.o" "$out-symbols.o" "$out-call.o" "$out-main.o" \
  -framework Foundation -o "$out"
"$out"
