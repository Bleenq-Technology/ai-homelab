# AI Governance — the standing position

**What this is.** How AI governance works on this platform, what it's enforced by, and where it
currently falls short. This is the **position**; the execution backlog is
[`todos.md` #36–#46](../todos.md). If you're adding an AI system, read this and
[adding-an-app.md](adding-an-app.md).

**Last reviewed:** 2026-07-22 · **Owner:** Paul Vilevac · **Review cadence:** quarterly, plus on any
new external-facing AI surface.

---

## 1. The thesis

**Governance that isn't technically enforced is advisory.**

Most AI governance programs are a policy problem, which is why most of them are theater — a document
asserting that models are used responsibly, with nothing in the system that would behave differently if
they weren't. The useful mental model is three layers:

| Layer | Answers | Where it lives here |
|---|---|---|
| **Governance** | Who decides, who's accountable | This doc + the owner field in the inventory |
| **Management** | What the lifecycle is | Registry, gates, evals, exceptions → `todos.md` #36/#37/#42 |
| **Enforcement** | How any of it becomes *physically true* | **Control points (§3)** — the gateway that won't authenticate an unapproved system, the generator that won't wire a private corpus into a public bot, the check that fails the build |

We optimize for the third layer. The reference frameworks (§6) describe *what* to govern well and *how
to enforce it* barely at all — that gap is where the engineering is.

**The practical test:** for every claim in this document, ask *"what would break if someone violated
it?"* If the answer is "nothing, but they shouldn't," it's advisory, and it belongs in the backlog as an
enforcement item — not here as a claim.

---

## 2. Scope and proportionality

This platform runs a shared local LLM, an embedding model, a RAG/KB layer, agent workflows, and two
public internet-facing chat surfaces, serving a two-person company, a family, and several sibling
product repos. It is **not** a regulated enterprise deployment, and the governance here is deliberately
sized to that.

Two things push it above hobby-grade anyway:

1. **Real consequence exists in places.** Public surfaces take input from strangers; `example-app`
   sits in the path of real money; `research-app` will handle entitled third-party feeds. Those
   deserve real controls. A personal ComfyUI instance does not. That asymmetry is the whole reason for
   risk tiering (§4).
2. **This repo is a reference architecture heading for open source** ([`todos.md` #14](../todos.md)).
   Governance we can *demonstrate* is part of what the repo is for.

**What we deliberately do NOT do,** and why — proportionality cuts both ways:

- **No governance body or review committee.** Two developers. A committee here would be pure ceremony
  and the bottleneck failure mode. Ownership is federated per system; this repo owns the schema and
  the gates (hub-and-spoke).
- **No formal bias/fairness program.** Wrong proportionality for internal tooling. Harm-category
  refusal tests on the *public* surfaces are folded into the eval suite instead ([#42](../todos.md)).
- **No ISO 42001 certification pursuit.** We borrow its structure; we're not buying an audit.
- **No model training.** We run open-weight models as-is. Training-data governance is therefore
  out of scope; **corpus** governance ([#43](../todos.md)) is very much in.

---

## 3. Control points — where governance is actually enforced

Governance operates at a high level precisely when it's enforced in a **small number of places**. Four
control points cover the platform. Every governance question should reduce to one of them; if a new
control needs a fifth, that's a design smell worth arguing about.

| # | Control point | Enforces | Status |
|---|---|---|---|
| **1** | **Traefik + Keycloak** (middleware chains, `secure-sso@file` / `secure-chain@file`, oauth2-proxy) | *Who reaches what.* No service is exposed without an explicit chain; SSO is one label, not a per-app integration | ✅ **Operating** |
| **2** | **Infisical** (`pull-secrets.sh` / `push-secret.sh`) | *What credentials exist.* Single source of truth; `.env` is a generated artifact; hand-editing on the host is a documented violation | ✅ **Operating** |
| **3** | **LiteLLM gateway** (virtual keys, model scoping, Langfuse tracing) | *What may talk to a model, and every call is recorded* | ⚠️ **Partial** — scoping works and is proven; **no budgets/rate limits/expiry** ([#38](../todos.md)); and it is **not yet a chokepoint** — egress around it is open ([#39](../todos.md)) |
| **4** | **AI inventory + AI-BOM** | *What is approved to exist.* Approval in the registry **is** the credential — an unregistered system can't authenticate | ❌ **Does not exist** ([#36](../todos.md)) — the highest-leverage gap |

Two structural principles behind these:

- **Approval should be the credential, not a document about the credential.** Minting a virtual key
  reads the inventory; a system with no entry gets no key. That's how a registry stops being a
  spreadsheet.
- **The audit answer should be an artifact, not a memory.** "What AI systems do we run, who owns them,
  what data do they touch, what did they do on July 8th" must be answerable by running something. Today
  it isn't. After #36 + #40, it is.

**And the tension to hold:** *enablement vs. control.* Clamp down and you create shadow AI. The paved
road has to be **faster** than the goat path — which is why #38 warns against over-tightening internal
limits at the same time #39 closes the bypass. Do only the second and people route around you; do only
the first and there's nothing to route around.

---

## 4. Risk tiers

Controls are applied proportionally to **impact if the system goes wrong** — not to how impressive the
model is. Provisional tiers (formalized in [#37](../todos.md)):

| Tier | Meaning | Examples here |
|---|---|---|
| **T0** | Sandbox / personal. No external data, no public surface, no money or identity impact | ComfyUI |
| **T1** | Internal assistive. Internal users and corpora; a human reads every output | OpenWebUI, the KB chat, Assistant |
| **T2** | External-facing **or** autonomous — a public surface, or acts without a human in the loop per action | `chat.example.com`, `chat.example-site.ai`, scheduled n8n agent flows, Home Assistant control |
| **T3** | Consequential. Money, safety, or irreversible action | Anything touching the markets execution path; anything with write access to a system of record |

Required controls escalate with tier — scoped key (all) → budget + rate limit (T1+) → attributable trace
(T1+) → named human-oversight point (T2+) → input/output guardrails (T2+) → eval gate (T2+) → owner +
incident runbook (T2+) → step-up or two-person approval on the consequential action (T3).

**The matrix is worthless if it's prose.** It's only real once #36's drift check asserts it.

---

## 5. Current posture by axis

Honest, as of **2026-07-22**, verified against the live platform rather than inferred. The pattern is
consistent: **strong where enforcement is infrastructure, absent where governance needs an artifact.**

| Axis | Posture | Evidence / gap |
|---|---|---|
| **Accountability & oversight** | ⚠️ Informal | Real ownership exists (two devs, sibling-repo sessions) but no named owner per system and no documented oversight point → [#46](../todos.md) |
| **Inventory & lifecycle** | ❌ Absent | No inventory, AI-BOM, or model card anywhere in the tree → [#36](../todos.md). **Blocks nine of the other axes** |
| **Risk classification** | ❌ Absent | Every surface gets identical controls regardless of blast radius → [#37](../todos.md) |
| **Data governance** | ⚠️ Partial | One embedding standard, a version-controlled KB registry, provenance fields in the payload schema. But `kb-manifest.json` carries **no owner/visibility/classification/license/retention** — drifted from [`kb-standards.md`](kb-standards.md) §6, which specifies owner + visibility → [#43](../todos.md) |
| **Security** | ✅ Strong / ⚠️ one gap | Keycloak + Traefik chains, three-network segmentation, Infisical, least-privilege DB/object roles **proven by negative test**, pinned images, CI (Trivy + hadolint + AI review + push protection). Gap: no injection/output guardrails on agent surfaces, incl. an unguarded text2cypher path → [#41](../todos.md) |
| **Privacy** | ❌ Absent | Discord-harvested corpora contain third-party PII with no consent record and **no delete path** (ingest clears-and-rebuilds); public prompts logged with no notice → [#44](../todos.md) |
| **Transparency & traceability** | ⚠️ Partial | Langfuse traces every gateway call — but only **14 days**, and only for traffic that opts into the gateway → [#40](../todos.md), [#39](../todos.md) |
| **Output safety** | ❌ Untested | No harm-category testing on the public surfaces; safety is asserted, not measured → [#42](../todos.md) |
| **Reliability & monitoring** | ✅ Infra / ❌ AI | Prometheus, Alertmanager→Discord, Loki, Uptime Kuma, backups **restore-verified weekly** with dead-man alerts. Zero evals, zero drift detection, zero AI-failure alerting → [#42](../todos.md) |
| **Third-party & shadow AI** | ❌ Absent | Verified: a container on the `ai` network reaches `api.openai.com` / `api.anthropic.com` (401 = reached). The gateway is a paved road, not a chokepoint → [#39](../todos.md) |

**Two summary judgments.** The platform is *stronger than most on enforcement modules and weaker than
most on inventory* — the opposite of the usual failure mode, and a much better place to start from,
because modules are the hard part. And the single highest-leverage move is [#36](../todos.md):
without an inventory you cannot tier, attribute, gate, or audit.

---

## 6. Reference frameworks

Borrowed for structure and vocabulary, not compliance:

- **NIST AI RMF** (+ Generative AI Profile, AI 600-1) — the Govern / Map / Measure / Manage functions.
  Our weakest is **Measure** (§5: no evals).
- **ISO/IEC 42001** — AI management-system structure (Annex SL: §5 leadership, §6 planning, §8
  operation, §9 performance evaluation, §10 improvement). Used as a checklist, not a certification target.
- **EU AI Act** — the risk-tier vocabulary (prohibited / high-risk / limited / minimal) behind §4, and
  the **limited-risk transparency** obligation — disclose that a human is interacting with AI — which is
  why the public-surface notice is in [#44](../todos.md).
- **OWASP Top 10 for LLM Applications** — the security slice: prompt injection (LLM01), insecure output
  handling (LLM02), supply chain (LLM03), poisoning (LLM04), excessive agency (LLM06), unbounded
  consumption (LLM10). Mapped item-by-item in the backlog.
- **MITRE ATLAS** — adversarial taxonomy for threat modeling AI-specific attack paths.

> **Currency caveat.** The **axes are stable** — they're the load-bearing structure everything new gets
> bolted onto. The **specifics move**: ISO 42001 certification practice and EU AI Act guidance have both
> been evolving through 2025–2026. Re-verify dates, phase-in deadlines, and clause references before
> citing them externally or to a customer. Treat the framework references above as a map, not a citation.

---

## 7. How this stays operating (and doesn't become theater)

A filed backlog is not a program. Four things convert it:

1. **A scheduled check for every claim.** Each backlog item terminates in something that runs on a
   cadence and **fails loudly** — weekly inventory drift, the eval suite, model-hash verification. This
   is the pattern [`verify-backups.sh`](../docker/verify-backups.sh) already proved: verify the
   *restore* side, don't trust the write side. A control nobody tests is a belief.
2. **Alerting through the existing path.** Every signal — eval failure, budget breach, guardrail trip,
   shadow-AI egress, inventory drift — goes to Alertmanager → Discord. No second notification channel,
   and nothing that requires a human to remember to look.
3. **Federated ownership, central schema.** Sibling repos (`assistant-app`, `web-app`, `example-app`,
   `research-app`, `content-curator`, `example-site-web`, `home-assistant-infra`) own their
   inventory entry's *content* and propose their own tier. This repo owns the schema and the gate.
   Handoffs go in **their** repo per [`CLAUDE.md`](../CLAUDE.md) — don't edit sibling configs.
4. **Honest status, dated.** §5 is a live posture table, not an aspiration. When something is absent it
   says absent. A governance doc that reads as uniformly green is the tell that nobody's checking.

**If only three things ever get done:** [#36](../todos.md) (inventory), [#38](../todos.md) (bounded
credentials), [#39](../todos.md) (close the bypass). That's the enforcement spine — approval → credential
→ chokepoint. The remaining seven are refinement on top of it, and refinement without the spine is
exactly the theater this document exists to avoid.

---

## Related

| Topic | Doc |
|---|---|
| Execution backlog (#36–#46) | [`todos.md`](../todos.md) |
| Adding an app/service (the workflow governance hooks into) | [adding-an-app.md](adding-an-app.md) |
| Identity, SSO, per-app auth decisions | [`docker/core/keycloak/README.md`](../docker/core/keycloak/README.md) |
| Routing, middleware chains, exposure | [`docker/core/traefik/README.md`](../docker/core/traefik/README.md) |
| Secrets (Infisical) | [`docker/core/infisical/README.md`](../docker/core/infisical/README.md) |
| LLM gateway + virtual keys | [`docker/ai/litellm/README.md`](../docker/ai/litellm/README.md) |
| KB standards + corpus registry | [kb-standards.md](kb-standards.md) · [kb-manifest.json](kb-manifest.json) |
| Vulnerability reporting (different thing) | [`SECURITY.md`](../SECURITY.md) |
