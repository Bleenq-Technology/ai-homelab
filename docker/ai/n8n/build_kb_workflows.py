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
OAI_CRED = {"id": "hIaZztiMPUNRvEZS", "name": "LiteLLM (OpenAI-compat)"}
QDR_CRED = {"id": "scAvBp08Km3zUMqK", "name": "Qdrant (homelab)"}

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
    kbs = [k for k in manifest["kbs"] if k.get("enabled")]
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
               "credentials": {"openAiApi": OAI_CRED}}
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
    kbs = [k for k in manifest["kbs"] if k.get("enabled")]
    catalog = "\n".join(f"- {k['name']}: {k['description']}" for k in kbs)
    sys_msg = (
        "You are the Bleenq Knowledge assistant. You answer from a library of knowledge bases (KBs), "
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
         "position": [-320, 0], "webhookId": "bleenq-kb-chat",
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


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(here, "..", "..", "..", "docs", "kb-manifest.json"))
    ap.add_argument("--out", default=os.path.join(here, "workflows"))
    args = ap.parse_args()

    manifest = json.load(open(args.manifest, encoding="utf-8"))
    os.makedirs(args.out, exist_ok=True)
    enabled = [k["collection"] for k in manifest["kbs"] if k.get("enabled")]
    ingest = build_ingest(manifest)
    pi = os.path.join(args.out, "kb-ingest.json")
    json.dump(ingest, open(pi, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"wrote {pi}: {len(ingest['nodes'])} nodes for KBs {enabled}")

    chat = build_chat(manifest)
    pc = os.path.join(args.out, "kb-chat.json")
    json.dump(chat, open(pc, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"wrote {pc}: {len(chat['nodes'])} nodes, {len(enabled)} KB tools")

if __name__ == "__main__":
    main()
