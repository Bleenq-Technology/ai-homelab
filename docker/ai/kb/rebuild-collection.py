#!/usr/bin/env python3
"""
Out-of-band rebuild of a single kb_* Qdrant collection, bypassing the n8n
kb-ingest workflow. Use it when a collection is missing/corrupt and you need it
back without a full ingest run (which clears + rebuilds ALL collections).

WHY IT EMBEDS DIRECTLY AGAINST bge-m3, NOT THROUGH THE GATEWAY. The gateway's
prompt-injection guardrails are `pre_call` + `default_on`, so they run on
/embeddings too. Our own infra docs legitimately contain phrases like
"enable ... override", which trips the `prompt_injection_malicious_code`
conditional -> HTTP 400. Guarding the vectorization of first-party documents
adds no security (embeddings do not generate, so there is nothing to hijack) and
breaks ingestion. This was the root cause of kb_homelab_docs vanishing on
2026-07-24: the daily ingest cleared it, then the re-embed was blocked. See the
systemic fix in todos.md #53.

Parity with the workflow, verified against a live point:
  * chunk 1400 / overlap 200, recursive character splitter
  * bge-m3, 1024-dim; collection 1024 / Cosine
  * payload {"content": ..., "metadata": {source, repository, branch, loc.lines}}

HOW TO RUN. It needs the `ai` network (both qdrant:6333 and bge-m3:8080 live
there) and a JSON bundle of {source, content} docs. Build the bundle from a
checkout of the source repo, scp it up, then:

  # local: make the bundle (markdown only, skip .git/node_modules)
  python3 - <<'PY' > /tmp/kb_homelab_src.json
  import json,os
  out=[]
  for dp,dn,fn in os.walk("."):
      dn[:]=[d for d in dn if d not in {".git","node_modules","local-notes"}]
      for f in fn:
          if f.lower().endswith((".md",".markdown")):
              p=os.path.join(dp,f); rel=os.path.relpath(p,".").replace("\\\\","/")
              t=open(p,encoding="utf-8",errors="replace").read()
              if t.strip(): out.append({"source":rel,"content":t})
  print(json.dumps(out,ensure_ascii=False))
  PY
  scp /tmp/kb_homelab_src.json Jarvis:/tmp/ ; scp rebuild-collection.py Jarvis:/tmp/

  # on jarvis: run in a container on the ai network
  K=$(grep -E '^QDRANT_API_KEY=' /opt/homelab/.env | cut -d= -f2-)
  docker run --rm --network ai -e QDRANT_API_KEY="$K" \
    -e KB_COLLECTION=kb_homelab_docs \
    -e KB_REPOSITORY=https://github.com/your-org/ai-homelab-infra \
    -v /tmp/rebuild-collection.py:/r.py:ro -v /tmp/kb_homelab_src.json:/src.json:ro \
    python:3.12-slim python /r.py /src.json

stdlib only; nothing to install.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

QDRANT = os.environ.get("QDRANT_URL", "http://qdrant:6333")
BGE = os.environ.get("BGE_URL", "http://bge-m3:8080/v1/embeddings")
QKEY = os.environ["QDRANT_API_KEY"]
COLL = os.environ.get("KB_COLLECTION", "kb_homelab_docs")
REPO = os.environ.get("KB_REPOSITORY", "https://github.com/your-org/ai-homelab-infra")
SRC = sys.argv[1] if len(sys.argv) > 1 else "/src.json"
CHUNK, OVERLAP = 1400, 200
SEPARATORS = ["\n\n", "\n", " ", ""]


def http(method, url, headers, body=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {url} -> {e.code}: {e.read().decode()[:300]}") from None


def qh():
    return {"api-key": QKEY, "Content-Type": "application/json"}


def split_text(text, separators=SEPARATORS):
    """Recursive character splitter (LangChain algorithm), chunk 1400 / overlap 200."""
    sep = separators[-1]
    for s in separators:
        if s == "" or s in text:
            sep = s
            break
    parts = list(text) if sep == "" else text.split(sep)
    chunks, cur = [], ""
    for part in parts:
        piece = part if sep == "" else (part + sep)
        if len(piece) > CHUNK and len(separators) > 1:
            if cur:
                chunks.append(cur)
                cur = ""
            chunks.extend(split_text(part, separators[separators.index(sep) + 1:]))
            continue
        if len(cur) + len(piece) <= CHUNK:
            cur += piece
        else:
            if cur:
                chunks.append(cur)
            cur = (cur[-OVERLAP:] if OVERLAP and cur else "") + piece
    if cur.strip():
        chunks.append(cur)
    return [c for c in (x.strip() for x in chunks) if c]


def line_span(text, chunk):
    idx = text.find(chunk[:60])
    start = (text.count("\n", 0, idx) + 1) if idx >= 0 else 1
    return {"from": start, "to": start + chunk.count("\n")}


def embed(batch):
    _, d = http("POST", BGE, {"Content-Type": "application/json"},
                {"model": "bge-m3", "input": batch}, timeout=180)
    return [row["embedding"] for row in d["data"]]


def main():
    docs = json.load(open(SRC, encoding="utf-8"))
    print(f"source docs: {len(docs)} -> collection {COLL}")

    points = []
    for doc in docs:
        for ch in split_text(doc["content"]):
            points.append({
                "id": str(uuid.uuid4()), "content": ch,
                "metadata": {"source": doc["source"], "repository": REPO,
                             "branch": "main", "loc": {"lines": line_span(doc["content"], ch)}},
            })
    print(f"chunks: {len(points)}")

    try:
        http("DELETE", f"{QDRANT}/collections/{COLL}", qh(), timeout=60)
    except RuntimeError as e:
        print(f"  (delete: {e})")
    http("PUT", f"{QDRANT}/collections/{COLL}", qh(),
         {"vectors": {"size": 1024, "distance": "Cosine"}}, timeout=60)
    print(f"created {COLL} (1024/Cosine)")

    B, done = 32, 0
    for i in range(0, len(points), B):
        batch = points[i:i + B]
        vecs = embed([p["content"] for p in batch])
        http("PUT", f"{QDRANT}/collections/{COLL}/points?wait=true", qh(),
             {"points": [{"id": p["id"], "vector": v,
                          "payload": {"content": p["content"], "metadata": p["metadata"]}}
                         for p, v in zip(batch, vecs)]}, timeout=180)
        done += len(batch)
        if done % 128 == 0 or done == len(points):
            print(f"  upserted {done}/{len(points)}")
        time.sleep(0.05)

    _, info = http("GET", f"{QDRANT}/collections/{COLL}", qh(), timeout=30)
    print(f"DONE: {COLL} status={info['result']['status']} points={info['result']['points_count']}")


if __name__ == "__main__":
    main()
