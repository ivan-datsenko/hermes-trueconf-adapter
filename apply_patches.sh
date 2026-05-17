#!/bin/bash
# ============================================
# TrueConf Adapter — Auto-Patch Script v2.0
# ============================================
# Applies all necessary patches to hermes-agent core files.
# Safe to run multiple times (idempotent).
#
# Usage: bash apply_patches.sh [HERMES_DIR]
# ============================================

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
        PYTHON_VER="python3.12"  # fallback
    fi
else
    PYTHON_VER="python3.12"  # fallback
fi
SITE_PACKAGES="${VENV_DIR}/lib/${PYTHON_VER}/site-packages"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TrueConf Adapter — Apply Patches v2.0"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Hermes: $HERMES_DIR"
echo "  Python: $PYTHON_VER"
echo ""

# ───────────────────────────────────────────
# 1. gateway/config.py — Platform enum
# ───────────────────────────────────────────
CONFIG_PY="${HERMES_DIR}/gateway/config.py"

if [ ! -f "$CONFIG_PY" ]; then
    echo "✗ gateway/config.py not found: $CONFIG_PY"
    exit 1
fi

# 1a. Platform.TRUECONF in enum
if grep -q 'TRUECONF = "trueconf"' "$CONFIG_PY" 2>/dev/null; then
    log_skip "Platform.TRUECONF enum"
else
    log_patch "Adding Platform.TRUECONF to enum..."
    sed -i '/QQBOT = "qqbot"/a\    TRUECONF = "trueconf"' "$CONFIG_PY"
    log_ok "Platform.TRUECONF enum added"
    PATCHED=$((PATCHED + 1))
fi

# 1b. Auto-detect block
if grep -q 'trueconf_server = os.getenv' "$CONFIG_PY" 2>/dev/null; then
    log_skip "auto-detect block in config.py"
else
    log_patch "Adding auto-detect block..."
    python3 - "$CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = 'trueconf_server = os.getenv("TRUECONF_SERVER"'
if marker in content:
    sys.exit(0)

# Find insertion point: after DingTalk home_channel block or before Feishu
insert_after = '    # Feishu / Lark'
if insert_after not in content:
    insert_after = '    feishu_app_id = os.getenv("FEISHU_APP_ID")'

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
        trueconf_ssl = os.getenv("TRUECONF_USE_SSL", "").strip().lower()
        if trueconf_ssl:
            config.platforms[Platform.TRUECONF].extra["use_ssl"] = trueconf_ssl in ("true", "1", "yes")
        trueconf_verify = os.getenv("TRUECONF_VERIFY_SSL", "").strip().lower()
        if trueconf_verify:
            config.platforms[Platform.TRUECONF].extra["verify_ssl"] = trueconf_verify in ("true", "1", "yes")
        trueconf_home = os.getenv("TRUECONF_HOME_CHANNEL")
        if trueconf_home:
            config.platforms[Platform.TRUECONF].home_channel = HomeChannel(
                platform=Platform.TRUECONF,
                chat_id=trueconf_home,
                name=os.getenv("TRUECONF_HOME_CHANNEL_NAME", "Home"),
            )

