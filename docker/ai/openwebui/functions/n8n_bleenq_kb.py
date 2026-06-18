"""
title: KB — Bleenq Knowledge (n8n)
author: homelab
version: 0.2.0
required_open_webui_version: 0.5.0
description: >
  Routes chat to the n8n `kb-chat` workflow — the AI Agent over the full Bleenq
  knowledge library (all KBs registered in docs/kb-manifest.json: homelab,
  trading, design, …). The agent enumerates the KBs and retrieves from whichever
  collection(s) are relevant before answering. Registers as one selectable model;
  the Open WebUI chat id is passed as the n8n sessionId for per-chat memory.
"""

import re
import requests
from typing import Optional, Callable, Awaitable
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        # Internal service URL (OpenWebUI and n8n share the `ai` docker network).
        n8n_url: str = Field(
            default="http://n8n:5678/webhook/bleenq-kb-chat/chat",
            description="n8n kb-chat Chat Trigger production webhook URL.",
        )
        input_field: str = Field(default="chatInput", description="n8n Chat Trigger input key.")
        response_field: str = Field(default="output", description="Key in the n8n JSON response to display.")
        bearer_token: str = Field(default="", description="Optional Authorization: Bearer token (if you gate the webhook).")
        timeout: int = Field(default=180, description="Request timeout (seconds) — multi-KB routing can take longer.")
        strip_code_fences: bool = Field(default=True, description="Unwrap a ```...``` fence the model sometimes adds.")
        emit_status: bool = Field(default=True, description="Show a status indicator while querying.")

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self):
        # A single selectable model entry spanning the whole KB library.
        return [{"id": "bleenq_kb", "name": "KB: Bleenq Knowledge"}]

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
                await __event_emitter__({"type": "status", "data": {"description": msg, "done": done}})

        user_message = ""
        for m in reversed(body.get("messages", [])):
            if m.get("role") == "user":
                user_message = m.get("content", "")
                break

        session_id = (__metadata__ or {}).get("chat_id") or "openwebui"
        payload = {"action": "sendMessage", "sessionId": session_id, self.valves.input_field: user_message}
        headers = {"Content-Type": "application/json"}
        if self.valves.bearer_token:
            headers["Authorization"] = f"Bearer {self.valves.bearer_token}"

        await status("Searching the Bleenq knowledge library…")
        try:
            r = requests.post(self.valves.n8n_url, json=payload, headers=headers, timeout=self.valves.timeout)
            r.raise_for_status()
            answer = self._clean(r.json().get(self.valves.response_field, ""))
            await status("Done", done=True)
            return answer or "_(empty response from n8n)_"
        except Exception as e:
            await status(f"n8n error: {e}", done=True)
            return f"**Error calling n8n KB workflow:** {e}"
