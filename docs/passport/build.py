#!/usr/bin/env python3
"""Render docs/passport/passport.html to PDF with headless Chromium. Usage: build.py [out.pdf]"""
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "Паспорт.pdf"))
chrome = next((c for c in (os.environ.get("CHROME"), "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
               "chromium", "chromium-browser", "google-chrome") if c), None)
subprocess.run([chrome, "--headless", "--no-sandbox", "--disable-gpu", "--no-pdf-header-footer",
                f"--print-to-pdf={out}", "file://" + os.path.join(here, "passport.html")],
               check=True, stderr=subprocess.DEVNULL)
print("wrote", out)
