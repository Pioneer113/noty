#!/bin/bash
# Rebuilds site/index.html from the template, inlining the screenshots so the
# page is a single self-contained file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import base64, pathlib, subprocess, tempfile, shutil

root = pathlib.Path(".")
tpl  = (root / "site/index.template.html").read_text()
tmp  = pathlib.Path(tempfile.mkdtemp())

def jpeg(png: pathlib.Path) -> str:
    """Downscale a screenshot and inline it as a JPEG data URI."""
    small = tmp / (png.stem + ".png")
    shutil.copy(png, small)
    subprocess.run(["sips", "-Z", "900", str(small), "--out", str(small)],
                   check=True, capture_output=True)
    jpg = tmp / (png.stem + ".jpg")
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88",
                    str(small), "--out", str(jpg)], check=True, capture_output=True)
    return "data:image/jpeg;base64," + base64.b64encode(jpg.read_bytes()).decode()

def png(p: pathlib.Path) -> str:
    return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode()

out = tpl
for token, path in [("{{REST}}", "screenshots/rest.png"),
                    ("{{FAN}}",  "screenshots/fan.png"),
                    ("{{OPEN}}", "screenshots/open.png")]:
    out = out.replace(token, jpeg(root / path))
out = out.replace("{{ICON}}", png(root / "site/icon.png"))

video = root / "site/demo.mp4"
out = out.replace("{{VIDEO}}",
                  "data:video/mp4;base64," + base64.b64encode(video.read_bytes()).decode())

(root / "site/index.html").write_text(out)
shutil.rmtree(tmp, ignore_errors=True)
print(f"✓ site/index.html rebuilt ({len(out) // 1024} KB)")
PY
