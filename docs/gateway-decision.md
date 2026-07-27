# LLM gateway: stay on LiteLLM, or move to Kong? — the decision

**Verdict (2026-07-22): STAY on LiteLLM. Do not swap for reputation alone.** Revisit only on a concrete
trigger (below). This is the written recommendation `todos.md` #5 asks for.

**Owner:** Paul Vilevac. **One-line summary for anyone who asks "why LiteLLM after its CVE year":**
we run a patched build, internal-only, CI-scanned, wrapped in a scoped-key governance layer — and a
swap now costs weeks plus an unresolved Langfuse-tracing risk, for a reputational concern that a
posture note answers more cheaply.

---

## 1. The concern is legitimate

LiteLLM had a genuinely bad 2026: an RCE in CISA's KEV catalog (`CVE-2026-42271`), an unauth SQLi
exploited within 36 hours (`CVE-2026-42208`, CVSS 9.3), a low-priv→host-RCE chain (CVSS 9.9), and an
auth-bypass (`CVE-2026-49468`). "The moment people see LiteLLM they recall the lapse" is a real
reaction, and for a firm whose product *is* AI governance, optics are not vanity — they're part of the
pitch.

So this document does not dismiss the concern. It argues the concern is best answered by making our
**posture legible**, not by swapping the tool.

## 2. Current LiteLLM security posture (verified live 2026-07-22)

| Control | State |
|---|---|
| **Version** | Pinned `ghcr.io/berriai/litellm:v1.89.1` — **above** the fixed `v1.83.14-stable`; all four CVEs above are patched |
| **Exposure** | Admin/proxy port `:4000` is **not published to the host** — internal to the Docker networks only (verified: no `ports:` mapping) |
| **Edge** | Behind Traefik `secure-chain@file` (hardened headers, rate-limit); a no-key request to the public URL returns **401** (verified live) |
| **Auth** | No runtime consumer holds the master key (#38); every system has a scoped virtual key with budget + rate-limit + expiry |
| **CI** | Every PR runs Trivy (config/IaC), hadolint, and an AI security review; GitHub secret-scanning + push protection on |
| **Wrapped by governance** | Scoped keys, the AI-BOM shadow-credential check, egress **detection**, an attributable + append-only audit trail |

**Reframed for the pitch:** *"They use the tool that had CVEs"* is the weak reading. The accurate one is
*"They pin above the fix, keep the admin surface off the network, scan every change in CI, and wrap the
gateway in a scoped-key + audit layer."* That is a **mature vulnerability-response process** — which is
the exact competency an AI-governance engagement is selling. The posture is a strength to show, not a
weakness to hide.

## 3. What a Kong swap would cost NOW (and why it grew)

When #5 was filed, the swap was "re-point everything at `:4000`." The governance work since has made the
platform's control plane **LiteLLM-key-shaped**, so the cost is no longer the proxy — it's re-homing the
governance layer. Coupled pieces, each needing a Kong-Admin-API rewrite:

| Piece | Depends on LiteLLM's… |
|---|---|
| [`provision-keys.py`](../docker/ai/litellm/provision-keys.py) | virtual-key objects (`max_budget`/`tpm`/`rpm`/`duration`) |
| [`build-ai-bom.py`](../docker/ai/inventory/build-ai-bom.py) | `/key/list` for the `unregistered_credential` drift check |
| [`export-audit.sh`](../docker/ai/audit/export-audit.sh) + the whole audit trail | `user_api_key_alias` stamped on every Langfuse trace |
| eval `key-scope-enforced`, the kill-switch, "one system one key" (AUP) | `/key/generate` · `/key/delete` · model scoping |
| config `langfuse_default_tags` | native Langfuse callback + per-key tagging |

Plus re-pointing ~14 files and 6 sibling repos at the new gateway, and confirming budget/spend parity —
some of which is **Kong Enterprise**, not CE.

## 4. The gate: Langfuse tracing (this is the go/no-go)

#5's original gating criterion still holds and is now sharper: **the audit trail (#40) reads the system
identity from the `user_api_key_alias` tag LiteLLM writes onto each Langfuse trace.** That tagging is
native to LiteLLM and is the spine of our attribution.

Kong CE has **no Langfuse plugin**. A swap would mean an `ai-proxy → http-log → shim → Langfuse` path,
and the open question — the one fact that decides the whole thing — is whether that path can carry a
**per-key identity** we can map to the inventory the way `user_api_key_alias` does today. If it can't,
the swap doesn't just cost more; it **regresses the audit trail** we just made tamper-resistant.

**So any serious Kong evaluation starts with a half-day spike:** stand up Kong CE DB-less, `ai-proxy` to
the unsloth upstream, and prove (or disprove) equivalent per-key Langfuse traces. **Spike fails → stay,
with evidence. Spike passes → scope the migration as its own project** and budget for §3.

We have **not** run that spike, because the verdict below doesn't require it yet.

## 5. Verdict + revisit trigger

**Stay on LiteLLM.** The reputational concern is answered by §2 (make the posture legible), the swap
cost is now weeks not hours (§3), and the Langfuse gate is an unresolved risk that could turn the swap
into an audit-trail regression (§4). Swapping a patched, wrapped, internal gateway for a different large
attack surface (Kong's OpenResty/Lua core has its own advisory history) trades a known devil for an
unknown one — not a reputation win, a lateral move.

**Revisit if any of these becomes true:**

1. **A new *unpatched* LiteLLM CVE** lands (especially unauth or RCE) with no timely fix — trust, not
   optics, would then be the driver, and that's a legitimate reason to move.
2. **A concrete reputational cost** materializes — a customer, partner, or auditor objects to LiteLLM by
   name in a way the posture note doesn't satisfy.
3. **We need a CE feature LiteLLM lacks** that Kong has natively.

On trigger (1) or (2), the first action is the **Langfuse spike (§4)**, not a migration — it's the cheap
fact that decides everything else.

---

*Alternatives briefly weighed and not pursued: **Apache APISIX** (similar AI plugins, same Langfuse-gap
question, same re-homing cost) and **Portkey** (adds a third-party dependency, cutting against the
"local-first, self-hosted" posture). Neither changes the analysis: the cost is the governance coupling
and the Langfuse gate, not the choice of replacement.*
