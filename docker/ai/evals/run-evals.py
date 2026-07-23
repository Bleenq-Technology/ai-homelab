#!/usr/bin/env python3
"""
Run the governance eval suite against the LIVE platform (todos.md #42).

    ./run-evals.py                 # run everything, report
    ./run-evals.py --publish       # + Prometheus metrics
    ./run-evals.py --blocking-only # only the security/isolation cases

Exit 1 if any BLOCKING case fails. Non-blocking (quality) cases are reported and
never gate — a gate that is usually red gets disabled, so only properties that
must hold are allowed to fail the run.

Deliberately assertion-based, not LLM-judged. Every case here is checkable with a
status code, a substring, a regex, or a vector length. Where a property cannot be
checked deterministically it does not belong in the blocking set.

See: docs/ai-governance.md · docker/ai/evals/README.md
"""
from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required:  pip install pyyaml  (or apt install python3-yaml)")

HERE = Path(__file__).resolve().parent
CASES = Path(os.environ.get("EVAL_CASES", HERE / "cases.yml"))
ENV_FILE = Path(os.environ.get("HOMELAB_ENV", "/opt/homelab/.env"))
LITELLM = os.environ.get("LITELLM_URL", "https://litellm.lab.example")
N8N = os.environ.get("N8N_URL", "https://n8n.lab.example")
TEXTFILE_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/node_exporter/textfile")
CTX = ssl.create_default_context()


def read_env(p: Path) -> dict[str, str]:
    d: dict[str, str] = {}
    if not p.is_file():
        return d
    for line in p.read_text(errors="replace").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


ENV = read_env(ENV_FILE)


