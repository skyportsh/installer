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
| Ubuntu | 24.04 |
| Debian | 13 |

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

## Updating

**Panel:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/skyportsh/installer/main/update-panel.sh)
```

**Daemon:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/skyportsh/installer/main/update-daemon.sh)
```

Both scripts back up your data before updating, handle maintenance mode, and restart services automatically.

## Migrating from Pterodactyl

If you have an existing Pterodactyl panel, install Skyport first, then run the migration script on the same machine:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/skyportsh/installer/main/migrate-panel.sh)
```

This migrates users, locations, nodes, eggs (→ cargo), allocations, and servers. User passwords are preserved so existing users can log in immediately.

## License

MIT
