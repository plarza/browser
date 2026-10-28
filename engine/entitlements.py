"""An XPC service's entitlements for a Developer ID release: what the build
gave it, minus JIT (Core runs without one) and the debugger's, plus leave
to read the dyld path Core's launcher sets."""
import plistlib
import sys

raw = open(sys.argv[1], "rb").read()
ents = plistlib.loads(raw) if raw.strip() else {}
for key in ["com.apple.security.cs.allow-jit", "com.apple.security.get-task-allow"]:
    ents.pop(key, None)
ents = {k: v for k, v in ents.items() if not k.startswith("com.apple.private.")}
ents["com.apple.security.cs.allow-dyld-environment-variables"] = True
sys.stdout.write(plistlib.dumps(ents).decode())
