# The infra ↔ project boundary

**Why this exists.** This repo is the **platform** (`ai-homelab-infra`). Sibling repos are **products**
(`assistant-app`, `example-app`, `research-app`, `content-curator`, `web-app`,
`example-site-web`, …). Over time, product-specific things drift *into* the platform repo —
which entangles the two, reveals the private portfolio, and makes the platform harder to open-source.
This doc draws the line, so every infra **and** project session keeps it.

**The good news, measured 2026-07-22:** the line already mostly holds. Product **apps are not defined in
the infra compose** — `example-api`, `web-app-bff`, `example-site-bff`, `dc-bot`, `assistant-app`
all deploy from *their own* repos onto the platform's shared networks. The infra compose defines only
platform services. The drift that remains is narrow (§4).

---

## 1. The principle

> **The platform is what any adopter would want. A product is one company's use of it.**

- **`ai-homelab-infra`** = reusable capability: reverse proxy, identity, secrets, the observability
  stack, the LLM gateway, the shared datastores, the AI-governance framework + tooling, the host LLM.
  Someone cloning this repo should get a *platform*, not our products.
- **A product repo** = one application's deployable units + its data + its config: its containers
  (BFF/bot/API), its KB corpus, its dashboards, its workflows, its schema.

## 2. The deciding test

For anything you're about to add to `ai-homelab-infra`, ask **in order**:

1. **Would a different adopter of this platform want it?** No → it's a product's, not the platform's.
2. **Is it one product's, or shared by several?** One product's → belongs in that product's repo.
3. **Is it a *capability* (a service/store/gateway) or a *use* of one (an app/corpus/dashboard)?**
   A use → the product's repo.

If all three point to the platform, it's infra. Otherwise it deploys **onto** the platform from a
product repo.

## 3. The two seams that keep it clean

**A. Deployment seam — products attach, they aren't baked in.** A product ships its **own** compose
(e.g. `deploy/prod/compose.*.yml` in its repo) that joins the platform's shared Docker networks
(`proxy` / `ai` / `data`). The infra repo defines the networks and the platform; the product's
containers are never added to the infra compose. *(This already holds — see the measured note above.)*

**B. Provisioning seam — the platform provisions, the product owns.** A product needs a namespace on a
shared store (a Postgres DB + roles, a Qdrant collection, a MinIO bucket, a scoped LiteLLM key, an
isolated Neo4j). It **files an ask** into `intake.md` (the cross-project intake queue, separate from the platform's own `todos.md`), infra **provisions the
namespace + credential** (`provision-*.sh`, the key pipeline), and the product **owns the schema, the
data, and the app**. Infra creates the empty room; the product furnishes it. This is the model already
used for #20/#21/#27/#31/#48 — it just needs to be the *only* model.

> **Common confusion (worth stating plainly): a project asking infra to create a Postgres DB + roles is
> NOT crossing the line — it's the seam working correctly.** The shared Postgres is a platform store;
> only infra holds the superuser needed to `CREATE DATABASE`/`CREATE ROLE`, and least-privilege
> provisioning is a security control a project *shouldn't* self-serve. So "provision me a DB + a
> non-superuser app role" is exactly the right ask. What would cross the line is the project's **schema,
> migrations, app, or data** living in the infra repo — those are the product's. Infra builds the empty,
> access-scoped room; the product furnishes it from its own repo. (This is why #31 provisioned the
> `research` DB + roles here but the desk's `db/apply.py` owns the schema — correct on both sides.)

| Concern | Infra provides | Product owns |
|---|---|---|
| Database | the DB + least-privilege roles | the schema, migrations, data |
| Vector store | the collection at the standard dims | what's ingested, the retrieval flow |
| LLM access | a scoped, tier-bounded virtual key | which prompts/models it calls |
| Object store | a bucket + scoped account | the objects |
| Isolated store (e.g. a dedicated Neo4j) | the container + backup/monitoring | the graph, the projection builder |
| Dashboards | the Grafana **folder** + datasource | the dashboard JSON |
| A web/bot surface | the network + the route + SSO | the app container, in its own repo |

## 4. Current state — where the line holds, and the drift to fix

✅ **Holds:** product apps deploy from their own repos (verified — none in the infra compose); the
provisioning seam is used for stores/keys; the AI-governance **live inventory** is export-ignored from
the public snapshot.

⚠️ **Residual drift (product-specific things still in the platform repo)** — none breaks the boundary
badly, but each should be ruled and, where needed, cleaned before the public cut (tracked as #15b):

| Item | Ruling |
|---|---|
| `neo4j-example` service (product-named store in infra compose) | **Stays** — an isolated store is a platform *capability* (like a per-app Postgres DB). Product-named for the consumer it was provisioned for, same as the `research` DB. Fine as infra. |
| `kb-manifest.json` entries sourcing from **private product repos** | The KB **registry** is infra; the entries that ingest from private product repos are product data. For public: genericise/exclude those entries (scrub step). |
| `provision-exampleapp.sh`, `provision-research.sh`, `provision-example-clients.sh` | Infra owns provisioning, so these are infra — but they're **instances**. Prefer one **generic, parameterised** provisioner + per-product invocation, so the platform ships the template, not the portfolio. |
| Keycloak realm `markets-*` clients baked into `realm-homelab.json` | Product artifacts in a platform file. Keep the **generic** realm; products provision their own clients via `kcadm` (the pattern `provision-*-clients.sh` already uses). |
| Product names in **doc prose** (governance/method docs) | Genericise to roles for the public snapshot (decided 2026-07-22). |

## 5. Guidance to project sessions (put this in your product's CLAUDE.md)

- **Your app is yours.** Containers, KB corpus, dashboards, workflows, schema → your repo, deployed
  onto the platform. Don't add them to `ai-homelab-infra`.
- **File platform asks, don't build them here.** Need a DB/collection/bucket/scoped key/isolated store?
  File it into `ai-homelab-infra/intake.md` (the cross-project intake queue) with the rationale.
  No item number needed — intake entries are keyed by repo + date. Infra provisions
  the namespace + credential; you get env-var names back and pin them.
- **Deploy onto the shared networks.** Ship your own compose that joins `proxy`/`ai`/`data`; get a
  Traefik route + SSO via labels (see [adding-an-app.md](adding-an-app.md)).
- **Governance travels with you.** Your system gets an inventory entry (owner, tier, scoped key) and is
  covered by the drift check + evals. Read the `PLATFORM-AI-GOVERNANCE.md` handoff in your repo.
- **Keep the platform publishable.** Anything that names or reveals your product doesn't belong in the
  platform repo. If you're unsure, apply §2's test — or ask.

## 6. Why this also solves open-source

If the boundary holds, the platform repo is **naturally clean**: no product apps, no product data, no
portfolio — just the reusable platform + the governance framework. The open-source scrub
(open-source-manifest.md) then only has to handle the domain and a thin layer
of doc prose, not disentangle products from infra. **The boundary is the real open-source-readiness
control; the scrub is the finish.**
