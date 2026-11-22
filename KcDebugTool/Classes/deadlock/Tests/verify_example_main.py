"""Exercise Example's pre-UIApplicationMain diagnostic harness using macOS Foundation.

Remove UIKit/app-delegate imports and select cycle2 in a temporary copy.
Exercise report logging without KC_DUMP_REPORT and reject an empty cycle size.
"""
import os
import re
from pathlib import Path
import subprocess
import sys

build = Path(sys.argv[1])
source_dir = Path(__file__).resolve().parent.parent
repo = source_dir.parents[2]
source = (repo / "Example/KcDebugTool/main.m").read_text()
source = source.replace("@import UIKit;", "#import <Foundation/Foundation.h>")
source = source.replace('#import "KCAppDelegate.h"', "")
# The developer can select cycle3/highCPU/etc. in the app; this regression always
# exercises two-thread report logging without changing their selected scenario.
source, replacements = re.subn(r'(\bNSString \*scenario = )@"[^"\n]*";',
                               r'\1@"cycle2";', source)
assert replacements == 1, "Expected one hardcoded Example diagnostic scenario"
portable_main = build / "example-main.m"
portable_main.write_text(source)
executable = build / "example-main"
subprocess.run([
    "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fmodules",
    f"-fmodules-cache-path={build / 'modules'}", "-O1", "-g", "-fno-omit-frame-pointer",
    "-framework", "Foundation", "-I", str(source_dir),
    str(source_dir / "KcDeadlockMonitor.m"), str(source_dir / "KcTrackedLock.m"),
    str(source_dir / "KcThreadSampler.m"), str(portable_main), "-o", str(executable),
], check=True)
env = os.environ.copy()
env.pop("KC_DUMP_REPORT", None)
result = subprocess.run([str(executable)], env=env, capture_output=True, text=True, timeout=10)
assert result.returncode == 0, result.stderr
assert "PASS cycle2" in result.stdout, result.stdout
assert "[KcDeadlock] dependencyCycle" in result.stderr, result.stderr
assert '"acquisitionStack"' in result.stderr, result.stderr
assert '"waitStack"' in result.stderr, result.stderr
assert '"threads"' in result.stderr, result.stderr
print("PASS example main prints cycle2 report without KC_DUMP_REPORT")

# A bare 'cycle' must fail immediately rather than wait four seconds for no threads.
invalid = subprocess.run([str(build / "tests"), "cycle"], env=env,
                         capture_output=True, text=True, timeout=2)
assert invalid.returncode == 1, invalid.stderr
assert "cycle scenario requires a positive size" in invalid.stderr, invalid.stderr
print("PASS empty cycle size rejected before waiting")
