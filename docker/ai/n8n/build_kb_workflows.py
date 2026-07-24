#!/usr/bin/env python3
"""
Generate the n8n KB workflows from the single source of truth: docs/kb-manifest.json.

Outputs (into docker/ai/n8n/workflows/):
  - kb-ingest.json   : one Schedule(daily 04:00)+Manual -> clear+insert chain per enabled KB.

Credentials are referenced by id+name only (no secrets). Deploy with deploy_kb_workflows.sh.
Re-run after editing the manifest, then redeploy.

Usage: python build_kb_workflows.py [--manifest PATH] [--out DIR]
"""
import argparse, json, os, sys

# n8n credential references (id+name only — created once via the n8n API; no secrets here).
GH_CRED  = {"id": "er4zkVl3U64gSEe2", "name": "KB GitHub (ai-homelab-infra RO)"}
# SCOPED key, not the master key. This was "LiteLLM (OpenAI-compat)" (id
# hIaZztiMPUNRvEZS) — the MASTER-key credential — until 2026-07-22 (todos.md #38).
# Leaving it pointed there would have made a routine `build && deploy` silently
# put every KB workflow back on an admin credential that can mint and revoke
# keys, quietly undoing the fix. A generator is a re-infection vector for
# anything you fix by hand in the running system.
OAI_CRED = {"id": "4dvGwVICEh5wFkML", "name": "LiteLLM (n8n-kb scoped)"}
QDR_CRED = {"id": "scAvBp08Km3zUMqK", "name": "Qdrant (homelab)"}
# bge-m3 DIRECT, bypassing the LiteLLM gateway. Used ONLY for the ingest embed
# nodes (todos.md #53). WHY: the gateway's injection guardrails are pre_call +
# default_on, so they filter /embeddings too — and our own infra docs contain
# phrases like "enable ... override" that trip prompt_injection_malicious_code
# -> HTTP 400. That silently destroyed kb_homelab_docs (ingest cleared it, then
# the re-embed was blocked). Embeddings vectorise trusted first-party documents;
# there is no generation and so nothing to hijack, so guarding them adds no
# security and only breaks ingestion. LiteLLM v1.89.1 AND v1.93.0 both filter
# embeddings (verified — the upgrade does not fix it), and there is no call-type
# gate or working per-request disable, so the embed calls go direct to bge-m3.
# openAiApi credential with base url http://bge-m3:8080/v1 (bge-m3 has no auth).
# TRADE-OFF, recorded: ingest embeds no longer transit the gateway, so they are
# not Langfuse-traced — an accepted, scoped exception for the lowest-risk call.
# NOTE: kb-chat / kb-search QUERY embeds still go via the gateway (OAI_CRED); a
# trigger-phrase user query would 400 there. Rare + non-destructive; left as a
# follow-up rather than widening this change onto live public retrieval paths.
BGE_CRED = {"id": "YvfEMuMoDCYip9XO", "name": "bge-m3 (direct, no gateway)"}

# ---- Corpus governance (todos.md #43) --------------------------------------
# Fields every KB must carry. kb-standards.md section 6 specified `owner` and
# `visibility` from the start; the manifest simply never had them, so the
# standard and its implementation had drifted on exactly the governance fields.
REQUIRED_GOV_FIELDS = ("owner", "visibility", "classification", "license",
                       "retention", "contains_pii")
VALID_VISIBILITY = ("public", "internal", "restricted")


def validate_manifest(manifest):
    """Refuse to generate anything from an under-specified manifest.

    This is the point of the exercise: the manifest ENTRY becomes the control.
    Documenting that corpora have owners does nothing; refusing to build
    workflows for a corpus without one is a control.
    """
    problems = []
    for kb in manifest.get("kbs", []):
        name = kb.get("name", "(unnamed)")
        for f in REQUIRED_GOV_FIELDS:
            if kb.get(f) is None or kb.get(f) == "":
                problems.append(f"{name}: missing required governance field '{f}'")
        vis = kb.get("visibility")
        if vis is not None and vis not in VALID_VISIBILITY:
            problems.append(f"{name}: visibility {vis!r} not one of {VALID_VISIBILITY}")
    if problems:
        for p in problems:
            print(f"  [FAIL] {p}", file=sys.stderr)
        raise SystemExit(
            "\nmanifest failed governance validation — refusing to generate.\n"
            "Every KB needs owner/visibility/classification/license/retention/"
            "contains_pii (docs/kb-standards.md section 6).")


