#!/bin/bash
# ===========================================
# TrueConf Adapter — Auto-Patch Script v2.6
# ===========================================
# Applies patches to hermes-agent core files.
# Safe to run multiple times (idempotent).
#
# Usage: bash apply_patches.sh [HERMES_DIR]
# ===========================================

set -e

HERMES_DIR="${1:-${HERMES_DIR:-$HOME/.hermes/hermes-agent}}"
PATCHED_COUNT=0

log_ok()   { echo "  ✓ $1"; }
log_skip() { echo "  · $1 (already patched)"; }
log_patch(){ echo "  → $1"; }

# Determine where this script lives
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"

# Determine Python and site-packages path
VENV_DIR="${HERMES_DIR}/venv"
PYTHON_BIN="${VENV_DIR}/bin/python"
if [ -f "$PYTHON_BIN" ]; then
    SITE_PACKAGES=$($PYTHON_BIN -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || \
                    $PYTHON_BIN -c "import sysconfig; print(sysconfig.get_path('purelib'))" 2>/dev/null || echo "")
else
    SITE_PACKAGES=""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TrueConf Adapter — Apply Patches v2.6"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Hermes: $HERMES_DIR"
if [ -n "$SITE_PACKAGES" ]; then
    echo "  Site-Packages: $SITE_PACKAGES"
fi
echo ""

# ───────────────────────────────────────────
# 1. hermes_cli/config.py — OPTIONAL_ENV_VARS
# ───────────────────────────────────────────
CLI_CONFIG_PY="${HERMES_DIR}/hermes_cli/config.py"

if [ ! -f "$CLI_CONFIG_PY" ]; then
    echo "✗ hermes_cli/config.py not found"
else
    if grep -q 'TRUECONF_SERVER' "$CLI_CONFIG_PY" 2>/dev/null; then
        log_skip "TrueConf variables in hermes_cli/config.py"
        # Cleanup API token if present from previous version
        sed -i '/TRUECONF_TOKEN/d' "$CLI_CONFIG_PY"
    else
        log_patch "Adding TrueConf variables to OPTIONAL_ENV_VARS..."
        python3 - "$CLI_CONFIG_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = '    # ── Messaging platforms ──'
if marker not in content:
    marker = '    "TELEGRAM_BOT_TOKEN": {'

patch = '''    "TRUECONF_SERVER": {
        "description": "TrueConf server hostname (e.g. video.example.com)",
        "prompt": "TrueConf Server",
        "url": None,
        "password": False,
        "category": "messaging",
    },
    "TRUECONF_USERNAME": {
        "description": "Bot username (without domain)",
        "prompt": "Bot Username",
        "url": None,
        "password": False,
        "category": "messaging",
    },
    "TRUECONF_PASSWORD": {
        "description": "Bot password",
        "prompt": "Bot Password",
        "url": None,
        "password": True,
        "category": "messaging",
    },
    "TRUECONF_PORT": {
        "description": "TrueConf server port (default: 443)",
        "prompt": "Server Port",
        "url": None,
        "password": False,
        "category": "messaging",
        "advanced": True,
    },
    "TRUECONF_USE_SSL": {
        "description": "Use HTTPS/SSL for connection (true/false)",
        "prompt": "Use SSL",
        "url": None,
        "password": False,
        "category": "messaging",
        "advanced": True,
    },
    "TRUECONF_VERIFY_SSL": {
        "description": "Verify SSL certificate (true/false, set false for self-signed)",
        "prompt": "Verify SSL",
        "url": None,
        "password": False,
        "category": "messaging",
        "advanced": True,
    },
    "TRUECONF_ALLOWED_USERS": {
        "description": "Comma-separated TrueConf IDs allowed to use the bot",
        "prompt": "Allowed Users",
        "url": None,
        "password": False,
        "category": "messaging",
    },
    "TRUECONF_ALLOW_ALL_USERS": {
        "description": "Allow all users to interact with the bot (true/false)",
        "prompt": "Allow All Users",
        "url": None,
        "password": False,
        "category": "messaging",
    },
'''
content = content.replace(marker, marker + "\n" + patch, 1)

