#!/bin/bash
# ===========================================
# TrueConf Adapter — Auto-Patch Script v2.0
# ===========================================
# Applies patches to hermes-agent core files.
# Safe to run multiple times (idempotent).
#
# Usage: bash apply_patches.sh [HERMES_DIR]
# ===========================================

set -e

HERMES_DIR="${1:-${HERMES_DIR:-$HOME/.hermes/hermes-agent}}"
PATCHED=0

log_ok()   { echo "  ✓ $1"; }
log_skip() { echo "  · $1 (already patched)"; }
log_patch(){ echo "  → $1"; }

# Determine where this script lives (could be in repo or in plugins dir)
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"

# Determine Python version in venv
VENV_DIR="${HERMES_DIR}/venv"
if [ -d "${VENV_DIR}/lib" ]; then
    PYTHON_VER=$(ls "${VENV_DIR}/lib/" | grep -oP 'python3\.\d+' | head -1)
    if [ -z "$PYTHON_VER" ]; then
        PYTHON_VER="python3.11"  # fallback
    fi
else
    PYTHON_VER="python3.11"  # fallback
fi
SITE_PACKAGES="${VENV_DIR}/lib/${PYTHON_VER}/site-packages"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TrueConf Adapter — Apply Patches v2.0"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Hermes: $HERMES_DIR"
echo "  Python: $PYTHON_VER"
echo ""

# ───────────────────────────────────────────
# 1. gateway/config.py — Platform Enum & Auto-Detect
# ───────────────────────────────────────────
CONFIG_PY="${HERMES_DIR}/gateway/config.py"

if [ ! -f "$CONFIG_PY" ]; then
    echo "✗ gateway/config.py not found: $CONFIG_PY"
    exit 1
fi

# 1a. Platform.TRUECONF Enum Entry
if grep -q 'TRUECONF = "trueconf"' "$CONFIG_PY" 2>/dev/null; then
    log_skip "Platform.TRUECONF enum"
else
    log_patch "Adding Platform.TRUECONF to enum..."
    sed -i '/QQBOT = "qqbot"/a\    TRUECONF = "trueconf"' "$CONFIG_PY"
    log_ok "Platform.TRUECONF enum added"
    PATCHED=$((PATCHED + 1))
fi

# 1b. Auto-Detect Block
if grep -q 'trueconf_server = os.getenv' "$CONFIG_PY" 2>/dev/null; then
    log_skip "auto-detect block in config.py"
else
    log_patch "Adding auto-detect block..."
    python3 - "$CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = '    # Feishu / Lark'
if marker not in content:
    marker = '    feishu_app_id = os.getenv("FEISHU_APP_ID")'