def select_for_surface(manifest, surface):
    """The corpora a workflow for `surface` is ALLOWED to touch.

    surface='public'   -> ONLY visibility=='public'. This is the isolation rule
                          from todos.md #28 expressed as data instead of relying
                          on whoever builds the workflow remembering it. A public
                          chat surface must be structurally unable to reach an
                          internal or restricted corpus.
    surface='internal' -> everything EXCEPT `external` corpora, which are owned
                          by a sibling repo's own manifest (web-app,
                          example-site-web) and must not be ingested or
                          re-exposed by the shared workflows.
    """
    kbs = [k for k in manifest["kbs"] if k.get("enabled")]
    if surface == "public":
        return [k for k in kbs if k.get("visibility") == "public"]
    if surface == "internal":
        return [k for k in kbs if not k.get("external")]
    raise ValueError(f"unknown surface {surface!r}")


def assert_surface_safe(kbs, surface):
    """Hard stop if a selection would expose a non-public corpus publicly."""
    if surface != "public":
        return
    leaked = [k["name"] for k in kbs if k.get("visibility") != "public"]
    if leaked:
        raise SystemExit(
            f"REFUSING to build a PUBLIC-surface workflow touching non-public "
            f"corpora: {leaked}. A public chat must be structurally unable to "
            f"reach internal/restricted content (todos.md #28/#43).")

# md-only is achieved by excluding every non-markdown extension (GitHub loader has no include filter).
NON_MD_EXTS = [
    "py","ts","tsx","js","jsx","mjs","cjs","json","yml","yaml","toml","ini","cfg","conf",
    "sh","bash","bat","ps1","xml","html","htm","css","scss","sass","less","svg","png","jpg",
    "jpeg","gif","ico","webp","pdf","txt","csv","tsv","lock","example","env","service",
    "gitignore","gitattributes","gitkeep","dockerignore","map","woff","woff2","ttf","eot",
]
NON_MD_NAMES = ["Dockerfile", "LICENSE", "Makefile"]

def md_only_ignore():
    pats = []
    for e in NON_MD_EXTS:
        pats += [f"*.{e}", f"**/*.{e}"]
    for n in NON_MD_NAMES:
        pats += [n, f"**/{n}"]
    return ",".join(pats)

def coll_rl(name):
    return {"__rl": True, "mode": "list", "value": name, "cachedResultName": name}

def repo_url(repo):
    return f"https://github.com/{repo}"

