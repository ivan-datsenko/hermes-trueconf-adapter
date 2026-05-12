#!/bin/bash
# ============================================
# TrueConf Adapter v2.2 — Interactive Installer
# ============================================
set -e

# ── Auto-detect HERMES_DIR ──────────────────
if [ -z "$HERMES_DIR" ]; then
    for dir in "$HOME/.hermes/hermes-agent" "/root/.hermes/hermes-agent" "/opt/hermes-agent"; do
        if [ -d "$dir/gateway" ]; then
            HERMES_DIR="$dir"
            break
        fi
    done
    if [ -z "$HERMES_DIR" ] && command -v hermes >/dev/null 2>&1; then
        HERMES_BIN=$(command -v hermes)
        while [ -L "$HERMES_BIN" ]; do HERMES_BIN=$(readlink -f "$HERMES_BIN"); done
        TMP_DIR=$(dirname "$HERMES_BIN")
        for _ in 1 2 3 4; do
            if [ -d "$TMP_DIR/gateway" ]; then
                HERMES_DIR="$TMP_DIR"
                break 2
            fi
            TMP_DIR=$(dirname "$TMP_DIR")
        done
    fi
    if [ -z "$HERMES_DIR" ]; then
        echo -e "\033[0;31m❌ Hermes Agent not found.\033[0m"
        echo "   Set HERMES_DIR=/path/to/hermes-agent bash install.sh"
        return 1 2>/dev/null || exit 1
    fi
fi

VENV_DIR="${HERMES_DIR}/venv"
PYTHON="${VENV_DIR}/bin/python"
PIP="${VENV_DIR}/bin/pip"
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HOME}/.hermes/.env"
PLUGINS_DIR="${HOME}/.hermes/plugins/trueconf-adapter"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

die() {
    echo -e "${RED}❌ $1${NC}" >&2
    return 1 2>/dev/null || exit 1
}

ask() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${YELLOW}$1${NC}"
    if [ -n "$2" ]; then
        echo -e " ${YELLOW}[$2]${NC}"
    else
        echo ""
    fi
}

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════╗"
echo "║   TrueConf Adapter v2.2 — Installer     ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ── 1. Check Hermes Agent ──────────────────────
echo -e "${YELLOW}⏳ Checking Hermes Agent...${NC}"
if [ ! -d "$HERMES_DIR" ]; then
    die "Hermes Agent not found: $HERMES_DIR"
fi
if [ ! -d "$VENV_DIR" ]; then
    die "Python venv not found: $VENV_DIR\n\n  Run 'hermes setup' to create venv."
fi
echo -e "${GREEN}✅${NC} Hermes Agent: $HERMES_DIR"
echo ""

# ── 2. Install dependencies ────────────────────
echo -e "${YELLOW}⏳ Installing dependencies...${NC}"

# Ensure pip is available
if ! $PYTHON -m pip --version >/dev/null 2>&1; then
    echo "  pip not found in venv, attempting to install via ensurepip..."
    $PYTHON -m ensurepip --upgrade 2>&1 || echo "  Warning: ensurepip failed, continuing anyway..."
fi

# Try to install bot library
echo "  Installing python-trueconf-bot..."
$PYTHON -m pip install --force-reinstall "git+https://github.com/TrueConf/python-trueconf-bot.git#egg=python-trueconf-bot" 2>&1 || \
$PYTHON -m pip install "git+https://github.com/TrueConf/python-trueconf-bot.git" 2>&1 || \
die "Failed to install bot library."

echo "  Installing httpx..."
$PYTHON -m pip install "httpx" 2>&1 || die "Failed to install httpx"

echo -e "${GREEN}✅${NC} Dependencies installed"
echo ""

# ── 3. Copy adapter and tools ──────────────────
echo -e "${YELLOW}⏳ Copying files...${NC}"
mkdir -p "$PLUGINS_DIR/gateway/platforms"
mkdir -p "$PLUGINS_DIR/lib_patches"
mkdir -p "$PLUGINS_DIR/tools"
cp "${ADAPTER_DIR}/gateway/platforms/trueconf.py" "${PLUGINS_DIR}/gateway/platforms/trueconf.py"
cp "${ADAPTER_DIR}/gateway/platforms/__init__.py" "${PLUGINS_DIR}/gateway/platforms/__init__.py"
cp "${ADAPTER_DIR}/tools/trueconf_tool.py" "${PLUGINS_DIR}/tools/trueconf_tool.py"
cp "${ADAPTER_DIR}/apply_patches.sh" "${PLUGINS_DIR}/apply_patches.sh"
chmod +x "${PLUGINS_DIR}/apply_patches.sh"
if [ -d "${ADAPTER_DIR}/lib_patches" ]; then
    cp "${ADAPTER_DIR}/lib_patches/"*.py "${PLUGINS_DIR}/lib_patches/" 2>/dev/null || true
fi
echo -e "${GREEN}✅${NC} Files copied"
echo ""

