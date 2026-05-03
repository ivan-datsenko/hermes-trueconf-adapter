#!/bin/bash
# ============================================
# TrueConf Adapter v2.0.0 — Interactive Installer
# ============================================
# Одна команда — и всё работает!
# Usage: bash install.sh
# ============================================

set -e

HERMES_DIR="${HERMES_DIR:-$HOME/.hermes/hermes-agent}"
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
    die "Hermes Agent не найден в $HERMES_DIR

  Установите Hermes Agent сначала:
  https://github.com/NousResearch/hermes-agent

  Или укажите путь: HERMES_DIR=/path/to/hermes-agent bash install.sh"
fi

if [ ! -d "$VENV_DIR" ]; then
    die "Python venv не найден в $VENV_DIR

  Запустите 'hermes setup' или 'hermes gateway start' чтобы создать venv."
fi

if [ ! -f "$PYTHON" ]; then
    die "Python не найден: $PYTHON"
fi

echo -e "${GREEN}✅${NC} Hermes Agent найден: $HERMES_DIR"
echo -e "${GREEN}✅${NC} Python: $($PYTHON --version 2>&1)"
echo ""

# ═══════════════════════════════════════════
# 2. Установка библиотеки python-trueconf-bot
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Устанавливаю python-trueconf-bot...${NC}"

# Проверяем есть ли pip в venv
if [ ! -f "$PIP" ]; then
    echo "  pip не найден, устанавливаю через ensurepip..."
    $PYTHON -m ensurepip --upgrade 2>&1 || die "Не удалось установить pip в venv"
fi

# Устанавливаем python-trueconf-bot
echo "  Устанавливаю python-trueconf-bot==1.2.0..."
$PYTHON -m pip install --pre "python-trueconf-bot==1.2.0" 2>&1 || {
    echo -e "${YELLOW}⚠ v1.2.0 не найдена, пробую последнюю версию...${NC}"
    $PYTHON -m pip install "python-trueconf-bot>=1.2.0" 2>&1 || die "Не удалось установить python-trueconf-bot"
}

# Фикс httpx — бот тянет httpx 1.0.dev3, который ломает AsyncClient
echo "  Фикс httpx (бот тянет несовместимую версию)..."
$PYTHON -m pip install "httpx==0.28.1" 2>&1 || die "Не удалось установить httpx==0.28.1"

# Проверяем импорт
if $PYTHON -c "from trueconf import Bot; print('  Библиотека:', Bot.__module__)" 2>&1; then
    echo -e "${GREEN}✅${NC} python-trueconf-bot установлен и проверен"
else
    die "Ошибка импорта trueconf.Bot — что-то пошло не так при установке

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

# Копируем основные файлы
cp "${ADAPTER_DIR}/gateway/platforms/trueconf.py" "${PLUGINS_DIR}/gateway/platforms/trueconf.py"
cp "${ADAPTER_DIR}/apply_patches.sh" "${PLUGINS_DIR}/apply_patches.sh"
chmod +x "${PLUGINS_DIR}/apply_patches.sh"

# Копируем lib_patches если есть
if [ -d "${ADAPTER_DIR}/lib_patches" ]; then
    cp "${ADAPTER_DIR}/lib_patches/"*.py "${PLUGINS_DIR}/lib_patches/" 2>/dev/null || true
fi

echo -e "${GREEN}✅${NC} Файлы адаптера скопированы"
echo ""

# ═══════════════════════════════════════════
# 4. Применение патчей к Hermes Agent
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Применяю патчи к Hermes Agent...${NC}"
bash "${PLUGINS_DIR}/apply_patches.sh" "$HERMES_DIR"
echo ""

# ═══════════════════════════════════════════
# 5. Git hooks (автовосстановление после update)
# ═══════════════════════════════════════════
echo -e "${YELLOW}⏳ Устанавливаю git hooks для автовосстановления...${NC}"
GIT_HOOKS_DIR="${HERMES_DIR}/.git/hooks"

if [ -d "$GIT_HOOKS_DIR" ]; then
    # post-merge — срабатывает после git pull/merge
    cat > "${GIT_HOOKS_DIR}/post-merge" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after hermes update
if [ -f "${PLUGINS_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after update..."
    bash "${PLUGINS_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-merge"

    # post-checkout — срабатывает при смене ветки
    cat > "${GIT_HOOKS_DIR}/post-checkout" << HOOK
#!/bin/bash
# TrueConf Adapter — auto-reapply patches after branch switch
if [ -f "${PLUGINS_DIR}/apply_patches.sh" ]; then
    echo "[TrueConf] Re-applying patches after checkout..."
    bash "${PLUGINS_DIR}/apply_patches.sh" 2>&1 | sed 's/^/  /'
fi
HOOK
    chmod +x "${GIT_HOOKS_DIR}/post-checkout"

    echo -e "${GREEN}✅${NC} Git hooks установлены (post-merge, post-checkout)"
else
    echo -e "${YELLOW}⚠${NC} Git hooks не установлены (.git/hooks не найден)"
fi
echo ""

# ═══════════════════════════════════════════
# 6. Systemd drop-in (ExecStartPre)
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
# 7. Интерактивный ввод настроек TrueConf
# ═══════════════════════════════════════════
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎯 Настройка подключения к TrueConf${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Проверяем, есть ли уже настройки
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
    # Сервер
    ask "Адрес сервера TrueConf (например: video.company.com):"
    read -r -p "  Введите: " TRUECONF_SERVER
    [ -z "$TRUECONF_SERVER" ] && die "Адрес сервера не может быть пустым"
    echo ""

    # Логин
    ask "Логин бота (например: bot_username):"
    read -r -p "  Введите: " TRUECONF_USERNAME
    [ -z "$TRUECONF_USERNAME" ] && die "Логин бота не может быть пустым"
    echo ""

    # Пароль (без отображения)
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ask "Пароль бота:"
    read -r -s -p "  Введите: " TRUECONF_PASSWORD
    echo ""
    [ -z "$TRUECONF_PASSWORD" ] && die "Пароль бота не может быть пустым"
    echo ""

    # SSL
    ask "Использовать SSL/HTTPS?" "[Y/n]"
    read -r -p "  Введите: " USE_SSL
    USE_SSL="${USE_SSL:-y}"
    echo ""

    # ═══════════════════════════════════════════
    # 8. Контроль доступа
    # ═══════════════════════════════════════════
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🔐 Контроль доступа${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    ask "Разрешить всем пользователям?" "[Y/n]"
    read -r -p "  Введите: " ALLOW_ALL

    if [[ "$ALLOW_ALL" =~ ^[Nn]$ ]]; then
        echo ""
        ask "Список разрешённых пользователей (TrueConf ID через запятую):"
        read -r -p "  Введите: " ALLOWED_USERS
        ALLOW_ALL_USERS="false"
    else
        ALLOW_ALL_USERS="true"
        ALLOWED_USERS=""
    fi
    echo ""

    # ═══════════════════════════════════════════
    # 9. Запись в .env
    # ═══════════════════════════════════════════
    echo -e "${YELLOW}⏳ Сохраняю настройки...${NC}"

    # Создаём backup если .env существует
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${GREEN}✅${NC} Backup .env создан"
    fi

    # Удаляем старые TRUECONF переменные
    if [ -f "$ENV_FILE" ]; then
        grep -v "^TRUECONF" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    fi

    # Добавляем новые
    cat >> "$ENV_FILE" << EOF

# TrueConf Adapter
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
# 10. Готово
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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