def build_ingest(manifest):
    # Only github-sourced KBs are git-pulled+rebuilt here. Other sources (e.g. "discord-harvest")
    # are populated by their own app's flow, so they're excluded from kb-ingest but still appear in
    # kb-chat / kb-list / kb-search (those include every enabled KB).
    kbs = [k for k in select_for_surface(manifest, "internal")
           if k.get("source", {}).get("type", "github") == "github"]
    nodes, conns = [], {}

    manual = {"id": "trg_manual", "name": "Manual Trigger",
              "type": "n8n-nodes-base.manualTrigger", "typeVersion": 1,
              "position": [-360, -40], "parameters": {}}
    sched = {"id": "trg_sched", "name": "Schedule Daily 04:00",
             "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.3,
             "position": [-360, 160],
             "parameters": {"rule": {"interval": [{"field": "days", "daysInterval": 1,
                            "triggerAtHour": 4, "triggerAtMinute": 0}]}}}
    nodes += [manual, sched]
    conns["Manual Trigger"] = {"main": [[]]}
    conns["Schedule Daily 04:00"] = {"main": [[]]}

    y = -120
    for i, kb in enumerate(kbs):
        coll = kb["collection"]
        clear_name = f"Clear {coll}"
        ins_name = f"Insert {coll}"
        load_name = f"Load {coll}"
        split_name = f"Split {coll}"
        emb_name = f"Embed {coll}"
        x0 = 0

        clear = {"id": f"clr_{i}", "name": clear_name,
                 "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4,
                 "position": [x0, y], "parameters": {
                     "method": "DELETE",
                     "url": f"http://qdrant:6333/collections/{coll}",
                     "authentication": "predefinedCredentialType",
                     "nodeCredentialType": "qdrantApi",
                     "options": {"response": {"response": {"neverError": True}}}},
                 "credentials": {"qdrantApi": QDR_CRED}}
        ins = {"id": f"ins_{i}", "name": ins_name,
               "type": "@n8n/n8n-nodes-langchain.vectorStoreQdrant", "typeVersion": 1.3,
               "position": [x0 + 320, y], "parameters": {
                   "mode": "insert", "qdrantCollection": coll_rl(coll), "options": {}},
               "credentials": {"qdrantApi": QDR_CRED}}
        load = {"id": f"ld_{i}", "name": load_name,
                "type": "@n8n/n8n-nodes-langchain.documentGithubLoader", "typeVersion": 1.1,
                "position": [x0 + 300, y + 180], "parameters": {
                    "repository": repo_url(kb["source"]["repo"]),
                    "branch": kb["source"].get("branch", "main"),
                    "textSplittingMode": "custom",
                    "additionalOptions": {"recursive": True, "ignorePaths": md_only_ignore()}},
                "credentials": {"githubApi": GH_CRED}}
        split = {"id": f"sp_{i}", "name": split_name,
                 "type": "@n8n/n8n-nodes-langchain.textSplitterRecursiveCharacterTextSplitter",
                 "typeVersion": 1, "position": [x0 + 300, y + 360],
                 "parameters": {"chunkSize": 1400, "chunkOverlap": 200, "options": {}}}
        emb = {"id": f"em_{i}", "name": emb_name,
               "type": "@n8n/n8n-nodes-langchain.embeddingsOpenAi", "typeVersion": 1.2,
               "position": [x0 + 560, y + 180],
               "parameters": {"model": manifest["embedder"], "options": {}},
               "credentials": {"openAiApi": BGE_CRED}}  # direct to bge-m3 — see #53
        nodes += [clear, ins, load, split, emb]

        conns["Manual Trigger"]["main"][0].append({"node": clear_name, "type": "main", "index": 0})
        conns["Schedule Daily 04:00"]["main"][0].append({"node": clear_name, "type": "main", "index": 0})
        conns[clear_name] = {"main": [[{"node": ins_name, "type": "main", "index": 0}]]}
        conns[load_name] = {"ai_document": [[{"node": ins_name, "type": "ai_document", "index": 0}]]}
        conns[split_name] = {"ai_textSplitter": [[{"node": load_name, "type": "ai_textSplitter", "index": 0}]]}
        conns[emb_name] = {"ai_embedding": [[{"node": ins_name, "type": "ai_embedding", "index": 0}]]}
        y += 560

    return {"name": "kb-ingest", "nodes": nodes, "connections": conns,
            "settings": {"executionOrder": "v1"}}

