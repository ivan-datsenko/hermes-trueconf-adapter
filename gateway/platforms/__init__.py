import logging
from gateway.platform_registry import platform_registry, PlatformEntry

logger = logging.getLogger(__name__)

def register_trueconf():
    """Register TrueConf platform in the global registry."""
    try:
        from .trueconf import TrueConfAdapter, check_trueconf_requirements
        platform_registry.register(PlatformEntry(
            name="trueconf",
            label="TrueConf",
            emoji="📹",
            adapter_factory=lambda cfg: TrueConfAdapter(cfg),
            check_fn=check_trueconf_requirements,
            validate_config=lambda cfg: bool(
                cfg.extra.get("server") and (
                    cfg.token or (cfg.extra.get("username") and cfg.extra.get("password"))
                )
            ),
            required_env=["TRUECONF_SERVER"],
            allowed_users_env="TRUECONF_ALLOWED_USERS",
            allow_all_env="TRUECONF_ALLOW_ALL_USERS",
            cron_deliver_env_var="TRUECONF_HOME_CHANNEL",
            standalone_sender_fn=standalone_send_trueconf,
        ))
        logger.debug("TrueConf platform registered via __init__.py")
    except Exception as e:
        logger.error("Failed to register TrueConf platform: %s", e)

# Auto-register on import
register_trueconf()

async def standalone_send_trueconf(pconfig, chat_id, message, *, thread_id=None, media_files=None, force_document=False):
    """Standalone sender for TrueConf, used by cron and out-of-process tools."""
    from .trueconf import TrueConfAdapter
    adapter = TrueConfAdapter(pconfig)
    connected = await adapter.connect()
    if not connected:
        return {"error": f"TrueConf: failed to connect - {adapter.fatal_error_message or 'unknown error'}"}
    try:
        result = await adapter.send(chat_id, message)
        if not result.success:
            return {"error": f"TrueConf send failed: {result.error}"}

        if media_files:
            for media_item in media_files:
                media_path = media_item[0] if isinstance(media_item, tuple) else media_item
                import os
                ext = os.path.splitext(media_path)[1].lower()
                if ext in {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"} and not force_document:
                    await adapter.send_image_file(chat_id, media_path)
                else:
                    await adapter.send_document(chat_id, media_path)
        return {"success": True, "message_id": result.message_id}
    finally:
        await adapter.disconnect()
