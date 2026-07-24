#!/usr/bin/env python3
"""
Build the AI-BOM and check it against reality.

The inventory (docs/ai-inventory.yml) records INTENT. This joins it against what
is actually live and FAILS when they disagree. That failure is the whole point:
a registry nobody checks is a spreadsheet.

    ./build-ai-bom.py --check           # static  — no network; runs in CI
    ./build-ai-bom.py --live --check    # full    — on jarvis (needs /opt/homelab/.env)
    ./build-ai-bom.py --live            # regenerate docs/ai-bom.{json,md}

Static mode validates schema, required fields, and the tier control matrix rows
that don't need the platform. Live mode adds the ones that do: credential
existence, budgets/limits/expiry, corpus reality, and trace liveness.

Deliberately stdlib-only except PyYAML (present on jarvis and trivial in CI) —
this has to run in a bare CI container and on the host without a venv.

See: docs/ai-governance.md · docs/ai-risk-tiers.md · todos.md #36/#37
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required:  pip install pyyaml  (or apt install python3-yaml)")

def find_root(start: Path) -> Path:
    """Locate the tree holding docs/ai-inventory.yml.

    Must work from BOTH layouts: the git repo (docker/ai/inventory/...) and the
    deployed host tree, where /opt/homelab mirrors docker/ with the prefix
    dropped — so the fixed-depth parents[3] that works in the repo lands on /opt
    on jarvis. Walk up instead, then fall back to a sibling docs/ next to the
    script (how it's deployed on the host).
    """
    env_root = os.environ.get("AI_BOM_ROOT")
    if env_root:
        return Path(env_root).resolve()
    for p in [start] + list(start.parents):
        if (p / "docs" / "ai-inventory.yml").is_file():
            return p
    return start.parent  # script dir: expects ./docs/ alongside


REPO = find_root(Path(__file__).resolve())
INVENTORY = REPO / "docs" / "ai-inventory.yml"
KB_MANIFEST = REPO / "docs" / "kb-manifest.json"
BOM_JSON = REPO / "docs" / "ai-bom.json"
BOM_MD = REPO / "docs" / "ai-bom.md"
ENV_FILE = Path(os.environ.get("HOMELAB_ENV", "/opt/homelab/.env"))

LITELLM_URL = os.environ.get("LITELLM_URL", "https://litellm.lab.example")
QDRANT_URL = os.environ.get("QDRANT_URL", "https://qdrant.lab.example")
N8N_URL = os.environ.get("N8N_URL", "https://n8n.lab.example")

VALID_TIERS = ("T0", "T1", "T2", "T3")

# The control matrix (docs/ai-risk-tiers.md), as code. Cumulative by tier index.
# Adding a row here is how a governance promise becomes a governance control.
MATRIX = {
    "scoped_credential": ["T0", "T1", "T2", "T3"],
    "registered_owner": ["T0", "T1", "T2", "T3"],
    "budget": ["T1", "T2", "T3"],
    "rate_limit": ["T1", "T2", "T3"],
    "expiry": ["T2", "T3"],
    "human_oversight": ["T2", "T3"],
}


def _days_until(expires: str) -> int | None:
    """Days until an ISO-8601 expiry. LiteLLM returns e.g.
    '2027-01-18T05:12:33.123456' or with a trailing 'Z'; be liberal, and return
    None rather than guessing if the shape changes."""
    from datetime import datetime, timezone
    try:
        s = str(expires).replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (dt - datetime.now(timezone.utc)).days
    except (ValueError, TypeError):
        return None


class Findings:
    """Collected drift. Severity decides the exit code; notes are informational."""

    def __init__(self) -> None:
        self.fail: list[tuple[str, str]] = []
        self.warn: list[tuple[str, str]] = []
        self.note: list[tuple[str, str]] = []

    def add(self, sev: str, code: str, msg: str) -> None:
        getattr(self, sev).append((code, msg))

    def render(self) -> None:
        for sev, mark in (("fail", "FAIL"), ("warn", "WARN"), ("note", "note")):
            for code, msg in getattr(self, sev):
                print(f"  [{mark}] {code}: {msg}")


# ---------------------------------------------------------------- http helpers


def _get(url: str, headers: dict[str, str], timeout: int = 20):
    """GET JSON. Returns None on any failure — a probe that can't run must not
    masquerade as a probe that found nothing."""
    req = urllib.request.Request(url, headers=headers)
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return json.loads(r.read().decode())
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, TimeoutError) as e:
        print(f"  ! probe failed {url}: {e}", file=sys.stderr)
        return None


def read_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


# ------------------------------------------------------------------- discovery


def discover_litellm(env) -> dict | None:
    mk = env.get("LITELLM_MASTER_KEY")
    if not mk:
        return None
    hdr = {"Authorization": f"Bearer {mk}"}
    # size caps at 100 — LiteLLM 422s above it rather than clamping.
    keys = _get(f"{LITELLM_URL}/key/list?return_full_object=true&size=100", hdr)
    models = _get(f"{LITELLM_URL}/model/info", hdr)
    # Guardrails are a SECURITY control that is default_on for every consumer,
    # so "what is actually loaded" belongs in the BOM next to keys and models.
    # The eval suite catches a guardrail that stops BLOCKING; only this catches
    # one that is quietly removed while the others still fire.
    guards = _get(f"{LITELLM_URL}/guardrails/list", hdr)
    if keys is None:
        return None
    out = {"keys": {}, "models": [], "guardrails": []}
    if guards:
        gl = guards.get("guardrails", guards) if isinstance(guards, dict) else guards
        if isinstance(gl, list):
            out["guardrails"] = sorted(
                g.get("guardrail_name") for g in gl
                if isinstance(g, dict) and g.get("guardrail_name")
            )
    for k in keys.get("keys", []):
        if isinstance(k, str) or not k.get("key_alias"):
            continue
        out["keys"][k["key_alias"]] = {
            "models": k.get("models") or [],
            "max_budget": k.get("max_budget"),
            "tpm_limit": k.get("tpm_limit"),
            "rpm_limit": k.get("rpm_limit"),
            "expires": k.get("expires"),
            "spend": k.get("spend"),
        }
    if models:
        out["models"] = [m["model_name"] for m in models.get("data", [])]
    return out


def discover_qdrant(env) -> list[str] | None:
    key = env.get("QDRANT_API_KEY")
    if not key:
        return None
    d = _get(f"{QDRANT_URL}/collections", {"api-key": key})
    if d is None:
        return None
    return sorted(c["name"] for c in d["result"]["collections"])


def discover_n8n(env) -> list[dict] | None:
    key = env.get("N8N_API_KEY")
    if not key:
        return None
    d = _get(f"{N8N_URL}/api/v1/workflows?limit=200", {"X-N8N-API-KEY": key})
    if d is None:
        return None
    return [{"name": w["name"], "active": w.get("active", False)} for w in d.get("data", [])]


def discover_trace_liveness() -> dict[str, str] | None:
    """Which systems have actually emitted a Langfuse trace, and when.

    This is the shadow-AI probe: a system producing traces that isn't in the
    inventory is ungoverned use, and an inventory entry with no traces is
    either dead or misattributed. Uses docker exec — ClickHouse is data-net only.
    """
    # Attribution lives in the TAGS, not user_id: LiteLLM's langfuse_default_tags
    # stamps `user_api_key_alias:<alias>` (todos.md #40). Reading user_id instead
    # made this probe report every trace as unattributed even after attribution
    # was working — the check was measuring the wrong column.
    #
    # Bounded to 7 days on purpose: traces predating the 2026-07-22 attribution
    # change are genuinely unattributable and would otherwise keep this warning
    # lit until they age out of the 14-day TTL, for nothing anyone can act on.
    q = ("SELECT replaceOne(arrayFirst(x -> startsWith(x, 'user_api_key_alias:'), tags), "
         "'user_api_key_alias:', '') AS who, max(timestamp) "
         "FROM default.traces WHERE timestamp > now() - INTERVAL 7 DAY "
         "GROUP BY who FORMAT TSV")
    try:
        r = subprocess.run(
            ["docker", "exec", "clickhouse", "clickhouse-client", "-q", q],
            capture_output=True, text=True, timeout=30,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"  ! trace liveness probe unavailable: {e}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"  ! trace liveness probe failed: {r.stderr.strip()[:200]}", file=sys.stderr)
        return None
    out = {}
    # strip("\n"), NOT strip(). The unattributed group comes back with an EMPTY
    # first column, i.e. a line starting with a tab — and a bare .strip() eats
    # that leading tab when the row sorts first, so the line no longer contains a
    # tab and gets skipped. That silently dropped the single row this probe exists
    # to surface: 1,890 unattributed traces read as "nothing to report".
    for line in r.stdout.strip("\n").splitlines():
        if "\t" in line:
            who, when = line.split("\t", 1)
            # ClickHouse renders NULL as \N in TSV. Both that and "" mean the
            # trace carries no system identity at all.
            # ClickHouse renders NULL as \N in TSV, and arrayFirst returns an
            # EMPTY STRING when no tag matches. Both mean "no system identity".
            if who in ("", "\\N", "None"):
                who = "(unattributed)"
            out[who] = when
    return out


# ---------------------------------------------------------------------- checks


def check_static(inv: dict, kb: dict, f: Findings) -> None:
    owners = set(inv.get("owners", {}))
    seen: set[str] = set()

    for s in inv.get("systems", []):
        n = s.get("name", "(unnamed)")
        if n in seen:
            f.add("fail", "duplicate_entry", f"{n}: declared more than once")
        seen.add(n)

        if not s.get("owner"):
            f.add("fail", "missing_owner", f"{n}: no owner")
        elif s["owner"] not in owners:
            f.add("fail", "unknown_owner", f"{n}: owner '{s['owner']}' not in owners:")

        tier = s.get("tier")
        if tier not in VALID_TIERS:
            f.add("fail", "bad_tier", f"{n}: tier {tier!r} not one of {VALID_TIERS}")
            continue

        cred = s.get("credential") or {}
        ctype = cred.get("type")
        if ctype == "master_key":
            f.add("fail", "master_key_use",
                  f"{n}: runs on the LiteLLM MASTER key — unscoped, unbounded, "
                  f"and its traces are unattributable (matrix: scoped_credential)")
        elif ctype not in ("litellm_key", "none", None):
            f.add("fail", "bad_credential_type", f"{n}: credential.type {ctype!r} unrecognised")
        elif ctype == "litellm_key" and not cred.get("alias"):
            f.add("fail", "missing_alias", f"{n}: credential.type litellm_key but no alias")

        if tier in MATRIX["human_oversight"]:
            ho = (s.get("human_oversight") or "").strip()
            if not ho:
                f.add("fail", "missing_oversight",
                      f"{n}: {tier} requires a NAMED human-oversight point")
            if s.get("disclosure") == "required":
                f.add("note", "disclosure_pending",
                      f"{n}: AI-use disclosure required and not yet shipped (todos.md #44)")

        for ar in s.get("accepted_risk") or []:
            if not ar.get("owner") or not ar.get("review_by"):
                f.add("fail", "unsigned_exception",
                      f"{n}: accepted_risk needs both an owner and a review_by date")
            else:
                f.add("note", "accepted_risk",
                      f"{n}: accepted risk owned by {ar['owner']}, review by {ar['review_by']}")

    # Corpora referenced by systems should exist in the KB manifest (kb_* only;
    # app-private and wildcard patterns are out of the manifest's scope).
    known = {k["name"] for k in kb.get("kbs", [])}
    for s in inv.get("systems", []):
        for c in s.get("corpora") or []:
            if c.startswith("kb_") and not c.endswith("*") and c not in known:
                f.add("warn", "corpus_not_in_manifest",
                      f"{s['name']}: corpus '{c}' is not in kb-manifest.json")


def check_live(inv: dict, live: dict, f: Findings) -> None:
    ll = live.get("litellm")
    if ll:
        declared = {
            (s.get("credential") or {}).get("alias"): s
            for s in inv["systems"]
            if (s.get("credential") or {}).get("alias")
        }
        actual = ll["keys"]

        # Shadow credential: a key nobody registered.
        for alias in sorted(set(actual) - set(declared)):
            f.add("fail", "unregistered_credential",
                  f"LiteLLM key '{alias}' exists but has no ai-inventory.yml entry")

        # Stale entry: registered but the credential is gone.
        for alias in sorted(set(declared) - set(actual)):
            f.add("fail", "stale_entry",
                  f"'{declared[alias]['name']}' declares key '{alias}' which does not exist")

        # Control matrix rows that need the live key object.
        for alias, s in sorted(declared.items()):
            k = actual.get(alias)
            if not k:
                continue
            tier, n = s["tier"], s["name"]
            if tier in MATRIX["budget"] and k["max_budget"] is None:
                f.add("fail", "missing_budget", f"{n} ({tier}): key '{alias}' has no max_budget")
            if tier in MATRIX["rate_limit"] and k["tpm_limit"] is None and k["rpm_limit"] is None:
                f.add("fail", "missing_rate_limit", f"{n} ({tier}): key '{alias}' has no tpm/rpm limit")
            if tier in MATRIX["expiry"] and k["expires"] is None:
                f.add("fail", "missing_expiry", f"{n} ({tier}): key '{alias}' never expires")
            elif k["expires"]:
                # Expiry without early warning is a self-inflicted outage waiting
                # to happen — a public surface would just start 401ing. Warn well
                # before it bites so rotation is scheduled, not reactive.
                days = _days_until(k["expires"])
                if days is not None and days <= 30:
                    sev = "fail" if days <= 7 else "warn"
                    f.add(sev, "key_expiring_soon",
                          f"{n}: key '{alias}' expires in {days}d — rotate via "
                          f"push-secret.sh + pull-secrets.sh + recreate")
            declared_models = set(s.get("models") or [])
            if declared_models and set(k["models"]) != declared_models:
                f.add("warn", "model_scope_drift",
                      f"{n}: key allows {sorted(k['models'])}, inventory declares {sorted(declared_models)}")

    # ---- guardrails: declared vs actually loaded ----------------------------
    if ll is not None:
        declared_g = {g["name"] for g in (inv.get("guardrails") or []) if g.get("name")}
        actual_g = set(ll.get("guardrails") or [])
        # MISSING is a FAIL, not a warn. LiteLLM warns-and-skips an unreadable
        # category_file and then starts HEALTHY, so a filter can vanish with no
        # other symptom — exactly the silent-degradation case this file exists for.
        for g in sorted(declared_g - actual_g):
            f.add("fail", "guardrail_missing",
                  f"guardrail '{g}' is declared in the inventory but is NOT loaded on the "
                  f"gateway — every consumer is running without it (check config.yaml and "
                  f"the category_file mounts)")
        # UNDECLARED is a warn: someone added a control through the admin UI, which
        # stores it in Postgres where it is invisible to git and to review.
        for g in sorted(actual_g - declared_g):
            f.add("warn", "guardrail_undeclared",
                  f"guardrail '{g}' is live but not declared in ai-inventory.yml — if it was "
                  f"added via the admin UI it lives only in the DB (not in git, not reviewable)")

    qd = live.get("qdrant")
    if qd is not None:
        manifest_cols = {k["collection"] for k in live["kb"].get("kbs", [])}
        for c in qd:
            if c.startswith("kb_") and c not in manifest_cols:
                f.add("warn", "orphan_collection",
                      f"Qdrant collection '{c}' has no kb-manifest.json entry")
        for c in sorted(manifest_cols - set(qd)):
            f.add("warn", "missing_collection",
                  f"kb-manifest declares '{c}' but it does not exist in Qdrant")

    traces = live.get("traces")
    if traces:
        known = {s["name"] for s in inv["systems"]}
        aliases = {(s.get("credential") or {}).get("alias") for s in inv["systems"]}
        for who in sorted(traces):
            if who == "(unattributed)":
                f.add("warn", "unattributable_traces",
                      f"Langfuse holds traces with no user_api_key_alias tag (newest "
                      f"{traces[who]}) — cannot tell which system produced them. "
                      f"Traces predating 2026-07-22 are expected here and age out "
                      f"with the 14d TTL; a RECENT timestamp means a live consumer "
                      f"is calling without an aliased key (todos.md #40)")
            elif who not in known and who not in aliases:
                f.add("fail", "unregistered_trace_source",
                      f"traces from '{who}' but no inventory entry — possible shadow AI")


# ----------------------------------------------------------------------- build


def build_bom(inv: dict, kb: dict, live: dict) -> dict:
    ll = (live.get("litellm") or {}).get("keys", {})
    traces = live.get("traces") or {}
    systems = []
    for s in inv.get("systems", []):
        alias = (s.get("credential") or {}).get("alias")
        k = ll.get(alias) if alias else None
        systems.append({
            "name": s["name"],
            "owner": s.get("owner"),
            "tier": s.get("tier"),
            "purpose": " ".join((s.get("purpose") or "").split()),
            "surface": s.get("surface"),
            "autonomy": s.get("autonomy"),
            "repo": s.get("repo"),
            "credential": {"type": (s.get("credential") or {}).get("type"), "alias": alias},
            "models": s.get("models") or [],
            "corpora": s.get("corpora") or [],
            "data_classes": s.get("data_classes") or [],
            "human_oversight": " ".join((s.get("human_oversight") or "").split()),
            "live": {
                "key_exists": bool(k),
                "max_budget": k["max_budget"] if k else None,
                "tpm_limit": k["tpm_limit"] if k else None,
                "rpm_limit": k["rpm_limit"] if k else None,
                "expires": k["expires"] if k else None,
                "last_trace": traces.get(s["name"]) or (traces.get(alias) if alias else None),
            },
        })
    return {
        "generated_from": "docs/ai-inventory.yml + live platform state",
        "inventory_updated": str(inv.get("updated")),
        "live_probes": sorted(k for k, v in live.items() if v),
        "systems": systems,
        "platform": inv.get("platform", []),
        # Guardrails are a control, not a system — but "what is enforcing right
        # now" is exactly the question the BOM exists to answer without anyone
        # having to remember.
        "guardrails": inv.get("guardrails", []),
        # What the gateway ACTUALLY has loaded, so the rendered BOM can mark each
        # declared guardrail live-or-missing rather than just restating intent.
        # Empty on a static (--check without --live) run, and the renderer says
        # "not probed" rather than inventing a tick.
        "live_guardrails": sorted((live.get("litellm") or {}).get("guardrails") or []),
        "corpora": [
            {"name": k["name"], "collection": k["collection"], "enabled": k.get("enabled")}
            for k in kb.get("kbs", [])
        ],
    }


def render_md(bom: dict) -> str:
    L = ["# AI-BOM — generated, do not edit",
         "",
         "Generated by [`docker/ai/inventory/build-ai-bom.py`](../docker/ai/inventory/build-ai-bom.py)",
         "from [`ai-inventory.yml`](ai-inventory.yml) joined against live platform state.",
         "Edit the inventory, not this file. Context: [`ai-governance.md`](ai-governance.md).",
         "",
         f"- Inventory updated: **{bom['inventory_updated']}**",
         f"- Live probes in this run: **{', '.join(bom['live_probes']) or 'none (static)'}**",
         "",
         "## Systems", "",
         "| System | Tier | Owner | Surface | Autonomy | Credential | Models | Budget | Rate | Expires | Last trace |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for s in bom["systems"]:
        lv, c = s["live"], s["credential"]
        cred = c["alias"] or c["type"] or "—"
        if c["type"] == "master_key":
            cred = "⚠️ **master key**"
        rate = lv["tpm_limit"] or lv["rpm_limit"] or "—"
        L.append(
            f"| `{s['name']}` | **{s['tier']}** | {s['owner']} | {s['surface']} | {s['autonomy']} "
            f"| {cred} | {', '.join(f'`{m}`' for m in s['models']) or '—'} "
            f"| {lv['max_budget'] if lv['max_budget'] is not None else '—'} | {rate} "
            f"| {lv['expires'] or '—'} | {lv['last_trace'] or '—'} |")
    L += ["", "## Human oversight", "",
          "| System | Tier | Where a human is in the loop |", "|---|---|---|"]
    for s in bom["systems"]:
        L.append(f"| `{s['name']}` | {s['tier']} | {s['human_oversight'] or '—'} |")
    if bom.get("guardrails"):
        L += ["", "## Guardrails (gateway, `pre_call`, all consumers)", "",
              "| Name | Categories | Ours | Live |", "|---|---|---|---|"]
        live_g = set(bom.get("live_guardrails") or [])
        probed = bool(live_g)
        for g in bom["guardrails"]:
            cats = ", ".join(f"`{c}`" for c in (g.get("categories") or [])) or "—"
            own = ", ".join(f"`{c}`" for c in (g.get("custom_categories") or [])) or "—"
            # Only claim liveness when a live probe actually ran; a static build
            # must not render an unverified "yes".
            live = ("✅" if g.get("name") in live_g else "❌ NOT LOADED") if probed else "not probed"
            L.append(f"| `{g.get('name')}` | {cats} | {own} | {live} |")

    L += ["", "## Platform components", "",
          "| Name | Kind | Model / served by | License | Provenance |", "|---|---|---|---|---|"]
    for p in bom["platform"]:
        L.append(f"| `{p['name']}` | {p.get('kind','—')} | {p.get('model_id') or p.get('served_by','—')} "
                 f"| {p.get('license','—')} | {p.get('provenance','—')} |")
    L += ["", "## Corpora", "", "| KB | Collection | Enabled |", "|---|---|---|"]
    for c in bom["corpora"]:
        L.append(f"| `{c['name']}` | `{c['collection']}` | {c['enabled']} |")
    return "\n".join(L) + "\n"


def publish_metrics(f: Findings, n_systems: int, textfile_dir: Path) -> None:
    """Emit to node-exporter's textfile collector so drift alerts via the
    existing Alertmanager -> Discord path.

    Mirrors verify-backups.sh, including its hard-won gotcha: check writability
    explicitly. A present-but-unwritable dir is the DANGEROUS case — absent()
    never fires because the stale file still gets scraped, so the alert silently
    reports yesterday's good news forever (that bug hid a broken backup metric
    for 9 days; see todos.md #11).
    """
    if not textfile_dir.is_dir():
        print(f"  ! metrics: SKIP (no {textfile_dir})", file=sys.stderr)
        return
    if not os.access(textfile_dir, os.W_OK):
        print(f"  ! metrics: {textfile_dir} NOT WRITABLE by uid {os.geteuid()} — drift "
              f"results will go STALE SILENTLY. Fix: sudo chgrp homelab {textfile_dir} "
              f"&& sudo chmod 2775 {textfile_dir}", file=sys.stderr)
        return
    import time
    body = (
        "# HELP homelab_ai_bom_check_success 1 if the AI-BOM drift check found no failures.\n"
        "# TYPE homelab_ai_bom_check_success gauge\n"
        f"homelab_ai_bom_check_success {0 if f.fail else 1}\n"
        "# HELP homelab_ai_bom_drift_failures Governance drift findings at FAIL severity.\n"
        "# TYPE homelab_ai_bom_drift_failures gauge\n"
        f"homelab_ai_bom_drift_failures {len(f.fail)}\n"
        "# HELP homelab_ai_bom_drift_warnings Governance drift findings at WARN severity.\n"
        "# TYPE homelab_ai_bom_drift_warnings gauge\n"
        f"homelab_ai_bom_drift_warnings {len(f.warn)}\n"
        "# HELP homelab_ai_bom_systems_total AI systems in the inventory.\n"
        "# TYPE homelab_ai_bom_systems_total gauge\n"
        f"homelab_ai_bom_systems_total {n_systems}\n"
        "# HELP homelab_ai_bom_last_run_timestamp_seconds Unix time of the last completed check.\n"
        "# TYPE homelab_ai_bom_last_run_timestamp_seconds gauge\n"
        f"homelab_ai_bom_last_run_timestamp_seconds {int(time.time())}\n"
    )
    # Write-then-rename so a scrape never sees a half-written file.
    tmp = textfile_dir / f".homelab_ai_bom.prom.{os.getpid()}"
    tmp.write_text(body, encoding="utf-8")
    tmp.replace(textfile_dir / "homelab_ai_bom.prom")
    print(f"  metrics: wrote homelab_ai_bom.prom (failures={len(f.fail)})")


def main() -> int:
    ap = argparse.ArgumentParser(description="Build + check the AI-BOM.")
    ap.add_argument("--live", action="store_true", help="probe the platform (run on jarvis)")
    ap.add_argument("--check", action="store_true", help="exit non-zero on drift")
    ap.add_argument("--write", action="store_true", help="write docs/ai-bom.{json,md}")
    ap.add_argument("--publish", action="store_true",
                    help="emit Prometheus metrics to the textfile collector")
    ap.add_argument("--textfile-dir", default=os.environ.get(
        "TEXTFILE_DIR", "/var/lib/node_exporter/textfile"))
    a = ap.parse_args()

    inv = yaml.safe_load(INVENTORY.read_text(encoding="utf-8"))
    kb = json.loads(KB_MANIFEST.read_text(encoding="utf-8"))
    f = Findings()

    live: dict = {"kb": kb}
    if a.live:
        env = read_env(ENV_FILE)
        if not env:
            print(f"  ! no env at {ENV_FILE} — live probes will be skipped", file=sys.stderr)
        live["litellm"] = discover_litellm(env)
        live["qdrant"] = discover_qdrant(env)
        live["n8n"] = discover_n8n(env)
        live["traces"] = discover_trace_liveness()

    check_static(inv, kb, f)
    if a.live:
        check_live(inv, live, f)

    bom = build_bom(inv, kb, live)
    if a.write:
        # default=str: PyYAML parses unquoted `2026-07-22` into a datetime.date,
        # which json cannot serialize. Sections we pass through verbatim (like
        # `platform:`) therefore carry raw date objects. Stringify rather than
        # forcing every date in the inventory to be quoted — the file is meant to
        # be pleasant to hand-edit.
        BOM_JSON.write_text(json.dumps(bom, indent=2, default=str) + "\n", encoding="utf-8")
        BOM_MD.write_text(render_md(bom), encoding="utf-8")
        print(f"wrote {BOM_JSON.relative_to(REPO)} and {BOM_MD.relative_to(REPO)}")

    mode = "live" if a.live else "static"
    print(f"\nAI-BOM {mode} check — {len(bom['systems'])} systems, "
          f"{len(bom['platform'])} platform components, {len(bom['corpora'])} corpora")
    if f.fail or f.warn or f.note:
        f.render()
    print(f"\n  {len(f.fail)} fail · {len(f.warn)} warn · {len(f.note)} note")

    if a.publish:
        publish_metrics(f, len(bom["systems"]), Path(a.textfile_dir))

    if a.check and f.fail:
        print("\nDRIFT: inventory and reality disagree. Fix one of them.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
