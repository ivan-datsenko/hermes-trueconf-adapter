# TrueConf Adapter for Hermes Agent

English | [Русский](README.md)

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Status](https://img.shields.io/badge/status-production--ready-brightgreen)

A [TrueConf](https://trueconf.com/) adapter for [Hermes Agent](https://github.com/NousResearch/hermes-agent) — lets you talk to your AI agent via TrueConf.

## Features

| Feature | Status |
|---------|--------|
| Text messages | ✅ |
| Slash commands (/help, /new, /reset) | ✅ |
| Send images (URL + files) | ✅ |
| Receive images (vision) | ✅ |
| Send and receive files | ✅ |
| Reply threading | ✅ |
| Access control | ✅ |
| Edit message | ✅ |
| Outbound sending (`hermes send`) | ✅ |
| Auto-repair after `hermes update` | ✅ |

## Install in 1 minute

```bash
git clone https://github.com/ivan-datsenko/hermes-trueconf-adapter.git /tmp/trueconf-adapter
cd /tmp/trueconf-adapter
bash install.sh
```

**The script will ask you for:**
- TrueConf server address
- Bot login and password
- Who can access the bot

It will install, configure and save everything automatically.

## Settings (in ~/.hermes/.env)

| Variable | Description |
|----------|-------------|
| `TRUECONF_SERVER` | TrueConf server address |
| `TRUECONF_USERNAME` | Bot login |
| `TRUECONF_PASSWORD` | Bot password |
| `TRUECONF_USE_SSL` | `true` for HTTPS (default) |
| `TRUECONF_VERIFY_SSL` | `false` for self-signed certificates |
| `TRUECONF_ALLOW_ALL_USERS` | `true` — everyone, `false` — whitelist only |
| `TRUECONF_ALLOWED_USERS` | Comma-separated list of allowed emails |

## Update protection

The adapter automatically restores its patches after `hermes update`:

1. **apply_patches.sh** — idempotent patcher (18 checks)
2. **Git hooks** — post-merge + post-checkout run the patcher automatically
3. **Systemd drop-in** — ExecStartPre runs the patcher on gateway start

```bash
# Manual patcher run (if needed)
bash ~/.hermes/plugins/trueconf-adapter/apply_patches.sh
```

## Restart

```bash
hermes gateway stop && hermes gateway start
```

## Verify

```bash
grep trueconf ~/.hermes/logs/agent.log | tail -20
```

## Debug

```bash
# Check settings
cat ~/.hermes/.env | grep TRUECONF

# Gateway status
ps aux | grep "hermes.*gateway" | grep -v grep

# Logs
tail -f ~/.hermes/logs/agent.log | grep -i trueconf
```

## Plugin structure

```
hermes-trueconf-adapter/
├── apply_patches.sh          # Idempotent patcher (18 checks)
├── install.sh                # Interactive installer
├── README.md                 # Documentation (Russian)
├── README_EN.md              # Documentation (English)
├── dotenv.template           # .env template
├── gateway/platforms/
│   └── trueconf.py           # Main adapter (1270+ lines)
├── lib_patches/
│   ├── bot.py                # Library patch (download_file_by_id)
│   └── parser.py             # Parser patch
└── patches/
    ├── config.py.patch
    ├── platforms.py.patch
    └── send_message_tool.py.patch
```

## License

MIT
