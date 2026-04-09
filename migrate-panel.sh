#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  Pterodactyl → Skyport Panel Migration
# ──────────────────────────────────────────────────────────────

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$INSTALLER_DIR/lib/ui.sh" ]]; then
    INSTALLER_DIR=$(mktemp -d)
    mkdir -p "$INSTALLER_DIR/lib"
    apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl >/dev/null 2>&1
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/ui.sh" -o "$INSTALLER_DIR/lib/ui.sh"
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/migrate-data.php" -o "$INSTALLER_DIR/lib/migrate-data.php"
fi
source "$INSTALLER_DIR/lib/ui.sh"

SKYPORT_DIR="/var/www/skyport"
LOG_FILE="/tmp/skyport-migrate.log"

trap 'abort_with_log "Migration failed at line $LINENO."' ERR

# ── Banner ───────────────────────────────────────────────────

banner "Pterodactyl → Skyport Migration                         "

check_root

echo ""
> "$LOG_FILE"

# ── Detect Pterodactyl ───────────────────────────────────────

step "Detecting Pterodactyl installation"

PTERO_DIR=""
PTERO_ENV=""

for candidate in /var/www/pterodactyl /var/www/pelican /var/www/panel; do
    if [[ -f "$candidate/artisan" ]] && [[ -f "$candidate/.env" ]]; then
        PTERO_DIR="$candidate"
        PTERO_ENV="$candidate/.env"
        break
    fi
done

if [[ -z "$PTERO_DIR" ]]; then
    error "No Pterodactyl/Pelican installation found."
    info "Looked in /var/www/pterodactyl, /var/www/pelican, /var/www/panel"
    exit 1
fi

success "Found Pterodactyl at $PTERO_DIR"

# ── Read database config ─────────────────────────────────────

step "Reading database configuration"

