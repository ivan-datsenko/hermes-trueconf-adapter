#!/bin/bash
# ============================================
# TrueConf Adapter v3.0.0 — Interactive Installer
# ============================================
# Usage:
#   Option 1 — from cloned repo:
#     cd ~/hermes-trueconf-adapter && bash install.sh
#
#   Option 2 — one-liner on clean machine:
#     curl -fsSL https://raw.githubusercontent.com/ivan-datsenko/hermes-trueconf-adapter/beta-v5/install.sh | bash
#
#   Option 3 — non-interactive (set env vars first):
#     export TRUECONF_SERVER=10.110.2.240
#     export TRUECONF_USERNAME=bot_name
#     export TRUECONF_PASSWORD=secret
#     export TRUECONF_VERIFY_SSL=false
#     bash install.sh
# ============================================

set -e

# ── Non-interactive mode: auto-yes via env vars ──
# If all required env vars are set, skip interactive prompts
NON_INTERACTIVE=0
if [ -n "$TRUECONF_SERVER" ] && [ -n "$TRUECONF_USERNAME" ] && [ -n "$TRUECONF_PASSWORD" ]; then
    NON_INTERACTIVE=1
fi

# ── Restore stdin from terminal for curl | bash ──
# When run via curl | bash, stdin is a pipe. Reattach to the controlling
# terminal so that read prompts work.
if [ "$NON_INTERACTIVE" != "1" ] && [ ! -t 0 ]; then
    if [ -e /dev/tty ]; then
        exec </dev/tty
    else
        echo "⚠ No terminal available — switching to non-interactive mode."
        echo "  Set TRUECONF_SERVER, TRUECONF_USERNAME, TRUECONF_PASSWORD env vars."
        echo ""
        if [ -z "$TRUECONF_SERVER" ] || [ -z "$TRUECONF_USERNAME" ] || [ -z "$TRUECONF_PASSWORD" ]; then
            echo "❌ Missing required env vars. Set them and re-run."
            exit 1
        fi
        NON_INTERACTIVE=1
    fi
fi

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
    echo -ne "${YELLOW}$1${NC}"
    if [ -n "$2" ]; then
        echo -e " ${YELLOW}[$2]${NC}"
    else
        echo ""
    fi
}

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════╗"
echo "║   TrueConf Adapter v3.0.0 — Installer    ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ═══════════════════════════════════════════
# 1. Проверка Hermes Agent
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Проверяю Hermes Agent...${NC}"

if [ ! -d "$HERMES_DIR" ]; then
    die "Hermes Agent не найден: $HERMES_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    die "Python venv не найден: $VENV_DIR"
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

# Use uv if available (Hermes uses uv), else pip
if command -v uv >/dev/null 2>&1; then
    UV_PYTHON="$PYTHON"
    echo "  Устанавливаю через uv..."
    uv pip install --pre "python-trueconf-bot>=1.2.0" --python "$UV_PYTHON" 2>&1 || {
        echo -e "${YELLOW}⚠ uv install failed, trying pip...${NC}"
        $PYTHON -m pip install --pre "python-trueconf-bot>=1.2.0" 2>&1 || die "Не удалось установить python-trueconf-bot"
    }
else
    $PYTHON -m pip install --pre "python-trueconf-bot>=1.2.0" 2>&1 || die "Не удалось установить python-trueconf-bot"
fi

if $PYTHON -c "from trueconf import Bot" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} python-trueconf-bot установлен"
else
    die "Ошибка импорта trueconf.Bot"
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
    cat > "${GIT_HOOKS_DIR}/post-merge" << 'HOOK'
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after hermes update
PLUGINS_DIR="${HOME}/.hermes/plugins/trueconf-adapter"
if [ -f "${PLUGINS_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after update..."
    bash "${PLUGINS_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-merge"

    cat > "${GIT_HOOKS_DIR}/post-checkout" << 'HOOK'
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after branch switch
PLUGINS_DIR="${HOME}/.hermes/plugins/trueconf-adapter"
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
    if [ "$NON_INTERACTIVE" != "1" ]; then
        ask "Перезаписать?" "[y/N]"
        read -r -p "  Введите: " OVERWRITE
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            echo ""
            echo -e "${GREEN}✅${NC} Сохраняю текущие настройки"
            SKIP_CONFIG=true
        fi
    else
        echo -e "${GREEN}✅${NC} Non-interactive: использую существующие настройки"
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" != "true" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        # Non-interactive: read from env vars
        TRUECONF_SERVER="${TRUECONF_SERVER}"
        TRUECONF_USERNAME="${TRUECONF_USERNAME}"
        TRUECONF_PASSWORD="${TRUECONF_PASSWORD}"
        USE_SSL="${TRUECONF_USE_SSL:-true}"
        VERIFY_SSL="${TRUECONF_VERIFY_SSL:-false}"
        ALLOW_ALL_USERS="${TRUECONF_ALLOW_ALL_USERS:-true}"
        ALLOWED_USERS="${TRUECONF_ALLOWED_USERS:-}"
    else
        # Interactive: ask user
        ask "Адрес сервера TrueConf (например: video.company.com или 10.110.2.240):"
        read -r -p "  Введите: " TRUECONF_SERVER
        [ -z "$TRUECONF_SERVER" ] && die "Адрес сервера не может быть пустым"
        echo ""

        ask "Логин бота (например: bot_username):"
        read -r -p "  Введите: " TRUECONF_USERNAME
        [ -z "$TRUECONF_USERNAME" ] && die "Логин бота не может быть пустым"
        echo ""

        ask "Пароль бота:"
        read -r -s -p "  Введите: " TRUECONF_PASSWORD
        echo ""
        [ -z "$TRUECONF_PASSWORD" ] && die "Пароль бота не может быть пустым"
        echo ""

        ask "Использовать SSL/HTTPS?" "[Y/n]"
        read -r -p "  Введите: " USE_SSL
        USE_SSL="${USE_SSL:-y}"
        echo ""

        # ── SSL certificate verification ──
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}🔒 Проверка SSL сертификата${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  Если TrueConf Server использует самоподписанный сертификат"
        echo "  (например, внутренний сервер), проверку нужно отключить."
        echo ""
        ask "Проверять SSL сертификат?" "[y/N]"
        read -r -p "  Введите: " VERIFY_SSL
        VERIFY_SSL="${VERIFY_SSL:-n}"
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
        echo "TRUECONF_VERIFY_SSL=$(echo "$VERIFY_SSL" | tr '[:upper:]' '[:lower:]')"
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
echo "   hermes gateway status"
echo ""
echo "3. Проверьте что бот онлайн в TrueConf клиенте"
echo ""
echo "4. Отправьте боту сообщение — он ответит! 🎉"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}💡 После hermes update патчи применятся автоматически${NC}"
echo -e "${GREEN}💡 Для ручного патча: bash ${PLUGINS_DIR}/apply_patches.sh${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
