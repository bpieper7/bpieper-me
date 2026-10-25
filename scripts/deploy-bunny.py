#!/usr/bin/env python3
"""
Sync a local directory to a bunny.net storage zone over the HTTPS Storage API.

Usage: scripts/deploy-bunny.py [--dry-run] <local-dir>

New and changed files are uploaded first, then remote files and directories
that no longer exist locally are deleted, so the live site never points at a
file that hasn't been uploaded yet. Files are compared by SHA256, which the
storage API reports for every object.

Environment:
  BUNNY_STORAGE_ZONE      Storage zone name
  BUNNY_STORAGE_PASSWORD  Storage zone password (FTP & API Access tab)
  BUNNY_STORAGE_HOST      Regional endpoint, e.g. ny.storage.bunnycdn.com
                          (default storage.bunnycdn.com, Frankfurt)
"""

import argparse
import hashlib
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

#zone = os.environ["BUNNY_STORAGE_ZONE"]
#password = os.environ["BUNNY_STORAGE_PASSWORD"]
#host = os.environ.get("BUNNY_STORAGE_HOST") or "storage.bunnycdn.com"
zone = "bpieper-me-blog"
password = "8538582e-18be-4581-9fe1eaeff757-e7a3-48ae"
host = "la.storage.bunnycdn.com"
base = f"https://{host}/{urllib.parse.quote(zone)}/"


def request(method, path, data=None, headers=None):
    url = base + urllib.parse.quote(path)
    headers = {"AccessKey": password, **(headers or {})}
    for attempt in range(4):
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            # Don't retry client errors (bad password, missing file, ...)
            if e.code < 500 or attempt == 3:
                raise RuntimeError(f"{method} {path}: HTTP {e.code} {e.read()[:200]!r}")
        except urllib.error.URLError:
            if attempt == 3:
                raise
        time.sleep(2**attempt)


def list_remote(prefix=""):
    """Return ({file path: SHA256}, set of directory paths) under prefix."""
    files, dirs = {}, set()
    for item in json.loads(request("GET", prefix)):
        path = prefix + item["ObjectName"]
        if item["IsDirectory"]:
            dirs.add(path + "/")
            sub_files, sub_dirs = list_remote(path + "/")
            files.update(sub_files)
            dirs.update(sub_dirs)
        else:
            files[path] = (item.get("Checksum") or "").upper()
    return files, dirs


def list_local(root):
    files, dirs = {}, set()
    for dirpath, _, names in os.walk(root):
        rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
        if rel != ".":
            dirs.add(rel + "/")
        for name in names:
            path = name if rel == "." else f"{rel}/{name}"
            with open(os.path.join(dirpath, name), "rb") as f:
                files[path] = hashlib.sha256(f.read()).hexdigest().upper()
    return files, dirs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("local_dir")
    args = parser.parse_args()

    # Refuse to sync an empty or broken build, which would wipe the zone
    if not os.path.isfile(os.path.join(args.local_dir, "index.html")):
        sys.exit(f"error: {args.local_dir}/index.html not found; not deploying")

    local_files, local_dirs = list_local(args.local_dir)
    remote_files, remote_dirs = list_remote()

    uploads = sorted(p for p, h in local_files.items() if remote_files.get(p) != h)

    # Deleting a directory removes everything in it, so delete only the
    # topmost stale directories, then any stale files outside of them.
    stale_dirs = sorted(d for d in remote_dirs - local_dirs
                        if not any(d != o and d.startswith(o) for o in remote_dirs - local_dirs))
    stale_files = sorted(p for p in remote_files.keys() - local_files.keys()
                         if not any(p.startswith(d) for d in stale_dirs))

    print(f"{len(uploads)} to upload, {len(stale_files)} files and "
          f"{len(stale_dirs)} directories to delete, "
          f"{len(local_files) - len(uploads)} unchanged")

    def upload(path):
        with open(os.path.join(args.local_dir, path), "rb") as f:
            data = f.read()
        if not args.dry_run:
            ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
            request("PUT", path, data, {"Checksum": local_files[path], "Content-Type": ctype})
        print(f"  put {path}")

    def delete(path):
        if not args.dry_run:
            request("DELETE", path)
        print(f"  del {path}")

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(upload, uploads))
        list(pool.map(delete, stale_files + stale_dirs))


if __name__ == "__main__":
    main()