# ── 4. Apply patches ───────────────────────────
echo -e "${YELLOW}⏳ Applying patches...${NC}"
bash "${PLUGINS_DIR}/apply_patches.sh" "$HERMES_DIR"
echo ""

# ── 5. Configure TrueConf ──────────────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎯 Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

SKIP_CONFIG=false
if grep -q "^TRUECONF_SERVER=" "$ENV_FILE" 2>/dev/null; then
    ask "TrueConf settings found in .env. Overwrite?" "[y/N]"
    read -r -p "  Enter: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" != "true" ]; then
    ask "TrueConf server address (e.g. video.company.com):"
    read -r -p "  Enter: " TRUECONF_SERVER
    [ -z "$TRUECONF_SERVER" ] && die "Server cannot be empty"

    # SSL Auto-detect: internal IPs default to no SSL, domains default to SSL
    if [[ "$TRUECONF_SERVER" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|localhost|127\.) ]]; then
        SSL_DEFAULT="n"
        SSL_PROMPT="y/N"
    else
        SSL_DEFAULT="y"
        SSL_PROMPT="Y/n"
    fi
    ask "Use SSL/HTTPS?" "[$SSL_PROMPT]"
    read -r -p "  Enter: " USE_SSL_RAW
    [ -z "$USE_SSL_RAW" ] && USE_SSL_RAW="$SSL_DEFAULT"
    [[ "$USE_SSL_RAW" =~ ^[Nn]$ ]] && TRUECONF_USE_SSL="false" || TRUECONF_USE_SSL="true"

    ask "Verify SSL certificate? (Set 'n' for self-signed)" "[Y/n]"
    read -r -p "  Enter: " VERIFY_SSL_RAW
    [[ "$VERIFY_SSL_RAW" =~ ^[Nn]$ ]] && TRUECONF_VERIFY_SSL="false" || TRUECONF_VERIFY_SSL="true"

    echo -e "\n  ${YELLOW}Authentication Method:${NC}"
    echo "  1) Username and Password"
    echo "  2) API Token"
    read -r -p "  Choice [1-2]: " AUTH_CHOICE

    if [ "$AUTH_CHOICE" == "2" ]; then
        ask "Bot API Token:"
        read -r -s -p "  Enter: " TRUECONF_TOKEN
        echo ""
        TRUECONF_USERNAME=""
        TRUECONF_PASSWORD=""
    else
        ask "Bot login (e.g. bot_username):"
        read -r -p "  Enter: " TRUECONF_USERNAME
        [ -z "$TRUECONF_USERNAME" ] && die "Login cannot be empty"
        ask "Bot password:"
        read -r -s -p "  Enter: " TRUECONF_PASSWORD
        echo ""
        TRUECONF_TOKEN=""
    fi

    ask "Allow all users?" "[Y/n]"
    read -r -p "  Enter: " ALLOW_ALL
    if [[ "$ALLOW_ALL" =~ ^[Nn]$ ]]; then
        ask "Allowed users (IDs comma-separated):"
        read -r -p "  Enter: " ALLOWED_USERS
        TRUECONF_ALLOW_ALL="false"
    else
        TRUECONF_ALLOW_ALL="true"
        ALLOWED_USERS=""
    fi

    ask "Default Home Channel ID (optional):"
    read -r -p "  Enter: " HOME_CHANNEL

    # Save to .env
    if [ -f "$ENV_FILE" ]; then
        grep -v "^TRUECONF" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    fi
    {
        echo ""
        echo "# TrueConf Adapter"
        echo "TRUECONF_SERVER=${TRUECONF_SERVER}"
        [ -n "$TRUECONF_USERNAME" ] && echo "TRUECONF_USERNAME=${TRUECONF_USERNAME}"
        [ -n "$TRUECONF_PASSWORD" ] && echo "TRUECONF_PASSWORD=${TRUECONF_PASSWORD}"
        [ -n "$TRUECONF_TOKEN" ] && echo "TRUECONF_TOKEN=${TRUECONF_TOKEN}"
        echo "TRUECONF_USE_SSL=${TRUECONF_USE_SSL}"
        echo "TRUECONF_VERIFY_SSL=${TRUECONF_VERIFY_SSL}"
        echo "TRUECONF_ALLOW_ALL_USERS=${TRUECONF_ALLOW_ALL}"
        echo "TRUECONF_ALLOWED_USERS=${ALLOWED_USERS}"
        [ -n "$HOME_CHANNEL" ] && echo "TRUECONF_HOME_CHANNEL=${HOME_CHANNEL}"
        echo "TRUECONF_HOME_CHANNEL_NAME=Home"
    } >> "$ENV_FILE"
    echo -e "${GREEN}✅${NC} Settings saved"
fi

echo ""
echo -e "${GREEN}✅ Installation complete!${NC}"
echo "Restart gateway: hermes gateway stop && hermes gateway start"
