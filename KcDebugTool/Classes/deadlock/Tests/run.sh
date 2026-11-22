#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/kc-deadlock-tests.XXXXXX")"
# macOS executable tests exercise Foundation + Mach without Example's local Pod dependencies.
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$build_dir/modules" \
  -Wall -Wextra -Werror -O1 -g -fno-omit-frame-pointer -framework Foundation \
  -I "$source_dir" "$source_dir/KcDeadlockMonitor.m" "$source_dir/KcTrackedLock.m" \
  "$source_dir/KcThreadSampler.m" "$source_dir/Tests/DeadlockTests.m" -o "$build_dir/tests"
for scenario in cycle1 cycle2 cycle3 gcdContext operationContext highCPU longWait explicitCycle heartbeat recursive cleanup contention; do
  "$build_dir/tests" "$scenario"
done
python3 "$source_dir/Tests/verify_example_main.py" "$build_dir"
printf 'Test executable: %s\n' "$build_dir/tests"