# Also add to _EXTRA_ENV_KEYS
extra_marker = '    "OPENAI_API_KEY", "OPENAI_BASE_URL",'
extra_patch = '''    "TRUECONF_SERVER", "TRUECONF_USERNAME", "TRUECONF_PASSWORD",
    "TRUECONF_USE_SSL", "TRUECONF_VERIFY_SSL", "TRUECONF_PORT",
    "TRUECONF_ALLOWED_USERS", "TRUECONF_ALLOW_ALL_USERS", "TRUECONF_HOME_CHANNEL", "TRUECONF_HOME_CHANNEL_NAME",'''
if extra_marker in content:
    content = content.replace(extra_marker, extra_marker + "\n" + extra_patch, 1)

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "TrueConf setup variables added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 2. gateway/config.py — Platform Enum & Auto-Detect
# ───────────────────────────────────────────
CONFIG_PY="${HERMES_DIR}/gateway/config.py"

if [ ! -f "$CONFIG_PY" ]; then
    echo "✗ gateway/config.py not found"
else
    # 2a. Platform.TRUECONF Enum Entry
    if grep -q 'TRUECONF = "trueconf"' "$CONFIG_PY" 2>/dev/null; then
        log_skip "Platform.TRUECONF enum"
    else
        log_patch "Adding Platform.TRUECONF to enum..."
        python3 - "$CONFIG_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

match = re.search(r'class Platform\(.*?\):', content)
if match:
    if 'YUANBAO = "yuanbao"' in content:
        content = content.replace('YUANBAO = "yuanbao"', 'YUANBAO = "yuanbao"\n    TRUECONF = "trueconf"')
    elif 'QQBOT = "qqbot"' in content:
        content = content.replace('QQBOT = "qqbot"', 'QQBOT = "qqbot"\n    TRUECONF = "trueconf"')
    else:
        content = content.replace(match.group(0), match.group(0) + '\n    TRUECONF = "trueconf"')
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
PYEOF
        log_ok "Platform.TRUECONF enum added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi

    # 2b. Auto-Detect Block
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
    trueconf_username = os.getenv("TRUECONF_USERNAME", "").strip()
    trueconf_password = os.getenv("TRUECONF_PASSWORD", "").strip()
    if trueconf_server and trueconf_username and trueconf_password:
        if Platform.TRUECONF not in config.platforms:
            config.platforms[Platform.TRUECONF] = PlatformConfig()
        config.platforms[Platform.TRUECONF].enabled = True
        config.platforms[Platform.TRUECONF].extra["server"] = trueconf_server
        config.platforms[Platform.TRUECONF].extra["username"] = trueconf_username
        config.platforms[Platform.TRUECONF].extra["password"] = trueconf_password
        trueconf_port = os.getenv("TRUECONF_PORT", "").strip()
        if trueconf_port:
            try:
                config.platforms[Platform.TRUECONF].extra["port"] = int(trueconf_port)
            except ValueError:
                pass
        # Auto-detect SSL: internal IPs default to no SSL, domains default to SSL
        import re as _re
        _is_internal_ip = bool(_re.match(r'^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|localhost|127\.)', trueconf_server))
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
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi

    # 2c. get_connected_platforms — TrueConf check
    if grep -q 'platform == Platform.TRUECONF and config.extra.get("server")' "$CONFIG_PY" 2>/dev/null; then
        log_skip "get_connected_platforms TrueConf check"
    else
        log_patch "Adding TrueConf to get_connected_platforms..."
        python3 - "$CONFIG_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

