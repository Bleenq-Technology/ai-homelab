#!/usr/bin/env python3
"""
Delete every chunk originating from one source URL/path (todos.md #44).

WHY THIS EXISTS: vector stores memorise. Deleting a row upstream does not remove
its embedded chunks, and the KB ingest CLEARS AND REBUILDS whole collections
(kb-standards.md section 8) — so before this there was no per-source delete
primitive at all. "Please remove that page/video" or a takedown request meant
rebuilding an entire collection, which is not a capability anyone reaches for
under time pressure. Now it is one call.

    ./delete-by-source.py --collection kb_topic_ai_ml --source https://youtube.com/watch?v=XYZ
    ./delete-by-source.py --collection kb_topic_ai_ml --source ... --apply
    ./delete-by-source.py --all-collections --source https://example.com/page --apply

DRY RUN BY DEFAULT. Deletion is irreversible and the source is only recoverable
by re-ingesting, so the default must never be "do it".

Matches on the `metadata.source` payload field, which kb-standards.md section 3
requires on every point.
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

QDRANT = os.environ.get("QDRANT_URL", "https://qdrant.lab.example")
CTX = ssl.create_default_context()


def env_key() -> str:
    k = os.environ.get("QDRANT_API_KEY")
    if k:
        return k
    envf = os.environ.get("HOMELAB_ENV", "/opt/homelab/.env")
    try:
        for line in open(envf, errors="replace"):
            if line.startswith("QDRANT_API_KEY="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    sys.exit("QDRANT_API_KEY not set and not found in the env file")


KEY = env_key()


def api(path: str, body=None, method: str | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        QDRANT + path, data=data, method=method or ("POST" if data else "GET"),
        headers={"api-key": KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120, context=CTX) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"qdrant {method or 'GET'} {path} -> {e.code}: "
                 f"{e.read().decode(errors='replace')[:300]}")


# `metadata.source` is the nested key the n8n vector-store nodes write; `source`
# is the flat form kb-standards section 3 documents. Match EITHER, so this works
# regardless of which writer produced the points.
def source_filter(src: str) -> dict:
    return {"should": [
        {"key": "metadata.source", "match": {"value": src}},
        {"key": "source", "match": {"value": src}},
    ]}


def count(coll: str, src: str) -> int:
    r = api(f"/collections/{coll}/points/count",
            {"filter": source_filter(src), "exact": True})
    return r["result"]["count"]


def main() -> int:
    ap = argparse.ArgumentParser(description="Delete all chunks from one source.")
    ap.add_argument("--source", required=True, help="exact source URL/path to erase")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--collection", help="single collection")
    g.add_argument("--all-collections", action="store_true",
                   help="every kb_*/app collection (use for a takedown)")
    ap.add_argument("--apply", action="store_true",
                    help="actually delete (default is a dry run)")
    a = ap.parse_args()

    if a.all_collections:
        colls = sorted(c["name"] for c in api("/collections")["result"]["collections"])
    else:
        colls = [a.collection]

    total = 0
    hits = []
    for c in colls:
        try:
            n = count(c, a.source)
        except SystemExit:
            raise
        except Exception as e:                      # noqa: BLE001
            print(f"  {c:32s} count failed: {e}")
            continue
        if n:
            hits.append((c, n))
            total += n
            print(f"  {c:32s} {n:6d} chunk(s) match")

    if not total:
        print(f"\nno chunks found for source {a.source!r} — nothing to do")
        return 0

    print(f"\n{total} chunk(s) across {len(hits)} collection(s)")
    if not a.apply:
        print("DRY RUN — re-run with --apply to delete. Deletion is irreversible; "
              "the only recovery is re-ingesting the source.")
        return 0

    for c, n in hits:
        api(f"/collections/{c}/points/delete", {"filter": source_filter(a.source)})
        left = count(c, a.source)
        # Verify rather than trust the 200: a filter that silently matched nothing
        # would otherwise look identical to a successful delete.
        status = "OK" if left == 0 else f"WARNING {left} remain"
        print(f"  deleted {n:6d} from {c:32s} -> {status}")

    print(f"\ndeleted {total} chunk(s) for source {a.source!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
