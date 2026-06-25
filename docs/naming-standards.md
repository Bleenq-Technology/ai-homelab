# Naming & Taxonomy Standard — sanctioned org

> **Status: v0.2 (2026-06-22)** — grounded in Paul's prior work in `ai-coding-eval` (the AI-coding-eval
> project's `DATA_MODELS.md` / `DATA_INTEGRATION.md`) and the **actual** practice in this repo. Supersedes
> the v0.1 strawman. Open reconciliation items in §8.

One naming model so data **correlates across infrastructure and products** — telemetry, tickets, services,
images, and code share one hierarchy. Naming is left-to-right hierarchical. **Infrastructure/shared-tech
(Jarvis) is named and managed separately from products** (e.g. the markets platform).

## 1. Business taxonomy (the correlation spine) — *from `ai-coding-eval` DATA_MODELS*

Five ordered levels, used as **dimensions/labels** on everything that emits data. Snake_case keys
(matching the data model's `*_id` FKs):

```
product_line  →  product  →  feature  →  use_case  →  workflow
```

| Level | Meaning | Example (markets) |
|-------|---------|-------------------|
| `product_line` | family of products | `example-products` |
| `product` | a deliverable product | `markets` |
| `feature` | capability area | `screening`, `execution`, `tax-reporting`, `portfolio` |
| `use_case` | a strategy / usage | `turtle`, `popper`, `orb` |
| `workflow` | the leaf — a user journey | `turtle-7am-review`, `popper-premarket-scan`, `tax-2026` |

**Secondary dimensions** also in the model: `release`, `sprint` (delivery); `capitalization_period`,
`capitalization_event` (cap-ex accounting of dev effort — ties to tax/financial reporting); `organization`,
`team`, `tenant`, `customer` (multi-tenant — productize-later).

## 2. Telemetry / logging fields — *CNCF-style, from `ai-coding-eval` DATA_INTEGRATION*

Every log/metric/trace carries these **plus** the §1 taxonomy dimensions:

`service` · `component` · `environment` (development|paper|production) · `site` (pdx|gcp|aws) · `version` ·
`trace_id` · `span_id` · `request_id` · `user_id` · `customer_id` · `tenant_id` · `organization_id`

(`component` and `service` are telemetry fields, **not** taxonomy levels.) This is what enables reporting
spanning *product_line → product → feature → use_case → workflow*.

## 3. Service identity & DNS — flat now, reverse-domain for `service.name` going forward

**Current practice (keep — do not churn):** flat-lowercase everywhere — Docker service/`container_name`,
Traefik routers, Prometheus `job_name`, volumes `<svc>_data`, Postgres `<app>`, Qdrant `kb_<domain>`.
Public DNS is **`<service>.<site>.example`** (wildcard TLS), where **`site`** is the hosting
location: **`pdx`** = the home lab (Jarvis + other hosts, Portland) today; cloud adds **`gcp`** / **`aws`**
(e.g. `<svc>.gcp.example`). Grafana dashboard uids already use a `jarvis-*` prefix.

**Going forward (identity layer only):** OTel **`service.name`** / correlation identity adopts the
reverse-domain form Paul intends for hosted services:
```
tech.sanctioned.<domain>.<service>     domain = jarvis (infra) | markets (product) | …
  tech.sanctioned.jarvis.qdrant        tech.sanctioned.markets.api
```
This is an **identity/label**, applied when OTel is wired — it does **not** rename containers, routers, or
DNS (those stay flat). `site` (e.g. `pdx`) and `environment` are labels, not part of the identity.

## 4. GitHub

- **One org** (`your-org`); model **product lines explicitly** via Projects + labels.
- **Repos = flat slugs**, split infra vs product: infra `ai-homelab-infra`; products `example-app`, …
- **Labels mirror the taxonomy:** `product:markets`, `feature:screening`, `use_case:turtle`,
  `workflow:turtle-7am-review`, plus `type:bug|feature|chore`, `priority:*`.
- Milestones = phases. `ai-coding-eval` used hierarchical `TASKS.md` checklists with **no formal IDs**; we
  add requirement IDs (`F-5`, …) as an improvement — issues reference them.

## 5. Container images (GHCR) — nested

```
ghcr.io/your-org/<repo>/<component>:<tag>     ghcr.io/your-org/example-app/api
```
Compose/service names stay short and flat: `<product>-<component>` (e.g. `example-api`). Built + published
by GitHub Actions; Jarvis pulls at deploy (registry auth via a `read:packages` token in Infisical).

## 6. Code naming — *idiomatic per language (matches `ai-coding-eval` + the scaffold)*

- **Python:** kebab-case package dirs (`analytics-engine`), snake_case modules (`analytics_engine`);
  our libs are short top-level (`signals`, `risk`, `brokers`).
- **TS/JS:** kebab-case dirs (`dashboard-service`, `shared-components`); **scoped packages**
  `@sanctioned/<name>` (Paul used `@your-org/shared-components`).
- **Service suffixes** seen historically: `-engine`, `-service`, `-components`, `-tools`.
- **Java/C#:** reverse-domain packages are natural (`tech.sanctioned.…`).
- Carry the taxonomy in labels/`service.name`, not Python import paths.

> **Repo strategy note:** `ai-coding-eval` was **multi-repo** (service-per-repo). example-app
> deliberately chose **monorepo-first** (ADR-0006) for its shared-core thesis + small team — an intentional
> divergence, not a contradiction; extract per-service repos only when a component earns it.

## 7. Knowledge bases (already standardized)
`kb_<domain>` shared / `<app>_<purpose>` private, `bge-m3` 1024/Cosine — see [`kb-standards.md`](kb-standards.md).

## 8. Decisions (2026-06-22) & remaining items
**Decided:**
- `product_line = example-products` (markets is a product under it).
- **DNS is site-based:** `<svc>.<site>.example`, `site ∈ {pdx (home/Portland), gcp, aws}`. `site`
  is a hosting-location label. (Not a `jarvis` subdomain — Jarvis is a host *in* the `pdx` site.)
- **Reverse-domain stays identity/`service.name`-layer only** — it does not rename services/DNS.

**Remaining:** exact label casing & controlled value lists; any Java reverse-domain roots already in use.
