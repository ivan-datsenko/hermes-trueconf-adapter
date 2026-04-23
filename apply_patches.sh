#!/bin/bash
# ============================================
# TrueConf Adapter — Auto-Patch Script
# ============================================
# Applies all necessary patches to hermes-agent core files.
# Safe to run multiple times (idempotent).
#
# Usage: bash apply_patches.sh [HERMES_DIR]
# ============================================

set -e

HERMES_DIR="${1:-${HERMES_DIR:-/root/.hermes/hermes-agent}}"
PATCHED=0
SKIPPED=0

log_ok()   { echo "  ✓ $1"; }
log_skip() { echo "  · $1 (already patched)"; }
log_patch(){ echo "  → $1"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TrueConf Adapter — Apply Patches"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
    # Find the last platform in the enum (before the empty line after QQBOT)
    sed -i '/QQBOT = "qqbot"/a\    TRUECONF = "trueconf"' "$CONFIG_PY"
    log_ok "Platform.TRUECONF enum added"
    PATCHED=$((PATCHED + 1))
fi

# 1b. Auto-detect block
if grep -q 'trueconf_server = os.getenv' "$CONFIG_PY" 2>/dev/null; then
    log_skip "auto-detect block in config.py"
else
    log_patch "Adding auto-detect block..."
    # Find the DingTalk home_channel block end and insert after it
    python3 - "$CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = 'trueconf_server = os.getenv("TRUECONF_SERVER"'
if marker in content:
    sys.exit(0)

# Find insertion point: after DingTalk block (last block before Feishu)
insert_after = '    # Feishu / Lark'
if insert_after not in content:
    # Fallback: find after the last HomeChannel block
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

# Insert after QQBOT check in get_connected_platforms
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
# 3. gateway/run.py — TrueConfAdapter creation
# ───────────────────────────────────────────
RUN_PY="${HERMES_DIR}/gateway/run.py"

if [ ! -f "$RUN_PY" ]; then
    echo "✗ gateway/run.py not found"
    exit 1
fi

if grep -q 'Platform.TRUECONF' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConfAdapter in run.py"
else
    log_patch "Adding TrueConfAdapter creation..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'Platform.TRUECONF' in content:
    sys.exit(0)

# Insert after QQAdapter block (the last adapter before return None)
marker = '            return QQAdapter(config)\n\n        return None'
replacement = '''            return QQAdapter(config)

        elif platform == Platform.TRUECONF:
            from gateway.platforms.trueconf import TrueConfAdapter, check_trueconf_requirements
            if not check_trueconf_requirements():
                logger.warning("TrueConf: python-trueconf-bot not installed. Run: pip install git+https://github.com/TrueConf/python-trueconf-bot")
                return None
            return TrueConfAdapter(config)

        return None'''

content = content.replace(marker, replacement, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
    log_ok "TrueConfAdapter creation added"
    PATCHED=$((PATCHED + 1))
fi

# 3b. run.py — Authorization maps (platform_allow_all_map, platform_env_map, _allow_all)
# These get wiped by upstream updates even when Platform.TRUECONF exists elsewhere
AUTH_PATCHED=0

# Check _allow_all list
if grep -q '"TRUECONF_ALLOW_ALL_USERS"' "$RUN_PY" 2>/dev/null; then
    log_skip "TRUECONF_ALLOW_ALL_USERS in _allow_all list"
else
    log_patch "Adding TRUECONF_ALLOW_ALL_USERS to _allow_all list..."
    sed -i '/"QQ_ALLOW_ALL_USERS")/{s/)$//; a\                       "TRUECONF_ALLOW_ALL_USERS")
}' "$RUN_PY"
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

# Check platform_allow_all_map (first occurrence in _is_user_authorized)
if grep -q 'Platform.TRUECONF.*TRUECONF_ALLOW_ALL_USERS' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConf in platform_allow_all_map"
else
    log_patch "Adding TrueConf to platform_allow_all_map..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

# Find the FIRST platform_allow_all_map block and add TRUECONF after QQBOT
in_allow_all_map = False
allow_all_count = 0
inserted = False
for i, line in enumerate(lines):
    if 'platform_allow_all_map' in line:
        allow_all_count += 1
        if allow_all_count == 1:
            in_allow_all_map = True
    if in_allow_all_map and 'QQ_ALLOW_ALL_USERS' in line and not inserted:
        # Add TRUECONF after QQBOT line
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

# Check platform_env_map (first occurrence in _is_user_authorized)
if grep -q 'Platform.TRUECONF.*TRUECONF_ALLOWED_USERS' "$RUN_PY" 2>/dev/null; then
    log_skip "TrueConf in platform_env_map"
else
    log_patch "Adding TrueConf to platform_env_map..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

# Find the FIRST platform_env_map block and add TRUECONF after QQBOT
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
    # Check if TRUECONF is in the second occurrence too
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
        # Check if TRUECONF already present in this block
        block_end = i + 5
        block = ''.join(lines[i:min(block_end, len(lines))])
        if 'TRUECONF' not in block:
            indent = line[:len(line) - len(line.lstrip())]
            lines.insert(i + 1, indent + 'Platform.TRUECONF:  "TRUECONF_ALLOWED_USERS",\n')
            with open(path, 'w') as f:
                f.writelines(lines)
            print("PATCHED")
        else:
            print("OK")
        break
PYEOF
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
# 3c. tools/send_message_tool.py — TrueConf sending support
# ───────────────────────────────────────────
SEND_PY="${HERMES_DIR}/tools/send_message_tool.py"

if [ -f "$SEND_PY" ]; then
    SEND_PATCHED=0

    # Check platform_map has trueconf
    if grep -q '"trueconf"' "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf in send_message platform_map"
    else
        log_patch "Adding TrueConf to send_message platform_map..."
        sed -i '/"sms": Platform.SMS,/a\        "trueconf": Platform.TRUECONF,' "$SEND_PY"
        log_ok "TrueConf added to platform_map"
        SEND_PATCHED=$((SEND_PATCHED + 1))
    fi

    # Check _send_trueconf function exists
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

# Insert before "# --- Registry ---"
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

    # Check TrueConf in non-media loop
    if grep -q 'Platform.TRUECONF' "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf in send_message routing"
    else
        log_patch "Adding TrueConf to send_message routing..."
        sed -i '/Platform.QQBOT:.*_send_qqbot/a\        elif platform == Platform.TRUECONF:\n            result = await _send_trueconf(pconfig.extra, chat_id, chunk)' "$SEND_PY"
        log_ok "TrueConf added to send_message routing"
        SEND_PATCHED=$((SEND_PATCHED + 1))
    fi

    # Check TrueConf media block before Non-media platforms
    if grep -q 'TrueConf.*special handling.*media' "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf media handling block"
    else
        log_patch "Adding TrueConf media handling block..."
        python3 - "$SEND_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'TrueConf.*special handling.*media' in content or '# --- TrueConf: special handling for media' in content:
    sys.exit(0)

marker = '    # --- Non-media platforms ---'
block = '''    # --- TrueConf: special handling for media attachments ---
    if platform == Platform.TRUECONF and media_files:
        last_result = None
        for i, chunk in enumerate(chunks):
            is_last = (i == len(chunks) - 1)
            result = await _send_trueconf(
                pconfig.extra,
                chat_id,
                chunk,
                media_files=media_files if is_last else [],
            )
            if isinstance(result, dict) and result.get("error"):
                return result
            last_result = result
        return last_result

'''

content = content.replace(marker, block + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "TrueConf media handling block added"
        SEND_PATCHED=$((SEND_PATCHED + 1))
    fi

    PATCHED=$((PATCHED + SEND_PATCHED))
fi

# ───────────────────────────────────────────
# 4. Copy adapter to gateway/platforms/
# ───────────────────────────────────────────
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
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
VENV_DIR="${HERMES_DIR}/venv"
BOT_PY="${VENV_DIR}/lib/python3.11/site-packages/trueconf/client/bot.py"
PARSER_PY="${VENV_DIR}/lib/python3.11/site-packages/trueconf/types/parser.py"

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
