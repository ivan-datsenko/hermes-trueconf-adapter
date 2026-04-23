![trueconf-adapter-logo](https://github.com/ivan-datsenko/hermes-trueconf-adapter/blob/main/trueconf-adapter.jpg)



# 🔌TrueConf Adapter for Hermes-Agent🤖

[English](README_EN.md) | Русский

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Status](https://img.shields.io/badge/status-production--ready-brightgreen)

Адаптер [TrueConf](https://trueconf.com/) для [Hermes Agent](https://github.com/NousResearch/hermes-agent) — позволяет общаться с AI-агентом через TrueConf.

## Возможности

| Функция | Статус |
|---------|--------|
| Текстовые сообщения | ✅ |
| Slash-команды (/help, /new, /reset) | ✅ |
| Отправка изображений (URL + файлы) | ✅ |
| Получение изображений (vision) | ✅ |
| Отправка и получение файлов | ✅ |
| Reply threading | ✅ |
| Контроль доступа | ✅ |
| Edit message | ✅ |
| Outbound sending (`hermes send`) | ✅ |
| Auto-repair после `hermes update` | ✅ |

## Установка за 1 минуту

```bash
git clone https://github.com/ivan-datsenko/hermes-trueconf-adapter.git /tmp/trueconf-adapter
cd /tmp/trueconf-adapter
bash install.sh
```

**Скрипт сам спросит:**
- Адрес сервера TrueConf
- Логин и пароль бота
- Кому разрешить доступ

Автоматически установит, настроит и сохранит все данные.

## Настройки (в ~/.hermes/.env)

| Переменная | Описание |
|-----------|----------|
| `TRUECONF_SERVER` | Сервер TrueConf |
| `TRUECONF_USERNAME` | Логин бота |
| `TRUECONF_PASSWORD` | Пароль бота |
| `TRUECONF_USE_SSL` | `true` для HTTPS (по умолчанию) |
| `TRUECONF_VERIFY_SSL` | `false` для самоподписанных сертификатов |
| `TRUECONF_ALLOW_ALL_USERS` | `true` — все, `false` — только разрешённые |
| `TRUECONF_ALLOWED_USERS` | Список email через запятую |

## Защита от обновлений

Адаптер автоматически восстанавливает свои патчи после `hermes update`:

1. **apply_patches.sh** — идемпотентный патчер (18 проверок)
2. **Git hooks** — post-merge + post-checkout вызывают патчер автоматически
3. **Systemd drop-in** — ExecStartPre запускает патчер при старте gateway

```bash
# Ручной запуск патчера (если нужно)
bash ~/.hermes/plugins/trueconf-adapter/apply_patches.sh
```

## Перезапуск

```bash
hermes gateway stop && hermes gateway start
```

## Проверка

```bash
grep trueconf ~/.hermes/logs/agent.log | tail -20
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
├── apply_patches.sh          # Идемпотентный патчер (18 проверок)
├── install.sh                # Интерактивный установщик
├── README.md                 # Документация (русский)
├── README_EN.md              # Documentation (English)
├── dotenv.template           # Шаблон .env
├── gateway/platforms/
│   └── trueconf.py           # Основной адаптер (1270+ строк)
├── lib_patches/
│   ├── bot.py                # Патч библиотеки (download_file_by_id)
│   └── parser.py             # Патч парсера
└── patches/
    ├── config.py.patch
    ├── platforms.py.patch
    └── send_message_tool.py.patch
```

## Лицензия

MIT
