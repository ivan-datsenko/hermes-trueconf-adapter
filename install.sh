#!/bin/bash
# ============================================
# TrueConf Adapter v5.0.0 — Interactive Installer
# ============================================
# Usage: 
#   Option 1 — from cloned repo:
#     cd ~/hermes-trueconf-adapter && bash install.sh
#
#   Option 2 — one-liner on clean machine:
#     curl -fsSL https://raw.githubusercontent.com/ivan-datsenko/hermes-trueconf-adapter/beta-v5/install.sh | bash
#
#   Option 3 — clone then install:
#     git clone -b beta-v5 https://github.com/ivan-datsenko/hermes-trueconf-adapter.git ~/hermes-trueconf-adapter
#     cd ~/hermes-trueconf-adapter && bash install.sh
# ============================================

set -e

# ── Non-interactive mode: read from env vars ──
# Set YES=1 to skip all interactive prompts (auto-yes)
# Set TRUECONF_SERVER, TRUECONF_USERNAME, TRUECONF_PASSWORD to auto-configure
NON_INTERACTIVE="${YES:-0}"

# Auto-detect if stdin is not a TTY (piped from curl)
if [ ! -t 0 ]; then
    NON_INTERACTIVE=1
fi

# ── Clone repo if running from curl (no local git repo) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -z "$SCRIPT_DIR" ] || [ ! -d "${SCRIPT_DIR}/.git" ]; then
    # Running from curl or outside repo — clone first
    REPO_DIR="${HOME}/hermes-trueconf-adapter"
    REPO_URL="https://github.com/ivan-datsenko/hermes-trueconf-adapter.git"
    BRANCH="beta-v5"

    echo -e "\033[0;36m📦 Cloning TrueConf Adapter (${BRANCH})...\033[0m"

    if [ -d "$REPO_DIR" ]; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            echo "  Recloning (non-interactive mode)..."
            rm -rf "$REPO_DIR"
        else
            echo -e "\033[1;33m⚠ Directory exists: ${REPO_DIR}\033[0m"
            read -p "  Reclone? (y/N): " rec
            if [[ "$rec" =~ ^[Yy]$ ]]; then
                rm -rf "$REPO_DIR"
            else
                echo "  Using existing directory."
            fi
        fi
    fi

    if [ ! -d "$REPO_DIR" ]; then
        if command -v git >/dev/null 2>&1; then
            git clone -b "$BRANCH" "$REPO_URL" "$REPO_DIR" || {
                echo -e "\033[0;31m❌ git clone failed. Install git first:\033[0m"
                echo "   sudo apt install git -y"
                exit 1
            }
        else
            echo -e "\033[0;31m❌ git not found. Install git first:\033[0m"
            echo "   sudo apt install git -y"
            exit 1
        fi
    fi

    echo -e "\033[0;32m✅ Repo ready: ${REPO_DIR}\033[0m"
    echo ""
    echo "  Running install from cloned repo..."
    cd "$REPO_DIR"
    exec bash "${REPO_DIR}/install.sh"
fi

# ── Auto-detect HERMES_DIR ──────────────────
if [ -z "$HERMES_DIR" ]; then
    # Try common paths
    for dir in "$HOME/.hermes/hermes-agent" "/root/.hermes/hermes-agent" "/opt/hermes-agent"; do
        if [ -d "$dir/gateway" ]; then
            HERMES_DIR="$dir"
            break
        fi
    done
    # Try to find via hermes binary
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
echo "╔═══════════════════════════════════════════╗"
echo "║   TrueConf Adapter v2.0.0 — Installer    ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ═══════════════════════════════════════════
# 1. Проверка Hermes Agent
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Проверяю Hermes Agent...${NC}"

if [ ! -d "$HERMES_DIR" ]; then
    die "Hermes Agent не найден: $HERMES_DIR

  Установите Hermes Agent:
  https://github.com/NousResearch/hermes-agent

  Или: HERMES_DIR=/path bash install.sh"
fi

if [ ! -d "$VENV_DIR" ]; then
    die "Python venv не найден: $VENV_DIR

  Запустите 'hermes setup' чтобы создать venv."
fi

if [ ! -f "$PYTHON" ]; then
    die "Python не найден: $PYTHON"
fi

echo -e "${GREEN}✅${NC} Hermes Agent: $HERMES_DIR"
echo -e "${GREEN}✅${NC} Python: $($PYTHON --version 2>&1)"
echo ""

