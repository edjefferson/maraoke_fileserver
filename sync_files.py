#!/usr/bin/env python3
"""
Downloads missing media files listed in a sync manifest JSON.

Usage: python3 sync_files.py <manifest.json>

The manifest is fetched from /admin/sync_manifest on the maraoke server.
It contains two lists of relative file paths:
  - core:  files for All-tagged songs (downloaded verbosely)
  - other: files for remaining songs (downloaded silently, failures noted)
"""

import json
import os
import sys
import urllib.request
from pathlib import Path

MEDIA_BASE_URL = "https://media.maraoke.com/uploads"
SCRIPT_DIR = Path(__file__).parent.resolve()
LOCAL_UPLOADS = SCRIPT_DIR / "public" / "uploads"
LOG_FILE = SCRIPT_DIR / "ftp_sync.log"


def download_file(rel, dest):
    url = f"{MEDIA_BASE_URL}/{rel}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def download_list(files, verbose):
    total = len(files)
    failures = []

    for i, rel in enumerate(files, 1):
        dest = LOCAL_UPLOADS / rel
        if verbose:
            print(f"  [{i}/{total}] {rel}")
        else:
            print(f"  [{i}/{total}] {rel}", end="", flush=True)

        try:
            download_file(rel, dest)
            if not verbose:
                print(" ✓")
        except Exception as e:
            if not verbose:
                print(" ✗")
            failures.append((rel, str(e)))
            with open(LOG_FILE, "a") as log:
                log.write(f"FAILED: {rel} — {e}\n")

    return failures


def main():
    if len(sys.argv) != 2:
        print(f"Usage: python3 {Path(__file__).name} <manifest.json>")
        sys.exit(1)

    manifest_path = Path(sys.argv[1])
    if not manifest_path.exists():
        print(f"⚠️  File not found: {manifest_path}")
        sys.exit(1)

    with open(manifest_path) as f:
        manifest = json.load(f)

    core_all  = manifest.get("core", [])
    other_all = manifest.get("other", [])

    core  = [r for r in core_all  if not (LOCAL_UPLOADS / r).exists()]
    other = [r for r in other_all if not (LOCAL_UPLOADS / r).exists()]

    if not core and not other:
        print("✅ All files already present — nothing to download.")
        return

    LOCAL_UPLOADS.mkdir(parents=True, exist_ok=True)

    if core:
        print(f"\n==> {len(core)} missing file(s) for All-tagged songs:")
        download_list(core, verbose=True)

    other_failures = []
    if other:
        print(f"\n==> {len(other)} missing file(s) for other songs:")
        other_failures = download_list(other, verbose=False)

    print("\n✅ Done. See ftp_sync.log for any errors.")
    if other_failures:
        print(f"   {len(other_failures)} file(s) failed — check ftp_sync.log.")


if __name__ == "__main__":
    main()