'''

content = content.replace(insert_after, patch + insert_after, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "auto-detect block added"
    PATCHED=$((PATCHED + 1))
fi

# 1c. get_connected_platforms — TrueConf check
if grep -q 'Platform.QQBOT and config.extra.get("app_id")' "$CONFIG_PY" 2>/dev/null; then
    if grep -q 'Platform.TRUECONF and config.extra' "$CONFIG_PY" 2>/dev/null; then
        log_skip "get_connected_platforms TrueConf check"
    else
        log_patch "Adding TrueConf to get_connected_platforms..."
        python3 - "$CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'Platform.TRUECONF and config.extra' in content:
    sys.exit(0)

marker = '            elif platform == Platform.QQBOT and config.extra.get("app_id") and config.extra.get("client_secret"):\n                connected.append(platform)'
replacement = marker + '''
            # TrueConf uses extra dict for server + credentials
            elif platform == Platform.TRUECONF and config.extra.get("server") and (
                config.token or config.extra.get("token")
                or (config.extra.get("username") and config.extra.get("password"))
            ):
                connected.append(platform)'''

content = content.replace(marker, replacement, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "get_connected_platforms TrueConf check added"
        PATCHED=$((PATCHED + 1))
    fi
fi

# ───────────────────────────────────────────
# 2. hermes_cli/platforms.py — PLATFORMS dict
# ───────────────────────────────────────────
PLATFORMS_PY="${HERMES_DIR}/hermes_cli/platforms.py"

if [ ! -f "$PLATFORMS_PY" ]; then
    echo "✗ hermes_cli/platforms.py not found"
    exit 1
fi

if grep -q '"trueconf"' "$PLATFORMS_PY" 2>/dev/null; then
    log_skip "TrueConf in PLATFORMS dict"
else
    log_patch "Adding TrueConf to PLATFORMS dict..."
    python3 - "$PLATFORMS_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if '"trueconf"' in content:
    sys.exit(0)

# Insert before the closing ]) of PLATFORMS OrderedDict
# Find the last entry before ])
marker = '    ("api_server",     PlatformInfo(label="🌐 API Server",      default_toolset="hermes-api-server")),'
replacement = marker + '''
    ("trueconf",       PlatformInfo(label="📹 TrueConf",        default_toolset="hermes-trueconf")),'''

content = content.replace(marker, replacement, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "TrueConf in PLATFORMS dict added"
    PATCHED=$((PATCHED + 1))
fi

# ───────────────────────────────────────────
# 2b. hermes_cli/gateway.py — _PLATFORMS dict (hermes setup menu)
# ───────────────────────────────────────────
GATEWAY_PY="${HERMES_DIR}/hermes_cli/gateway.py"

if [ -f "$GATEWAY_PY" ]; then
    GATEWAY_PATCHED=0

    # 2b-i: Add TrueConf entry to _PLATFORMS list
    if grep -q '"key": "trueconf"' "$GATEWAY_PY" 2>/dev/null; then
        log_skip "TrueConf in _PLATFORMS"
    else
log_patch "Adding TrueConf to _PLATFORMS in gateway.py..."
        python3 - "$GATEWAY_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if '"key": "trueconf"' in content:
    sys.exit(0)

# Find the yuanbao entry and insert after it
# yuanbao is the LAST entry before the closing ]
# Pattern: find "key": "yuanbao" then find its closing "},\n" and insert after that
yuanbao_marker = '"key": "yuanbao"'
idx = content.find(yuanbao_marker)
if idx == -1:
    print("SKIP: yuanbao not found")
    sys.exit(0)

# Find the closing of yuanbao entry: look for the pattern "...YUANBAO...    },\n"
# right before the final "]\n" that closes _PLATFORMS
# The yuanbao entry ends with:
#         ],  <-- vars array close
#     },  <-- dict close
# ]   <-- list close
# So we need to find the "},\n" that is immediately followed by "]\n"

# Strategy: find the final "\n]\ndef" in the file (end of _PLATFORMS)
# and find the "},\n" right before it (that's yuanbao's dict close)
import re
# Find the end of _PLATFORMS list (starts with "def _all_platforms")
all_platforms_start = content.find("def _all_platforms")
if all_platforms_start == -1:
    print("SKIP: _all_platforms not found")
    sys.exit(0)

# The list content is everything between "_PLATFORMS = [" and "def _all_platforms"
list_start = content.find("_PLATFORMS = [")
list_end = all_platforms_start
list_content = content[list_start:list_end]

# Find the last "},\n" in the list (that's yuanbao's close)
last_brace_idx = list_content.rfind("},\n")
if last_brace_idx == -1:
    print("SKIP: closing } not found")
    sys.exit(0)

# Calculate absolute position in file
abs_pos = list_start + last_brace_idx + 2  # +2 for "},\n"
trueconf_entry = '''
    {
        "key": "trueconf",
        "label": "TrueConf",
        "emoji": "📹",
        "token_var": "",
        "vars": [
            {"name": "TRUECONF_SERVER", "prompt": "TrueConf Server (e.g. video.example.net or IP)", "password": False,
             "help": "Enter your TrueConf Server hostname or IP address."},
            {"name": "TRUECONF_USERNAME", "prompt": "Bot username", "password": False,
             "help": "Username of the bot account on this server."},
            {"name": "TRUECONF_PASSWORD", "prompt": "Bot password", "password": True,
             "help": "Password for the bot account."},
            {"name": "TRUECONF_HOME_CHANNEL", "prompt": "Home channel (user ID, or empty to set later with /sethome)", "password": False,
             "help": "User ID for DM delivery, or empty to set via /sethome command."},
        ],
    },'''

content = content[:abs_pos] + trueconf_entry + content[abs_pos:]
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "TrueConf in _PLATFORMS added"
            GATEWAY_PATCHED=$((GATEWAY_PATCHED + 1))
        fi
    fi

    # 2b-ii: Add _setup_trueconf function
    if grep -q 'def _setup_trueconf' "$GATEWAY_PY" 2>/dev/null; then
        log_skip "_setup_trueconf function"
    else
        log_patch "Adding _setup_trueconf function..."
        python3 - "$GATEWAY_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'def _setup_trueconf' in content:
    sys.exit(0)

# Insert after _setup_yuanbao
marker = 'def _setup_yuanbao():'
if marker not in content:
    marker = 'def _builtin_setup_fn'

func = '''

