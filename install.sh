#!/bin/bash
# ============================================
# TrueConf Adapter v1.0.0 — Interactive Installer
# ============================================
# Одна команда — и всё работает!
# Usage: bash install.sh
# ============================================

set -e

HERMES_DIR="${HERMES_DIR:-/root/.hermes/hermes-agent}"
VENV_DIR="${HERMES_DIR}/venv"
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HOME}/.hermes/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функция для вопросов
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
echo "║   TrueConf Adapter v1.0.0 — Installer    ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ═══════════════════════════════════════════
# 1. Проверка Hermes Agent
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Проверяю Hermes Agent...${NC}"

if [ ! -d "$HERMES_DIR" ]; then
    echo -e "${RED}❌ Hermes Agent не найден: $HERMES_DIR${NC}"
    exit 1
fi

if [ ! -d "$VENV_DIR" ]; then
    echo -e "${RED}❌ Python venv не найден${NC}"
    exit 1
fi

echo -e "${GREEN}✅${NC} Hermes Agent найден"
source "$VENV_DIR/bin/activate"
echo -e "${GREEN}✅${NC} Python venv активирован"
echo ""

# ═══════════════════════════════════════════
# 2. Установка библиотеки
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Устанавливаю python-trueconf-bot...${NC}"
pip install -q --pre "python-trueconf-bot==1.2.0" 2>/dev/null || pip install -q "python-trueconf-bot>=1.2.0" 2>/dev/null || true
# Fix httpx dependency conflict (bot pulls httpx 1.0.dev3 which breaks AsyncClient)
pip install -q "httpx>=0.27,<0.29" 2>/dev/null || true
# Verify import
if python -c "from trueconf import Bot" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} Библиотека установлена и проверена"
else
    echo -e "${RED}❌${NC} Ошибка импорта trueconf.Bot — проверьте логи выше"
    exit 1
fi
echo ""

# ═══════════════════════════════════════════
# 3. Применение патчей (единый скрипт)
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Применяю патчи к Hermes Agent...${NC}"
bash "${ADAPTER_DIR}/apply_patches.sh" "$HERMES_DIR"
echo ""

# ═══════════════════════════════════════════
# 4. Git hooks (автовосстановление после update)
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Устанавливаю git hooks...${NC}"
GIT_HOOKS_DIR="${HERMES_DIR}/.git/hooks"

if [ -d "$GIT_HOOKS_DIR" ]; then
    # post-merge — срабатывает после git pull/merge
    cat > "${GIT_HOOKS_DIR}/post-merge" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after hermes update
