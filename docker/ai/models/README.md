# Model weights — provenance & integrity

**Purpose:** Record what every model weight on jarvis *is*, where it came from, and prove it hasn't
changed. **URL:** none (manifest + a verification script). **Networks / data:** host filesystem only.

Context: [`docs/ai-governance.md`](../../../docs/ai-governance.md) · backlog: `todos.md` #45.

## Why this exists

We pin image versions rigorously — *no `:latest`* is a stated quality bar — and until 2026-07-22 we
pinned our **model weights not at all**. No hash, no source URL, no revision, no licence for any GGUF
on the box. A silently swapped, truncated, or corrupted weights file was **undetectable**.

For `bge-m3` that matters more than it first looks: it is the **KB interoperability standard**, and
every `kb_*` collection is embedded with it. Change that file and every collection is silently
invalidated — while every service keeps starting cleanly and reports healthy.

## Files

| File | What |
|---|---|
| [`manifest.json`](manifest.json) | The provenance record: path, sha256, source URL, upstream revision, licence, status |
| [`verify-models.sh`](verify-models.sh) | Re-hashes and reports; `--publish` emits `homelab_ai_model_*` metrics |

Weights themselves stay **out of git** (huge, gitignored). The manifest is what's committed.

## It checks BOTH directions

1. **manifest → disk:** every recorded model still hashes to its recorded `sha256`.
2. **disk → manifest:** every `.gguf` >10 MB on the host has a manifest entry.

**Direction 2 is the one that finds things.** It is what surfaced **6.9 GB of unregistered
`gemma-4-E2B-it` weights** that nothing serves and nobody had registered.

## Running it

```bash
/opt/homelab/ai/models/verify-models.sh            # report
/opt/homelab/ai/models/verify-models.sh --publish  # + Prometheus metrics
```

Weekly cron **Sun 04:00** → `/srv/ai-data/backups/ai-models.log`. Hashing several GB takes a few
minutes, which is why it's weekly rather than per-deploy. Four alerts in the `ai-model-integrity`
group: verify-failed (**critical** — a weights file does not change on its own), unregistered,
staleness, and the dead-man.

**Both directions are negative-tested:** a deliberately corrupted copy produced a HASH MISMATCH with
both hashes printed, and a planted rogue `.gguf` was reported UNREGISTERED.

## Adding / changing a model

1. Download to its serving location.
2. `sha256sum <file>` and add an entry: path, hash, **source URL**, **upstream revision**, **licence**.
   For HuggingFace models the snapshot directory name *is* the revision — free provenance, use it.
3. Re-run `verify-models.sh` — it should report `ok` and **0 unregistered**.
4. Mirror the model into [`docs/ai-inventory.yml`](../../../docs/ai-inventory.yml) under `platform:`.

**Record `unverified` rather than guessing.** An honest `unverified` is a work item; a guessed licence
is a liability — and this repo is heading for open source (`todos.md` #14). `bge-m3`'s licence is
recorded as unverified for exactly this reason: upstream BAAI/bge-m3 is MIT, but the GGUF *conversion*
repo the file came from wasn't recorded at download time.

## Fixes & gotchas

- **jq: bind `.path` before piping.** `$f | startswith(.path + "/")` pipes into the **string** `$f`,
  so `.path` is then evaluated against a string and jq errors *"Cannot index string with string"*.
  Because `or` short-circuits, the first entry passed and every later one errored — and the non-zero
  exit made `if !` read as "unregistered", producing false positives. Correct form:
  `select(.path as $p | ($f == $p) or ($f | startswith($p + "/")))`.
- **`ggml-vocab-*.gguf` are ignored** — tiny tokenizer fixtures inside the llama.cpp source tree, not
  served models. They're in `ignore_globs`.
- **A manifest entry may be a directory** (HF caches are directories of blobs). A file counts as
  registered if it sits under one.
- **`sudo` is required** to read `/opt/unsloth/.cache` — the cron runs as a user in `homelab`.
- Present-but-unwritable textfile dir is checked explicitly (the `todos.md` #11 trap).

## Secrets

None. The manifest holds hashes and public URLs only — safe to commit and to open-source.
