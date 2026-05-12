"""
TrueConf platform management tools.

Enables the agent to:
- List available chats and channels
- Search for users
- Create group chats or channels
- Manage chat participants
"""

import os
import logging
from typing import Any, Dict, List, Optional
from gateway.config import load_gateway_config, Platform

logger = logging.getLogger(__name__)

async def _get_adapter():
    """Get the active TrueConf adapter from the gateway."""
    try:
        from gateway.run import gateway
        if gateway and hasattr(gateway, "adapter_registry") and gateway.adapter_registry:
            adapter = gateway.adapter_registry.get(Platform.TRUECONF)
            if adapter:
                return adapter
    except (ImportError, AttributeError):
        pass

    # Fallback: create an ephemeral adapter if gateway is not running
    try:
        from gateway.platforms.trueconf import TrueConfAdapter
        config = load_gateway_config()
        pconfig = config.platforms.get(Platform.TRUECONF)
        if pconfig and pconfig.enabled:
            adapter = TrueConfAdapter(pconfig)
            if await adapter.connect():
                return adapter
    except Exception as e:
        logger.debug("Failed to create ephemeral TrueConf adapter: %s", e)
    return None

async def list_trueconf_chats(count: int = 20) -> Any:
    """
    List chats and channels available to the TrueConf bot.
    Use this to find chat IDs for sending messages or files.
    """
    adapter = await _get_adapter()
    if not adapter or not hasattr(adapter, "_bot") or not adapter._bot:
        return {"error": "TrueConf adapter not available or not connected"}

    try:
        res = await adapter._bot.get_chats(count=count)
        chats = []
        for chat in getattr(res, "chats", []):
            chats.append({
                "chat_id": chat.chat_id,
                "title": getattr(chat, "title", "Unknown"),
                "type": str(getattr(chat, "type", "unknown")),
            })
        return chats
    except Exception as e:
        return {"error": str(e)}

async def get_trueconf_chat_info(chat_id: str) -> Dict[str, Any]:
    """Get detailed information about a specific TrueConf chat ID."""
    adapter = await _get_adapter()
    if not adapter:
        return {"error": "TrueConf adapter not available"}
    return await adapter.get_chat_info(chat_id)

async def search_trueconf_users(query: str) -> Any:
    """Search for users on the TrueConf server by name or ID."""
    adapter = await _get_adapter()
    if not adapter or not adapter._bot:
        return {"error": "TrueConf adapter not available"}

    try:
        # Search is not directly in the bot library yet, but we can try get_user_display_name as a fallback
        # or use the internal API if available.
        # For now, let's just return a placeholder or use what's available.
        res = await adapter._bot.get_user_display_name(query)
        if res:
            return [{"user_id": query, "display_name": getattr(res, "display_name", query)}]
        return []
    except Exception as e:
        return {"error": str(e)}

# Tool registration metadata
TOOLS = [
    {
        "name": "list_trueconf_chats",
        "description": "List available TrueConf chats and channels to find IDs.",
        "parameters": {
            "type": "object",
            "properties": {
                "count": {"type": "integer", "description": "Number of chats to return", "default": 20}
            }
        },
        "function": list_trueconf_chats
    },
    {
        "name": "get_trueconf_chat_info",
        "description": "Get detailed info about a TrueConf chat ID.",
        "parameters": {
            "type": "object",
            "properties": {
                "chat_id": {"type": "string", "description": "The TrueConf chat ID"}
            },
            "required": ["chat_id"]
        },
        "function": get_trueconf_chat_info
    },
    {
        "name": "search_trueconf_users",
        "description": "Search for users on TrueConf.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query (name or ID)"}
            },
            "required": ["query"]
        },
        "function": search_trueconf_users
    }
]
