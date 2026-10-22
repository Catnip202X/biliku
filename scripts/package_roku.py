"""Zip the Roku app (roku/) into a sideloadable package: python scripts/package_roku.py <output.zip>"""
import os, sys, zipfile

src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "roku")
out = sys.argv[1] if len(sys.argv) > 1 else "biliku-roku.zip"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for name in sorted(files):
            if name != ".DS_Store":
                path = os.path.join(root, name)
                z.write(path, os.path.relpath(path, src).replace(os.sep, "/"))
print(f"wrote {out} ({os.path.getsize(out) // 1024} KB)")
