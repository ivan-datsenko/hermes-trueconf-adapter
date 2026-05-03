# TrueConf Adapter for Hermes Agent

[English](README_EN.md) | Русский

![Version](https://img.shields.io/badge/version-2.0.0-blue)
![Status](https://img.shields.io/badge/status-beta-orange)

Адаптер [TrueConf](https://trueconf.com/) для [Hermes Agent](https://github.com/NousResearch/hermes-agent) — позволяет общаться с AI-агентом через TrueConf.

## Возможности

- ✅ Текстовые сообщения
- ✅ Slash-команды (/help, /new, /reset)
- ✅ Отправка и получение изображений
- ✅ Отправка и получение файлов
- ✅ Reply threading
- ✅ Контроль доступа
- ✅ Edit message
- ✅ Outbound sending (`hermes send`)
- ✅ Auto-reconnect при обрыве связи
- ✅ Auto-repair после `hermes update`

## Требования

- **Hermes Agent** установлен и настроен (`hermes setup` выполнен)
- **TrueConf Server** с созданным аккаунтом бота
- **Python 3.10+**

## Установка

```bash
# 1. Клонируем репозиторий
git clone https://github.com/ivan-datsenko/hermes-trueconf-adapter.git /tmp/trueconf-adapter

# 2. Переходим в директорию
cd /tmp/trueconf-adapter

# 3. Запускаем установщик
bash install.sh
```

Установщик сам спросит:
- Адрес сервера TrueConf
- Логин и пароль бота
- Кому разрешить доступ

И автоматически установит зависимости, применит патчи и сохранит настройки.

### Если Hermes Agent установлен не в стандартную директорию

```bash
HERMES_DIR=/home/user/.hermes/hermes-agent bash install.sh
```

## Настройки (в ~/.hermes/.env)

| Переменная | Описание |
|-----------|----------|
| `TRUECONF_SERVER` | Адрес сервера TrueConf (например: video.company.com) |
| `TRUECONF_USERNAME` | Логин бота |
| `TRUECONF_PASSWORD` | Пароль бота |
| `TRUECONF_USE_SSL` | `true` для HTTPS (по умолчанию) |
| `TRUECONF_VERIFY_SSL` | `false` для самоподписанных сертификатов |
| `TRUECONF_ALLOW_ALL_USERS` | `true` — все, `false` — только разрешённые |
| `TRUECONF_ALLOWED_USERS` | Список TrueConf ID через запятую |

## После установки

```bash
# Перезапустите gateway (НЕ используйте 'restart' — может зависнуть)
hermes gateway stop && hermes gateway start

# Проверьте подключение
grep -i trueconf ~/.hermes/logs/agent.log | tail -10

# Проверьте что бот онлайн в клиенте TrueConf
```

## Защита от обновлений

Адаптер автоматически восстанавливает свои патчи после `hermes update`:

1. **apply_patches.sh** — идемпотентный патчер (17 проверок)
2. **Git hooks** — post-merge + post-checkout вызывают патчер автоматически
3. **Systemd drop-in** — ExecStartPre запускает патчер при старте gateway

```bash
# Ручной запуск патчера (если нужно)
bash ~/.hermes/plugins/trueconf-adapter/apply_patches.sh
```

## Отладка

```bash
# Проверить настройки
cat ~/.hermes/.env | grep TRUECONF

# Статус gateway
ps aux | grep "hermes.*gateway" | grep -v grep

# Логи
tail -f ~/.hermes/logs/agent.log | grep -i trueconf
```

## Структура плагина

```
hermes-trueconf-adapter/
├── apply_patches.sh          # Идемпотентный патчер (17 проверок)
├── install.sh                # Интерактивный установщик
├── README.md                 # Документация (русский)
├── README_EN.md              # Documentation (English)
├── dotenv.template           # Шаблон .env
├── gateway/platforms/
│   └── trueconf.py           # Основной адаптер (1360+ строк)
├── lib_patches/
│   ├── bot.py                # Патч библиотеки (download_file_by_id)
│   └── parser.py             # Патч парсера
└── patches/
    ├── config.py.patch
    ├── platforms.py.patch
    └── send_message_tool.py.patch
```

## Устранение неполадок

| Проблема | Решение |
|----------|---------|
| `externally-managed-environment` | Установщик использует venv pip, это не должно произойти |
| Бот моргает/уходит в офлайн | Обновлено в v2.0.0 — исправлен мониторинг WebSocket |
| `ImportError: cannot import name 'AsyncClient'` | `pip install httpx==0.28.1` — конфликт версий httpx |
| `KeyError: 'trueconf'` | Перезапустите `bash ~/.hermes/plugins/trueconf-adapter/apply_patches.sh` |
| Бот не отвечает на сообщения | Проверьте `TRUECONF_ALLOW_ALL_USERS` или добавьте свой ID в `TRUECONF_ALLOWED_USERS` |
| `hermes gateway restart` зависает | Используйте `hermes gateway stop && hermes gateway start` |

## Лицензия

MIT
