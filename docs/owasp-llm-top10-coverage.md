# OWASP Top 10 for LLM Applications — platform coverage

**What this is.** A vetting of *this platform* against the **OWASP Top 10 for LLM Applications (2025)** —
each risk mapped to the controls we actually run, the evidence, and the **honest residual gap**. It's
the security-specific slice of [`ai-governance.md`](ai-governance.md); the general framing is there.

**Last vetted:** 2026-07-22 · **Owner:** Paul Vilevac. A ✅ has a control *and* a test behind it; ⚠️ is
partial; ❌ is a named gap. Rounding everything to green would defeat the point.

---

| # | Risk | Coverage | The control(s) — and the gap |
|---|---|:--:|---|
| **LLM01** | Prompt Injection | ⚠️ | **Output-side is enforced** on the one path where injection reaches an action: the text2cypher graph tool runs an LLM-generated query against a live Neo4j, and the guard denylists write verbs, allowlists the opening clause, caps `LIMIT`, and logs every statement ([#41](../todos.md)). Injection→`DETACH DELETE` is refused and **eval-tested**. **Gap:** no input-side classifier on the public surfaces (deliberately deferred — #41 calls it the weakest control), and indirect injection via poisoned RAG content is only partly mitigated (provenance, not sanitisation). |
| **LLM02** | Sensitive Information Disclosure | ✅ | Secrets **redacted in logs** by shape ([#49](../todos.md)); the audit record stores **hashes, not prompt/response bodies** ([#40](../todos.md)); PII **measured, minimised, with a delete path** ([#44](../todos.md)); per-system **scoped keys** cap what any one system can reach; private corpora are **structurally isolated** from public surfaces ([#43](../todos.md), generator-enforced + eval-tested). |
| **LLM03** | Supply Chain | ✅ | Model weights carry a **provenance manifest** and are **hash-verified weekly** ([#45](../todos.md)); **all images pinned** (no `:latest`); CI runs **Trivy + hadolint + an AI review**; the LiteLLM CVE posture is a **documented decision** ([gateway-decision.md](gateway-decision.md)). |
| **LLM04** | Data & Model Poisoning | ⚠️ | Corpus **provenance + licence** recorded ([#43](../todos.md)); model **integrity hashing** ([#45](../todos.md)); **per-source erasure** for a bad source ([#44](../todos.md)). **Gap:** harvested web/YouTube content is not sanitised or credibility-gated at ingest beyond the curator's filter — poisoned-source handling is **reactive** (delete once found), not preventive. |
| **LLM05** | Improper Output Handling | ✅ | The dangerous output path (LLM→Cypher→live DB) is handled: **read-only intent, statement allowlist, capped limit, full logging** ([#41](../todos.md)). Tool outputs are scoped by **corpus-boundary authz** ([#43](../todos.md)). **Note:** rendering chat answers safely (markdown/HTML/script) is the consuming **app's** responsibility (project side) — see [infra-vs-project-boundary.md](infra-vs-project-boundary.md). |
| **LLM06** | Excessive Agency | ✅ | **Model scoping** per key (out-of-scope model → 403, eval-tested); the text2cypher tool holds a **read-only credential** and an allowlist ([#41](../todos.md)); no autonomous **money/irreversible** action without a human (the T3 execution gate); agent tools are per-credential scoped in n8n. |
| **LLM07** | System Prompt Leakage | ⚠️ | **Mitigating fact:** our system prompts carry **no secrets** — keys live in credentials, not prompts; a leaked system prompt exposes the KB catalog + instructions, not credentials. **Gap:** no explicit control or eval that a crafted prompt can't extract the system prompt. Filed as [#50a](../todos.md) (add an extraction-attempt eval; keep the no-secrets-in-prompts invariant). |
| **LLM08** | Vector & Embedding Weaknesses | ⚠️ | **Cross-corpus isolation is enforced and eval-tested** — a public bot cannot reach a private collection ([#43](../todos.md); the `playbook-cannot-reach-web-app-corpus` blocking eval); **per-source delete** limits residue ([#44](../todos.md)); one embedding standard. **Gap:** no defence against embedding-inversion (content recovery from vectors) — low impact as collections are internal, but unaddressed. |
| **LLM09** | Misinformation | ⚠️ | Answers are **grounded RAG with citations**; the eval suite checks **retrieval correctness** ([#42](../todos.md)); human-oversight points are named per system. **Gap:** no **harm-category / hallucination testing** on the public surfaces (deferred #42 residual), and the AI-use **disclosure** that manages over-reliance is pending ([#44](../todos.md), handed to the sibling repos). |
| **LLM10** | Unbounded Consumption | ✅ | **Rate limits (rpm/tpm) + budgets + expiry per tier** on every key ([#38](../todos.md)); **429 negative-tested** (200,200,429,429…); public surfaces get the **tightest** numbers; the shared 3090 is protected from one scraped key. |

**Scorecard: 5 enforced-and-tested (LLM02/03/05/06/10), 4 partial (LLM01/04/08/09), 1 gap being closed
(LLM07).** No LLM risk is unmapped or unaddressed; the partials and the gap all have a named next step.

---

## The honest gaps, consolidated

1. **Input-side prompt-injection filtering** (LLM01) — deferred by design; output-handling is the
   stronger control and it's enforced.
2. **Ingest-time content vetting** (LLM04) — poisoned-source handling is reactive.
3. **System-prompt-extraction test** (LLM07) — [#50a], plus the standing invariant *no secrets in
   system prompts*.
4. **Harm-category / hallucination testing** on public surfaces (LLM09) — [#42] residual.
5. **AI-use disclosure** on the public chats (LLM09 over-reliance) — [#44], sibling-repo side.

## How this stays honest

This matrix is **re-vetted quarterly** (with `ai-governance.md`) and whenever a new external-facing AI
surface ships. The controls behind the ✅s are **the same tested controls** the daily eval suite and
weekly checks assert — so this isn't a point-in-time attestation, it's a view of the live, enforced
state. A ✅ that stopped being true would fail a scheduled check, not sit stale in a table.

*Ships in the public snapshot — an AI-governance firm showing its own platform vetted against OWASP-LLM,
gaps and all, is the point.*
