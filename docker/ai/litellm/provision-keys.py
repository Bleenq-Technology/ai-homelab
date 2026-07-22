#!/usr/bin/env python3
"""
Provision LiteLLM virtual keys FROM the AI inventory.

This is where "approval in the registry IS the credential" becomes physically
true: the only source of key configuration is docs/ai-inventory.yml, and a
system with no entry there cannot get a key from this tool. Minting by hand with
curl still works — which is exactly what the AI-BOM drift check catches
(`unregistered_credential`). The two halves are the control.

    ./provision-keys.py                 # dry run — show what WOULD change
    ./provision-keys.py --apply         # apply limits to existing keys
    ./provision-keys.py --apply --mint  # also mint keys the inventory declares
                                        # but that don't exist yet

Idempotent. Run it again and it reports "no changes".

Reads limits from `tier_limits` + `public_surface_overrides` in the inventory,
so changing policy is a reviewable diff, not a code edit.

See: docs/ai-governance.md · docs/ai-risk-tiers.md · todos.md #38
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required:  pip install pyyaml  (or apt install python3-yaml)")


def find_root(start: Path) -> Path:
    """Same dual-layout resolution as build-ai-bom.py — the repo and the
    deployed /opt/homelab tree have different depths."""
    if os.environ.get("AI_BOM_ROOT"):
        return Path(os.environ["AI_BOM_ROOT"]).resolve()
    for p in [start] + list(start.parents):
        if (p / "docs" / "ai-inventory.yml").is_file():
            return p
    return start.parent


ROOT = find_root(Path(__file__).resolve())
INVENTORY = ROOT / "docs" / "ai-inventory.yml"
ENV_FILE = Path(os.environ.get("HOMELAB_ENV", "/opt/homelab/.env"))
LITELLM_URL = os.environ.get("LITELLM_URL", "https://litellm.lab.example")


def read_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def api(path: str, mk: str, payload: dict | None = None, method: str | None = None):
    url = f"{LITELLM_URL}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method=method or ("POST" if data else "GET"),
        headers={"Authorization": f"Bearer {mk}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        print(f"  ! {method or 'GET'} {path} -> HTTP {e.code}: {body}", file=sys.stderr)
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        print(f"  ! {method or 'GET'} {path} failed: {e}", file=sys.stderr)
        return None


def wanted_limits(system: dict, inv: dict) -> dict:
    """Resolve the target limits for a system from its tier + surface."""
    tier = system.get("tier")
    base = dict((inv.get("tier_limits") or {}).get(tier) or {})
    if system.get("surface") == "public":
        base.update(inv.get("public_surface_overrides") or {})
    return base


def main() -> int:
    ap = argparse.ArgumentParser(description="Provision LiteLLM keys from the AI inventory.")
    ap.add_argument("--apply", action="store_true", help="actually write changes")
    ap.add_argument("--mint", action="store_true", help="mint declared-but-missing keys")
    a = ap.parse_args()

    inv = yaml.safe_load(INVENTORY.read_text(encoding="utf-8"))
    env = read_env(ENV_FILE)
    mk = env.get("LITELLM_MASTER_KEY")
    if not mk:
        sys.exit(f"LITELLM_MASTER_KEY not found in {ENV_FILE}")

    listing = api("/key/list?return_full_object=true&size=100", mk)
    if listing is None:
        sys.exit("could not list keys — refusing to guess at platform state")
    live = {k["key_alias"]: k for k in listing.get("keys", [])
            if not isinstance(k, str) and k.get("key_alias")}

    changes, minted, skipped = [], [], []

    for s in inv.get("systems", []):
        cred = s.get("credential") or {}
        alias = cred.get("alias")
        ctype = cred.get("type")

        if ctype in ("none", None):
            continue
        if ctype == "master_key":
            skipped.append(f"{s['name']}: still on the MASTER key — needs its own alias "
                           f"in the inventory before this tool can provision it")
            continue
        if not alias:
            skipped.append(f"{s['name']}: credential.type=litellm_key but no alias")
            continue

        want = wanted_limits(s, inv)
        if not want:
            continue

        payload: dict = {}
        for f in ("rpm_limit", "tpm_limit", "max_budget", "budget_duration"):
            if want.get(f) is not None:
                payload[f] = want[f]
        # LiteLLM sets expiry from a relative `duration` on both create and update.
        if want.get("expiry_days"):
            payload["duration"] = f"{want['expiry_days']}d"

        k = live.get(alias)
        if not k:
            if not a.mint:
                skipped.append(f"{s['name']}: key '{alias}' does not exist (use --mint)")
                continue
            body = {"key_alias": alias, "models": s.get("models") or [], **payload}
            if a.apply:
                r = api("/key/generate", mk, body)
                if r and r.get("key"):
                    minted.append((alias, r["key"]))
                else:
                    skipped.append(f"{s['name']}: mint FAILED")
            else:
                minted.append((alias, "<would mint>"))
            continue

        # Only send fields that actually differ — keeps the run idempotent and
        # makes the dry-run output an honest diff.
        diff = {f: v for f, v in payload.items()
                if f != "duration" and k.get(f) != v}
        if "duration" in payload and k.get("expires") is None:
            diff["duration"] = payload["duration"]
        if not diff:
            continue

        changes.append((s["name"], alias, diff))
        if a.apply:
            r = api("/key/update", mk, {"key": k["token"], **diff})
            if r is None:
                skipped.append(f"{s['name']}: update FAILED")

    mode = "APPLIED" if a.apply else "DRY RUN (use --apply)"
    print(f"\nLiteLLM key provisioning — {mode}\n")
    for name, alias, diff in changes:
        print(f"  {name} [{alias}]")
        for f, v in sorted(diff.items()):
            print(f"      {f} -> {v}")
    for alias, val in minted:
        shown = val if val.startswith("<") else f"{val[:8]}…{val[-4:]}"
        print(f"  MINTED  {alias}  {shown}")
        if not val.startswith("<"):
            key_env = alias.upper().replace("-", "_") + "_LLM_KEY"
            print(f"      -> store it:  ./push-secret.sh {key_env} '{val}'  &&  ./pull-secrets.sh")
    for s in skipped:
        print(f"  SKIP    {s}")
    if not changes and not minted:
        print("  no changes — every declared key already matches its tier policy")
    print(f"\n  {len(changes)} updated · {len(minted)} minted · {len(skipped)} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
