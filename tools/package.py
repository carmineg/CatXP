"""Build <addon>-<version>.zip next to the addon folder (entries start with the folder name, so it
unzips straight into Interface/AddOns). The version comes from the TOC.
Usage: package.py [addon dir]   (default: ../CatXP)"""
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
addon = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "CatXP"))
root = os.path.dirname(addon)
name = os.path.basename(addon)

version = "0"
with open(os.path.join(addon, name + ".toc"), encoding="utf-8") as fh:
    for line in fh:
        m = re.match(r"##\s*Version:\s*(\S+)", line)
        if m:
            version = m.group(1)

out = os.path.join(root, "%s-%s.zip" % (name, version))
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, files in os.walk(addon):
        for f in sorted(files):
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, root).replace(os.sep, "/"))

print("%s: %d bytes" % (out, os.path.getsize(out)))