def _setup_trueconf():
    """Interactive setup for TrueConf with SSL and access control questions."""
    from hermes_cli.gateway import _all_platforms, _setup_standard_platform
    from hermes_cli.setup_wizard import _read_line_bool
    platforms = _all_platforms()
    trueconf_platform = next((p for p in platforms if p["key"] == "trueconf"), None)
    if not trueconf_platform:
        print("  TrueConf platform not found in _PLATFORMS")
        return

    # Use standard setup for basic config (server, username, password)
    _setup_standard_platform(trueconf_platform)

    # Additional TrueConf-specific questions
    try:
        # SSL verification
        verify_ssl = _read_line_bool("  Verify SSL certificate", default=False)
        # Allow all users
        allow_all = _read_line_bool("  Allow all users", default=True)

        # Save to config extra
        import yaml
        from pathlib import Path
        config_path = Path.home() / ".hermes" / "config.yaml"
        if config_path.exists():
            config = yaml.safe_load(config_path.read_text()) or {}
            if "platforms" not in config:
                config["platforms"] = {}
            if "trueconf" not in config["platforms"]:
                config["platforms"]["trueconf"] = {}
            if "extra" not in config["platforms"]["trueconf"]:
                config["platforms"]["trueconf"]["extra"] = {}
            config["platforms"]["trueconf"]["extra"]["verify_ssl"] = verify_ssl
            config["platforms"]["trueconf"]["extra"]["allow_all_users"] = allow_all
            config_path.write_text(yaml.dump(config, default_flow_style=False, allow_unicode=True))
            print(f"  ✓ TrueConf configured: ssl_verify={verify_ssl}, allow_all={allow_all}")
    except Exception as e:
        print(f"  ⚠ Could not save extra config: {e}")
