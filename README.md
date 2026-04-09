# Skyport Installer

Official installation scripts for the Skyport Panel and skyportd daemon.

## Quick Install

**Panel:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/skyportsh/installer/main/install-panel.sh)
```

**Daemon:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/skyportsh/installer/main/install-daemon.sh)
```

## Supported Operating Systems

| OS | Versions |
|---|---|
| Ubuntu | 22.04, 24.04 |
| Debian | 11, 12, 13 |

## Panel Stack

- PHP 8.4 with Swoole
- Laravel Octane (Swoole)
- Inertia SSR (Node.js)
- Bun (asset compilation)
- SQLite (default) or MySQL/MariaDB
- Nginx reverse proxy
- Optional Let's Encrypt SSL via Certbot

## Daemon

The daemon installer downloads a pre-built binary (stable) or compiles from source (bleeding edge) and configures a systemd service.

## License

MIT