patch = '''
    # TrueConf
    trueconf_server = os.getenv("TRUECONF_SERVER", "").strip()
    trueconf_token = os.getenv("TRUECONF_TOKEN", "").strip()
    trueconf_username = os.getenv("TRUECONF_USERNAME", "").strip()
    trueconf_password = os.getenv("TRUECONF_PASSWORD", "").strip()
    if trueconf_server and (trueconf_token or (trueconf_username and trueconf_password)):
        if Platform.TRUECONF not in config.platforms:
            config.platforms[Platform.TRUECONF] = PlatformConfig()
        config.platforms[Platform.TRUECONF].enabled = True
        if trueconf_token:
            config.platforms[Platform.TRUECONF].token = trueconf_token
        config.platforms[Platform.TRUECONF].extra["server"] = trueconf_server
        if trueconf_username:
            config.platforms[Platform.TRUECONF].extra["username"] = trueconf_username
        if trueconf_password:
            config.platforms[Platform.TRUECONF].extra["password"] = trueconf_password
        trueconf_port = os.getenv("TRUECONF_PORT", "").strip()
        if trueconf_port:
            try:
                config.platforms[Platform.TRUECONF].extra["port"] = int(trueconf_port)
            except ValueError:
                pass
        # Auto-detect SSL: internal IPs default to no SSL, domains default to SSL
        import re as _re
        _is_internal_ip = bool(_re.match(r'^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)', trueconf_server))
        _default_ssl = not _is_internal_ip
        trueconf_ssl = os.getenv("TRUECONF_USE_SSL", "").strip().lower()
        if trueconf_ssl:
            config.platforms[Platform.TRUECONF].extra["use_ssl"] = trueconf_ssl in ("true", "1", "yes", "y")
        else:
            config.platforms[Platform.TRUECONF].extra["use_ssl"] = _default_ssl
        trueconf_verify = os.getenv("TRUECONF_VERIFY_SSL", "").strip().lower()
        if trueconf_verify:
            config.platforms[Platform.TRUECONF].extra["verify_ssl"] = trueconf_verify in ("true", "1", "yes", "y")
        trueconf_home = os.getenv("TRUECONF_HOME_CHANNEL")
        if trueconf_home:
            config.platforms[Platform.TRUECONF].home_channel = HomeChannel(
                platform=Platform.TRUECONF,
                chat_id=trueconf_home,
                name=os.getenv("TRUECONF_HOME_CHANNEL_NAME", "Home"),
            )
'''
content = content.replace(marker, patch + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "auto-detect block added"
    PATCHED=$((PATCHED + 1))
fi

# 1c. get_connected_platforms — TrueConf check
if grep -q 'Platform.TRUECONF and config.extra' "$CONFIG_PY" 2>/dev/null; then
    log_skip "get_connected_platforms TrueConf check"
else
    log_patch "Adding TrueConf to get_connected_platforms..."
    python3 - "$CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = '            elif platform == Platform.QQBOT and config.extra.get("app_id") and config.extra.get("client_secret"):\n                connected.append(platform)'
replacement = marker + '''\n            # TrueConf uses extra dict for server + credentials\n            elif platform == Platform.TRUECONF and config.extra.get("server") and (\n                config.token or config.extra.get("token")\n                or (config.extra.get("username") and config.extra.get("password"))\n            ):\n                connected.append(platform)'''
content = content.replace(marker, replacement, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "get_connected_platforms TrueConf check added"
    PATCHED=$((PATCHED + 1))
fi

# ───────────────────────────────────────────
# 2. hermes_cli/platforms.py + gateway.py — PLATFORMS Dict & Setup Wizard
# ───────────────────────────────────────────
PLATFORMS_PY="${HERMES_DIR}/hermes_cli/platforms.py"
GATEWAY_PY="${HERMES_DIR}/hermes_cli/gateway.py"

if [ ! -f "$PLATFORMS_PY" ]; then
    echo "✗ hermes_cli/platforms.py not found"
    exit 1
fi

if grep -q '"trueconf"' "$PLATFORMS_PY" 2>/dev/null; then
    log_skip "TrueConf in PLATFORMS dict"
else
    log_patch "Adding TrueConf to PLATFORMS dict..."
    python3 - "$PLATFORMS_PY" << 'PYEOF2'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

import re
# Find the closing ]) of the PLATFORMS OrderedDict and insert before it
pattern = r'(\]\))'
matches = list(re.finditer(pattern, content))
if matches:
    insert_pos = matches[0].start()
    trueconf_line = '    ("trueconf",       PlatformInfo(label="📹 TrueConf",        default_toolset="hermes-trueconf")),'
    content = content[:insert_pos] + trueconf_line + "\n" + content[insert_pos:]
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF2
    log_ok "TrueConf in PLATFORMS dict added"
    PATCHED=$((PATCHED + 1))
fi

# 2b. hermes_cli/gateway.py — _PLATFORMS list (setup wizard)
if [ ! -f "$GATEWAY_PY" ]; then
    log_skip "hermes_cli/gateway.py not found (skipping setup wizard patch)"
else
    if grep -q '"key": "trueconf"' "$GATEWAY_PY" 2>/dev/null; then
        log_skip "TrueConf in gateway.py _PLATFORMS"
    else
        log_patch "Adding TrueConf to setup wizard _PLATFORMS..."
        python3 - "$GATEWAY_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

trueconf_entry = '''    {
        "key": "trueconf",
        "label": "TrueConf",
        "emoji": "📹",
        "token_var": "TRUECONF_SERVER",
        "setup_instructions": [
            "1. Get a TrueConf Server account (ask your admin)",
            "2. Note the server address, your bot username and password",
            "3. Enter them below — Hermes will connect via WebSocket",
        ],
        "vars": [
            {"name": "TRUECONF_SERVER", "prompt": "Server address (e.g. video.example.com)", "password": False,
             "help": "TrueConf Server hostname without https:// prefix."},
            {"name": "TRUECONF_USERNAME", "prompt": "Bot username", "password": False,
             "help": "The TrueConf login for your bot account."},
            {"name": "TRUECONF_PASSWORD", "prompt": "Bot password", "password": True,
             "help": "The TrueConf password for your bot account."},
            {"name": "TRUECONF_ALLOWED_USERS", "prompt": "Allowed user logins (comma-separated, leave empty for open access)", "password": False,
             "is_allowlist": True,
             "help": "Optional — restrict who can message the bot."},
            {"name": "TRUECONF_HOME_CHANNEL", "prompt": "Home channel login (for cron delivery, or empty)", "password": False,
             "help": "User login to deliver cron results and notifications to."},
        ],
    },
]'''
if ']' in content:
    # Find the last ] that closes the _PLATFORMS list
    # Match pattern: } on its own line followed by ]
    import re
    pattern = '(\n]\ndef _all_platforms)'
    m = re.search(pattern, content)
    if m:
        content = content[:m.start(1)] + '\n' + trueconf_entry + m.group(1) + content[m.end(1):]
        with open(path, 'w') as f:
            f.write(content)
        print("OK")
    else:
        # Fallback: find ] after last dict entry
        # Find last "key": "yuanbao" section and insert after it
        idx = content.rfind('"key": "yuanbao"')
        if idx >= 0:
            # Find the closing ] after yuanbao
            bracket_idx = content.find('\n]', idx)
            if bracket_idx >= 0:
                entry_no_bracket = trueconf_entry.rstrip().rstrip(']')
                content = content[:bracket_idx] + '\n' + entry_no_bracket + content[bracket_idx:]
                with open(path, 'w') as f:
                    f.write(content)
                print("OK")
            else:
                print("SKIP: could not find ] after yuanbao")
        else:
            print("SKIP: could not find yuanbao entry")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "TrueConf added to setup wizard"
            PATCHED=$((PATCHED + 1))
        fi
    fi
fi

# ───────────────────────────────────────────
# 3. gateway/run.py — Adapter Creation & Auth Maps
# ───────────────────────────────────────────
RUN_PY="${HERMES_DIR}/gateway/run.py"

if [ ! -f "$RUN_PY" ]; then
    echo "✗ gateway/run.py not found"
    exit 1
fi

# 3a. TrueConfAdapter Creation Block
if grep -q 'Platform.TRUECONF' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConfAdapter creation block"
else
    log_patch "Adding TrueConfAdapter creation block..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find stable anchor: "return None" before "def _is_user_authorized"
pattern = r'(\n        return None\n    def _is_user_authorized)'
match = re.search(pattern, content)
if not match:
    print("FAIL: Could not find insertion point")
    sys.exit(1)

block = '''
        elif platform == Platform.TRUECONF:
            from gateway.platforms.trueconf import TrueConfAdapter, check_trueconf_requirements
            if not check_trueconf_requirements():
                logger.warning("TrueConf: python-trueconf-bot not installed. Run: pip install python-trueconf-bot")
                return None
            return TrueConfAdapter(config)
'''
content = content.replace(match.group(1), block + match.group(1), 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "TrueConfAdapter creation block added"
    PATCHED=$((PATCHED + 1))
fi

# 3b. Authorization Maps (4 patches)
# _any_allowlist
if grep -q 'TRUECONF_ALLOWED_USERS' "$RUN_PY" 2>/dev/null; then
    log_skip "TRUECONF_ALLOWED_USERS in _any_allowlist"
else
    log_patch "Adding TRUECONF_ALLOWED_USERS to _any_allowlist..."
    sed -i "/'QQ_ALLOWED_USERS'/a\        'TRUECONF_ALLOWED_USERS'," "$RUN_PY"
    log_ok "TRUECONF_ALLOWED_USERS added"
    PATCHED=$((PATCHED + 1))
fi

# _allow_all
if grep -q 'TRUECONF_ALLOW_ALL_USERS' "$RUN_PY" 2>/dev/null; then
    log_skip "TRUECONF_ALLOW_ALL_USERS in _allow_all"
else
    log_patch "Adding TRUECONF_ALLOW_ALL_USERS to _allow_all..."
    sed -i "/'QQ_ALLOW_ALL_USERS'/a\        'TRUECONF_ALLOW_ALL_USERS'," "$RUN_PY"
    log_ok "TRUECONF_ALLOW_ALL_USERS added"
    PATCHED=$((PATCHED + 1))
fi

# platform_allow_all_map
if grep -q "Platform.TRUECONF:.*TRUECONF_ALLOW_ALL_USERS" "$RUN_PY" 2>/dev/null; then
    log_skip "Platform.TRUECONF in platform_allow_all_map"
else
    log_patch "Adding TrueConf to platform_allow_all_map..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = 'Platform.QQBOT: "QQ_ALLOW_ALL_USERS",'
replacement = marker + '\n        Platform.TRUECONF: "TRUECONF_ALLOW_ALL_USERS",'
content = content.replace(marker, replacement, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "TrueConf added to platform_allow_all_map"
    PATCHED=$((PATCHED + 1))
fi

# platform_env_map (x2)
if grep -q "Platform.TRUECONF:.*TRUECONF_ALLOWED_USERS" "$RUN_PY" 2>/dev/null; then
    log_skip "Platform.TRUECONF in platform_env_map"
else
    log_patch "Adding TrueConf to platform_env_map..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# First occurrence (in _is_user_authorized)
marker1 = 'Platform.QQBOT: "QQ_ALLOWED_USERS",'
replacement1 = marker1 + '\n        Platform.TRUECONF: "TRUECONF_ALLOWED_USERS",'
content = content.replace(marker1, replacement1, 1)

# Second occurrence (in _handle_unauthorized)
marker2 = 'Platform.QQBOT: "QQ_ALLOWED_USERS",'
replacement2 = marker2 + '\n        Platform.TRUECONF: "TRUECONF_ALLOWED_USERS",'
content = content.replace(marker2, replacement2, 1)

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "TrueConf added to platform_env_map"
    PATCHED=$((PATCHED + 1))
fi

# ───────────────────────────────────────────
# 4. tools/send_message_tool.py — Message Sending
# ───────────────────────────────────────────
SEND_PY="${HERMES_DIR}/tools/send_message_tool.py"

if [ ! -f "$SEND_PY" ]; then
    echo "✗ tools/send_message_tool.py not found"
    exit 1
fi

# 4a. platform_map
if grep -q '"trueconf": Platform.TRUECONF' "$SEND_PY" 2>/dev/null; then
    log_skip "TrueConf in platform_map"
else
    log_patch "Adding TrueConf to platform_map..."
    sed -i '/"qqbot": Platform.QQBOT,/a\    "trueconf": Platform.TRUECONF,' "$SEND_PY"
    log_ok "TrueConf added to platform_map"
    PATCHED=$((PATCHED + 1))
fi

# 4b. _send_trueconf Function
if grep -q 'async def _send_trueconf' "$SEND_PY" 2>/dev/null; then
    log_skip "_send_trueconf function"
else
    log_patch "Adding _send_trueconf function..."
    python3 - "$SEND_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert before "# --- Registry ---" or "# --- Non-media platforms ---"
marker = '# --- Registry ---'
if marker not in content:
    marker = '# --- Non-media platforms ---'

func = '''
async def _send_trueconf(extra, chat_id, message, media_files=None):
    """Send via TrueConf — reuses running adapter when available."""
    import os, logging
    _logger = logging.getLogger(__name__)
    try:
        from gateway.platforms.trueconf import get_active_adapter, TrueConfAdapter, check_trueconf_requirements
    except ImportError:
        return {"error": "TrueConf adapter not available."}

    # Reuse the running gateway adapter (fast path — no new connection)
    adapter = get_active_adapter()
    if adapter is None:
        return {"error": "TrueConf adapter is not running. Start the gateway with trueconf platform enabled."}

    try:
        # Send text
        if message and message.strip():
            result = await adapter.send(chat_id, message)
            if not result.success:
                return {"error": f"TrueConf send failed: {result.error}"}

        # Send media files
        if media_files:
            for media_item in media_files:
                try:
                    if isinstance(media_item, tuple):
                        media_path = media_item[0]
                    else:
                        media_path = media_item
                    ext = os.path.splitext(media_path)[1].lower()
                    _IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
                    if ext in _IMAGE_EXTS:
                        await adapter.send_image_file(chat_id, media_path)
                    else:
                        await adapter.send_document(chat_id, media_path)
                except Exception as e:
                    _logger.error("[TrueConf] Failed to send media %s: %s", media_path, e)
                    return {"error": f"TrueConf media send failed: {e}"}

        return {"success": True, "platform": "trueconf", "chat_id": chat_id}
    except Exception as e:
        return {"error": f"TrueConf send failed: {e}"}

'''
content = content.replace(marker, func + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "_send_trueconf function added"
    PATCHED=$((PATCHED + 1))
fi

# 4c. TrueConf media handler in _send_to_platform
if grep -q "platform == Platform.TRUECONF" "$SEND_PY" 2>/dev/null && grep -q "_send_trueconf(pconfig" "$SEND_PY" 2>/dev/null; then
    log_skip "TrueConf media handler in _send_to_platform"
else
    log_patch "Adding TrueConf media handler to _send_to_platform..."
    python3 - "$SEND_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1. Add TrueConf handler before "# --- Non-media platforms ---"
old_marker = "    # --- Non-media platforms ---"
trueconf_block = """\
    elif platform == Platform.TRUECONF:
        return await _send_trueconf(pconfig.extra, chat_id, message or "", media_files=media_files)
"""
if old_marker in content:
    # Only add if not already present in _send_to_platform section
    parts = content.split(old_marker)
    if len(parts) >= 2 and "platform == Platform.TRUECONF" not in parts[0].rsplit("def _send_to_platform", 1)[-1]:
        content = parts[0] + trueconf_block + old_marker + parts[1]

# 2. Update error message to include trueconf
old_error = '"send_message MEDIA delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao and feishu; "'
new_error = '"send_message MEDIA delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao, feishu and trueconf; "'
content = content.replace(old_error, new_error)

# 3. Update warning message to include trueconf
old_warning = '"native send_message media delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao and feishu"'
new_warning = '"native send_message media delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao, feishu and trueconf"'
content = content.replace(old_warning, new_warning)

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    if [ $? -eq 0 ]; then
        log_ok "TrueConf media handler added"
        PATCHED=$((PATCHED + 1))
    else
        echo "  ⚠️ Warning: Failed to add TrueConf media handler"
    fi
fi

# 4d. _PLATFORM_CONNECTED_CHECKERS — TrueConf entry
if grep -q '_PLATFORM_CONNECTED_CHECKERS' "$CONFIG_PY" 2>/dev/null && grep -q 'Platform.TRUECONF' "$CONFIG_PY" 2>/dev/null && grep -A1 '_PLATFORM_CONNECTED_CHECKERS' "$CONFIG_PY" | grep -q 'TRUECONF'; then
    log_skip "_PLATFORM_CONNECTED_CHECKERS TrueConf entry"
else
    # Check if _PLATFORM_CONNECTED_CHECKERS exists in config.py
    if grep -q '_PLATFORM_CONNECTED_CHECKERS' "$CONFIG_PY" 2>/dev/null; then
        log_patch "Adding TrueConf to _PLATFORM_CONNECTED_CHECKERS..."
        python3 - "$CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the dictionary and add TrueConf entry
# Pattern: look for the closing } of _PLATFORM_CONNECTED_CHECKERS and insert before it
import re
# Find last entry before closing brace in _PLATFORM_CONNECTED_CHECKERS
pattern = r'(_PLATFORM_CONNECTED_CHECKERS\s*=\s*\{[^}]*)(Platform\.\w+:\s*lambda[^,}]+,?\s*\n)'
matches = list(re.finditer(pattern, content, re.DOTALL))
if matches:
    last_match = matches[-1]
    insert_pos = last_match.end()
    trueconf_entry = '    Platform.TRUECONF: lambda cfg: bool(cfg.extra.get("server") and (cfg.token or (cfg.extra.get("username") and cfg.extra.get("password")))),\n'
    content = content[:insert_pos] + trueconf_entry + content[insert_pos:]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP: Could not find _PLATFORM_CONNECTED_CHECKERS dictionary")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "_PLATFORM_CONNECTED_CHECKERS TrueConf entry added"
            PATCHED=$((PATCHED + 1))
        else
            echo "  ⚠️ Warning: Failed to add _PLATFORM_CONNECTED_CHECKERS entry"
        fi
    else
        log_skip "_PLATFORM_CONNECTED_CHECKERS not found in config.py (may not exist in this version)"
    fi
fi

# ───────────────────────────────────────────
# 4e. SEND_MESSAGE_SCHEMA — add trueconf to target description
# ───────────────────────────────────────────
if grep -q "trueconf" "$SEND_PY" 2>/dev/null && grep -q "SEND_MESSAGE_SCHEMA" "$SEND_PY" 2>/dev/null && grep -A30 "SEND_MESSAGE_SCHEMA" "$SEND_PY" | grep -q "trueconf.*chat_id\|trueconf:.*<"; then
    log_skip "TrueConf in SEND_MESSAGE_SCHEMA target description"
else
    log_patch "Adding TrueConf to SEND_MESSAGE_SCHEMA target description..."
    python3 - "$SEND_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if "trueconf:<chat_id>" in content:
    print("SKIP")
    sys.exit(0)

# Find the target description string in SEND_MESSAGE_SCHEMA and add trueconf
# Look for the description ending with a platform example like 'yuanbao:...' and add trueconf before the closing quote
pattern = r"((?:yuanbao|matrix|signal|slack|discord|telegram)[^\"']*(?:group|chat|DM|channel)[^\"']*)[\"']"
m = re.search(pattern, content)
if m:
    insert_pos = m.end(1)
    content = content[:insert_pos] + ", 'trueconf:<chat_id>'" + content[insert_pos:]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP: could not find target description anchor")
PYEOF
    if [ $? -eq 0 ]; then
        log_ok "TrueConf added to SEND_MESSAGE_SCHEMA"
        PATCHED=$((PATCHED + 1))
    fi
fi

# 4f. Non-media error message — include trueconf
if grep -q "yuanbao, feishu and trueconf" "$SEND_PY" 2>/dev/null || grep -q "yuanbao, feishu, trueconf" "$SEND_PY" 2>/dev/null; then
    log_skip "Non-media error messages include trueconf"
else
    log_patch "Updating error/warning messages to include trueconf..."
    python3 - "$SEND_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Add trueconf to any "supported for X, Y and Z" or "X, Y; " patterns in error messages
import re
# Pattern: "... yuanbao, feishu ..." or "... yuanbao and feishu ..."
added = False
for pat, repl in [
    ('"native send_message media delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao and feishu"',
     '"native send_message media delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao, feishu and trueconf"'),
    ('"send_message MEDIA delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao and feishu; "',
     '"send_message MEDIA delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao, feishu and trueconf; "'),
    ('"send_message MEDIA delivery is currently only supported for telegram, discord, matrix, weixin, signal and yuanbao; "',
     '"send_message MEDIA delivery is currently only supported for telegram, discord, matrix, weixin, signal, yuanbao and trueconf; "'),
]:
    if pat in content:
        content = content.replace(pat, repl)
        added = True
if added:
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP")
PYEOF
    if [ $? -eq 0 ]; then
        log_ok "Error messages updated"
        PATCHED=$((PATCHED + 1))
    fi
fi

# ───────────────────────────────────────────
# 5. Copy Adapter to gateway/platforms/
# ───────────────────────────────────────────
ADAPTER_SRC="${ADAPTER_DIR}/gateway/platforms/trueconf.py"
ADAPTER_DST="${HERMES_DIR}/gateway/platforms/trueconf.py"

if [ -f "$ADAPTER_SRC" ]; then
    if [ -f "$ADAPTER_DST" ] && diff -q "$ADAPTER_SRC" "$ADAPTER_DST" >/dev/null 2>&1; then
        log_skip "TrueConf adapter (already up to date)"
    else
        log_patch "Copying TrueConf adapter..."
        cp "$ADAPTER_SRC" "$ADAPTER_DST"
        log_ok "TrueConf adapter copied"
        PATCHED=$((PATCHED + 1))
    fi
else
    echo "  ⚠️ Warning: adapter source not found: $ADAPTER_SRC"
fi

# ───────────────────────────────────────────
# 6. Patch installed library — None-guard only (non-destructive)
# ───────────────────────────────────────────
BOT_PY="${SITE_PACKAGES}/trueconf/client/bot.py"

if [ -f "$BOT_PY" ]; then
    if grep -q "current_version is None" "$BOT_PY" 2>/dev/null; then
        log_skip "bot.py None-guard (already present)"
    else
        log_patch "Adding None-guard to check_version..."
        python3 - "$BOT_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'current_version is None' in content:
    sys.exit(0)

old = '    current_version = await self.server_version\n'
guard = '    current_version = await self.server_version\n        if current_version is None:\n            loggers.chatbot.warning("\u26a0\ufe0f Could not determine server version, skipping version check")\n            return\n    '

if old not in content:
    print("FAIL: marker not found")
    sys.exit(1)

content = content.replace(old, guard, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "bot.py None-guard added"
            PATCHED=$((PATCHED + 1))
        else
            echo "  ⚠️ Warning: Failed to add None-guard (non-critical)"
        fi
    fi
else
    log_skip "bot.py not found: $BOT_PY"
fi

# ───────────────────────────────────────────
# 7. config.yaml — platform_toolsets for TrueConf
# ───────────────────────────────────────────
CONFIG_YAML="${HOME}/.hermes/config.yaml"

if [ -f "$CONFIG_YAML" ]; then
    if grep -q '^  trueconf:' "$CONFIG_YAML" 2>/dev/null; then
        log_skip "platform_toolsets for TrueConf in config.yaml"
    else
        log_patch "Adding TrueConf toolsets to config.yaml..."
        python3 - "$CONFIG_YAML" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if '\n  trueconf:' in content or content.endswith('trueconf:'):
    sys.exit(0)

trueconf_section = '''  trueconf:
  - browser
  - clarify
  - code_execution
  - cronjob
  - delegation
  - file
  - image_gen
  - memory
  - messaging
  - session_search
  - skills
  - terminal
  - todo
  - tts
  - vision
  - web
'''

# Strategy 1: Find existing platform sections (two-space indented word: followed by
# two-space indented dash + hermes-) and insert after the last match.
# Pattern: lines like "  <platform>:" followed by "  - hermes-..."
pattern = r'(^ {2}\w+:\n(?: {2}- hermes-.*\n)+)'
matches = list(re.finditer(pattern, content, re.MULTILINE))
if matches:
    last = matches[-1]
    insert_pos = last.end()
    content = content[:insert_pos] + '\n' + trueconf_section + content[insert_pos:]
else:
    # Strategy 2: append to end of file
    if not content.endswith('\n'):
        content += '\n'
    content += trueconf_section

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "TrueConf toolsets added to config.yaml"
        PATCHED=$((PATCHED + 1))
    fi
else
    echo "  ⚠️ Warning: config.yaml not found, skipping"
fi

# ───────────────────────────────────────────
# 8. gateway/run.py — Home channel notice fix
# ───────────────────────────────────────────
RUN_PY="${HERMES_DIR}/gateway/run.py"

if [ -f "$RUN_PY" ]; then
    if grep -q "get_home_channel.*source.platform" "$RUN_PY" 2>/dev/null; then
        log_skip "Home channel notice checks config"
    else
        log_patch "Patching home channel notice to check config..."
        python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# The notice fires when os.getenv(env_key) is empty.
# Patch: also check config.get_home_channel() so env-loaded + config-based
# home channels both suppress the notice.
old = '            if not os.getenv(env_key):'
new = '''            # TrueConf patch: also check gateway config for home channel
            _home_from_config = False
            try:
                from gateway.config import load_gateway_config
                _cfg = load_gateway_config()
                _hc = _cfg.get_home_channel(source.platform)
                if _hc:
                    _home_from_config = True
            except Exception:
                pass
            if not os.getenv(env_key) and not _home_from_config:'''
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "Home channel notice patched"
            PATCHED=$((PATCHED + 1))
        fi
    fi
fi

# ───────────────────────────────────────────
# Done
# ───────────────────────────────────────────
echo ""
if [ $PATCHED -gt 0 ]; then
    echo "✅ Patches applied: $PATCHED"
else
    echo "✅ All patches already applied"
fi
echo ""
