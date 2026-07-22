# AI risk tiers + control matrix

Controls are applied **proportionally to impact if the system goes wrong** — not to how impressive the
model is, how new it is, or how much we like it. This is the tiering that
[`ai-governance.md`](ai-governance.md) §4 refers to and that
[`docker/ai/inventory/build-ai-bom.py`](../docker/ai/inventory/build-ai-bom.py) **mechanically enforces**.

**One page on purpose.** The moment tiering needs a committee to apply, it's dead.

---

## The tiers

| Tier | Test | Blast radius |
|---|---|---|
| **T0** | Sandbox / personal. No external data in, no public surface, no money or identity impact | A bad output wastes your afternoon |
| **T1** | Internal assistive. Internal users, internal corpora, **a human reads every output** before it matters | A bad output misleads someone who can check it |
| **T2** | External-facing **or** autonomous. A public surface, **or** it acts without a human in the loop per action | A bad output reaches a stranger, or takes an action nobody reviewed |
| **T3** | Consequential. Money, safety, or irreversible action | A bad output costs money or can't be undone |

**Deciding rules, in order:**

1. **Public surface → at least T2.** "Internal users are sensible" stops being a control the moment a
   stranger can type into it.
2. **Acts without a per-action human → at least T2**, even if internal. Autonomy is the risk, not the
   audience. A scheduled agent that writes to a store is T2; a chat window a human reads is T1.
3. **Touches money, safety, or an irreversible write → T3.** No exceptions for "it's only paper
   markets" — the tier tracks the *path*, not the current mode. A paper-mode system on the execution
   path is T3 with a mitigating control, not T2.
4. **When genuinely torn, round up.** The cost of over-tiering is some wasted rigor; the cost of
   under-tiering is the incident.

Tier is a **field in [`ai-inventory.yml`](ai-inventory.yml)**, not a judgment re-litigated per
conversation. Sibling repos propose their system's tier; this repo confirms it.

---

## The control matrix

Requirements are **cumulative** — T2 must satisfy everything T1 requires.

| Control | T0 | T1 | T2 | T3 | Enforced by |
|---|:--:|:--:|:--:|:--:|---|
| **Scoped credential** — a per-system LiteLLM virtual key, never the master key | ● | ● | ● | ● | `build-ai-bom.py` (`master_key_use`) |
| **Model scoping** — the key may call only the models it needs | ● | ● | ● | ● | LiteLLM (403 `key_model_access_denied`) |
| **Registered** — an inventory entry with an owner | ● | ● | ● | ● | `build-ai-bom.py` (`unregistered_credential`) |
| **Budget + rate limit** on the key | ○ | ● | ● | ● | `build-ai-bom.py` (`missing_budget`, `missing_rate_limit`) |
| **Attributable trace** — Langfuse can tell which system produced a call | ○ | ● | ● | ● | `build-ai-bom.py` (liveness / attribution) |
| **Key expiry + scheduled rotation** | ○ | ○ | ● | ● | `build-ai-bom.py` (`missing_expiry`) |
| **Named human-oversight point** — *where* a human is in the loop | ○ | ○ | ● | ● | `build-ai-bom.py` (`missing_oversight`) |
| **Input/output guardrails** — untrusted input and tool/query output are constrained | ○ | ○ | ● | ● | `todos.md` #41 |
| **Eval suite + pre-change gate** | ○ | ○ | ● | ● | `todos.md` #42 |
| **Incident runbook + tested kill-switch** | ○ | ○ | ● | ● | `todos.md` #46 |
| **AI-use disclosure** to the human interacting with it | ○ | ○ | ● | ● | `todos.md` #44 |
| **Step-up auth or two-person approval** on the consequential action | ○ | ○ | ○ | ● | Keycloak (`todos.md` #21) |

● required · ○ not required

**A row that isn't in the "Enforced by" column is a promise, not a control.** As each backlog item
lands, its row moves from a `todos.md` reference to a mechanical check. That migration *is* the
governance program — when the last row names an enforcer, the matrix is real.

---

## Applying it

**New system:** pick the tier with the four rules above → add an
[`ai-inventory.yml`](ai-inventory.yml) entry with an owner → run
`python3 docker/ai/inventory/build-ai-bom.py --check` (static) and, on jarvis, `--live`. It will tell
you which matrix rows you're failing. Full onboarding flow: [adding-an-app.md](adding-an-app.md).

**Changing a tier** is a real decision — record *why* in the entry's `notes`. Tiers ratchet up easily
and down only with reasoning, because "we downgraded it and then it broke" is the exact failure this
exists to prevent.

**Exceptions** go in the entry as `accepted_risk` with an owner and a date. An accepted risk that
nobody signed is just a gap; the field forces a name against it. The checker reports them but does not
fail on them — an exception you can enumerate is governance working, not governance failing.
