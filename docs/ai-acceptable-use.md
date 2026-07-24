# AI acceptable use

**One page.** For the two of us and for the sibling-repo Claude Code sessions working on this platform.
It exists because policy that names the paved road only works if the goat path is also closed
([`ai-governance.md`](ai-governance.md) §3) — this is the naming half.

**Owner:** Paul Vilevac · **Last reviewed:** 2026-07-22

---

## The rules

1. **Go through the gateway.** Every model call from a platform service goes through **LiteLLM** with
   that system's own scoped key. Not the master key, not a direct call to unsloth, not a personal cloud
   key in a container env. This is what makes traffic attributable, bounded, and traced — and every
   claim in our governance story holds *only* for traffic that goes through it.

2. **One system, one key.** A new consumer gets its **own** entry in
   [`ai-inventory.yml`](ai-inventory.yml) and its own key from
   `docker/ai/litellm/provision-keys.py`. Don't borrow another system's key "just to test" — it
   silently mis-attributes the audit record. That's why the eval suite has its own key.

3. **The master key is administrative, never runtime.** It mints and revokes keys and reads all spend.
   If a service holds it, that service can revoke every other credential on the platform. The drift
   check fails on `master_key_use`.

4. **Know your tier before you build.** [`ai-risk-tiers.md`](ai-risk-tiers.md). Public surface or
   autonomous action ⇒ **at least T2**, which brings expiry, an oversight point, guardrails, and eval
   coverage. Decide it up front; retro-fitting is what makes governance feel like tax.

5. **Sensitive content stays local.** The local model is the default and that is a genuine privacy
   advantage — a deliberate posture, not an accident of the hardware. **Do not** paste credentials,
   customer data, entitled third-party feeds, or markets positions into a cloud model.

   ⚠️ **This rule went live on 2026-07-23 and is no longer hypothetical.** Three third-party models
   are now on the gateway and selectable in OpenWebUI:

   | Model in the picker | Goes to |
   |---|---|
   | `openrouter/claude-sonnet-5` | Anthropic, via OpenRouter |
   | `openrouter/gpt-5-mini` | OpenAI, via OpenRouter |
   | `openrouter/gemini-2.5-flash-lite` | Google, via OpenRouter |

   **Anything you type into a model whose name starts with `openrouter/` leaves the building.** That
   is the entire reason the prefix is in the model name rather than hidden in config — you should be
   able to see the boundary in the picker, at the moment you choose. Models with no prefix
   (`unsloth/Qwen3-8B-GGUF`, `bge-m3`) still run on our own hardware and never leave.

   These exist for **testing and demonstration** — evaluating frontier quality, and showing that a
   third-party model is subject to the same scoping, budget, rate limit, and trace attribution as a
   local one. They are not the default, and nothing routes to them automatically.

   OpenRouter's **`:free`** tier is deliberately **not** configured: free variants are generally
   served by providers that may train on submitted prompts, which is incompatible with this rule.

6. **A public surface may only reach a `public` corpus.** Enforced by `build_kb_workflows.py`
   (`select_for_surface`), asserted by the eval suite. If you find yourself wanting an exception,
   you want a different corpus.

7. **Don't wire in a new corpus without governance metadata.** owner / visibility / classification /
   licence / retention / `contains_pii` — the generator refuses without them. Record `unverified`
   rather than guessing a licence.

8. **Treat retrieved content as untrusted data, not instructions.** RAG corpora include third-party web
   pages and transcripts. A system prompt asking the model to behave is a *usability* control; the
   security control is what constrains the **output** (read-only queries, statement allowlists, capped
   limits).

9. **Prove it, then say it's done.** Same bar as the rest of this repo: run it, hit the endpoint, read
   the logs. For guardrails specifically, prove the **negative** — that the thing you blocked is
   actually blocked.

10. **Using AI assistants on your own machine is fine and encouraged.** This page governs what the
    *platform's services* do, not how you work. The line: don't paste anything from rule 5 into a tool
    that sends it off-box, and don't let an assistant's convenience become an ungoverned service.

---

## If you need an exception

Add `accepted_risk` to the system's inventory entry with an **owner** and a **`review_by` date**. The
drift check reports it (and fails if it's unsigned). An exception you can enumerate is governance
working; an undocumented one is just a gap.

## If something goes wrong

[`ai-incident-response.md`](ai-incident-response.md). The kill-switch is `/key/delete` on that system's
alias, and it is tested.