# ═══════════════════════════════════════════
# 2. Установка python-trueconf-bot
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Устанавливаю python-trueconf-bot...${NC}"

if [ ! -f "$PIP" ]; then
    echo "  pip не найден, устанавливаю через ensurepip..."
    $PYTHON -m ensurepip --upgrade 2>&1 || die "Не удалось установить pip в venv"
fi

echo "  Устанавливаю python-trueconf-bot==1.2.0..."
$PYTHON -m pip install --pre "python-trueconf-bot==1.2.0" 2>&1 || {
    echo -e "${YELLOW}⚠ v1.2.0 не найдена, пробую последнюю...${NC}"
    $PYTHON -m pip install "python-trueconf-bot>=1.2.0" 2>&1 || die "Не удалось установить python-trueconf-bot"
}

echo "  Фикс httpx (бот тянет несовместимую версию)..."
$PYTHON -m pip install "httpx==0.28.1" 2>&1 || die "Не удалось установить httpx==0.28.1"

if $PYTHON -c "from trueconf import Bot" 2>&1; then
    echo -e "${GREEN}✅${NC} python-trueconf-bot установлен"
else
    die "Ошибка импорта trueconf.Bot

  Попробуйте вручную:
  $PYTHON -m pip install --pre 'python-trueconf-bot==1.2.0'
  $PYTHON -m pip install 'httpx==0.28.1'"
fi
echo ""

# ═══════════════════════════════════════════
# 3. Копирование адаптера в plugins
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Копирую адаптер в ${PLUGINS_DIR}...${NC}"

mkdir -p "$PLUGINS_DIR/gateway/platforms"
mkdir -p "$PLUGINS_DIR/lib_patches"

cp "${ADAPTER_DIR}/gateway/platforms/trueconf.py" "${PLUGINS_DIR}/gateway/platforms/trueconf.py"
cp "${ADAPTER_DIR}/apply_patches.sh" "${PLUGINS_DIR}/apply_patches.sh"
chmod +x "${PLUGINS_DIR}/apply_patches.sh"

if [ -d "${ADAPTER_DIR}/lib_patches" ]; then
    cp "${ADAPTER_DIR}/lib_patches/"*.py "${PLUGINS_DIR}/lib_patches/" 2>/dev/null || true
fi

echo -e "${GREEN}✅${NC} Файлы адаптера скопированы"
echo ""

# ═══════════════════════════════════════════
# 4. Применение патчей
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Применяю патчи к Hermes Agent...${NC}"
bash "${PLUGINS_DIR}/apply_patches.sh" "$HERMES_DIR"
echo ""

# ═══════════════════════════════════════════
# 5. Git hooks
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Устанавливаю git hooks...${NC}"
GIT_HOOKS_DIR="${HERMES_DIR}/.git/hooks"

if [ -d "$GIT_HOOKS_DIR" ]; then
    cat > "${GIT_HOOKS_DIR}/post-merge" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after hermes update