def build_chat(manifest):
    """One Chat Trigger -> AI Agent with a Qdrant retrieve-as-tool per enabled KB.
    The KB catalog is baked into the system prompt so the agent can enumerate KBs
    and route to the right collection(s)."""
    kbs = select_for_surface(manifest, "internal")
    catalog = "\n".join(f"- {k['name']}: {k['description']}" for k in kbs)
    sys_msg = (
        "You are the Homelab Knowledge assistant. You answer from a library of knowledge bases (KBs), "
        "each backed by a retrieval tool. Available knowledge bases:\n"
        f"{catalog}\n\n"
        "Rules:\n"
        "- For every question, call the most relevant KB tool(s) to retrieve context BEFORE answering. "
        "You may query multiple KBs and synthesise across them.\n"
        "- If the user asks what knowledge bases exist (or which you can search), list the KBs above "
        "with their descriptions.\n"
        "- Ground answers in retrieved content and cite the KB/doc where possible. If the KBs do not "
        "contain the answer, say so plainly rather than guessing."
    )

    nodes = [
        {"id": "c_trigger", "name": "Chat Trigger",
         "type": "@n8n/n8n-nodes-langchain.chatTrigger", "typeVersion": 1.4,
         "position": [-320, 0], "webhookId": "homelab-kb-chat",
         "parameters": {"public": True, "options": {"responseMode": "lastNode"}}},
        {"id": "c_agent", "name": "AI Agent",
         "type": "@n8n/n8n-nodes-langchain.agent", "typeVersion": 3.1,
         "position": [-40, 0], "parameters": {"promptType": "auto", "options": {"systemMessage": sys_msg}}},
        {"id": "c_llm", "name": "OpenAI Chat Model",
         "type": "@n8n/n8n-nodes-langchain.lmChatOpenAi", "typeVersion": 1.3,
         "position": [-140, 220], "parameters": {
             "model": {"__rl": True, "mode": "list", "value": manifest["chat_model"],
                       "cachedResultName": manifest["chat_model"]},
             "options": {"responseFormat": "text"}, "responsesApiEnabled": False},
         "credentials": {"openAiApi": OAI_CRED}},
        {"id": "c_mem", "name": "Window Buffer Memory",
         "type": "@n8n/n8n-nodes-langchain.memoryBufferWindow", "typeVersion": 1.4,
         "position": [60, 220], "parameters": {"contextWindowLength": 10}},
    ]
    conns = {
        "Chat Trigger": {"main": [[{"node": "AI Agent", "type": "main", "index": 0}]]},
        "OpenAI Chat Model": {"ai_languageModel": [[{"node": "AI Agent", "type": "ai_languageModel", "index": 0}]]},
        "Window Buffer Memory": {"ai_memory": [[{"node": "AI Agent", "type": "ai_memory", "index": 0}]]},
    }

    x = 240
    for i, kb in enumerate(kbs):
        coll = kb["collection"]
        tool_name = f"Search {coll}"
        emb_name = f"Embed {coll}"
        tool = {"id": f"tool_{i}", "name": tool_name,
                "type": "@n8n/n8n-nodes-langchain.vectorStoreQdrant", "typeVersion": 1.3,
                "position": [x, -40 + i * 30], "parameters": {
                    "mode": "retrieve-as-tool",
                    "toolName": kb["name"],
                    "toolDescription": kb["description"],
                    "qdrantCollection": coll_rl(coll),
                    "topK": 6, "options": {}},
                "credentials": {"qdrantApi": QDR_CRED}}
        emb = {"id": f"cemb_{i}", "name": emb_name,
               "type": "@n8n/n8n-nodes-langchain.embeddingsOpenAi", "typeVersion": 1.2,
               "position": [x + 220, 140 + i * 30],
               "parameters": {"model": manifest["embedder"], "options": {}},
               "credentials": {"openAiApi": OAI_CRED}}
        nodes += [tool, emb]
        conns[tool_name] = {"ai_tool": [[{"node": "AI Agent", "type": "ai_tool", "index": 0}]]}
        conns[emb_name] = {"ai_embedding": [[{"node": tool_name, "type": "ai_embedding", "index": 0}]]}
        x += 240

    return {"name": "kb-chat", "nodes": nodes, "connections": conns,
            "settings": {"executionOrder": "v1"}}


def build_search(manifest):
    """Reusable shared retrieval endpoint (§5 access layer): POST /webhook/kb-search
    {collection, query, topK?} -> embed(bge-m3) -> Qdrant search -> {results, collection, query}.
    Any app (Assistant, example-app, agents) can call this; no per-KB nodes."""
    WH = "KB Search Webhook"
    nodes = [
        {"id": "s_wh", "name": WH, "type": "n8n-nodes-base.webhook", "typeVersion": 2.1,
         "position": [-320, 0], "webhookId": "kb-search",
         "parameters": {"httpMethod": "POST", "path": "kb-search", "responseMode": "lastNode", "options": {}}},
        {"id": "s_emb", "name": "Embed Query", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4,
         "position": [-80, 0], "parameters": {
             "method": "POST", "url": "http://litellm:4000/v1/embeddings",
             "authentication": "predefinedCredentialType", "nodeCredentialType": "openAiApi",
             "sendBody": True, "contentType": "json", "specifyBody": "json",
             "jsonBody": "={{ { \"model\": \"" + manifest["embedder"] + "\", \"input\": $json.body.query } }}",
             "options": {}},
         "credentials": {"openAiApi": OAI_CRED}},
        {"id": "s_qd", "name": "Qdrant Search", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4,
         "position": [160, 0], "parameters": {
             "method": "POST",
             "url": "=http://qdrant:6333/collections/{{ $('" + WH + "').item.json.body.collection }}/points/search",
             "authentication": "predefinedCredentialType", "nodeCredentialType": "qdrantApi",
             "sendBody": True, "contentType": "json", "specifyBody": "json",
             "jsonBody": "={{ { \"vector\": $json.data[0].embedding, \"limit\": ($('" + WH + "').item.json.body.topK || 6), \"with_payload\": true } }}",
             "options": {}},
         "credentials": {"qdrantApi": QDR_CRED}},
        {"id": "s_shape", "name": "Shape Response", "type": "n8n-nodes-base.set", "typeVersion": 3.4,
         "position": [400, 0], "parameters": {
             "mode": "manual",
             "assignments": {"assignments": [
                 {"id": "r1", "name": "results", "value": "={{ $json.result }}", "type": "array"},
                 {"id": "r2", "name": "collection", "value": "={{ $('" + WH + "').item.json.body.collection }}", "type": "string"},
                 {"id": "r3", "name": "query", "value": "={{ $('" + WH + "').item.json.body.query }}", "type": "string"},
             ]},
             "includeOtherFields": False, "options": {}}},
    ]
    conns = {
        WH: {"main": [[{"node": "Embed Query", "type": "main", "index": 0}]]},
        "Embed Query": {"main": [[{"node": "Qdrant Search", "type": "main", "index": 0}]]},
        "Qdrant Search": {"main": [[{"node": "Shape Response", "type": "main", "index": 0}]]},
    }
    return {"name": "kb-search", "nodes": nodes, "connections": conns, "settings": {"executionOrder": "v1"}}