if [ -f "${ADAPTER_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after update..."
    bash "${ADAPTER_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-merge"

    # post-checkout — срабатывает при смене ветки
    cat > "${GIT_HOOKS_DIR}/post-checkout" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after branch switch
if [ -f "${ADAPTER_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after checkout..."
    bash "${ADAPTER_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-checkout"

    echo -e "${GREEN}✅${NC} Git hooks установлены (post-merge, post-checkout)"
else
    echo -e "${YELLOW}⚠${NC} Git hooks не установлены (не git-репозиторий)"
fi
echo ""

# ═══════════════════════════════════════════
# 5. Systemd drop-in (ExecStartPre)
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Настраиваю systemd service...${NC}"
DROPIN_DIR="${HOME}/.config/systemd/user/hermes-gateway.service.d"

if [ -d "${HOME}/.config/systemd/user" ]; then
    mkdir -p "$DROPIN_DIR"
    cat > "${DROPIN_DIR}/trueconf-patches.conf" << DROPIN
[Service]
ExecStartPre=
ExecStartPre=/bin/bash ${ADAPTER_DIR}/apply_patches.sh
DROPIN
    systemctl --user daemon-reload 2>/dev/null || true
    echo -e "${GREEN}✅${NC} Systemd drop-in установлен"
else
    echo -e "${YELLOW}⚠${NC} Systemd user dir не найден, пропускаю"
fi
echo ""

# ═══════════════════════════════════════════
# 6. Интерактивный ввод настроек
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎯 Настройка подключения к TrueConf${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Проверяем, есть ли уже настройки
if grep -q "^TRUECONF_SERVER=" "$ENV_FILE" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} Настройки TrueConf уже есть в .env"
    ask "Перезаписать?" "[y/N]"
    read -p "  Введите: " -e -i "n" OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${GREEN}✅${NC} Настройки сохранены"
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" != "true" ]; then
    # Сервер
    ask "Адрес сервера TrueConf:"
    read -p "  Введите: " TRUECONF_SERVER
    echo ""

    # Логин
    ask "Логин бота:"
    read -p "  Введите: " TRUECONF_USERNAME
    echo ""

    # Пароль (без отображения)
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ask "Пароль бота:"
    read -s -p "  Введите: " TRUECONF_PASSWORD
    echo ""
    echo ""

    # SSL
    ask "Использовать SSL/HTTPS?" "[Y/n]"
    read -p "  Введите: " -e -i "y" USE_SSL
    USE_SSL="${USE_SSL:-y}"
    echo ""

    # ═══════════════════════════════════════════
    # 7. Контроль доступа
    # ═══════════════════════════════════════════
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🔐 Контроль доступа${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    ask "Разрешить всем пользователям?" "[Y/n]"
    read -p "  Введите: " -e -i "n" ALLOW_ALL

    if [[ "$ALLOW_ALL" =~ ^[Nn]$ ]]; then
        echo ""
        ask "Список разрешённых пользователей (через запятую):"
        read -p "  Введите: " -e -i "" ALLOWED_USERS
        ALLOW_ALL_USERS="false"
    else
        ALLOW_ALL_USERS="true"
        ALLOWED_USERS=""
    fi
    echo ""

    # ═══════════════════════════════════════════
    # 8. Запись в .env
    # ═══════════════════════════════════════════
    echo -e "${YELLOW}⏳ Сохраняю настройки...${NC}"

    # Создаём backup если .env существует
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${GREEN}✅${NC} Backup .env создан"
    fi

    # Удаляем старые TRUECONF переменные
    if [ -f "$ENV_FILE" ]; then
        grep -v "^TRUECONF" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    fi

    # Добавляем новые
    cat >> "$ENV_FILE" << EOF

# TrueConf Adapter v1.0.0
TRUECONF_SERVER=${TRUECONF_SERVER}
TRUECONF_USERNAME=${TRUECONF_USERNAME}
TRUECONF_PASSWORD=${TRUECONF_PASSWORD}
TRUECONF_USE_SSL=$(echo "$USE_SSL" | tr '[:upper:]' '[:lower:]')
TRUECONF_VERIFY_SSL=false
TRUECONF_ALLOW_ALL_USERS=${ALLOW_ALL_USERS}
TRUECONF_ALLOWED_USERS=${ALLOWED_USERS:-}
EOF

    echo -e "${GREEN}✅${NC} Настройки сохранены в ~/.hermes/.env"
fi
echo ""

# ═══════════════════════════════════════════
# 9. Готово
# ═══════════════════════════════════════════
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════╗"
echo "║     ✅ Установка завершена!               ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${YELLOW}📋 Что дальше:${NC}"
echo ""
echo "1. Перезапустите gateway:"
echo "   hermes gateway stop && hermes gateway start"
echo "   (НЕ используйте 'restart' — он может зависнуть)"
echo ""
echo "2. Проверьте подключение:"
echo "   grep -i trueconf ~/.hermes/logs/agent.log | tail -10"
echo ""
echo "3. Проверьте работу:"
echo "   journalctl --user -u hermes-gateway.service -f"
echo ""
echo "4. После hermes update патчи применятся автоматически:"
echo "   • Git hook (post-merge) — после git pull"
echo "   • Systemd ExecStartPre — при старте gateway"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}💡 Бот готов к использованию!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
