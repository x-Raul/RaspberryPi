#!/usr/bin/env python3
"""Make homebridge-tuya 3.1.2-beta.2 load on Homebridge 2.x.

Homebridge 2 removed, from the objects this plugin reads:
  * Characteristic.Perms/Formats/Units (now api.hap.Perms/Formats/Units, with
    Perms.READ/WRITE renamed to PAIRED_READ/PAIRED_WRITE);
  * Accessory.Categories (now api.hap.Categories).
Each step re-attaches what is missing right after the plugin reads the HAP
objects. Idempotent (one marker per step); reapply after reinstalling the plugin.
Usage: patch-homebridge-tuya.py [path/to/index.js]
"""
import shutil, sys, time

PATH = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/homebridge/node_modules/homebridge-tuya/index.js"
ANCHOR = "    } = homebridge);\n"
STEPS = [
    ("// hb2-compat\n",
     "    if (!Characteristic.Perms) Object.assign(Characteristic, { // hb2-compat\n"
     "        Perms: Object.assign({READ: homebridge.hap.Perms.PAIRED_READ, WRITE: homebridge.hap.Perms.PAIRED_WRITE}, homebridge.hap.Perms),\n"
     "        Formats: homebridge.hap.Formats,\n"
     "        Units: homebridge.hap.Units,\n"
     "    });\n"),
    ("// hb2-compat-categories\n",
     "    if (!Categories) Categories = homebridge.hap.Categories; // hb2-compat-categories\n"),
]

src = open(PATH).read()
if src.count(ANCHOR) != 1:
    sys.exit("anchor not found; plugin changed, not patching")
todo = [code for marker, code in STEPS if marker not in src]
if not todo:
    print("already patched"); sys.exit(0)
shutil.copy2(PATH, PATH + ".orig-" + time.strftime("%Y%m%d-%H%M%S"))
open(PATH, "w").write(src.replace(ANCHOR, ANCHOR + "".join(todo)))
print("patched %s (%d step(s))" % (PATH, len(todo)))
