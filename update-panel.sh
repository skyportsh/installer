#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  Skyport Panel Updater
# ──────────────────────────────────────────────────────────────

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$INSTALLER_DIR/lib/ui.sh" ]]; then
    INSTALLER_DIR=$(mktemp -d)
    mkdir -p "$INSTALLER_DIR/lib"
    apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl >/dev/null 2>&1
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/ui.sh" -o "$INSTALLER_DIR/lib/ui.sh"
fi
source "$INSTALLER_DIR/lib/ui.sh"

INSTALL_DIR="/var/www/skyport"
PANEL_USER="www-data"
PANEL_GROUP="www-data"
LOG_FILE="/tmp/skyport-update.log"

trap 'abort_with_log "Update failed at line $LINENO."' ERR

banner "Panel Updater                                           "

check_root
echo ""
> "$LOG_FILE"

# ── Check installation ───────────────────────────────────────

if [[ ! -f "$INSTALL_DIR/artisan" ]]; then
    error "No Skyport panel found at $INSTALL_DIR."
    exit 1
fi

CURRENT_VERSION=$(cd "$INSTALL_DIR" && php artisan tinker --no-interaction --execute "echo config('app.version');" 2>/dev/null || echo "unknown")
success "Found Skyport panel at $INSTALL_DIR (${CURRENT_VERSION})"

# ── Determine update source ─────────────────────────────────

step "Update source"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Installation is git-based (bleeding edge)."
    UPDATE_MODE="git"
else
    info "Installation is release-based (stable)."
    UPDATE_MODE="release"
fi

LATEST_TAG=$(latest_github_release "skyportsh/panel")

if [[ "$UPDATE_MODE" == "release" && -n "$LATEST_TAG" ]]; then
    info "Latest release: $LATEST_TAG"
elif [[ "$UPDATE_MODE" == "git" ]]; then
    info "Will pull latest from main branch."
fi

if ! ask_yes_no "Proceed with update?" "y"; then
    info "Update cancelled."
    exit 0
fi

# ── Maintenance mode ─────────────────────────────────────────

step "Preparing update"

enter_maintenance() {
    cd "$INSTALL_DIR"
    php artisan down 2>/dev/null || true
}

run_step "Entering maintenance mode" enter_maintenance

# ── Back up database ─────────────────────────────────────────

backup_db() {
    cd "$INSTALL_DIR"
    local db_conn
    db_conn=$(grep "^DB_CONNECTION=" .env | cut -d= -f2)
    local backup_dir="$INSTALL_DIR/storage/backups"
    mkdir -p "$backup_dir"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [[ "$db_conn" == "sqlite" && -f database/database.sqlite ]]; then
        cp database/database.sqlite "$backup_dir/database_${timestamp}.sqlite"
        echo "Backed up SQLite to $backup_dir/database_${timestamp}.sqlite"
    elif [[ "$db_conn" == "mysql" ]]; then
        local db_host db_port db_name db_user db_pass
        db_host=$(grep "^DB_HOST=" .env | cut -d= -f2)
        db_port=$(grep "^DB_PORT=" .env | cut -d= -f2)
        db_name=$(grep "^DB_DATABASE=" .env | cut -d= -f2)
        db_user=$(grep "^DB_USERNAME=" .env | cut -d= -f2)
        db_pass=$(grep "^DB_PASSWORD=" .env | cut -d= -f2- | sed 's/^"//;s/"$//')
        MYSQL_PWD="$db_pass" mysqldump -u"$db_user" -h"${db_host:-127.0.0.1}" -P"${db_port:-3306}" "$db_name" > "$backup_dir/database_${timestamp}.sql"
        echo "Backed up MySQL to $backup_dir/database_${timestamp}.sql"
    fi
    cp .env "$backup_dir/env_${timestamp}"
}

run_step "Backing up database and .env" backup_db

# ── Pull code ────────────────────────────────────────────────

step "Downloading update"

