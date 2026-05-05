#!/bin/bash
# ============================================
# TrueConf Adapter v2.0.0 — Interactive Installer
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
        exit 1
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
    exit 1
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
echo "║   TrueConf Adapter v2.0.0 — Installer    ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ── 1. Check Hermes Agent ──────────────────────
echo -e "${YELLOW}⏳ Checking Hermes Agent...${NC}"
if [ ! -d "$HERMES_DIR" ]; then
    die "Hermes Agent not found: $HERMES_DIR\n\n  Install Hermes Agent:\n  https://github.com/NousResearch/hermes-agent\n\n  Or: HERMES_DIR=/path bash install.sh"
fi
if [ ! -d "$VENV_DIR" ]; then
    die "Python venv not found: $VENV_DIR\n\n  Run 'hermes setup' to create venv."
fi
if [ ! -f "$PYTHON" ]; then
    die "Python not found: $PYTHON"
fi
echo -e "${GREEN}✅${NC} Hermes Agent: $HERMES_DIR"
echo -e "${GREEN}✅${NC} Python: $($PYTHON --version 2>&1)"
echo ""

# ── 2. Install python-trueconf-bot ─────────────
echo -e "${YELLOW}⏳ Installing python-trueconf-bot...${NC}"

# Ensure pip is available (ensurepip may not create bin/pip)
if ! $PYTHON -m pip --version >/dev/null 2>&1; then
    echo "  pip not found, installing via ensurepip..."
    $PYTHON -m ensurepip --upgrade 2>&1 || die "Failed to install pip in venv"
fi

# Install from GitHub (original working source, not broken PyPI)
echo "  Installing from GitHub (TrueConf/python-trueconf-bot)..."
$PYTHON -m pip install --force-reinstall "git+https://github.com/TrueConf/python-trueconf-bot.git#egg=python-trueconf-bot" 2>&1 || \
$PYTHON -m pip install "git+https://github.com/TrueConf/python-trueconf-bot.git#egg=python-trueconf-bot" 2>&1 || \
die "Failed to install python-trueconf-bot"

# Fix httpx (bot pulls incompatible version)
echo "  Fixing httpx..."
$PYTHON -m pip install "httpx==0.28.1" 2>&1 || die "Failed to install httpx==0.28.1"

if $PYTHON -c "from trueconf import Bot" 2>&1; then
    echo -e "${GREEN}✅${NC} python-trueconf-bot installed"
else
    die "Import error: trueconf.Bot\n\n  Try manually:\n  $PYTHON -m pip install 'git+https://github.com/TrueConf/python-trueconf-bot.git#egg=python-trueconf-bot'\n  $PYTHON -m pip install 'httpx==0.28.1'"
fi
echo ""

# ── 3. Copy adapter to plugins ──────────────────
echo -e "${YELLOW}⏳ Copying adapter to ${PLUGINS_DIR}...${NC}"
mkdir -p "$PLUGINS_DIR/gateway/platforms"
mkdir -p "$PLUGINS_DIR/lib_patches"
cp "${ADAPTER_DIR}/gateway/platforms/trueconf.py" "${PLUGINS_DIR}/gateway/platforms/trueconf.py"
cp "${ADAPTER_DIR}/apply_patches.sh" "${PLUGINS_DIR}/apply_patches.sh"
chmod +x "${PLUGINS_DIR}/apply_patches.sh"
if [ -d "${ADAPTER_DIR}/lib_patches" ]; then
    cp "${ADAPTER_DIR}/lib_patches/"*.py "${PLUGINS_DIR}/lib_patches/" 2>/dev/null || true
fi
echo -e "${GREEN}✅${NC} Adapter files copied"
echo ""

# ── 4. Apply patches ───────────────────────────
echo -e "${YELLOW}⏳ Applying patches to Hermes Agent...${NC}"
bash "${PLUGINS_DIR}/apply_patches.sh" "$HERMES_DIR"
echo ""

# ── 5. Git hooks ───────────────────────────────
echo -e "${YELLOW}⏳ Installing git hooks...${NC}"
GIT_HOOKS_DIR="${HERMES_DIR}/.git/hooks"
if [ -d "$GIT_HOOKS_DIR" ]; then
    for hook in post-merge post-checkout; do
        cat > "${GIT_HOOKS_DIR}/${hook}" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after hermes update