pattern = r'(elif platform == Platform\.\w+.*?:\s+connected\.append\(platform\))'
matches = list(re.finditer(pattern, content, re.DOTALL))
if matches:
    last_match = matches[-1]
    patch = '''
            # TrueConf uses extra dict for server + credentials
            elif platform == Platform.TRUECONF and config.extra.get("server") and (
                config.extra.get("username") and config.extra.get("password")
            ):
                connected.append(platform)'''
    content = content[:last_match.end()] + patch + content[last_match.end():]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP")
PYEOF
        log_ok "get_connected_platforms TrueConf check added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 3. hermes_cli/gateway.py — Platform UI Integration
# ───────────────────────────────────────────
GATEWAY_PY="${HERMES_DIR}/hermes_cli/gateway.py"

if [ ! -f "$GATEWAY_PY" ]; then
    echo "✗ hermes_cli/gateway.py not found"
else
    if grep -q '"key": "trueconf"' "$GATEWAY_PY" 2>/dev/null; then
        log_skip "TrueConf in _PLATFORMS list"
    else
        log_patch "Adding TrueConf to _PLATFORMS and setup mapping..."
        python3 - "$GATEWAY_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1. Add to _PLATFORMS list
platform_block = '''    {
        "key": "trueconf",
        "label": "TrueConf",
        "emoji": "📹",
        "token_var": "TRUECONF_SERVER",
        "setup_instructions": [
            "1. TrueConf Server must be reachable from this machine.",
            "2. You need a Bot username and password.",
            "3. Bot must be registered on the TrueConf Server.",
        ],
        "vars": [
            {"name": "TRUECONF_SERVER", "prompt": "Server hostname", "password": False,
             "help": "TrueConf server hostname (e.g. video.example.net)."},
            {"name": "TRUECONF_USERNAME", "prompt": "Bot username", "password": False,
             "help": "Bot username (without domain)."},
            {"name": "TRUECONF_PASSWORD", "prompt": "Bot password", "password": True,
             "help": "Bot password."},
            {"name": "TRUECONF_ALLOWED_USERS", "prompt": "Allowed user IDs (comma-separated)", "password": False,
             "is_allowlist": True,
             "help": "TrueConf IDs allowed to interact with the bot."},
        ],
    },
'''
# Insert before Telegram
if '    {' in content:
    content = content.replace('    {', platform_block + '    {', 1)

# 2. Add to _builtin_setup_fn mapping
fn_block_match = re.search(r'(_builtin_setup_fn\s*=\s*\{[^}]*)(\})', content, re.DOTALL)
if fn_block_match:
    prefix = "_s." if "_s._setup_telegram" in content else ""
    entry = f'        "trueconf": {prefix}_setup_trueconf,\n'
    content = content[:fn_block_match.end(1)] + entry + content[fn_block_match.start(2):]

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "TrueConf UI integration added to gateway.py"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 4. hermes_cli/setup.py — TrueConf Setup Flow
# ───────────────────────────────────────────
SETUP_PY="${HERMES_DIR}/hermes_cli/setup.py"

if [ ! -f "$SETUP_PY" ]; then
    echo "✗ hermes_cli/setup.py not found"
else
    if grep -q 'def _setup_trueconf():' "$SETUP_PY" 2>/dev/null; then
        log_skip "_setup_trueconf function in setup.py"
        # Cleanup API token version of the function if present
        python3 - "$SETUP_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# New simplified function without API Token