pull_code() {
    cd "$INSTALL_DIR"
    if [[ "$UPDATE_MODE" == "git" ]]; then
        git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
        git fetch --all --tags
        git reset --hard origin/main
    else
        if [[ -n "$LATEST_TAG" ]]; then
            local tmp_dir
            tmp_dir=$(mktemp -d)
            curl -fsSL --retry 3 "https://github.com/skyportsh/panel/archive/refs/tags/${LATEST_TAG}.tar.gz" \
                | tar -xz --strip-components=1 -C "$tmp_dir"
            # Preserve .env, database, storage, and vendor
            rsync -a --exclude='.env' --exclude='database/database.sqlite' \
                --exclude='storage/logs' --exclude='storage/backups' \
                --exclude='vendor' --exclude='node_modules' \
                "$tmp_dir/" "$INSTALL_DIR/"
            rm -rf "$tmp_dir"
        else
            error "No release found and not a git installation."
            exit 1
        fi
    fi
}

run_step "Pulling latest code" pull_code

# ── Update dependencies ──────────────────────────────────────

step "Updating dependencies"

update_php_deps() {
    cd "$INSTALL_DIR"
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --optimize-autoloader --no-progress
}

update_js_deps() {
    cd "$INSTALL_DIR"
    bun install --frozen-lockfile 2>/dev/null || bun install
}

run_step "Installing PHP dependencies" update_php_deps
run_step "Installing JS dependencies" update_js_deps

# ── Migrate & build ──────────────────────────────────────────

step "Building"

run_migrations() {
    cd "$INSTALL_DIR"
    php artisan migrate --force --no-interaction
}

generate_wayfinder() {
    cd "$INSTALL_DIR"
    php artisan wayfinder:generate --with-form --no-interaction
}

build_assets() {
    cd "$INSTALL_DIR"
    bun run build:ssr
}

clear_caches() {
    cd "$INSTALL_DIR"
    php artisan optimize:clear
}

run_step "Running migrations" run_migrations
run_step "Generating route bindings" generate_wayfinder
run_step "Building assets" build_assets
run_step "Clearing caches" clear_caches

# ── Permissions ──────────────────────────────────────────────

fix_permissions() {
    cd "$INSTALL_DIR"
    chown -R "$PANEL_USER:$PANEL_GROUP" .
    chmod -R 755 storage bootstrap/cache
    if [[ -f database/database.sqlite ]]; then
        chown "$PANEL_USER:$PANEL_GROUP" database database/database.sqlite
        chmod 775 database
        chmod 664 database/database.sqlite
    fi
}

run_step "Fixing permissions" fix_permissions

# ── Restart services ─────────────────────────────────────────

step "Restarting services"

restart_services() {
    systemctl restart skyport-panel 2>/dev/null || true
    systemctl restart skyport-queue 2>/dev/null || true
    systemctl restart skyport-ssr 2>/dev/null || true
}

exit_maintenance() {
    cd "$INSTALL_DIR"
    php artisan up 2>/dev/null || true
}

run_step "Restarting services" restart_services
run_step "Exiting maintenance mode" exit_maintenance

# Verify
sleep 2
FAILED=""
for svc in skyport-panel skyport-queue skyport-ssr; do
    if ! systemctl is-active --quiet "$svc"; then
        FAILED="$FAILED $svc"
    fi
done

if [[ -n "$FAILED" ]]; then
    warn "Some services may still be starting:$FAILED"
else
    success "All services running"
fi

NEW_VERSION=$(cd "$INSTALL_DIR" && php artisan tinker --no-interaction --execute "echo config('app.version');" 2>/dev/null || echo "unknown")

# ── Done ─────────────────────────────────────────────────────

trap - ERR

step "Update complete"

echo ""
echo -e "  ${ORANGE}╭──────────────────────────────────────────────────────╮${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${WHITE}Panel updated!${RESET}                                     ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Previous:${RESET} ${DIM}${CURRENT_VERSION}${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Current:${RESET}  ${ORANGE_DARK}${NEW_VERSION}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Backup:${RESET} ${DIM}${INSTALL_DIR}/storage/backups/${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Log:${RESET}    ${DIM}${LOG_FILE}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
