# TrueConf Adapter for Hermes Agent

English | [Русский](README.md)

![Version](https://img.shields.io/badge/version-2.0.0-blue)
![Status](https://img.shields.io/badge/status-beta-orange)

A [TrueConf](https://trueconf.com/) adapter for [Hermes Agent](https://github.com/NousResearch/hermes-agent) — communicate with your AI agent through TrueConf.

## Features

- ✅ Text messages
- ✅ Slash commands (/help, /new, /reset)
- ✅ Send and receive images
- ✅ Send and receive files
- ✅ Reply threading
- ✅ Access control
- ✅ Edit message
- ✅ Outbound sending (`hermes send`)
- ✅ Auto-reconnect on disconnect
- ✅ Auto-repair after `hermes update`

## Requirements

- **Hermes Agent** installed and configured (`hermes setup` completed)
- **TrueConf Server** with a bot account created
- **Python 3.10+**

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/ivan-datsenko/hermes-trueconf-adapter.git /tmp/trueconf-adapter

# 2. Enter the directory
cd /tmp/trueconf-adapter

# 3. Run the installer
bash install.sh
```

The installer will ask you for:
- TrueConf server address
- Bot username and password
- Access control settings

It will automatically install dependencies, apply patches, and save your settings.

### Non-standard Hermes installation path

```bash
HERMES_DIR=/home/user/.hermes/hermes-agent bash install.sh
```

## Configuration (in ~/.hermes/.env)

| Variable | Description |
|----------|-------------|
| `TRUECONF_SERVER` | TrueConf server address (e.g. video.company.com) |
| `TRUECONF_USERNAME` | Bot username |
| `TRUECONF_PASSWORD` | Bot password |
| `TRUECONF_USE_SSL` | `true` for HTTPS (default) |
| `TRUECONF_VERIFY_SSL` | `false` for self-signed certificates |
| `TRUECONF_ALLOW_ALL_USERS` | `true` — allow all, `false` — allowlisted only |
| `TRUECONF_ALLOWED_USERS` | Comma-separated TrueConf IDs |

## After installation

```bash
# Restart the gateway (do NOT use 'restart' — it may hang)
hermes gateway stop && hermes gateway start

# Check connection
grep -i trueconf ~/.hermes/logs/agent.log | tail -10

# Verify the bot is online in TrueConf client
```

## Update protection

The adapter automatically restores its patches after `hermes update`:

1. **apply_patches.sh** — idempotent patcher (17 checks)
2. **Git hooks** — post-merge + post-checkout run the patcher automatically
3. **Systemd drop-in** — ExecStartPre runs the patcher on gateway start

```bash
# Manual patch run (if needed)
bash ~/.hermes/plugins/trueconf-adapter/apply_patches.sh
```

## Debugging

```bash
# Check configuration
cat ~/.hermes/.env | grep TRUECONF

# Gateway status
ps aux | grep "hermes.*gateway" | grep -v grep

# Logs
tail -f ~/.hermes/logs/agent.log | grep -i trueconf
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Bot flickers/goes offline | Fixed in v2.0.0 — WebSocket monitoring corrected |
| `ImportError: cannot import name 'AsyncClient'` | `pip install httpx==0.28.1` — httpx version conflict |
| `KeyError: 'trueconf'` | Re-run `bash ~/.hermes/plugins/trueconf-adapter/apply_patches.sh` |
| Bot doesn't respond to messages | Check `TRUECONF_ALLOW_ALL_USERS` or add your ID to `TRUECONF_ALLOWED_USERS` |
| `hermes gateway restart` hangs | Use `hermes gateway stop && hermes gateway start` instead |

## License

MIT