'''

content = content.replace(marker, func + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "_setup_trueconf function added"
        GATEWAY_PATCHED=$((GATEWAY_PATCHED + 1))
    fi

    # 2b-iii: Add trueconf to _builtin_setup_fn dict
    if grep -q '"qqbot": _setup_qqbot,' "$GATEWAY_PY" 2>/dev/null; then
        if grep -q '"trueconf": _setup_trueconf,' "$GATEWAY_PY" 2>/dev/null; then
            log_skip "TrueConf in _builtin_setup_fn"
        else
            log_patch "Adding TrueConf to _builtin_setup_fn..."
            sed -i 's/"qqbot": _setup_qqbot,/"qqbot": _setup_qqbot,\n        "trueconf": _setup_trueconf,/' "$GATEWAY_PY"
            log_ok "TrueConf in _builtin_setup_fn added"
            GATEWAY_PATCHED=$((GATEWAY_PATCHED + 1))
        fi
    fi

    PATCHED=$((PATCHED + GATEWAY_PATCHED))
fi

# ───────────────────────────────────────────
# 3. gateway/run.py — TrueConfAdapter creation + auth maps
# ───────────────────────────────────────────
RUN_PY="${HERMES_DIR}/gateway/run.py"

if [ ! -f "$RUN_PY" ]; then
    echo "✗ gateway/run.py not found"
    exit 1
fi

# 3a. TrueConfAdapter creation block
# IMPORTANT: check for TrueConfAdapter specifically, NOT just Platform.TRUECONF
# (auth maps in 3b also contain Platform.TRUECONF and would give false positive)
if grep -q 'TrueConfAdapter' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConfAdapter in run.py"
else
    log_patch "Adding TrueConfAdapter creation..."
    python3 "${ADAPTER_DIR}/patch_run.py" "$RUN_PY"
    if [ $? -eq 0 ]; then
        log_ok "TrueConfAdapter creation added"
        PATCHED=$((PATCHED + 1))
    else
        log_patch "TrueConfAdapter creation failed — check errors above"
    fi
fi

# 3b. run.py — Authorization maps
AUTH_PATCHED=0

# Check _allow_all list
if grep -q '"TRUECONF_ALLOW_ALL_USERS"' "$RUN_PY" 2>/dev/null; then
    log_skip "TRUECONF_ALLOW_ALL_USERS in _allow_all list"
else
    log_patch "Adding TRUECONF_ALLOW_ALL_USERS to _allow_all list..."
    sed -i '/"QQ_ALLOW_ALL_USERS")/{s/)$/                       "TRUECONF_ALLOW_ALL_USERS")/}' "$RUN_PY"
    log_ok "TRUECONF_ALLOW_ALL_USERS added to _allow_all"
    AUTH_PATCHED=$((AUTH_PATCHED + 1))
fi

# Check _any_allowlist
if grep -q '"TRUECONF_ALLOWED_USERS"' "$RUN_PY" 2>/dev/null; then
    log_skip "TRUECONF_ALLOWED_USERS in _any_allowlist"
else
    log_patch "Adding TRUECONF_ALLOWED_USERS to _any_allowlist..."
    sed -i '/"GATEWAY_ALLOWED_USERS")/{s/.*GATEWAY_ALLOWED_USERS.*/                       "QQ_ALLOWED_USERS",\n                       "TRUECONF_ALLOWED_USERS",\n                       "GATEWAY_ALLOWED_USERS")/;}' "$RUN_PY"
    log_ok "TRUECONF_ALLOWED_USERS added to _any_allowlist"
    AUTH_PATCHED=$((AUTH_PATCHED + 1))
fi

# Check platform_allow_all_map (first occurrence)
if grep -q 'Platform.TRUECONF.*TRUECONF_ALLOW_ALL_USERS' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConf in platform_allow_all_map"
else
    log_patch "Adding TrueConf to platform_allow_all_map..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

in_allow_all_map = False
allow_all_count = 0
inserted = False
for i, line in enumerate(lines):
    if 'platform_allow_all_map' in line:
        allow_all_count += 1
        if allow_all_count == 1:
            in_allow_all_map = True
    if in_allow_all_map and 'QQ_ALLOW_ALL_USERS' in line and not inserted:
        indent = line[:len(line) - len(line.lstrip())]
        lines.insert(i + 1, indent + 'Platform.TRUECONF: "TRUECONF_ALLOW_ALL_USERS",\n')
        inserted = True
        break
    if in_allow_all_map and line.strip() == '}':
        in_allow_all_map = False

if inserted:
    with open(path, 'w') as f:
        f.writelines(lines)
    print("OK")
else:
    print("SKIP")
PYEOF
    log_ok "TrueConf added to platform_allow_all_map"
    AUTH_PATCHED=$((AUTH_PATCHED + 1))
fi

# Check platform_env_map (first occurrence)
if grep -q 'Platform.TRUECONF.*TRUECONF_ALLOWED_USERS' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConf in platform_env_map"
else
    log_patch "Adding TrueConf to platform_env_map..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

in_env_map = False
env_map_count = 0
inserted = False
for i, line in enumerate(lines):
    if 'platform_env_map' in line and 'group' not in line:
        env_map_count += 1
        if env_map_count == 1:
            in_env_map = True
    if in_env_map and 'QQ_ALLOWED_USERS' in line and 'group' not in line and not inserted:
        indent = line[:len(line) - len(line.lstrip())]
        lines.insert(i + 1, indent + 'Platform.TRUECONF: "TRUECONF_ALLOWED_USERS",\n')
        inserted = True
        break
    if in_env_map and line.strip() == '}':
        in_env_map = False

if inserted:
    with open(path, 'w') as f:
        f.writelines(lines)
    print("OK")
else:
    print("SKIP")
PYEOF
    log_ok "TrueConf added to platform_env_map"
    AUTH_PATCHED=$((AUTH_PATCHED + 1))
fi

# Check second platform_env_map (in _handle_unauthorized)
SECOND_ENV=$(grep -c 'platform_env_map' "$RUN_PY")
if [ "$SECOND_ENV" -ge 2 ]; then
    RESULT=$(python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

env_map_count = 0
in_second = False
for i, line in enumerate(lines):
    if 'platform_env_map' in line and 'group' not in line:
        env_map_count += 1
        if env_map_count == 2:
            in_second = True
    if in_second and 'QQ_ALLOWED_USERS' in line:
        block_end = i + 5
        block = ''.join(lines[i:min(block_end, len(lines))])
        if 'TRUECONF' not in block:
            print("NEEDS_PATCH")
        else:
            print("OK")
        break
PYEOF
    )
    if [ "$RESULT" = "NEEDS_PATCH" ]; then
        log_patch "Adding TrueConf to second platform_env_map..."
        python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

env_map_count = 0
in_second = False
for i, line in enumerate(lines):
    if 'platform_env_map' in line and 'group' not in line:
        env_map_count += 1
        if env_map_count == 2:
            in_second = True
    if in_second and 'QQ_ALLOWED_USERS' in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines.insert(i + 1, indent + 'Platform.TRUECONF:  "TRUECONF_ALLOWED_USERS",\n')
        break

with open(path, 'w') as f:
    f.writelines(lines)
print("OK")
PYEOF
        log_ok "TrueConf added to second platform_env_map"
        AUTH_PATCHED=$((AUTH_PATCHED + 1))
    else
        log_skip "TrueConf in second platform_env_map"
    fi
fi

PATCHED=$((PATCHED + AUTH_PATCHED))

# ───────────────────────────────────────────
# 3c. tools/send_message_tool.py — TrueConf sending
# ───────────────────────────────────────────
SEND_PY="${HERMES_DIR}/tools/send_message_tool.py"

if [ -f "$SEND_PY" ]; then
    SEND_PATCHED=0

    # platform_map
    if grep -q '"trueconf"' "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf in send_message platform_map"
    else
        log_patch "Adding TrueConf to send_message platform_map..."
        sed -i '/"sms": Platform.SMS,/a\        "trueconf": Platform.TRUECONF,' "$SEND_PY"
        log_ok "TrueConf added to platform_map"
        SEND_PATCHED=$((SEND_PATCHED + 1))
    fi

    # _send_trueconf function
    if grep -q '_send_trueconf' "$SEND_PY" 2>/dev/null; then
        log_skip "_send_trueconf function"
    else
        log_patch "Adding _send_trueconf function..."
        python3 - "$SEND_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if '_send_trueconf' in content:
    sys.exit(0)

marker = '# --- Registry ---'
func = '''