def http(url: str, body=None, headers=None, method=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method or ("POST" if data else "GET"),
        headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        # 0 = the probe could not run. Distinct from a failed assertion, and
        # never silently treated as a pass.
        return 0, f"__probe_error__ {e}"



def http_noredirect(url: str, timeout: int = 30):
    """GET without following redirects — a 3xx is the signal, not a failure."""
    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    op = urllib.request.build_opener(_NoRedirect)
    try:
        with op.open(urllib.request.Request(url), timeout=timeout) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return 0, f"__probe_error__ {e}"

def status_ok(spec, got: int) -> bool:
    """Accepts 200, '200', or a '401-403' range — some checks legitimately admit
    more than one refusal code (LiteLLM answers 401 for a bad key and 403 for an
    out-of-scope model, and which one applies is not the property under test)."""
    if spec is None:
        return True
    s = str(spec)
    if "-" in s:
        lo, hi = (int(x) for x in s.split("-", 1))
        return lo <= got <= hi
    return got == int(s)


def dig(obj, path: str):
    cur = obj
    for part in path.split("."):
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def run_case(c: dict) -> tuple[bool, str]:
    kind = c.get("kind")
    if kind == "litellm":
        key = ENV.get(c["key_env"], "")
        if not key:
            return False, f"{c['key_env']} not in {ENV_FILE}"
        st, body = http(LITELLM + c["endpoint"], c.get("body"),
                        {"Authorization": f"Bearer {key}"}, c.get("method"))
    elif kind == "litellm_raw":
        # Unauthenticated GET that must NOT follow redirects — used to assert the
        # admin UI hands off to Keycloak instead of serving a password form.
        st, body = http_noredirect(LITELLM + c["path"])
    elif kind == "webhook":
        headers = {}
        if c.get("send_token"):
            tenv = c.get("token_env", "WEB_APP_BFF_TOKEN")
            tok = ENV.get(tenv, "")
            if not tok:
                return False, f"{tenv} not in {ENV_FILE}"
            headers["x-app-token"] = tok
        st, body = http(N8N + c["path"], c.get("body"), headers, c.get("method"))
    else:
        return False, f"unknown case kind {kind!r}"

    if body.startswith("__probe_error__"):
        return False, body

    if not status_ok(c.get("expect_status"), st):
        return False, f"status {st}, expected {c['expect_status']}"

    low = body.lower()

    for needle in c.get("expect_not_contains", []):
        if needle.lower() in low:
            return False, f"response contained forbidden {needle!r}"

    nca = c.get("expect_not_contains_any")
    if nca:
        hits = [n for n in nca if n.lower() in low]
        if hits:
            return False, f"leaked out-of-scope terms: {hits}"

    cany = c.get("expect_contains_any")
    if cany and not any(n.lower() in low for n in cany):
        return False, f"none of {cany} present in response"

    pat = c.get("expect_not_matches")
    if pat and re.search(pat, body, re.I):
        return False, f"response matched forbidden pattern /{pat}/"

    jp = c.get("expect_json_path")
    if jp:
        try:
            if dig(json.loads(body), jp) in (None, ""):
                return False, f"json path {jp} missing/empty"
        except json.JSONDecodeError:
            return False, "response was not JSON"

    dim = c.get("expect_vector_dim")
    if dim:
        try:
            v = dig(json.loads(body), "data.0.embedding")
            if not isinstance(v, list):
                return False, "no embedding in response"
            if len(v) != dim:
                return False, f"embedding dim {len(v)}, expected {dim}"
        except json.JSONDecodeError:
            return False, "response was not JSON"

    return True, "ok"


def publish(passed, failed, blocking_failed, total, dur):
    d = Path(TEXTFILE_DIR)
    if not d.is_dir():
        print(f"metrics: SKIP (no {d})", file=sys.stderr)
        return
    if not os.access(d, os.W_OK):
        print(f"[ERROR] metrics: {d} NOT WRITABLE — results go STALE SILENTLY", file=sys.stderr)
        return
    body = (
        "# HELP homelab_ai_eval_success 1 if no BLOCKING eval case failed.\n"
        "# TYPE homelab_ai_eval_success gauge\n"
        f"homelab_ai_eval_success {0 if blocking_failed else 1}\n"
        "# HELP homelab_ai_eval_blocking_failures Failing security/isolation cases.\n"
        "# TYPE homelab_ai_eval_blocking_failures gauge\n"
        f"homelab_ai_eval_blocking_failures {blocking_failed}\n"
        "# HELP homelab_ai_eval_failures Failing cases of any severity.\n"
        "# TYPE homelab_ai_eval_failures gauge\n"
        f"homelab_ai_eval_failures {failed}\n"
        "# HELP homelab_ai_eval_cases Total cases executed.\n"
        "# TYPE homelab_ai_eval_cases gauge\n"
        f"homelab_ai_eval_cases {total}\n"
        "# HELP homelab_ai_eval_duration_seconds Wall time of the last suite run.\n"
        "# TYPE homelab_ai_eval_duration_seconds gauge\n"
        f"homelab_ai_eval_duration_seconds {dur:.1f}\n"
        "# HELP homelab_ai_eval_last_run_timestamp_seconds Unix time of the last run.\n"
        "# TYPE homelab_ai_eval_last_run_timestamp_seconds gauge\n"
        f"homelab_ai_eval_last_run_timestamp_seconds {int(time.time())}\n"
    )
    tmp = d / f".homelab_ai_evals.prom.{os.getpid()}"
    tmp.write_text(body, encoding="utf-8")
    tmp.replace(d / "homelab_ai_evals.prom")
    print(f"metrics: wrote homelab_ai_evals.prom (blocking_failures={blocking_failed})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--publish", action="store_true")
    ap.add_argument("--blocking-only", action="store_true")
    a = ap.parse_args()

    spec = yaml.safe_load(CASES.read_text(encoding="utf-8"))
    cases = [c for c in spec["cases"] if not a.blocking_only or c.get("blocking")]

    t0 = time.time()
    passed = failed = blocking_failed = 0
    results = []
    print(f"\nAI governance evals — {len(cases)} cases\n")
    for c in cases:
        ok, msg = run_case(c)
        tag = "BLOCKING" if c.get("blocking") else "advisory"
        if ok:
            passed += 1
            print(f"  PASS  [{tag}] {c['name']}")
        else:
            failed += 1
            if c.get("blocking"):
                blocking_failed += 1
            print(f"  FAIL  [{tag}] {c['name']}  — {msg}")
            print(f"          why: {' '.join((c.get('why') or '').split())}")
        results.append((c["name"], ok))

    dur = time.time() - t0
    print(f"\n  {passed} passed · {failed} failed "
          f"({blocking_failed} blocking) · {dur:.0f}s")

    if a.publish:
        publish(passed, failed, blocking_failed, len(cases), dur)

    if blocking_failed:
        print("\nBLOCKING eval failure — a security or isolation property regressed.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
