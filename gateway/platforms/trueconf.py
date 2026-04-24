"""
TrueConf Server platform adapter.

Connects to TrueConf Server via WebSocket using the python-trueconf-bot library.
Supports:
- Text messages (plain and formatted)
- File/document attachments
- Photo/image messages
- Voice/audio messages
- Surveys/polls
- Group chats and channels
- Slash-commands
- Reply threading

Built-in anti-spam-loop protection:
- Rate limiting on incoming messages per user
- Loop detection (bot responding to itself)
- Message deduplication
- Emergency stop mechanism
- Debouncing of repeated events

Requirements:
    pip install git+https://github.com/TrueConf/python-trueconf-bot

Environment variables:
    TRUECONF_SERVER          Server hostname (e.g. video.example.net)
    TRUECONF_USERNAME        Bot username
    TRUECONF_PASSWORD        Bot password
    TRUECONF_TOKEN           Bot token (alternative to username/password)
    TRUECONF_ALLOWED_USERS   Comma-separated user IDs allowed to use the bot
    TRUECONF_ALLOW_ALL_USERS Set to "true" to allow all users
    TRUECONF_HOME_CHANNEL    Default channel ID for cron delivery
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Library availability check
# ---------------------------------------------------------------------------

try:
    from trueconf import Bot, Dispatcher, Router, F
    from trueconf.types import Message, Update
    from trueconf.types.content import Photo, Video, Document
    from trueconf.enums import ChatType, MessageType as TCMessageType, ParseMode
    TRUECONF_AVAILABLE = True
except ImportError:
    TRUECONF_AVAILABLE = False
    Bot = Any
    Dispatcher = Any
    Router = Any
    F = None
    ChatType = None
    TCMessageType = None
    Message = Any
    Update = Any
    Photo = Any
    Video = Any
    Document = Any
    Audio = Any
    ParseMode = None

import sys
from pathlib import Path as _Path
sys.path.insert(0, str(_Path(__file__).resolve().parents[2]))

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
    cache_image_from_bytes,
    cache_audio_from_bytes,
    cache_document_from_bytes,
)
from gateway.platforms.helpers import MessageDeduplicator


def check_trueconf_requirements() -> bool:
    """Check if TrueConf dependencies are available."""
    if not TRUECONF_AVAILABLE:
        logger.debug("TrueConf: python-trueconf-bot not installed")
        return False
    return True


# ---------------------------------------------------------------------------
# Anti-spam-loop protection
# ---------------------------------------------------------------------------

@dataclass
class _RateLimitState:
    """Per-user rate limiting state."""
    timestamps: List[float] = field(default_factory=list)
    last_reset: float = 0.0


class AntiSpamProtection:
    """
    Multi-layered anti-spam-loop protection.

    Layers:
    1. Rate limiting: max N messages per minute per user
    2. Burst detection: max M messages in a short burst window
    3. Loop detection: bot messages arriving as events (self-response loop)
    4. Message deduplication: same message ID processed twice
    5. Emergency stop: global kill switch
    """

    def __init__(
        self,
        max_per_minute: int = 10,
        burst_limit: int = 5,
        burst_window: float = 3.0,
        bot_user_id: Optional[str] = None,
    ):
        self._max_per_minute = max_per_minute
        self._burst_limit = burst_limit
        self._burst_window = burst_window
        self._bot_user_id = bot_user_id
        self._rate_states: Dict[str, _RateLimitState] = defaultdict(_RateLimitState)
        self._emergency_stop = False
        self._dedup = MessageDeduplicator(max_size=5000, ttl_seconds=600)

    def set_bot_user_id(self, user_id: str) -> None:
        """Set the bot's own user ID for loop detection."""
        self._bot_user_id = user_id

    def is_emergency_stopped(self) -> bool:
        """Check if emergency stop is active."""
        return self._emergency_stop

    def trigger_emergency_stop(self, reason: str = "spam loop detected") -> None:
        """Activate emergency stop."""
        self._emergency_stop = True
        logger.critical(
            "[TrueConf] EMERGENCY STOP activated: %s. "
            "Bot will stop processing all messages until restarted.",
            reason,
        )

    def reset_emergency_stop(self) -> None:
        """Deactivate emergency stop."""
        self._emergency_stop = False
        logger.info("[TrueConf] Emergency stop deactivated")

    def is_duplicate(self, message_id: str) -> bool:
        """Check message deduplication."""
        return self._dedup.is_duplicate(message_id)

    def is_self_loop(self, user_id: str) -> bool:
        """
        Detect if a message came from the bot itself.

        This prevents the bot from responding to its own messages,
        which was the root cause of the 1000-message spam loop incident.
        """
        if not self._bot_user_id:
            return False
        return user_id == self._bot_user_id

    def check_rate_limit(self, user_id: str) -> bool:
        """
        Check if user has exceeded the rate limit.

        Returns True if the message should be BLOCKED (rate limited).
        Returns False if the message is allowed through.
        """
        now = time.time()
        state = self._rate_states[user_id]

        # Clean up old timestamps (older than 60 seconds)
        state.timestamps = [ts for ts in state.timestamps if now - ts < 60.0]

        # Check burst limit (messages within burst_window seconds)
        recent_burst = [ts for ts in state.timestamps if now - ts < self._burst_window]
        if len(recent_burst) >= self._burst_limit:
            logger.warning(
                "[TrueConf] Burst limit exceeded for user %s: %d messages in %.1fs",
                _redact_user_id(user_id),
                len(recent_burst),
                self._burst_window,
            )
            self.trigger_emergency_stop(
                f"Burst limit: {len(recent_burst)} messages in {self._burst_window}s from {_redact_user_id(user_id)}"
            )
            return True

        # Check per-minute rate limit
        if len(state.timestamps) >= self._max_per_minute:
            logger.warning(
                "[TrueConf] Rate limit exceeded for user %s: %d messages/min",
                _redact_user_id(user_id),
                len(state.timestamps),
            )
            return True

        # Record this timestamp
        state.timestamps.append(now)
        return False

    def get_stats(self) -> Dict[str, Any]:
        """Return current protection statistics."""
        now = time.time()
        active_users = 0
        total_recent = 0
        for state in self._rate_states.values():
            recent = [ts for ts in state.timestamps if now - ts < 60.0]
            if recent:
                active_users += 1
                total_recent += len(recent)
        return {
            "emergency_stop": self._emergency_stop,
            "active_users": active_users,
            "total_messages_last_min": total_recent,
            "bot_user_id": self._bot_user_id,
        }