async def _send_trueconf(extra, chat_id, message, media_files=None):
    """Send via TrueConf using the adapter's WebSocket send pipeline."""
    try:
        from gateway.platforms.trueconf import TrueConfAdapter, check_trueconf_requirements
        if not check_trueconf_requirements():
            return {"error": "TrueConf requirements not met. Need python-trueconf-bot."}
    except ImportError:
        return {"error": "TrueConf adapter not available."}

    try:
        from gateway.config import PlatformConfig
        pconfig = PlatformConfig(extra=extra)
        adapter = TrueConfAdapter(pconfig)
        connected = await adapter.connect()
        if not connected:
            return _error(f"TrueConf: failed to connect - {adapter.fatal_error_message or 'unknown error'}")
        try:
            result = await adapter.send(chat_id, message)
            if not result.success:
                return _error(f"TrueConf send failed: {result.error}")

            # Send media files if any
            if media_files:
                for media_item in media_files:
                    try:
                        import os
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
                        logger.error("[TrueConf] Failed to send media %s: %s", media_path, e)

            return {"success": True, "platform": "trueconf", "chat_id": chat_id, "message_id": result.message_id}
        finally:
            await adapter.disconnect()
    except Exception as e:
        return _error(f"TrueConf send failed: {e}")


'''

content = content.replace(marker, func + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "_send_trueconf function added"
        SEND_PATCHED=$((SEND_PATCHED + 1))
    fi

    # TrueConf in non-media routing
    if grep -q 'Platform.TRUECONF' "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf in send_message routing"
    else
        log_patch "Adding TrueConf to send_message routing..."
        sed -i '/Platform.QQBOT:.*_send_qqbot/a\        elif platform == Platform.TRUECONF:\n            return await _send_trueconf(pconfig.extra, chat_id, chunk, media_files=media_files)' "$SEND_PY"
        log_ok "TrueConf added to send_message routing"
        SEND_PATCHED=$((SEND_PATCHED + 1))
    fi

    # Note: TrueConf media handling is done by the elif block above (line 658)
    # which passes media_files to _send_trueconf. No separate block needed.

    PATCHED=$((PATCHED + SEND_PATCHED))
fi

# ───────────────────────────────────────────
# 4. Copy adapter to gateway/platforms/
# ───────────────────────────────────────────
ADAPTER_SRC="${ADAPTER_DIR}/gateway/platforms/trueconf.py"
ADAPTER_DST="${HERMES_DIR}/gateway/platforms/trueconf.py"

if [ -f "$ADAPTER_SRC" ]; then
    if diff -q "$ADAPTER_SRC" "$ADAPTER_DST" >/dev/null 2>&1; then
        log_skip "trueconf.py in gateway/platforms/"
    else
        log_patch "Copying trueconf.py to gateway/platforms/..."
        cp "$ADAPTER_SRC" "$ADAPTER_DST"
        log_ok "trueconf.py copied"
        PATCHED=$((PATCHED + 1))
    fi
fi

# ───────────────────────────────────────────
# 5. Patch python-trueconf-bot library
# ───────────────────────────────────────────
BOT_PY="${SITE_PACKAGES}/trueconf/client/bot.py"
PARSER_PY="${SITE_PACKAGES}/trueconf/types/parser.py"

if [ -f "$BOT_PY" ] && [ -f "${ADAPTER_DIR}/lib_patches/bot.py" ]; then
    if grep -q "download_file_by_id" "$BOT_PY" 2>/dev/null; then
        log_skip "bot.py lib patch"
    else
        log_patch "Patching bot.py (adding download_file_by_id)..."
        cp "${ADAPTER_DIR}/lib_patches/bot.py" "$BOT_PY"
        log_ok "bot.py patched"
        PATCHED=$((PATCHED + 1))
    fi
fi

if [ -f "$PARSER_PY" ] && [ -f "${ADAPTER_DIR}/lib_patches/parser.py" ]; then
    if diff -q "${ADAPTER_DIR}/lib_patches/parser.py" "$PARSER_PY" >/dev/null 2>&1; then
        log_skip "parser.py lib patch"
    else
        log_patch "Patching parser.py..."
        cp "${ADAPTER_DIR}/lib_patches/parser.py" "$PARSER_PY"
        log_ok "parser.py patched"
        PATCHED=$((PATCHED + 1))
    fi
fi

# ───────────────────────────────────────────
# 6. config.yaml — platform_toolsets for TrueConf
# ───────────────────────────────────────────
CONFIG_YAML="${HOME}/.hermes/config.yaml"

if [ -f "$CONFIG_YAML" ]; then
    if grep -q '^  trueconf:' "$CONFIG_YAML" 2>/dev/null; then
        log_skip "platform_toolsets for TrueConf in config.yaml"
    else
        log_patch "Adding TrueConf toolsets to config.yaml..."
        # Insert trueconf section after qqbot in platform_toolsets
        python3 - "$CONFIG_YAML" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if '\n  trueconf:' in content or content.endswith('trueconf:'):
    sys.exit(0)

# Find qqbot section and insert after it
marker = '  qqbot:\n  - hermes-qqbot'
if marker not in content:
    # Try finding the signal section instead
    marker = '  signal:\n  - hermes-signal'

if marker in content:
    trueconf_section = '''  qqbot:
  - hermes-qqbot
  trueconf:
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
  - web'''
    content = content.replace(marker, trueconf_section)
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    # Fallback: append at end of platform_toolsets section
    # Find the end of platform_toolsets by looking for the next top-level key
    lines = content.split('\n')
    in_toolsets = False
    insert_idx = None
    for i, line in enumerate(lines):
        if line.startswith('platform_toolsets:'):
            in_toolsets = True
        elif in_toolsets and line and not line.startswith(' ') and not line.startswith('#'):
            insert_idx = i
            break
    
    if insert_idx:
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
        lines.insert(insert_idx, trueconf_section.rstrip())
        with open(path, 'w') as f:
            f.write('\n'.join(lines))
        print("OK")
    else:
        print("SKIP")
PYEOF
        log_ok "TrueConf toolsets added to config.yaml"
        PATCHED=$((PATCHED + 1))
    fi
else
    echo "  ⚠ config.yaml not found — skipping toolsets config"
    echo "    After hermes setup, run: bash ${ADAPTER_DIR}/apply_patches.sh"
fi

# ───────────────────────────────────────────
# 7. tools/send_message_tool.py — add trueconf to media platforms
# ───────────────────────────────────────────
SEND_MSG_TOOL="${HERMES_DIR}/tools/send_message_tool.py"

if [ -f "$SEND_MSG_TOOL" ]; then
    SEND_MSG_PATCHED=0

    # 7a. Add trueconf to the error message list (line ~708)
    if grep -q 'telegram, discord, matrix, weixin, signal, yuanbao and feishu' "$SEND_MSG_TOOL" 2>/dev/null; then
        log_patch "Adding trueconf to send_message media platforms (error message)..."
        sed -i 's/telegram, discord, matrix, weixin, signal, yuanbao and feishu/telegram, discord, matrix, weixin, signal, yuanbao, feishu and trueconf/g' "$SEND_MSG_TOOL"
        log_ok "trueconf added to error message list"
        SEND_MSG_PATCHED=$((SEND_MSG_PATCHED + 1))
    else
        log_skip "trueconf in error message list"
    fi

    # 7b. Add trueconf to the warning message list (line ~716)
    if grep -q 'telegram, discord, matrix, weixin, signal, yuanbao and feishu' "$SEND_MSG_TOOL" 2>/dev/null; then
        log_patch "Adding trueconf to send_message media platforms (warning message)..."
        sed -i 's/telegram, discord, matrix, weixin, signal, yuanbao and feishu/telegram, discord, matrix, weixin, signal, yuanbao, feishu and trueconf/g' "$SEND_MSG_TOOL"
        log_ok "trueconf added to warning message list"
        SEND_MSG_PATCHED=$((SEND_MSG_PATCHED + 1))
    else
        log_skip "trueconf in warning message list"
    fi

    # 7c. Add trueconf to the platform mapping dict (for send_message target resolution)
    if grep -q '"trueconf": Platform.TRUECONF' "$SEND_MSG_TOOL" 2>/dev/null; then
        log_skip "trueconf in platform mapping dict"
    else
        log_patch "Adding trueconf to platform mapping dict..."
        python3 - "$SEND_MSG_TOOL" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if '"trueconf": Platform.TRUECONF' in content:
    sys.exit(0)

# Find the platform mapping dict and add trueconf
# Look for the pattern: "feishu": Platform.FEISHU,
marker = '"feishu": Platform.FEISHU,'
if marker in content:
    replacement = marker + '\n    "trueconf": Platform.TRUECONF,'
    content = content.replace(marker, replacement, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP: feishu marker not found")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "trueconf added to platform mapping dict"
            SEND_MSG_PATCHED=$((SEND_MSG_PATCHED + 1))
        fi
    fi

    PATCHED=$((PATCHED + SEND_MSG_PATCHED))
else
    echo "  ⚠ tools/send_message_tool.py not found — skipping"
fi

# ───────────────────────────────────────────
# 8. run.py — TrueConf media delivery without streaming
# ───────────────────────────────────────────
# TrueConf doesn't support streaming, so MEDIA: files in agent responses
# are never delivered. This patch adds TrueConf to the media delivery
# condition so _deliver_media_from_response is called for TrueConf
# even when already_sent is False.
RUN_PY="${HERMES_DIR}/gateway/run.py"

if [ -f "$RUN_PY" ]; then
    if grep -q 'source.platform == Platform.TRUECONF' "$RUN_PY" 2>/dev/null; then
        log_skip "TrueConf media delivery in run.py"
    else
        log_patch "Adding TrueConf media delivery to run.py..."
        python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the line: if agent_result.get("already_sent") and not agent_result.get("failed"):
# And add TrueConf condition
old = 'if agent_result.get("already_sent") and not agent_result.get("failed"):'
new = 'if (agent_result.get("already_sent") or source.platform == Platform.TRUECONF) and not agent_result.get("failed"):'

if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP: target line not found")
PYEOF
        if [ $? -eq 0 ]; then
            log_ok "TrueConf media delivery added to run.py"
            PATCHED=$((PATCHED + 1))
        fi
    fi
else
    echo "  ⚠ gateway/run.py not found — skipping"
fi

# ───────────────────────────────────────────
# Summary
# ───────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$PATCHED" -eq 0 ]; then
    echo "  ✓ All patches already applied"
else
    echo "  ✓ Applied $PATCHED patch(es)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