if [ -f "${PLUGINS_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after update..."
    bash "${PLUGINS_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
        chmod +x "${GIT_HOOKS_DIR}/${hook}"
    done
    echo -e "${GREEN}✅${NC} Git hooks installed"
else
    echo -e "${YELLOW}⚠${NC} .git/hooks not found, skipping"
fi
echo ""

# ── 6. Systemd drop-in ─────────────────────────
echo -e "${YELLOW}⏳ Configuring systemd service...${NC}"
DROPIN_DIR="${HOME}/.config/systemd/user/hermes-gateway.service.d"
if [ -d "${HOME}/.config/systemd/user" ]; then
    mkdir -p "$DROPIN_DIR"
    cat > "${DROPIN_DIR}/trueconf-patches.conf" << DROPIN
[Service]
ExecStartPre=
ExecStartPre=/bin/bash ${PLUGINS_DIR}/apply_patches.sh
DROPIN
    systemctl --user daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✅${NC} Systemd drop-in installed"
else
    echo -e "${YELLOW}⚠${NC} Systemd user dir not found, skipping"
fi
echo ""

# ── 7. Configure TrueConf connection ─────────────
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎯 Configuring TrueConf connection${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

SKIP_CONFIG=false
if grep -q "^TRUECONF_SERVER=" "$ENV_FILE" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} TrueConf settings already in .env"
    ask "Overwrite?" "[y/N]"
    read -r -p "  Enter: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${GREEN}✅${NC} Keeping current settings"
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" != "true" ]; then
    ask "TrueConf server address (e.g.: video.company.com):"
    read -r -p "  Enter: " TRUECONF_SERVER
    [ -z "$TRUECONF_SERVER" ] && die "Server address cannot be empty"

    ask "Bot login (e.g.: bot_username):"
    read -r -p "  Enter: " TRUECONF_USERNAME
    [ -z "$TRUECONF_USERNAME" ] && die "Bot login cannot be empty"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ask "Bot password:"
    read -r -s -p "  Enter: " TRUECONF_PASSWORD
    echo ""
    [ -z "$TRUECONF_PASSWORD" ] && die "Bot password cannot be empty"

    # ── SSL: auto-detect (always default to y) ──
    USE_SSL="y"

    # ── Access control ──
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🔐 Access control${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    ask "Allow all users?" "[Y/n]"
    read -r -p "  Enter: " ALLOW_ALL
    if [[ "$ALLOW_ALL" =~ ^[Nn]$ ]]; then
        echo ""
        ask "Allowed users (TrueConf IDs, comma-separated):"
        read -r -p "  Enter: " ALLOWED_USERS
        ALLOW_ALL_USERS="false"
    else
        ALLOW_ALL_USERS="true"
        ALLOWED_USERS=""
    fi

    # ── Home channel (optional) ──
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}📬 Home channel${NC}"
    echo -e "Home channel — это чат, куда бот будет слать результаты крон-задач."
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ask "Логин пользователя для home channel (или пусто чтобы пропустить):"
    read -r -p "  Enter: " TRUECONF_HOME_CHANNEL

    # ── Save to .env ──
    echo -e "${YELLOW}⏳ Saving settings...${NC}"
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${GREEN}✅${NC} Backup .env created"
    fi
    if [ -f "$ENV_FILE" ]; then
        grep -v "^TRUECONF" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    fi
    {
        echo ""
        echo "# TrueConf Adapter"
        echo "TRUECONF_SERVER=${TRUECONF_SERVER}"
        echo "TRUECONF_USERNAME=${TRUECONF_USERNAME}"
        echo "TRUECONF_PASSWORD=${TRUECONF_PASSWORD}"
        echo "TRUECONF_USE_SSL=y"
        echo "TRUECONF_VERIFY_SSL=false"
        echo "TRUECONF_ALLOW_ALL_USERS=${ALLOW_ALL_USERS}"
        echo "TRUECONF_ALLOWED_USERS=${ALLOWED_USERS:-}"
        if [ -n "$TRUECONF_HOME_CHANNEL" ]; then
            echo "TRUECONF_HOME_CHANNEL=${TRUECONF_HOME_CHANNEL}"
        fi
    } >> "$ENV_FILE"
    echo -e "${GREEN}✅${NC} Settings saved to ~/.hermes/.env"
fi
echo ""

# ── 8. Done ────────────────────────────────────
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════╗"
echo "║          ✅ Installation complete!          ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${YELLOW}📋 Next steps:${NC}"
echo ""
echo "1. Restart gateway:"
echo "   hermes gateway stop && hermes gateway start"
echo "   (Do NOT use 'restart' — may hang)"
echo ""
echo "2. Check connection:"
echo "   grep -i trueconf ~/.hermes/logs/agent.log | tail -10"
echo ""
echo "3. Check bot is online in TrueConf client"
echo ""
echo "4. Send a message to the bot — it will reply! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}💡 After 'hermes update' patches auto-apply${NC}"
echo -e "${GREEN}💡 Manual patch: bash ${PLUGINS_DIR}/apply_patches.sh${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