setup_func = '''
def _setup_trueconf():
    """Configure TrueConf Server credentials."""
    print_header("TrueConf")
    existing = get_env_value("TRUECONF_SERVER")
    if existing:
        print_info(f"TrueConf: already configured ({existing})")
        if not prompt_yes_no("Reconfigure TrueConf?", False):
            return

    server = prompt("TrueConf Server (e.g. video.example.net)")
    if not server:
        return
    save_env_value("TRUECONF_SERVER", server)

    # SSL Auto-detect logic
    import re as _re
    _is_internal_ip = bool(_re.match(r'^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|localhost|127\.)', server))
    use_ssl = prompt_yes_no("Use SSL (HTTPS)?", default=not _is_internal_ip)
    save_env_value("TRUECONF_USE_SSL", "true" if use_ssl else "false")

    username = prompt("Bot Username")
    password = prompt("Bot Password", password=True)
    save_env_value("TRUECONF_USERNAME", username)
    save_env_value("TRUECONF_PASSWORD", password)
    remove_env_value("TRUECONF_TOKEN")

    allowed = prompt("Allowed user IDs (comma-separated, leave empty for open access)")
    if allowed:
        save_env_value("TRUECONF_ALLOWED_USERS", allowed.replace(" ", ""))
        print_success("TrueConf allowlist configured")
    else:
        if prompt_yes_no("Allow all users to access the bot?", False):
            save_env_value("TRUECONF_ALLOW_ALL_USERS", "true")
            print_warning("Open access enabled for TrueConf")

    home = prompt("Home channel ID (leave empty to set later)")
    if home:
        save_env_value("TRUECONF_HOME_CHANNEL", home)
        print_success(f"Home channel set to {home}")
'''

# Find existing _setup_trueconf and replace it
pattern = r'def _setup_trueconf\(\):.*?print_success\(f"Home channel set to {home}"\)'
if re.search(pattern, content, re.DOTALL):
    content = re.sub(pattern, setup_func.strip(), content, flags=re.DOTALL)
    with open(path, 'w') as f:
        f.write(content)
    print("OK - Updated setup function")
else:
    print("SKIP - Setup function unchanged")
PYEOF
    else
        log_patch "Adding _setup_trueconf function to setup.py..."
        python3 - "$SETUP_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

setup_func = '''
def _setup_trueconf():
    """Configure TrueConf Server credentials."""
    print_header("TrueConf")
    existing = get_env_value("TRUECONF_SERVER")
    if existing:
        print_info(f"TrueConf: already configured ({existing})")
        if not prompt_yes_no("Reconfigure TrueConf?", False):
            return

    server = prompt("TrueConf Server (e.g. video.example.net)")
    if not server:
        return
    save_env_value("TRUECONF_SERVER", server)

    # SSL Auto-detect logic
    import re as _re
    _is_internal_ip = bool(_re.match(r'^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|localhost|127\.)', server))
    use_ssl = prompt_yes_no("Use SSL (HTTPS)?", default=not _is_internal_ip)
    save_env_value("TRUECONF_USE_SSL", "true" if use_ssl else "false")

    username = prompt("Bot Username")
    password = prompt("Bot Password", password=True)
    save_env_value("TRUECONF_USERNAME", username)
    save_env_value("TRUECONF_PASSWORD", password)
    remove_env_value("TRUECONF_TOKEN")

    allowed = prompt("Allowed user IDs (comma-separated, leave empty for open access)")
    if allowed:
        save_env_value("TRUECONF_ALLOWED_USERS", allowed.replace(" ", ""))
        print_success("TrueConf allowlist configured")
    else:
        if prompt_yes_no("Allow all users to access the bot?", False):
            save_env_value("TRUECONF_ALLOW_ALL_USERS", "true")
            print_warning("Open access enabled for TrueConf")

    home = prompt("Home channel ID (leave empty to set later)")
    if home:
        save_env_value("TRUECONF_HOME_CHANNEL", home)
        print_success(f"Home channel set to {home}")
'''

# Find a place to insert the function
match = re.search(r'\ndef _setup_\w+\(\):', content)
if match:
    content = content[:match.start()] + setup_func + content[match.start():]
else:
    content += setup_func

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "_setup_trueconf function added to setup.py"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 5. hermes_cli/platforms.py — PLATFORMS Dict
# ───────────────────────────────────────────
PLATFORMS_PY="${HERMES_DIR}/hermes_cli/platforms.py"

