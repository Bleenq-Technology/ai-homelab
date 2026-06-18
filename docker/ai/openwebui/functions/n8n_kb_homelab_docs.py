"""
title: KB — Homelab Docs (n8n)
author: homelab
version: 0.1.0
required_open_webui_version: 0.5.0
description: >
  Routes chat to the n8n `kb_homelab_docs-chat` workflow (AI Agent + Qdrant
  retrieval over the homelab docs KB). Registers as a selectable model in
  OpenWebUI; each message is POSTed to the n8n Chat Trigger webhook and the
  agent's answer is returned. The OpenWebUI chat id is passed as the n8n
  sessionId so conversation memory is per-chat.
"""

import re
import requests
from typing import Optional, Callable, Awaitable
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        # Internal service URL (OpenWebUI and n8n share the `ai` docker network).
        n8n_url: str = Field(
            default="http://n8n:5678/webhook/kb-homelab-docs-chat/chat",
            description="n8n Chat Trigger production webhook URL.",
        )
        input_field: str = Field(
            default="chatInput", description="n8n Chat Trigger input key."
        )
        response_field: str = Field(
            default="output", description="Key in the n8n JSON response to display."
        )
        bearer_token: str = Field(
            default="", description="Optional Authorization: Bearer token (if you gate the webhook)."
        )
        timeout: int = Field(default=150, description="Request timeout (seconds).")
        strip_code_fences: bool = Field(
            default=True, description="Unwrap a ```...``` fence the model sometimes adds."
        )
        emit_status: bool = Field(default=True, description="Show a status indicator while querying.")

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        # A single selectable model entry.
        return [{"id": "kb_homelab_docs", "name": "KB: Homelab Docs"}]

    def _clean(self, text: str) -> str:
        if not isinstance(text, str):
            return str(text)
        if self.valves.strip_code_fences:
            m = re.match(r"^\s*```[a-zA-Z0-9]*\s*\n(.*?)\n?```\s*$", text, re.DOTALL)
            if m:
                text = m.group(1)
        return text.strip()

    async def pipe(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __metadata__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
    ) -> str:
        async def status(msg: str, done: bool = False):
            if self.valves.emit_status and __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": msg, "done": done}}
                )

        # Last user message.
        user_message = ""
        for m in reversed(body.get("messages", [])):
            if m.get("role") == "user":
                user_message = m.get("content", "")
                break

        session_id = (__metadata__ or {}).get("chat_id") or "openwebui"
        payload = {
            "action": "sendMessage",
            "sessionId": session_id,
            self.valves.input_field: user_message,
        }
        headers = {"Content-Type": "application/json"}
        if self.valves.bearer_token:
            headers["Authorization"] = f"Bearer {self.valves.bearer_token}"

        await status("Querying homelab docs knowledge base…")
        try:
            r = requests.post(
                self.valves.n8n_url, json=payload, headers=headers, timeout=self.valves.timeout
            )
            r.raise_for_status()
            data = r.json()
            answer = self._clean(data.get(self.valves.response_field, ""))
            await status("Done", done=True)
            return answer or "_(empty response from n8n)_"
        except Exception as e:
            await status(f"n8n error: {e}", done=True)
            return f"**Error calling n8n KB workflow:** {e}"