read_env() {
    local key="$1" file="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

PTERO_DB_HOST=$(read_env "DB_HOST" "$PTERO_ENV")
PTERO_DB_PORT=$(read_env "DB_PORT" "$PTERO_ENV")
PTERO_DB_NAME=$(read_env "DB_DATABASE" "$PTERO_ENV")
PTERO_DB_USER=$(read_env "DB_USERNAME" "$PTERO_ENV")
PTERO_DB_PASS=$(read_env "DB_PASSWORD" "$PTERO_ENV")

PTERO_DB_HOST="${PTERO_DB_HOST:-127.0.0.1}"
PTERO_DB_PORT="${PTERO_DB_PORT:-3306}"

info "Host: $PTERO_DB_HOST:$PTERO_DB_PORT"
info "Database: $PTERO_DB_NAME"
info "User: $PTERO_DB_USER"

# Test connection
if ! MYSQL_PWD="$PTERO_DB_PASS" mysql -u"$PTERO_DB_USER" -h"$PTERO_DB_HOST" -P"$PTERO_DB_PORT" "$PTERO_DB_NAME" -e "SELECT 1" >/dev/null 2>&1; then
    error "Cannot connect to Pterodactyl database."
    exit 1
fi

success "Database connection OK"

# ── Count records ────────────────────────────────────────────

ptero_query() {
    MYSQL_PWD="$PTERO_DB_PASS" mysql -u"$PTERO_DB_USER" -h"$PTERO_DB_HOST" -P"$PTERO_DB_PORT" "$PTERO_DB_NAME" -sN -e "$1" 2>/dev/null
}

USER_COUNT=$(ptero_query "SELECT COUNT(*) FROM users")
LOCATION_COUNT=$(ptero_query "SELECT COUNT(*) FROM locations")
NODE_COUNT=$(ptero_query "SELECT COUNT(*) FROM nodes")
EGG_COUNT=$(ptero_query "SELECT COUNT(*) FROM eggs")
ALLOC_COUNT=$(ptero_query "SELECT COUNT(*) FROM allocations")
SERVER_COUNT=$(ptero_query "SELECT COUNT(*) FROM servers")

step "Pterodactyl data summary"

info "Users:       $USER_COUNT"
info "Locations:   $LOCATION_COUNT"
info "Nodes:       $NODE_COUNT"
info "Eggs:        $EGG_COUNT (→ cargo)"
info "Allocations: $ALLOC_COUNT"
info "Servers:     $SERVER_COUNT"

# ── Check Skyport ─────────────────────────────────────────────

step "Checking Skyport installation"

if [[ ! -f "$SKYPORT_DIR/artisan" ]]; then
    error "Skyport panel not found at $SKYPORT_DIR."
    info "Install the Skyport panel first, then run this migration."
    exit 1
fi

success "Found Skyport at $SKYPORT_DIR"

# ── Confirm ──────────────────────────────────────────────────

step "Ready to migrate"

warn "This will import Pterodactyl data into your Skyport panel."
warn "Existing Skyport data will NOT be deleted, but conflicts may occur."
warn "User passwords are preserved — users can log in with their existing credentials."
echo ""

if ! ask_yes_no "Continue with migration?" "y"; then
    info "Migration cancelled."
    exit 0
fi

# ── Copy PHP migration helper ────────────────────────────────

step "Running migration"

MIGRATE_PHP="$INSTALLER_DIR/lib/migrate-data.php"
if [[ ! -f "$MIGRATE_PHP" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/migrate-data.php" -o "$SKYPORT_DIR/migrate-data.php"
    MIGRATE_PHP="$SKYPORT_DIR/migrate-data.php"
else
    cp "$MIGRATE_PHP" "$SKYPORT_DIR/migrate-data.php"
fi

# Run the PHP migration
cd "$SKYPORT_DIR"
MIGRATION_OUTPUT=$(PTERO_DB_PASS="$PTERO_DB_PASS" php migrate-data.php "$PTERO_DB_HOST" "$PTERO_DB_PORT" "$PTERO_DB_NAME" "$PTERO_DB_USER" 2>> "$LOG_FILE")

# Parse results
MIGRATED_USERS=$(echo "$MIGRATION_OUTPUT" | grep "^users=" | cut -d= -f2)
MIGRATED_LOCATIONS=$(echo "$MIGRATION_OUTPUT" | grep "^locations=" | cut -d= -f2)
MIGRATED_NODES=$(echo "$MIGRATION_OUTPUT" | grep "^nodes=" | cut -d= -f2)
MIGRATED_EGGS=$(echo "$MIGRATION_OUTPUT" | grep "^cargo=" | cut -d= -f2)
MIGRATED_ALLOCS=$(echo "$MIGRATION_OUTPUT" | grep "^allocations=" | cut -d= -f2)
MIGRATED_SERVERS=$(echo "$MIGRATION_OUTPUT" | grep "^servers=" | cut -d= -f2)

success "Users:       ${MIGRATED_USERS:-0}"
success "Locations:   ${MIGRATED_LOCATIONS:-0}"
success "Nodes:       ${MIGRATED_NODES:-0}"
success "Cargo:       ${MIGRATED_EGGS:-0}"
success "Allocations: ${MIGRATED_ALLOCS:-0}"
success "Servers:     ${MIGRATED_SERVERS:-0}"

# Cleanup
rm -f "$SKYPORT_DIR/migrate-data.php"

# Fix permissions
chown -R www-data:www-data "$SKYPORT_DIR/database" 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────────

trap - ERR

step "Migration complete"

echo ""
echo -e "  ${ORANGE}╭──────────────────────────────────────────────────────╮${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${WHITE}Migration finished!${RESET}                                ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Next steps:${RESET}                                         ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}1. Enroll skyportd on each node${RESET}                ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}2. Migrate server volumes from Wings${RESET}           ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}3. Users can log in with existing passwords${RESET}    ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Log:${RESET} ${DIM}${LOG_FILE}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