if [ ! -f "$PLATFORMS_PY" ]; then
    echo "✗ hermes_cli/platforms.py not found"
else
    if grep -q '"trueconf"' "$PLATFORMS_PY" 2>/dev/null; then
        log_skip "TrueConf in PLATFORMS dict"
    else
        log_patch "Adding TrueConf to PLATFORMS dict..."
        python3 - "$PLATFORMS_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

pattern = r'(\s+\("\w+",\s+PlatformInfo\(label=".*?"\)\),)'
matches = list(re.finditer(pattern, content))
if matches:
    last_match = matches[-1]
    patch = '\n    ("trueconf",       PlatformInfo(label="📹 TrueConf",        default_toolset="hermes-trueconf")),'
    content = content[:last_match.end()] + patch + content[last_match.end():]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
PYEOF
        log_ok "TrueConf in PLATFORMS dict added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 6. gateway/run.py — Adapter Creation & Auth Maps
# ───────────────────────────────────────────
RUN_PY="${HERMES_DIR}/gateway/run.py"

if [ ! -f "$RUN_PY" ]; then
    echo "✗ gateway/run.py not found"
else
    # 6a. TrueConfAdapter Creation Block
    if grep -q 'Platform.TRUECONF' "$RUN_PY" 2>/dev/null; then
        log_skip "TrueConfAdapter creation block"
    else
        log_patch "Adding TrueConfAdapter creation block..."
        python3 - "$RUN_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

pattern = r'(\n\s+return None\n\s+def _is_user_authorized)'
match = re.search(pattern, content)
if match:
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
else:
    print("FAIL")
    sys.exit(1)
PYEOF
        log_ok "TrueConfAdapter creation block added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi

    # 6b. Authorization Maps
    log_patch "Patching authorization maps in run.py..."
    python3 - "$RUN_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 1. _builtin_allowed_vars
if 'TRUECONF_ALLOWED_USERS' not in content:
    pattern = r'(_builtin_allowed_vars\s*=\s*\()(.*?)(\n\s+\))'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        content = content[:match.start(3)] + ',\n            "TRUECONF_ALLOWED_USERS"' + content[match.start(3):]
        changed = True

# 2. _builtin_allow_all_vars
if 'TRUECONF_ALLOW_ALL_USERS' not in content:
    pattern = r'(_builtin_allow_all_vars\s*=\s*\()(.*?)(\n\s+\))'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        content = content[:match.start(3)] + ',\n            "TRUECONF_ALLOW_ALL_USERS"' + content[match.start(3):]
        changed = True

# 3. platform_allow_all_map
if 'Platform.TRUECONF: "TRUECONF_ALLOW_ALL_USERS"' not in content:
    pattern = r'(platform_allow_all_map\s*=\s*\{)(.*?)(\})'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        content = content[:match.start(3)] + '    Platform.TRUECONF: "TRUECONF_ALLOW_ALL_USERS",\n        ' + content[match.start(3):]
        changed = True

# 4. platform_env_map
if 'Platform.TRUECONF: "TRUECONF_ALLOWED_USERS"' not in content:
    pattern = r'(platform_env_map\s*=\s*\{)(.*?)(\})'
    for m in re.finditer(pattern, content, re.DOTALL):
        if 'Platform.TRUECONF' not in content[m.start():m.end()]:
             content = content[:m.start(3)] + '    Platform.TRUECONF: "TRUECONF_ALLOWED_USERS",\n        ' + content[m.start(3):]
             changed = True

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
else:
    print("SKIP")
PYEOF
    log_ok "Authorization maps patched"
    PATCHED_COUNT=$((PATCHED_COUNT + 1))
fi

# ───────────────────────────────────────────
# 7. tools/send_message_tool.py — Message Sending
# ───────────────────────────────────────────
SEND_PY="${HERMES_DIR}/tools/send_message_tool.py"

if [ ! -f "$SEND_PY" ]; then
    echo "✗ tools/send_message_tool.py not found"
