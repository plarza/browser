#!/usr/bin/env python3
"""Exercise the real build, launcher and executable without opening a browser."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo / "build/Browser.app"
env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "__XPC_DYLD_"))}
env.pop("BROWSER_ENGINE", None)


def check(name, command, expected, variables=None):
    result = subprocess.run(command, env=env | (variables or {}), capture_output=True, text=True, timeout=20)
    if result.returncode != expected:
        raise AssertionError(f"{name}: exit {result.returncode}, expected {expected}\n{result.stdout}{result.stderr}")
    print("PASS", name)
    return result


launcher = app / "Contents/MacOS/Browser"
binary = app / "Contents/MacOS/BrowserApp"
result = check("bundled patched engine is accepted", [str(launcher), "--check-engine"], 0)
assert "patched WebKit verified" in result.stdout
check("launcher overrides a system-engine environment", [str(launcher), "--check-engine"], 0,
      {"DYLD_FRAMEWORK_PATH": "/System/Library/Frameworks"})
executables = [("release", binary)] + [("debug", Path(path).resolve()) for path in sys.argv[2:]]
for configuration, executable in executables:
    for arguments in ([], ["--check-engine"], ["https://example.com"]):
        result = check(f"direct unpatched {configuration} executable is rejected {arguments!r}",
                       [str(executable), *arguments], 78)
        assert "cannot start without its patched WebKit" in result.stderr

with tempfile.TemporaryDirectory(prefix="browser-engine-test-") as temporary:
    root = Path(temporary)
    empty = root / "Missing.app/Contents"
    (empty / "MacOS").mkdir(parents=True)
    shutil.copy2(launcher, empty / "MacOS/Browser")
    # The original signature seals its bundle's Info.plist. Re-sign this
    # stripped fixture so macOS lets the real launcher execute its checks.
    subprocess.run(["codesign", "--force", "--sign", "-", str(empty / "MacOS/Browser")],
                   check=True, capture_output=True)
    check("launcher rejects absent frameworks", [str(empty / "MacOS/Browser")], 78)
    (empty / "Frameworks").mkdir()
    check("launcher rejects an empty framework directory", [str(empty / "MacOS/Browser")], 78)
    result = check("build rejects a missing engine", [str(repo / "build.sh")], 1,
                   {"BROWSER_ENGINE": str(root / "missing")})
    assert "Browser requires its patched engine" in result.stderr
    invalid = root / "invalid"
    for name in ("JavaScriptCore", "WebCore", "WebKit"):
        file = invalid / f"{name}.framework/Versions/A/{name}"
        file.parent.mkdir(parents=True)
        file.write_bytes(b"unpatched engine")
    result = check("build rejects an unpatched engine", [str(repo / "build.sh")], 1,
                   {"BROWSER_ENGINE": str(invalid)})
    assert "Browser refuses an unpatched WebKit" in result.stderr