if [ -f "${PLUGINS_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after update..."
    bash "${PLUGINS_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-merge"

    cat > "${GIT_HOOKS_DIR}/post-checkout" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after branch switch
if [ -f "${PLUGINS_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after checkout..."
    bash "${PLUGINS_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-checkout"

    echo -e "${GREEN}✅${NC} Git hooks установлены"
else
    echo -e "${YELLOW}⚠${NC} .git/hooks не найден, пропускаю"
fi
echo ""

# ═══════════════════════════════════════════
# 6. Systemd drop-in
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Настраиваю systemd service...${NC}"
DROPIN_DIR="${HOME}/.config/systemd/user/hermes-gateway.service.d"

if [ -d "${HOME}/.config/systemd/user" ]; then
    mkdir -p "$DROPIN_DIR"
    cat > "${DROPIN_DIR}/trueconf-patches.conf" << DROPIN
[Service]
ExecStartPre=
ExecStartPre=/bin/bash ${PLUGINS_DIR}/apply_patches.sh
DROPIN
    systemctl --user daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✅${NC} Systemd drop-in установлен"
else
    echo -e "${YELLOW}⚠${NC} Systemd user dir не найден, пропускаю"
fi
echo ""

# ═══════════════════════════════════════════
# 7. Настройка подключения к TrueConf
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎯 Настройка подключения к TrueConf${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

SKIP_CONFIG=false
if grep -q "^TRUECONF_SERVER=" "$ENV_FILE" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} Настройки TrueConf уже есть в .env"
    ask "Перезаписать?" "[y/N]"
    read -r -p "  Введите: " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${GREEN}✅${NC} Сохраняю текущие настройки"
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" != "true" ]; then
    if [ "$NON_INTERACTIVE" = "1" ] && [ -n "$TRUECONF_SERVER" ] && [ -n "$TRUECONF_USERNAME" ] && [ -n "$TRUECONF_PASSWORD" ]; then
        # Non-interactive: read from env vars
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}🎯 Настройка TrueConf (non-interactive)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  Server:   $TRUECONF_SERVER"
        echo "  Username: $TRUECONF_USERNAME"
        echo "  Password: ***"
        USE_SSL="${TRUECONF_USE_SSL:-y}"
        ALLOW_ALL_USERS="${TRUECONF_ALLOW_ALL_USERS:-true}"
        ALLOWED_USERS="${TRUECONF_ALLOWED_USERS:-}"
    else
        ask "Адрес сервера TrueConf (например: video.company.com):"
        read -r -p "  Введите: " TRUECONF_SERVER
        [ -z "$TRUECONF_SERVER" ] && die "Адрес сервера не может быть пустым"
        echo ""

        ask "Логин бота (например: bot_username):"
        read -r -p "  Введите: " TRUECONF_USERNAME
        [ -z "$TRUECONF_USERNAME" ] && die "Логин бота не может быть пустым"
        echo ""

        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        ask "Пароль бота:"
        read -r -s -p "  Введите: " TRUECONF_PASSWORD
        echo ""
        [ -z "$TRUECONF_PASSWORD" ] && die "Пароль бота не может быть пустым"
        echo ""

        ask "Использовать SSL/HTTPS?" "[Y/n]"
        read -r -p "  Введите: " USE_SSL
        USE_SSL="${USE_SSL:-y}"
        echo ""

        # ── Контроль доступа ──
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}🔐 Контроль доступа${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        ask "Разрешить всем пользователям?" "[Y/n]"
        read -r -p "  Введите: " ALLOW_ALL

        if [[ "$ALLOW_ALL" =~ ^[Nn]$ ]]; then
            echo ""
            ask "Список разрешённых (TrueConf ID через запятую):"
            read -r -p "  Введите: " ALLOWED_USERS
            ALLOW_ALL_USERS="false"
        else
            ALLOW_ALL_USERS="true"
            ALLOWED_USERS=""
        fi
        echo ""
    fi

    # ── Запись в .env ──
    echo -e "${YELLOW}⏳ Сохраняю настройки...${NC}"

    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${GREEN}✅${NC} Backup .env создан"
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
        echo "TRUECONF_USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')"
        echo "TRUECONF_VERIFY_SSL=false"
        echo "TRUECONF_ALLOW_ALL_USERS=${ALLOW_ALL_USERS}"
        echo "TRUECONF_ALLOWED_USERS=${ALLOWED_USERS:-}"
    } >> "$ENV_FILE"

    echo -e "${GREEN}✅${NC} Настройки сохранены в ~/.hermes/.env"
fi
echo ""

# ═══════════════════════════════════════════
# 8. Готово
# ═══════════════════════════════════════════
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════╗"
echo "║          ✅ Установка завершена!          ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${YELLOW}📋 Что дальше:${NC}"
echo ""
echo "1. Перезапустите gateway:"
echo "   hermes gateway stop && hermes gateway start"
echo "   (НЕ используйте 'restart' — может зависнуть)"
echo ""
echo "2. Проверьте подключение:"
echo "   grep -i trueconf ~/.hermes/logs/agent.log | tail -10"
echo ""
echo "3. Проверьте что бот онлайн в TrueConf клиенте"
echo ""
echo "4. Отправьте боту сообщение — он ответит! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}💡 После hermes update патчи применятся автоматически${NC}"
echo -e "${GREEN}💡 Для ручного патча: bash ${PLUGINS_DIR}/apply_patches.sh${NC}"
echo ""
echo -e "${GREEN}💡 Неинтерактивная установка (для автоматизации):${NC}"
echo "   export TRUECONF_SERVER=video.example.com"
echo "   export TRUECONF_USERNAME=bot_name"
echo "   export TRUECONF_PASSWORD=secret"
echo "   curl -fsSL https://raw.githubusercontent.com/ivan-datsenko/hermes-trueconf-adapter/beta-v5/install.sh | bash"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