else
    # 7a. platform_map
    if grep -q '"trueconf": Platform.TRUECONF' "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf in platform_map"
    else
        log_patch "Adding TrueConf to platform_map..."
        python3 - "$SEND_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

pattern = r'(platform_map\s*=\s*\{[^}]*)(\})'
match = re.search(pattern, content, re.DOTALL)
if match:
    content = content[:match.start(2)] + '    "trueconf": Platform.TRUECONF,\n' + content[match.start(2):]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
PYEOF
        log_ok "TrueConf added to platform_map"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi

    # 7b. _send_trueconf Function
    if grep -q 'async def _send_trueconf' "$SEND_PY" 2>/dev/null; then
        log_skip "_send_trueconf function"
    else
        log_patch "Adding _send_trueconf function..."
        python3 - "$SEND_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = '# --- Registry ---'
if marker not in content:
    marker = '# --- Non-media platforms ---'

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
            return {"error": f"TrueConf: failed to connect - {adapter.fatal_error_message or 'unknown error'}"}
        try:
            result = await adapter.send(chat_id, message)
            if not result.success:
                return {"error": f"TrueConf send failed: {result.error}"}

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
                        import logging
                        logger = logging.getLogger(__name__)
                        logger.error("[TrueConf] Failed to send media %s: %s", media_path, e)
            return {"success": True, "platform": "trueconf", "chat_id": chat_id, "message_id": result.message_id}
        finally:
            await adapter.disconnect()
    except Exception as e:
        return {"error": f"TrueConf send failed: {e}"}

'''
content = content.replace(marker, func + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "_send_trueconf function added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi

    # 7c. _parse_target_ref TrueConf support
    if grep -q 'if platform_name == "trueconf":' "$SEND_PY" 2>/dev/null; then
        log_skip "_parse_target_ref TrueConf support"
    else
        log_patch "Adding TrueConf support to _parse_target_ref..."
        python3 - "$SEND_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

match = re.search(r'def _parse_target_ref\(.*?\):', content)
if match:
    patch = '''
    if platform_name == "trueconf":
        return target_ref.strip(), None, True
