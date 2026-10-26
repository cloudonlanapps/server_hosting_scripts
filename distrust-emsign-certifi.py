"""Remove every emSign root from the app's certifi bundle.

Run with the app's own Python (/app/.venv/bin/python) after `uv sync`.
certifi follows Mozilla, which still trusts emSign Root CA - G1; the hosts
distrust every emSign root (eMudhra CA incident, October 2026), and so does
the image. Exits non-zero if the bundle cannot be read, if an emSign root is
left, or if the trimmed bundle no longer loads.
"""

import re
import ssl
import sys

import certifi

path = certifi.where()
with open(path, encoding="ascii") as f:
    bundle = f.read()

# One entry: its "# ..." header lines, then the PEM block.
entry = re.compile(
    r"((?:#[^\n]*\n)+)(-----BEGIN CERTIFICATE-----\n.*?\n-----END CERTIFICATE-----\n)",
    re.S,
)
entries = entry.findall(bundle)
if not entries or len(entries) != bundle.count("-----BEGIN CERTIFICATE-----"):
    sys.exit(f"ERROR: could not parse {path}")

dropped = [h for h, _ in entries if "emsign" in h.lower()]
kept = "\n".join(h + pem for h, pem in entries if "emsign" not in h.lower())
with open(path, "w", encoding="ascii") as f:
    f.write(kept)

with open(path, encoding="ascii") as f:
    if "emsign" in f.read().lower():
        sys.exit("ERROR: an emSign root is still in the certifi bundle")
ssl.create_default_context(cafile=path)

for header in dropped:
    label = re.search(r'# Label: "([^"]*)"', header)
    print("removed", label.group(1) if label else header.splitlines()[0])
print(f"certifi {certifi.__version__}: {len(entries) - len(dropped)} roots, no emSign")