def _redact_user_id(user_id: str) -> str:
    """Redact user ID for safe logging."""
    if not user_id:
        return "<none>"
    if "@" in user_id:
        local, domain = user_id.split("@", 1)
        if len(local) <= 4:
            redacted = "***"
        else:
            redacted = local[:2] + "***" + local[-2:]
        return f"{redacted}@{domain}"
    if len(user_id) <= 6:
        return "***"
    return user_id[:3] + "***" + user_id[-3:]


# ---------------------------------------------------------------------------
# TrueConf Adapter
# ---------------------------------------------------------------------------

class TrueConfAdapter(BasePlatformAdapter):
    """
    TrueConf Server gateway adapter.

    Connects via WebSocket to a TrueConf Server (5.5.0+) using the
    python-trueconf-bot library.  The adapter uses aiogram-like
    router/message-handler patterns for event dispatch.

    Features:
    - Text, photo, document, audio message handling
    - Survey/poll support
    - Group chats and channels
    - Reply threading
    - Anti-spam-loop protection with rate limiting
    - Automatic reconnection with exponential backoff
    """

    MAX_MESSAGE_LENGTH = 4096

    def __init__(self, config: PlatformConfig):
        super().__init__(config, Platform.TRUECONF)

        # Connection parameters
        self._server: str = (
            config.extra.get("server", "")
            or os.getenv("TRUECONF_SERVER", "")
        ).strip()
        self._username: str = (
            config.extra.get("username", "")
            or os.getenv("TRUECONF_USERNAME", "")
        ).strip()
        self._password: str = (
            config.extra.get("password", "")
            or os.getenv("TRUECONF_PASSWORD", "")
        ).strip()
        self._token: str = (
            config.token
            or config.extra.get("token", "")
            or os.getenv("TRUECONF_TOKEN", "")
        ).strip()

        # Connection options
        self._port: int = int(config.extra.get("port", 443))
        self._use_ssl: bool = self._coerce_bool_extra("use_ssl", True)
        self._verify_ssl: bool = self._coerce_bool_extra("verify_ssl", True)
        self._receive_unread: bool = self._coerce_bool_extra("receive_unread", False)

        # Library objects
        self._bot: Optional[Bot] = None
        self._dispatcher: Optional[Dispatcher] = None
        self._ws_task: Optional[asyncio.Task] = None
        self._closing = False
        self._bot_user_id: Optional[str] = None

        # Anti-spam protection
        rate_cfg = config.extra.get("rate_limit", {})
        if isinstance(rate_cfg, str):
            rate_cfg = {}
        self._anti_spam = AntiSpamProtection(
            max_per_minute=int(rate_cfg.get("max_per_minute", 10)),
            burst_limit=int(rate_cfg.get("burst_limit", 5)),
            burst_window=float(rate_cfg.get("burst_window", 3.0)),
        )

        # Message deduplication
        self._dedup = MessageDeduplicator(max_size=5000, ttl_seconds=300)

        # Reconnection state
        self._reconnect_count = 0
        self._max_reconnects = 50
        self._reconnect_base_delay = 2.0
        self._reconnect_max_delay = 60.0
        self._monitor_task: asyncio.Task | None = None

        # Sent message tracking for loop detection
        self._sent_message_ids: set = set()
        self._max_tracked_sent = 2000

    def _coerce_bool_extra(self, key: str, default: bool = False) -> bool:
        """Parse a boolean from config extra."""
        value = self.config.extra.get(key)
        if value is None:
            return default
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in ("true", "1", "yes", "on"):
                return True
            if lowered in ("false", "0", "no", "off"):
                return False
            return default
        return bool(value)

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------

    async def connect(self) -> bool:
        """
        Connect to TrueConf Server via WebSocket.

        Creates a Bot instance, sets up event handlers, and starts
        the WebSocket listener in a background task.
        """
        if not TRUECONF_AVAILABLE:
            logger.error(
                "[TrueConf] python-trueconf-bot not installed. "
                "Run: pip install git+https://github.com/TrueConf/python-trueconf-bot"
            )
            return False

        if not self._server:
            logger.error("[TrueConf] Server hostname not configured")
            return False

        self._closing = False

        try:
            # Create bot instance
            if self._token:
                self._bot = Bot(
                    server=self._server,
                    token=self._token,
                    web_port=self._port,
                    https=self._use_ssl,
                    verify_ssl=self._verify_ssl,
                    receive_unread_messages=self._receive_unread,
                )
            elif self._username and self._password:
                self._bot = Bot.from_credentials(
                    server=self._server,
                    username=self._username,
                    password=self._password,
                    verify_ssl=self._verify_ssl,
                    https=self._use_ssl,
                    web_port=self._port,
                    receive_unread_messages=self._receive_unread,
                )
            else:
                logger.error(
                    "[TrueConf] No credentials configured. "
                    "Set TRUECONF_TOKEN or TRUECONF_USERNAME + TRUECONF_PASSWORD"
                )
                return False

            # Set up dispatcher with event handlers
            self._dispatcher = Dispatcher()
            self._register_handlers(self._dispatcher)

            # Bind dispatcher to bot (library uses bot.dp, not bot.dispatcher)
            self._bot.dp = self._dispatcher

            # Start bot connection
            logger.info(
                "[TrueConf] Connecting to %s:%d (ssl=%s)...",
                self._server, self._port, self._use_ssl,
            )

            # Start the bot (connects WebSocket and begins listening)
            self._ws_task = asyncio.create_task(self._bot.start())

            # Wait for connection + authorization
            try:
                await asyncio.wait_for(self._bot.connected_event.wait(), timeout=15)
                logger.info("[TrueConf] WebSocket connected")
                await asyncio.wait_for(self._bot.authorized_event.wait(), timeout=15)
                logger.info("[TrueConf] Authorized")
            except asyncio.TimeoutError:
                logger.error("[TrueConf] Connection/authorization timed out")
                return False

            # If the task has already failed, raise the exception
            if self._ws_task.done():
                exc = self._ws_task.exception()
                if exc:
                    raise exc

            # Get bot's own user ID for loop detection
            try:
                self._bot_user_id = await self._bot.me
                self._anti_spam.set_bot_user_id(self._bot_user_id)
                logger.info("[TrueConf] Bot user ID: %s", self._bot_user_id)
            except Exception as e:
                logger.warning("[TrueConf] Could not get bot user ID: %s", e)

            self._reconnect_count = 0
            self._mark_connected()
            logger.info(
                "[TrueConf] Connected to %s as bot", self._server,
            )

            # Start WebSocket monitor — detects disconnects and auto-reconnects
            self._monitor_task = asyncio.create_task(self._ws_monitor())

            return True

        except Exception as exc:
            logger.error(
                "[TrueConf] Connection failed: %s", exc, exc_info=True,
            )
            self._set_fatal_error(
                "trueconf_connect_error",
                f"Failed to connect to TrueConf Server: {exc}",
                retryable=True,
            )
            await self._notify_fatal_error()
            return False

    async def disconnect(self) -> None:
        """Disconnect from TrueConf Server."""
        self._closing = True

        # Stop monitor task
        if self._monitor_task and not self._monitor_task.done():
            self._monitor_task.cancel()
            try:
                await self._monitor_task
            except (asyncio.CancelledError, Exception):
                pass

        if self._ws_task and not self._ws_task.done():
            self._ws_task.cancel()
            try:
                await self._ws_task
            except (asyncio.CancelledError, Exception):
                pass

        if self._bot:
            try:
                await self._bot.shutdown()
            except Exception:
                pass

        self._bot = None
        self._dispatcher = None
        self._mark_disconnected()
        logger.info("[TrueConf] Disconnected")

    # ------------------------------------------------------------------
    # WebSocket monitor — auto-reconnect on unexpected disconnect
    # ------------------------------------------------------------------

    async def _ws_monitor(self) -> None:
        """Monitor WebSocket task and auto-reconnect on unexpected disconnect."""
        while not self._closing:
            if self._bot is None:
                break

            # Watch the library's internal _connect_task (the actual WS loop)
            # NOT _ws_task which completes instantly after bot.start()
            connect_task = getattr(self._bot, '_connect_task', None)
            if connect_task is None:
                # Bot not started yet, wait a bit
                await asyncio.sleep(1)
                continue

            # Wait for the connect task to finish (disconnect or crash)
            try:
                await asyncio.shield(connect_task)
            except asyncio.CancelledError:
                break
            except Exception as exc:
                logger.warning("[TrueConf] WebSocket task error: %s", exc)

            # If we're shutting down, don't reconnect
            if self._closing:
                break

            # Unexpected disconnect — attempt reconnect
            self._reconnect_count += 1
            if self._reconnect_count > self._max_reconnects:
                logger.error(
                    "[TrueConf] Max reconnects (%d) reached, giving up",
                    self._max_reconnects,
                )
                self._set_fatal_error(
                    "trueconf_max_reconnects",
                    f"Failed to reconnect after {self._max_reconnects} attempts",
                    retryable=False,
                )
                await self._notify_fatal_error()
                break

            delay = min(
                self._reconnect_base_delay * (2 ** (self._reconnect_count - 1)),
                self._reconnect_max_delay,
            )
            logger.info(
                "[TrueConf] Connection lost, reconnecting in %.1fs (attempt %d/%d)...",
                delay, self._reconnect_count, self._max_reconnects,
            )
            await asyncio.sleep(delay)

            # Cleanup old bot before reconnect
            if self._bot:
                try:
                    await self._bot.shutdown()
                except Exception:
                    pass
                self._bot = None
                self._dispatcher = None

            # Reconnect
            try:
                success = await self.connect()
                if success:
                    logger.info("[TrueConf] Reconnected successfully")
                    # connect() starts a new _ws_task and _monitor_task
                    # This monitor can exit — the new one takes over
                    break
                else:
                    logger.warning("[TrueConf] Reconnect attempt failed")
            except Exception as exc:
                logger.error("[TrueConf] Reconnect error: %s", exc)

    # ------------------------------------------------------------------
    # Event handler registration
    # ------------------------------------------------------------------

    def _register_handlers(self, dp: Dispatcher) -> None:
        """Register message and event handlers with the dispatcher."""

        router = Router(name="hermes_gateway")

        # --- Message handlers ---

        @router.message(F.text)
        async def handle_text_message(message: Message) -> None:
            """Handle text messages."""
            await self._on_text_message(message)

        @router.message(F.photo)
        async def handle_photo_message(message: Message) -> None:
            """Handle photo messages."""
            await self._on_photo_message(message)

        @router.message(F.document)
        async def handle_document_message(message: Message) -> None:
            """Handle document/file messages."""
            await self._on_document_message(message)

        @router.message(F.video)
        async def handle_video_message(message: Message) -> None:
            """Handle video messages."""
            await self._on_video_message(message)

        @router.message(F.content.mimetype.startswith("audio/"))
        async def handle_audio_message(message: Message) -> None:
            """Handle audio/voice messages."""
            await self._on_audio_message(message)

        @router.message()
        async def handle_other_message(message: Message) -> None:
            """Handle all other message types."""
            await self._on_other_message(message)

        # --- Update handlers ---

        @router.edited_message()
        async def handle_edited_message(message: Message) -> None:
            """Handle edited messages — ignore for now."""
            logger.debug(
                "[TrueConf] Message %s edited in chat %s",
                message.message_id, message.chat_id,
            )

        dp.include_router(router)

    # ------------------------------------------------------------------
    # Message event handlers
    # ------------------------------------------------------------------

    async def _on_text_message(self, message: Message) -> None:
        """Process a text message from TrueConf."""
        if not self._validate_incoming(message):
            return

        text = message.text or ""
        if not text.strip():
            return

        # Determine chat type
        chat_type = self._resolve_chat_type(message)
        user_id = message.from_user.id if message.from_user else ""
        user_name = getattr(message.from_user, "display_name", None) or user_id

        # Build source
        source = self.build_source(
            chat_id=str(message.chat_id),
            chat_name=getattr(message.box, "title", None),
            chat_type=chat_type,
            user_id=user_id,
            user_name=user_name,
        )

        # Check if this is a slash command
        msg_type = MessageType.TEXT
        if text.startswith("/"):
            msg_type = MessageType.COMMAND

        event = MessageEvent(
            text=text,
            message_type=msg_type,
            source=source,
            raw_message=message,
            message_id=str(message.message_id),
            reply_to_message_id=str(message.reply_message_id) if message.reply_message_id else None,
            timestamp=message.timestamp if hasattr(message, "timestamp") else None,
        )

        await self.handle_message(event)

    async def _on_photo_message(self, message: Message) -> None:
        """Process a photo message from TrueConf. Uses built-in download_file_by_id."""
        if not self._validate_incoming(message):
            return

        media_urls: List[str] = []
        media_types: List[str] = []

        try:
            photo = message.photo
            file_id = getattr(photo, "file_id", None) if photo else None
            if file_id and self._bot:
                data = await self._bot.download_file_by_id(file_id=file_id)
                if data and isinstance(data, bytes):
                    ext = ".jpg"
                    mime = getattr(photo, "mimetype", "image/jpeg") or "image/jpeg"
                    if mime == "image/png":
                        ext = ".png"
                    elif mime == "image/webp":
                        ext = ".webp"
                    elif mime == "image/gif":
                        ext = ".gif"
                    filepath = cache_image_from_bytes(data, ext)
                    media_urls.append(filepath)
                    media_types.append(mime)
        except Exception as e:
            logger.warning("[TrueConf] Failed to download photo: %s", e)

        text = message.text or getattr(message, "caption", None) or ""
        chat_type = self._resolve_chat_type(message)
        user_id = message.from_user.id if message.from_user else ""
        user_name = getattr(message.from_user, "display_name", None) or user_id

        source = self.build_source(
            chat_id=str(message.chat_id),
            chat_name=getattr(message.box, "title", None),
            chat_type=chat_type,
            user_id=user_id,
            user_name=user_name,
        )

        event = MessageEvent(
            text=text,
            message_type=MessageType.PHOTO,
            source=source,
            raw_message=message,
            message_id=str(message.message_id),
            media_urls=media_urls,
            media_types=media_types,
            reply_to_message_id=str(message.reply_message_id) if message.reply_message_id else None,
        )

        await self.handle_message(event)

    async def _on_document_message(self, message: Message) -> None:
        """Process a document/file message from TrueConf. Uses built-in download_file_by_id."""
        if not self._validate_incoming(message):
            return

        media_urls: List[str] = []
        media_types: List[str] = []

        try:
            doc = message.document
            file_id = getattr(doc, "file_id", None) if doc else None
            if file_id and self._bot:
                data = await self._bot.download_file_by_id(file_id=file_id)
                if data and isinstance(data, bytes):
                    filename = getattr(doc, "file_name", "document")
                    filepath = cache_document_from_bytes(data, filename)
                    media_urls.append(filepath)
                    mime = getattr(doc, "mimetype", "application/octet-stream") or "application/octet-stream"
                    media_types.append(mime)
                elif doc and hasattr(doc, "download"):
                    # Fallback: use Document.download() with temp dir
                    import tempfile
                    tmp_dir = tempfile.mkdtemp(prefix="tc_doc_")
                    dest = await doc.download(dest_path=tmp_dir)
                    if dest:
                        media_urls.append(str(dest))
                        mime = getattr(doc, "mimetype", "application/octet-stream") or "application/octet-stream"
                        media_types.append(mime)
        except Exception as e:
            logger.warning("[TrueConf] Failed to download document: %s", e)

        text = message.text or getattr(message, "caption", None) or ""
        chat_type = self._resolve_chat_type(message)
        user_id = message.from_user.id if message.from_user else ""
        user_name = getattr(message.from_user, "display_name", None) or user_id

        source = self.build_source(
            chat_id=str(message.chat_id),
            chat_name=getattr(message.box, "title", None),
            chat_type=chat_type,
            user_id=user_id,
            user_name=user_name,
        )

        event = MessageEvent(
            text=text,
            message_type=MessageType.DOCUMENT,
            source=source,
            raw_message=message,
            message_id=str(message.message_id),
            media_urls=media_urls,
            media_types=media_types,
            reply_to_message_id=str(message.reply_message_id) if message.reply_message_id else None,
        )

        await self.handle_message(event)

    async def _on_video_message(self, message: Message) -> None:
        """Process a video message from TrueConf. Uses built-in download_file_by_id."""
        if not self._validate_incoming(message):
            return

        media_urls: List[str] = []
        media_types: List[str] = []

        try:
            video = message.video
            file_id = getattr(video, "file_id", None) if video else None
            if file_id and self._bot:
                data = await self._bot.download_file_by_id(file_id=file_id)
                if data and isinstance(data, bytes):
                    mime = getattr(video, "mimetype", "video/mp4") or "video/mp4"
                    ext = ".mp4"
                    if "webm" in mime:
                        ext = ".webm"
                    elif "avi" in mime:
                        ext = ".avi"
                    filepath = cache_document_from_bytes(data, f"video_{message.message_id}{ext}")
                    media_urls.append(filepath)
                    media_types.append(mime)
        except Exception as e:
            logger.warning("[TrueConf] Failed to download video: %s", e)

        text = message.text or getattr(message, "caption", None) or ""
        chat_type = self._resolve_chat_type(message)
        user_id = message.from_user.id if message.from_user else ""
        user_name = getattr(message.from_user, "display_name", None) or user_id

        source = self.build_source(
            chat_id=str(message.chat_id),
            chat_name=getattr(message.box, "title", None),
            chat_type=chat_type,
            user_id=user_id,
            user_name=user_name,
        )

        event = MessageEvent(
            text=text,
            message_type=MessageType.VIDEO,
            source=source,
            raw_message=message,
            message_id=str(message.message_id),
            media_urls=media_urls,
            media_types=media_types,
            reply_to_message_id=str(message.reply_message_id) if message.reply_message_id else None,
        )

        await self.handle_message(event)

    async def _on_audio_message(self, message: Message) -> None:
        """Process an audio/voice message from TrueConf. Uses built-in download_file_by_id."""
        if not self._validate_incoming(message):
            return

        media_urls: List[str] = []
        media_types: List[str] = []

        try:
            audio = message.content
            file_id = getattr(audio, "file_id", None) if audio else None
            if file_id and self._bot:
                data = await self._bot.download_file_by_id(file_id=file_id)
                if data and isinstance(data, bytes):
                    mime = getattr(audio, "mimetype", "audio/ogg") or "audio/ogg"
                    # Derive correct file extension from mimetype
                    ext = ".ogg"
                    if "mp4" in mime or "m4a" in mime:
                        ext = ".m4a"
                    elif "mpeg" in mime or "mp3" in mime:
                        ext = ".mp3"
                    elif "wav" in mime:
                        ext = ".wav"
                    elif "webm" in mime:
                        ext = ".webm"
                    elif "amr" in mime:
                        ext = ".amr"
                    filepath = cache_audio_from_bytes(data, ext=ext)
                    media_urls.append(filepath)
                    media_types.append(mime)
        except Exception as e:
            logger.warning("[TrueConf] Failed to download audio: %s", e)

        text = message.text or getattr(message, "caption", None) or ""
        chat_type = self._resolve_chat_type(message)
        user_id = message.from_user.id if message.from_user else ""
        user_name = getattr(message.from_user, "display_name", None) or user_id

        source = self.build_source(
            chat_id=str(message.chat_id),
            chat_name=getattr(message.box, "title", None),
            chat_type=chat_type,
            user_id=user_id,
            user_name=user_name,
        )

        event = MessageEvent(
            text=text,
            message_type=MessageType.VOICE,
            source=source,
            raw_message=message,
            message_id=str(message.message_id),
            media_urls=media_urls,
            media_types=media_types,
            reply_to_message_id=str(message.reply_message_id) if message.reply_message_id else None,
        )

        await self.handle_message(event)

    async def _on_other_message(self, message: Message) -> None:
        """Handle other/unrecognized message types."""
        if not self._validate_incoming(message):
            return

        chat_type = self._resolve_chat_type(message)
        user_id = message.from_user.id if message.from_user else ""
        user_name = getattr(message.from_user, "display_name", None) or user_id

        source = self.build_source(
            chat_id=str(message.chat_id),
            chat_name=getattr(message.box, "title", None),
            chat_type=chat_type,
            user_id=user_id,
            user_name=user_name,
        )

        text = getattr(message, "text", "") or ""
        if not text:
            msg_type_name = str(getattr(message, "type", "unknown"))
            text = f"[Unsupported message type: {msg_type_name}]"

        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=source,
            raw_message=message,
            message_id=str(message.message_id),
        )

        await self.handle_message(event)

    # ------------------------------------------------------------------
    # Validation (anti-spam, loop detection, dedup)
    # ------------------------------------------------------------------

    def _validate_incoming(self, message: Message) -> bool:
        """
        Validate an incoming message through all protection layers.

        Returns True if the message should be processed, False to skip.
        """
        # Emergency stop check
        if self._anti_spam.is_emergency_stopped():
            logger.debug("[TrueConf] Message blocked by emergency stop")
            return False

        # Get user ID
        user_id = ""
        if message.from_user:
            user_id = getattr(message.from_user, "id", "") or ""

        # Loop detection: never process our own messages
        if self._anti_spam.is_self_loop(user_id):
            logger.debug(
                "[TrueConf] Ignoring self-message from bot (%s)",
                _redact_user_id(user_id),
            )
            return False

        # Also check if we sent this message ID ourselves
        msg_id = str(message.message_id) if message.message_id else ""
        if msg_id and msg_id in self._sent_message_ids:
            logger.debug("[TrueConf] Ignoring echo of sent message %s", msg_id)
            return False

        # Message deduplication
        if self._dedup.is_duplicate(msg_id):
            logger.debug("[TrueConf] Duplicate message %s, skipping", msg_id)
            return False

        # Rate limiting
        if user_id and self._anti_spam.check_rate_limit(user_id):
            logger.warning(
                "[TrueConf] Rate-limited message from %s",
                _redact_user_id(user_id),
            )
            return False

        return True

    def _track_sent_message(self, message_id: Optional[str]) -> None:
        """Track a message ID we sent to filter echo events."""
        if not message_id:
            return
        self._sent_message_ids.add(str(message_id))
        # Prevent unbounded growth
        if len(self._sent_message_ids) > self._max_tracked_sent:
            # Remove oldest half
            ids_list = list(self._sent_message_ids)
            self._sent_message_ids = set(ids_list[len(ids_list) // 2:])

    # ------------------------------------------------------------------
    # Sending messages
    # ------------------------------------------------------------------

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """
        Send a text message to a TrueConf chat.

        Supports message chunking for long messages.
        """
        if not content:
            return SendResult(success=True)

        if not self._bot:
            return SendResult(success=False, error="Bot not connected")

        try:
            # Format and chunk the message
            formatted = self.format_message(content)
            chunks = self.truncate_message(formatted, self.MAX_MESSAGE_LENGTH)

            last_id = None
            for chunk in chunks:
                kwargs: Dict[str, Any] = {
                    "chat_id": chat_id,
                    "text": chunk,
                    "parse_mode": ParseMode.HTML if ParseMode else None,
                }
                if reply_to:
                    kwargs["reply_message_id"] = reply_to

                result = await self._bot.send_message(**kwargs)
                if result and hasattr(result, "message_id"):
                    last_id = result.message_id
                    self._track_sent_message(last_id)
                    # Only the first chunk replies to the original message
                    reply_to = None

            return SendResult(success=True, message_id=last_id)

        except Exception as exc:
            error_str = str(exc)
            logger.error("[TrueConf] Send failed: %s", error_str)
            return SendResult(
                success=False,
                error=error_str,
                retryable=self._is_retryable_error(error_str),
            )

    async def send_typing(
        self, chat_id: str, metadata: Optional[Dict[str, Any]] = None
    ) -> None:
        """
        Send typing indicator.

        TrueConf doesn't have a standard typing indicator API,
        so this is a no-op. Override if the server supports it.
        """
        pass

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """
        Send a photo to a TrueConf chat.

        Downloads the image and sends it as a photo attachment.
        Uses BufferedInputFile from python-trueconf-bot library.
        """
        if not self._bot:
            return SendResult(success=False, error="Bot not connected")

        try:
            import httpx
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.get(image_url)
                resp.raise_for_status()
                image_data = resp.content

            from trueconf.types import BufferedInputFile
            file = BufferedInputFile(data=image_data, filename="image.jpg")

            kwargs: Dict[str, Any] = {
                "chat_id": chat_id,
                "file": file,
                "preview": None,
            }
            if caption:
                kwargs["caption"] = caption
                kwargs["parse_mode"] = ParseMode.HTML if ParseMode else "html"
            if reply_to:
                kwargs["reply_message_id"] = reply_to

            result = await self._bot.send_photo(**kwargs)
            msg_id = result.message_id if result and hasattr(result, "message_id") else None
            self._track_sent_message(msg_id)
            return SendResult(success=True, message_id=msg_id)

        except Exception as exc:
            error_str = str(exc)
            logger.error("[TrueConf] send_image failed: %s", error_str)
            return SendResult(
                success=False,
                error=error_str,
                retryable=self._is_retryable_error(error_str),
            )

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Send a local image file as a photo. Uses FSInputFile."""
        if not self._bot:
            return SendResult(success=False, error="Bot not connected")

        try:
            from trueconf.types import FSInputFile
            file = FSInputFile(path=image_path)

            kwargs: Dict[str, Any] = {
                "chat_id": chat_id,
                "file": file,
                "preview": None,
            }
            if caption:
                kwargs["caption"] = caption
                kwargs["parse_mode"] = ParseMode.HTML if ParseMode else "html"
            if reply_to:
                kwargs["reply_message_id"] = reply_to

            result = await self._bot.send_photo(**kwargs)
            msg_id = result.message_id if result and hasattr(result, "message_id") else None
            self._track_sent_message(msg_id)
            return SendResult(success=True, message_id=msg_id)

        except Exception as exc:
            error_str = str(exc)
            logger.error("[TrueConf] send_image_file failed: %s", error_str)
            return SendResult(
                success=False,
                error=error_str,
                retryable=self._is_retryable_error(error_str),
            )

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: Optional[str] = None,
        file_name: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Send a file/document to a TrueConf chat. Uses FSInputFile."""
        if not self._bot:
            return SendResult(success=False, error="Bot not connected")

        try:
            from trueconf.types import FSInputFile
            file = FSInputFile(path=file_path)

            kwargs: Dict[str, Any] = {
                "chat_id": chat_id,
                "file": file,
            }
            if caption:
                kwargs["caption"] = caption
                kwargs["parse_mode"] = ParseMode.HTML if ParseMode else "html"
            if reply_to:
                kwargs["reply_message_id"] = reply_to

            result = await self._bot.send_document(**kwargs)
            msg_id = result.message_id if result and hasattr(result, "message_id") else None
            self._track_sent_message(msg_id)
            return SendResult(success=True, message_id=msg_id)

        except Exception as exc:
            error_str = str(exc)
            logger.error("[TrueConf] send_document failed: %s", error_str)
            return SendResult(
                success=False,
                error=error_str,
                retryable=self._is_retryable_error(error_str),
            )

    async def send_voice(
        self,
        chat_id: str,
        audio_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Send an audio file to a TrueConf chat."""
        # TrueConf doesn't differentiate voice from document for audio,
        # so we send it as a document with audio mime type
        return await self.send_document(
            chat_id=chat_id,
            file_path=audio_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def send_video(
        self,
        chat_id: str,
        video_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Send a video file to a TrueConf chat."""
        return await self.send_document(
            chat_id=chat_id,
            file_path=video_path,
            caption=caption,
            reply_to=reply_to,
            metadata=metadata,
        )

    async def edit_message(
        self,
        chat_id: str,
        message_id: str,
        content: str,
        *,
        finalize: bool = False,
    ) -> SendResult:
        """Edit a previously sent message."""
        if not self._bot:
            return SendResult(success=False, error="Bot not connected")

        try:
            formatted = self.format_message(content)
            result = await self._bot.edit_message(
                message_id=message_id,
                text=formatted,
                parse_mode=ParseMode.HTML if ParseMode else None,
            )
            msg_id = result.message_id if result and hasattr(result, "message_id") else message_id
            return SendResult(success=True, message_id=msg_id)

        except Exception as exc:
            error_str = str(exc)
            logger.warning("[TrueConf] edit_message failed: %s", error_str)
            return SendResult(success=False, error=error_str)

    # ------------------------------------------------------------------
    # Chat info
    # ------------------------------------------------------------------

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        """Get information about a TrueConf chat."""
        if not self._bot:
            return {"name": chat_id, "type": "dm"}

        try:
            chat = await self._bot.get_chat_by_id(chat_id)
            if chat:
                chat_type = "group"
                if hasattr(chat, "type"):
                    ct = str(chat.type).lower()
                    if "channel" in ct:
                        chat_type = "channel"
                    elif "private" in ct or "personal" in ct:
                        chat_type = "dm"
                return {
                    "name": getattr(chat, "title", None) or chat_id,
                    "type": chat_type,
                    "chat_id": chat_id,
                }
        except Exception as e:
            logger.debug("[TrueConf] get_chat_info(%s) failed: %s", chat_id, e)

        return {"name": chat_id, "type": "dm"}

    # ------------------------------------------------------------------
    # Formatting
    # ------------------------------------------------------------------

    def format_message(self, content: str) -> str:
        """
        Format message content for TrueConf.

        TrueConf supports HTML formatting. Convert common markdown
        to HTML tags.
        """
        import re

        # Convert markdown code blocks to HTML
        content = re.sub(
            r'```(\w*)\n(.*?)```',
            lambda m: f'<pre><code>{m.group(2)}</code></pre>',
            content,
            flags=re.DOTALL,
        )

        # Convert inline code
        content = re.sub(r'`([^`]+)`', r'<code>\1</code>', content)

        # Convert bold
        content = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', content)

        # Convert italic
        content = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<i>\1</i>', content)

        # Convert strikethrough
        content = re.sub(r'~~(.+?)~~', r'<s>\1</s>', content)

        # Convert links
        content = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', content)

        # Strip image markdown (images are sent separately)
        content = re.sub(r'!\[([^\]]*)\]\([^)]+\)', '', content)

        # Clean up excess blank lines
        content = re.sub(r'\n{3,}', '\n\n', content).strip()

        return content

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _resolve_chat_type(message: Message) -> str:
        """Determine chat type from a TrueConf message."""
        if hasattr(message, "box") and hasattr(message.box, "chat_type"):
            ct = str(message.box.chat_type).lower()
            if "channel" in ct:
                return "channel"
            if "group" in ct:
                return "group"
        # Check if there are multiple participants
        if hasattr(message, "box") and hasattr(message.box, "participants_count"):
            count = getattr(message.box, "participants_count", 0) or 0
            if count > 2:
                return "group"
        return "dm"

    def _is_retryable_error(self, error: str) -> bool:
        """Check if an error string indicates a transient failure."""
        if not error:
            return False
        lowered = error.lower()
        return any(
            pat in lowered
            for pat in (
                "timeout", "connection", "network", "temporarily",
                "retry", "reset", "broken pipe", "eof",
            )
        )

    # ------------------------------------------------------------------
    # Emergency control methods (accessible from gateway)
    # ------------------------------------------------------------------

    def emergency_stop(self, reason: str = "manual") -> None:
        """Manually trigger the emergency stop."""
        self._anti_spam.trigger_emergency_stop(reason)

    def reset_stop(self) -> None:
        """Reset the emergency stop."""
        self._anti_spam.reset_emergency_stop()

    def get_protection_stats(self) -> Dict[str, Any]:
        """Get anti-spam protection statistics."""
        return self._anti_spam.get_stats()