'''
    content = content[:match.end()] + patch + content[match.end():]
    with open(path, 'w') as f:
        f.write(content)
    print("OK")
PYEOF
        log_ok "_parse_target_ref TrueConf support added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi

    # 7d. TrueConf media handler in _send_to_platform
    if grep -q "platform == Platform.TRUECONF" "$SEND_PY" 2>/dev/null && grep -q "_send_trueconf(pconfig" "$SEND_PY" 2>/dev/null; then
        log_skip "TrueConf media handler in _send_to_platform"
    else
        log_patch "Adding TrueConf media handler to _send_to_platform..."
        python3 - "$SEND_PY" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

trueconf_block = """    elif platform == Platform.TRUECONF:
        return await _send_trueconf(pconfig.extra, chat_id, message or "", media_files=media_files)
"""
pattern = r'(async def _send_to_platform.*?)(return await _send_to_registry)'
match = re.search(pattern, content, re.DOTALL)
if match:
     content = content[:match.start(2)] + trueconf_block + content[match.start(2):]

# Update error/warning messages
content = re.sub(r'(send_message MEDIA delivery is currently only supported for .*?) and (\w+);', r'\1, \2 and trueconf;', content)
content = re.sub(r'(native send_message media delivery is currently only supported for .*?) and (\w+)"', r'\1, \2 and trueconf"', content)

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "TrueConf media handler added"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 8. Copy Adapter to gateway/platforms/
# ───────────────────────────────────────────
ADAPTER_SRC="${ADAPTER_DIR}/gateway/platforms/trueconf.py"
ADAPTER_DST="${HERMES_DIR}/gateway/platforms/trueconf.py"

if [ -f "$ADAPTER_SRC" ]; then
    log_patch "Copying TrueConf adapter..."
    mkdir -p "$(dirname "$ADAPTER_DST")"
    cp "$ADAPTER_SRC" "$ADAPTER_DST"
    log_ok "TrueConf adapter copied"
    PATCHED_COUNT=$((PATCHED_COUNT + 1))
fi

# ───────────────────────────────────────────
# 9. Patch installed library — applying files from lib_patches/
# ───────────────────────────────────────────
LIB_PATCHES_SRC="${ADAPTER_DIR}/lib_patches"

if [ -n "$SITE_PACKAGES" ]; then
    # 9a. Patch trueconf/client/bot.py
    BOT_PY="${SITE_PACKAGES}/trueconf/client/bot.py"
    if [ -f "$LIB_PATCHES_SRC/bot.py" ] && [ -f "$BOT_PY" ]; then
        if grep -q "async def download_file_by_id" "$BOT_PY" 2>/dev/null; then
            log_skip "bot.py (already contains download_file_by_id)"
        else
            log_patch "Applying full bot.py patch from lib_patches..."
            cp "$LIB_PATCHES_SRC/bot.py" "$BOT_PY"
            log_ok "bot.py patched"
            PATCHED_COUNT=$((PATCHED_COUNT + 1))
        fi
    fi

    # 9b. Patch trueconf/types/parser.py
    PARSER_PY="${SITE_PACKAGES}/trueconf/types/parser.py"
    if [ -f "$LIB_PATCHES_SRC/parser.py" ] && [ -f "$PARSER_PY" ]; then
        if grep -q "match env_type:" "$PARSER_PY" 2>/dev/null; then
            log_skip "parser.py (already patched)"
        else
            log_patch "Applying full parser.py patch from lib_patches..."
            cp "$LIB_PATCHES_SRC/parser.py" "$PARSER_PY"
            log_ok "parser.py patched"
            PATCHED_COUNT=$((PATCHED_COUNT + 1))
        fi
    fi
fi

# ───────────────────────────────────────────
# 10. config.yaml — platform_toolsets for TrueConf
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
  - trueconf
  - vision
  - web
'''

pattern = r'(^ {2}\w+:\n(?: {2}- .*\n)+)'
matches = list(re.finditer(pattern, content, re.MULTILINE))
if matches:
    last = matches[-1]
    insert_pos = last.end()
    content = content[:insert_pos] + '\n' + trueconf_section + content[insert_pos:]
else:
    if not content.endswith('\n'):
        content += '\n'
    content += trueconf_section

with open(path, 'w') as f:
    f.write(content)
print("OK")
PYEOF
        log_ok "TrueConf toolsets added to config.yaml"
        PATCHED_COUNT=$((PATCHED_COUNT + 1))
    fi
fi

# ───────────────────────────────────────────
# 11. tools/trueconf_tool.py — Platform Tools
# ───────────────────────────────────────────
TOOLS_SRC="${ADAPTER_DIR}/tools/trueconf_tool.py"
TOOLS_DST="${HERMES_DIR}/tools/trueconf_tool.py"

if [ -f "$TOOLS_SRC" ]; then
    log_patch "Copying TrueConf tools..."
    mkdir -p "$(dirname "$TOOLS_DST")"
    cp "$TOOLS_SRC" "$TOOLS_DST"
    log_ok "TrueConf tools copied"
    PATCHED_COUNT=$((PATCHED_COUNT + 1))
fi

# ───────────────────────────────────────────
# Cleanup redundant plugin files
# ───────────────────────────────────────────
rm -f "${HERMES_DIR}/hermes_cli/plugins/trueconf_plugin.py"

# ───────────────────────────────────────────
# Done
# ───────────────────────────────────────────
echo ""
if [ $PATCHED_COUNT -gt 0 ]; then
    echo "✅ Patches applied: $PATCHED_COUNT"
else
    echo "✅ All patches already applied"
fi
echo ""
