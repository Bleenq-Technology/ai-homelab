#!/usr/bin/env python3
"""
Container image drift: how far behind is what we are actually running?

WHY THIS EXISTS. We pin every image on purpose (CLAUDE.md: no `:latest`) — which
is right, and which means nothing ever updates unless a human notices. On
2026-07-24 a manual sweep found cloudflared **17 months** old (it terminates the
public tunnels) and minio **15 months** (a Keycloak OIDC client). Neither was a
decision; both were drift. Pinning without a drift check is just a slower way to
run old software.

This does NOT upgrade anything. It reports, exports metrics, and lets the
dead-man complain — same shape as check-egress.sh and verify-models.sh.

TWO THINGS THE NAIVE VERSION GETS WRONG, both learned by getting them wrong:

  1. ARCH/VARIANT TAGS ARE NOT NEWER VERSIONS. `v7.15.3-s390x`,
     `13.1.1-distroless`, `2.11.4-nanoserver` are the same release built
     differently. A sort that includes them reports upgrades that do not exist.
  2. A PINNED MAJOR IS A DECISION, NOT DRIFT. postgres 16 and redis 7 are
     deliberate tracks. Reporting "18 is out!" as if we were behind is noise, and
     noise is how a check gets ignored. Newer majors are reported SEPARATELY, as
     information.

It also flags FLOATING tags (`:latest`, `:2-alpine`, `:3`) — an image that can
change under you on any recreate is unpinned no matter how specific it looks.

Usage:  ./check-image-versions.py [--publish]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TEXTFILE_DIR = Path(os.environ.get("TEXTFILE_DIR", "/var/lib/node_exporter/textfile"))
UA = {"User-Agent": "homelab-version-drift/1.0"}
TIMEOUT = 25

VARIANT = re.compile(
    r"-(amd64|arm64|arm|armv[0-9]|armhf|s390x|ppc64le|386|distroless|"
    r"nanoserver[a-z0-9.-]*|windowsservercore[a-z0-9.-]*|cpuv[0-9]|fips|debug|"
    r"root|rootless|otel|ubi[0-9]*)$", re.I)
PRERELEASE = re.compile(r"(rc[0-9-]|beta|alpha|nightly|canary|snapshot|-dev|-pre|-next|insider)", re.I)
# FLOATING = the tag can point at different content over time. Named channels
# (`latest`, `main`) and MAJOR-only tags (`3`, `2-alpine`) both move.
#
# `[0-9]+\.[0-9]+` is deliberately NOT here: `postgres:16.14` and
# `dpage/pgadmin4:9.15` are specific releases, and an earlier version of this
# check flagged them as unpinned. A drift check that cries "unpinned!" at a
# correctly pinned image is one nobody reads by the third week.
FLOATING = re.compile(r"^(latest|main|stable|edge|master)$|^[0-9]+(-[a-z][a-z0-9]*)?$", re.I)
# Content-addressed tags (`sha-7bb1d58`) are the STRICTEST pin there is. They
# cannot be version-compared, but calling them "unknown" alongside a failed
# registry query would be actively misleading.
DIGEST_TAG = re.compile(r"^sha-[0-9a-f]{7,}$|^sha256[:-][0-9a-f]{7,}$", re.I)
# A bare 12+ hex string is a docker image ID, and compose-built images appear as
# `<project>-<service>` with no registry at all. Neither is upstream-trackable.
IMAGE_ID = re.compile(r"^[0-9a-f]{12,64}$")
# MinIO ships `RELEASE.2025-04-08T15-41-24Z` — not semver, but ISO-ordered, so it
# sorts correctly as a string. Handled explicitly because minio is a Keycloak
# OIDC client and "unknown" is precisely the wrong answer for the image that was
# 15 months stale when this check was written.
RELEASE_TAG = re.compile(r"^RELEASE\.\d{4}-\d{2}-\d{2}T[\d-]+Z$")

# Registries we do not know how to query. Recorded as `unknown`, never silently
# treated as current — an unknown must look different from an OK.
SKIP_HOSTS = ("lscr.io",)


def sh(*a) -> str:
    return subprocess.run(a, capture_output=True, text=True).stdout


def get(url, headers=None):
    r = urllib.request.Request(url, headers={**UA, **(headers or {})})
    with urllib.request.urlopen(r, timeout=TIMEOUT) as resp:
        return json.load(resp)


def split_image(img: str):
    """docker image ref -> (host, repo, tag)."""
    ref, _, tag = img.rpartition(":")
    if "/" not in img or ("." not in img.split("/")[0] and ":" not in img.split("/")[0]):
        if not ref:
            ref, tag = img, "latest"
    if not ref:
        ref, tag = img, "latest"
    parts = ref.split("/")
    if "." in parts[0] or ":" in parts[0]:
        return parts[0], "/".join(parts[1:]), tag
    if len(parts) == 1:
        return "docker.io", "library/" + parts[0], tag
    return "docker.io", ref, tag


def hub_tags(repo, pages=3):
    out, url = [], (f"https://hub.docker.com/v2/repositories/{repo}/tags"
                    f"?page_size=100&ordering=last_updated")
    for _ in range(pages):
        d = get(url)
        out += [t["name"] for t in d.get("results", [])]
        url = d.get("next")
        if not url:
            break
    return out


def quay_tags(repo):
    return [t["name"] for t in get(
        f"https://quay.io/api/v1/repository/{repo}/tag/"
        f"?limit=100&onlyActiveTags=true").get("tags", [])]


def github_releases(repo):
    """Newest non-prerelease tags from the GitHub Releases API.

    PREFERRED over the GHCR tag list for ghcr.io images, because tag listing does
    not scale: Open WebUI publishes 20,000+ tags, pagination is not ordered
    newest-first, and a page cap silently returns a STALE slice. That produced the
    worst possible output — v0.9.6 reported as `current` with "latest 0.3.13"
    while v0.10.2 existed. An `unknown` that looks like a pass is bad; a `current`
    that is wrong is worse, because nothing ever prompts a second look.
    """
    d = get(f"https://api.github.com/repos/{repo}/releases?per_page=30",
            {"Accept": "application/vnd.github+json"})
    return [r["tag_name"] for r in d if not r.get("prerelease") and not r.get("draft")]


def ghcr_tags(repo, max_pages=6):
    tok = get(f"https://ghcr.io/token?scope=repository:{repo}:pull")["token"]
    url, out = f"https://ghcr.io/v2/{repo}/tags/list?n=1000", []
    for _ in range(max_pages):
        r = urllib.request.Request(url, headers={**UA, "Authorization": f"Bearer {tok}"})
        with urllib.request.urlopen(r, timeout=TIMEOUT) as resp:
            out += json.load(resp).get("tags", [])
            link = resp.headers.get("Link", "")
        m = re.search(r'<([^>]+)>;\s*rel="next"', link)
        if not m:
            break
        url = "https://ghcr.io" + m.group(1)
    return out


def numeric(tag, suffix):
    """Version tuple for a tag on our track, else None."""
    t = VARIANT.sub("", tag)
    if PRERELEASE.search(t):
        return None
    if suffix:
        if not t.endswith(suffix):
            return None
        t = t[: -len(suffix)]
    elif "-" in t:
        return None
    t = t.lstrip("vV")
    return tuple(int(x) for x in t.split(".")) if re.fullmatch(r"\d+(\.\d+){1,3}", t) else None


def track_suffix(tag):
    """`7.4.9-alpine` -> `-alpine`; a variant we deliberately track."""
    t = VARIANT.sub("", tag).lstrip("vV")
    m = re.fullmatch(r"\d+(\.\d+){1,3}(-[a-z][a-z0-9]*)", t)
    return m.group(2) if m else ""


def running_images():
    seen = {}
    for line in sh("docker", "ps", "--format", "{{.Image}}").splitlines():
        img = line.strip()
        if img and not img.startswith("sha256:"):
            seen.setdefault(img, 0)
            seen[img] += 1
    return sorted(seen)


def check(img):
    host, repo, tag = split_image(img)
    row = {"image": img, "repo": repo, "tag": tag, "status": "unknown",
           "latest": None, "newer_majors": []}
    if IMAGE_ID.match(img) or (host == "docker.io" and "." not in img and ":" not in img):
        row["status"] = "local"          # compose-built; no upstream to track
        return row
    if DIGEST_TAG.match(tag):
        row["status"] = "digest"         # immutable by construction
        return row
    if FLOATING.match(tag):
        row["status"] = "floating"
        return row
    if any(host.startswith(h) for h in SKIP_HOSTS):
        row["status"] = "unknown"
        return row
    try:
        if host.startswith("ghcr.io"):
            # GitHub Releases first (authoritative + one call); fall back to the
            # registry for images whose repo has no releases or is private.
            try:
                tags = github_releases(repo)
                if not tags:
                    raise ValueError("no releases")
            except Exception:
                tags = ghcr_tags(repo)
        elif host.startswith("quay.io"):
            tags = quay_tags(repo)
        elif host.startswith("docker.io"):
            tags = hub_tags(repo)
        else:
            return row
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError):
        return row                                   # stays `unknown`, never "ok"
    # Date-ordered RELEASE.* tags: compare as strings, which is valid because the
    # embedded timestamp is ISO-ordered.
    if RELEASE_TAG.match(tag):
        rel = sorted(x for x in tags if RELEASE_TAG.match(x))
        if rel:
            row["latest"] = rel[-1]
            row["status"] = "behind" if rel[-1] > tag else "current"
        return row

    suffix = track_suffix(tag)
    cur = numeric(tag, suffix)
    if cur is None:
        return row
    vs = [v for t in tags for v in [numeric(t, suffix)] if v]
    if not vs:
        return row
    same = sorted([v for v in vs if v[0] == cur[0]], reverse=True)
    row["newer_majors"] = sorted({v[0] for v in vs if v[0] > cur[0]})
    if same:
        row["latest"] = ".".join(map(str, same[0]))
        row["status"] = "behind" if same[0] > cur else "current"
    return row


def publish(rows):
    if not TEXTFILE_DIR.is_dir():
        print(f"  ! metrics: {TEXTFILE_DIR} missing — skipped", file=sys.stderr)
        return
    if not os.access(TEXTFILE_DIR, os.W_OK):
        # Present-but-unwritable never fires absent() — the stale file keeps
        # getting scraped. Same trap as todos.md #11.
        print(f"  ! metrics: {TEXTFILE_DIR} NOT WRITABLE — results go STALE SILENTLY",
              file=sys.stderr)
        return
    c = lambda s: sum(1 for r in rows if r["status"] == s)  # noqa: E731
    body = (
        "# HELP homelab_image_versions_total Running container images checked.\n"
        "# TYPE homelab_image_versions_total gauge\n"
        f"homelab_image_versions_total {len(rows)}\n"
        "# HELP homelab_image_versions_behind Images with a newer release on their pinned major track.\n"
        "# TYPE homelab_image_versions_behind gauge\n"
        f"homelab_image_versions_behind {c('behind')}\n"
        "# HELP homelab_image_versions_floating Images on a moving tag (:latest, :2-alpine) — unpinned, violates the repo standard.\n"
        "# TYPE homelab_image_versions_floating gauge\n"
        f"homelab_image_versions_floating {c('floating')}\n"
        "# HELP homelab_image_versions_unknown Images whose registry could not be queried — NOT the same as current.\n"
        "# TYPE homelab_image_versions_unknown gauge\n"
        f"homelab_image_versions_unknown {c('unknown')}\n"
        "# HELP homelab_image_versions_last_run_timestamp_seconds Unix time of the last drift check.\n"
        "# TYPE homelab_image_versions_last_run_timestamp_seconds gauge\n"
        f"homelab_image_versions_last_run_timestamp_seconds {int(datetime.now(timezone.utc).timestamp())}\n")
    tmp = TEXTFILE_DIR / ".homelab_image_versions.prom.tmp"
    tmp.write_text(body)
    tmp.replace(TEXTFILE_DIR / "homelab_image_versions.prom")
    print(f"  metrics: wrote homelab_image_versions.prom (behind={c('behind')}, "
          f"floating={c('floating')}, unknown={c('unknown')})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--publish", action="store_true", help="write Prometheus textfile metrics")
    a = ap.parse_args()

    imgs = running_images()
    print(f"== container image drift — {len(imgs)} running images ==\n")
    rows = [check(i) for i in imgs]

    for label, head in (("behind", "BEHIND (newer release on the pinned major track)"),
                        ("local", "LOCALLY BUILT (no upstream to compare)"),
                        ("floating", "FLOATING TAG (unpinned — can change on any recreate)"),
                        ("unknown", "UNKNOWN (registry not queryable — NOT a clean bill of health)")):
        sel = [r for r in rows if r["status"] == label]
        if not sel:
            continue
        print(f"-- {head} --")
        for r in sorted(sel, key=lambda r: r["image"]):
            extra = f"  -> {r['latest']}" if r["latest"] else ""
            maj = (f"   (newer majors: {', '.join(map(str, r['newer_majors']))})"
                   if r["newer_majors"] else "")
            print(f"  {r['image']}{extra}{maj}")
        print()

    ok = [r for r in rows if r["status"] in ("current", "digest")]
    majors = [r for r in rows if r["status"] == "current" and r["newer_majors"]]
    if majors:
        print("-- current on a DELIBERATELY pinned major (informational, not drift) --")
        for r in sorted(majors, key=lambda r: r["image"]):
            print(f"  {r['image']}   (newer majors available: "
                  f"{', '.join(map(str, r['newer_majors']))})")
        print()
    print(f"== {len(ok)} current/digest-pinned · {sum(1 for r in rows if r['status']=='behind')} behind · "
          f"{sum(1 for r in rows if r['status']=='floating')} floating · "
          f"{sum(1 for r in rows if r['status']=='local')} local · "
          f"{sum(1 for r in rows if r['status']=='unknown')} unknown ==")

    if a.publish:
        publish(rows)
    # Reporting control: never fail the run. Being behind is a decision to make,
    # not an incident, and a job that exits non-zero every week gets muted.
    return 0


if __name__ == "__main__":
    sys.exit(main())