def build_list():
    """Convenience registry endpoint: GET /webhook/kb-list -> the live kb-manifest.json
    (fetched from the repo via the GitHub API). Consumers use entries where enabled==true."""
    nodes = [
        {"id": "l_wh", "name": "KB List Webhook", "type": "n8n-nodes-base.webhook", "typeVersion": 2.1,
         "position": [-200, 0], "webhookId": "kb-list",
         "parameters": {"httpMethod": "GET", "path": "kb-list", "responseMode": "lastNode", "options": {}}},
        {"id": "l_get", "name": "Fetch Manifest", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.4,
         "position": [40, 0], "parameters": {
             "method": "GET",
             "url": "https://api.github.com/repos/your-org/ai-homelab-infra/contents/docs/kb-manifest.json",
             "authentication": "predefinedCredentialType", "nodeCredentialType": "githubApi",
             "sendHeaders": True, "specifyHeaders": "keypair",
             "headerParameters": {"parameters": [
                 {"name": "Accept", "value": "application/vnd.github.raw"}]},
             "options": {"response": {"response": {"responseFormat": "json"}}}},
         "credentials": {"githubApi": GH_CRED}},
    ]
    conns = {"KB List Webhook": {"main": [[{"node": "Fetch Manifest", "type": "main", "index": 0}]]}}
    return {"name": "kb-list", "nodes": nodes, "connections": conns, "settings": {"executionOrder": "v1"}}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(here, "..", "..", "..", "docs", "kb-manifest.json"))
    ap.add_argument("--out", default=os.path.join(here, "workflows"))
    args = ap.parse_args()

    manifest = json.load(open(args.manifest, encoding="utf-8"))
    # Governance gate FIRST — never emit workflows from an under-specified manifest.
    validate_manifest(manifest)
    os.makedirs(args.out, exist_ok=True)
    internal = select_for_surface(manifest, "internal")
    external = [k["name"] for k in manifest["kbs"] if k.get("enabled") and k.get("external")]
    enabled = [k["collection"] for k in internal]
    ingest_kbs = [k["collection"] for k in internal
                  if k.get("source", {}).get("type", "github") == "github"]
    if external:
        print(f"  excluded {len(external)} EXTERNAL corpora (owned by sibling repos): {external}")
    ingest = build_ingest(manifest)
    pi = os.path.join(args.out, "kb-ingest.json")
    json.dump(ingest, open(pi, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"wrote {pi}: {len(ingest['nodes'])} nodes for github KBs {ingest_kbs} "
          f"(non-github enabled KBs are populated by their own app)")

    chat = build_chat(manifest)
    pc = os.path.join(args.out, "kb-chat.json")
    json.dump(chat, open(pc, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"wrote {pc}: {len(chat['nodes'])} nodes, {len(enabled)} KB tools")

    for name, wf in (("kb-search", build_search(manifest)), ("kb-list", build_list())):
        p = os.path.join(args.out, name + ".json")
        json.dump(wf, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
        print(f"wrote {p}: {len(wf['nodes'])} nodes")

if __name__ == "__main__":
    main()
