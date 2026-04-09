#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  Skyport Panel Installer
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

trap 'abort_with_log "Installation failed unexpectedly at line $LINENO."' ERR

# ── Preflight ────────────────────────────────────────────────

banner "Panel Installer                                         "

check_root
check_os
check_disk_space 2000 "$INSTALL_DIR"
check_memory

echo ""
> "$LOG_FILE"

# ── Existing installation check ──────────────────────────────

if [[ -f "$INSTALL_DIR/artisan" ]]; then
    warn "An existing Skyport installation was found at $INSTALL_DIR."
    echo ""
    if ask_yes_no "Remove it and start fresh?" "n"; then
        systemctl stop skyport-panel skyport-queue skyport-ssr 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
        success "Removed existing installation."
    else
        error "Installation cancelled. Remove $INSTALL_DIR first or choose a different path."
        exit 1
    fi
fi

# ── Release channel ──────────────────────────────────────────

step "Release channel"

CHANNEL_CHOICE=$(ask_choice "Which release channel?" "Stable (latest release — recommended)" "Bleeding edge (main branch)")
if [[ "$CHANNEL_CHOICE" == "2" ]]; then
    CHANNEL="edge"
    warn "Bleeding edge uses the latest commit on main."
    warn "This may contain bugs or incomplete features."
    echo ""
    if ! ask_yes_no "Continue with bleeding edge?" "n"; then
        CHANNEL="stable"
    fi
else
    CHANNEL="stable"
fi
success "Channel: $CHANNEL"

# ── Domain & SSL ─────────────────────────────────────────────

step "Web server configuration"

if ask_yes_no "Set up with a domain name (with SSL)?" "y"; then
    FQDN=$(ask "Domain name" "panel.example.com")
    while [[ -z "$FQDN" || "$FQDN" == "panel.example.com" ]] && ! ask_yes_no "Use 'panel.example.com' as the actual domain?" "n"; do
        FQDN=$(ask "Domain name")
    done
    APP_URL="https://${FQDN}"
    USE_SSL=true
    LISTEN_PORT=""
    info "Will configure Nginx + Let's Encrypt for $FQDN"
else
    LISTEN_PORT=$(ask "Port to listen on" "8080")
    # Validate port
    while ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [[ "$LISTEN_PORT" -lt 1 || "$LISTEN_PORT" -gt 65535 ]]; do
        warn "Invalid port. Enter a number between 1 and 65535."
        LISTEN_PORT=$(ask "Port to listen on" "8080")
    done
    if ! check_port_available "$LISTEN_PORT"; then
        warn "Port $LISTEN_PORT is already in use."
        if ! ask_yes_no "Continue anyway?" "n"; then
            LISTEN_PORT=$(ask "Port to listen on" "8080")
        fi
    fi
    FQDN=""
    APP_URL="http://$(hostname -I | awk '{print $1}'):${LISTEN_PORT}"
    USE_SSL=false
    info "Will configure Nginx on port $LISTEN_PORT"
fi

# ── Database ─────────────────────────────────────────────────

step "Database"

DB_CHOICE=$(ask_choice "Database engine" "SQLite (simple, no setup)" "MySQL / MariaDB (existing server)")
if [[ "$DB_CHOICE" == "2" ]]; then
    DB_CONNECTION="mysql"
    DB_HOST=$(ask "Database host" "127.0.0.1")
    DB_PORT=$(ask "Database port" "3306")
    DB_DATABASE=$(ask "Database name" "skyport")
    DB_USERNAME=$(ask "Database username" "skyport")
    DB_PASSWORD=$(ask_password "Database password")

    # Test connection if PHP is available
    if check_command php; then
        info "Testing database connection..."
        if php -r "try { new PDO('mysql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_DATABASE}', '${DB_USERNAME}', '${DB_PASSWORD}'); echo 'ok'; } catch(Exception \$e) { echo 'fail: ' . \$e->getMessage(); exit(1); }" 2>/dev/null; then
            success "Database connection successful"
        else
            warn "Could not connect to the database."
            warn "The installer will continue, but migrations may fail."
            if ! ask_yes_no "Continue anyway?" "y"; then
                exit 1
            fi
        fi
    fi
else
    DB_CONNECTION="sqlite"
    DB_HOST="" DB_PORT="" DB_DATABASE="" DB_USERNAME="" DB_PASSWORD=""
fi
success "Database: $DB_CONNECTION"

# ── Admin user ───────────────────────────────────────────────

step "Administrator account"

ADMIN_NAME=$(ask "Admin name" "Admin")
ADMIN_EMAIL=$(ask "Admin email" "admin@example.com")
while [[ ! "$ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
    warn "Please enter a valid email address."
    ADMIN_EMAIL=$(ask "Admin email")
done
ADMIN_PASSWORD=$(ask_password "Admin password")
while [[ ${#ADMIN_PASSWORD} -lt 8 ]]; do
    warn "Password must be at least 8 characters."
    ADMIN_PASSWORD=$(ask_password "Admin password")
done
success "Admin: $ADMIN_EMAIL"

# ── Confirm ──────────────────────────────────────────────────

step "Installation summary"

info "Channel:    ${CHANNEL}"
if $USE_SSL; then
    info "URL:        ${APP_URL} (with Let's Encrypt)"
else
    info "URL:        ${APP_URL}"
fi
info "Database:   ${DB_CONNECTION}"
info "Admin:      ${ADMIN_EMAIL}"
info "Install to: ${INSTALL_DIR}"
echo ""

if ! ask_yes_no "Begin installation?" "y"; then
    info "Installation cancelled."
    exit 0
fi

# ── System packages ──────────────────────────────────────────

step "Installing system dependencies"

run_step "Updating package lists" apt-get update -y

install_base_packages() {
    local packages=(curl gnupg2 ca-certificates lsb-release unzip git nginx)
    # Only add apt-transport-https on older systems
    if [[ ! -f /usr/share/doc/apt/changelog.gz ]] || dpkg --compare-versions "$(dpkg -s apt 2>/dev/null | grep ^Version | awk '{print $2}')" lt "2.0"; then
        packages+=(apt-transport-https)
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

run_step "Installing base packages" install_base_packages

install_php_packages() {
    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "$ID" == "ubuntu" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
        add-apt-repository -y ppa:ondrej/php
    else
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor --yes -o /usr/share/keyrings/sury-php.gpg
        local codename
        codename=$(lsb_release -sc)
        if ! curl -fsSL --head "https://packages.sury.org/php/dists/${codename}/Release" >/dev/null 2>&1; then
            codename="bookworm"
        fi
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${codename} main" > /etc/apt/sources.list.d/sury-php.list
    fi

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php8.4-cli php8.4-common php8.4-curl php8.4-mbstring \
        php8.4-xml php8.4-zip php8.4-bcmath php8.4-sqlite3 \
        php8.4-mysql php8.4-swoole php8.4-readline php8.4-gd php8.4-intl
}

run_step "Installing PHP 8.4 + Swoole" install_php_packages

# Verify PHP installed correctly
if ! php -v >> "$LOG_FILE" 2>&1; then
    abort_with_log "PHP 8.4 installation failed."
fi

# ── Composer ─────────────────────────────────────────────────

install_composer() {
    if check_command composer; then return 0; fi
    local expected_sig actual_sig
    expected_sig=$(curl -fsSL --retry 3 https://composer.github.io/installer.sig)
    curl -fsSL --retry 3 https://getcomposer.org/installer -o /tmp/composer-setup.php
    actual_sig=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
    if [[ "$expected_sig" != "$actual_sig" ]]; then
        echo "Composer installer signature mismatch" >&2
        rm -f /tmp/composer-setup.php
        return 1
    fi
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
}

run_step "Installing Composer" install_composer

# ── Bun ──────────────────────────────────────────────────────

install_bun() {
    if check_command bun; then return 0; fi
    curl -fsSL --retry 3 https://bun.sh/install | bash
    [[ -f "$HOME/.bun/bin/bun" ]] && ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
}

run_step "Installing Bun" install_bun
export PATH="/usr/local/bin:$HOME/.bun/bin:$PATH"

if ! check_command bun; then
    abort_with_log "Bun installation failed."
fi

# ── Node.js (for SSR) ───────────────────────────────────────

install_node() {
    local need_install=true
    if check_command node; then
        local current_major
        current_major=$(node -v 2>/dev/null | grep -oP '^v\K\d+' || echo "0")
        if [[ "$current_major" -ge 22 ]]; then
            need_install=false
        else
            echo "Node.js v${current_major} is too old, upgrading to v22..." >> "$LOG_FILE"
        fi
    fi
    if $need_install; then
        curl -fsSL --retry 3 https://deb.nodesource.com/setup_22.x | bash -
        DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    fi
}

run_step "Installing Node.js (SSR runtime)" install_node

# ── Download panel ───────────────────────────────────────────

step "Downloading Skyport Panel"

download_panel() {
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    if [[ "$CHANNEL" == "stable" ]]; then
        local tag
        tag=$(latest_github_release "skyportsh/panel")
        if [[ -n "$tag" ]]; then
            curl -fsSL --retry 3 "https://github.com/skyportsh/panel/archive/refs/tags/${tag}.tar.gz" \
                | tar -xz --strip-components=1 -C "$INSTALL_DIR"
            return 0
        fi
    fi
    # Edge channel or no stable release — clone main
    git clone --depth 1 https://github.com/skyportsh/panel.git "$INSTALL_DIR"
}

run_step "Downloading panel ($CHANNEL)" download_panel

if [[ ! -f "$INSTALL_DIR/artisan" ]]; then
    abort_with_log "Panel download failed — artisan file not found."
fi

# ── Install dependencies ─────────────────────────────────────

step "Installing application dependencies"

install_php_deps() {
    cd "$INSTALL_DIR"
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --optimize-autoloader --no-progress
}

install_js_deps() {
    cd "$INSTALL_DIR"
    bun install --frozen-lockfile 2>/dev/null || bun install
}

run_step "Installing PHP dependencies" install_php_deps
run_step "Installing JS dependencies" install_js_deps

# ── Configure environment ────────────────────────────────────

step "Configuring application"

configure_env() {
    cd "$INSTALL_DIR"

    cp .env.example .env
    php artisan key:generate --no-interaction --force

    local env_args=(--url="$APP_URL" --db-connection="$DB_CONNECTION")
    if [[ "$DB_CONNECTION" == "mysql" ]]; then
        env_args+=(
            --db-host="$DB_HOST" --db-port="$DB_PORT"
            --db-database="$DB_DATABASE" --db-username="$DB_USERNAME"
            --db-password="$DB_PASSWORD"
        )
    fi

    php artisan environment:setup "${env_args[@]}" --no-interaction

    if [[ "$DB_CONNECTION" == "sqlite" ]]; then
        touch database/database.sqlite
    fi

    # Ensure trailing newline
    sed -i -e '$a\' .env

    # Octane server
    if grep -q "^OCTANE_SERVER=" .env; then
        sed -i "s/^OCTANE_SERVER=.*/OCTANE_SERVER=swoole/" .env
    else
        echo "OCTANE_SERVER=swoole" >> .env
    fi

    # Reverse proxy trust
    echo "TRUSTED_PROXIES=*" >> .env

    # ASSET_URL for SSL (prevents mixed content)
    if $USE_SSL; then
        echo "ASSET_URL=${APP_URL}" >> .env
    fi
}

run_step "Configuring environment" configure_env

# ── Database & Assets ────────────────────────────────────────

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

create_admin_user() {
    cd "$INSTALL_DIR"
    php artisan user:create \
        --name="$ADMIN_NAME" --email="$ADMIN_EMAIL" \
        --password="$ADMIN_PASSWORD" --admin --no-interaction
}

run_step "Running database migrations" run_migrations || abort_with_log "Database migrations failed. Check your database configuration."
run_step "Generating route bindings" generate_wayfinder
run_step "Building frontend assets (this takes a minute)" build_assets || abort_with_log "Asset build failed."
run_step "Creating admin user" create_admin_user

# ── Permissions ──────────────────────────────────────────────

set_permissions() {
    cd "$INSTALL_DIR"
    chown -R "$PANEL_USER:$PANEL_GROUP" .
    chmod -R 755 storage bootstrap/cache
    if [[ "$DB_CONNECTION" == "sqlite" && -f database/database.sqlite ]]; then
        chown "$PANEL_USER:$PANEL_GROUP" database/database.sqlite
        chmod 664 database/database.sqlite
        chown "$PANEL_USER:$PANEL_GROUP" database
        chmod 775 database
    fi
}

run_step "Setting file permissions" set_permissions

# ── SSL / Certbot ────────────────────────────────────────────

if $USE_SSL; then
    step "Setting up SSL"

    install_certbot() {
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
    }

    obtain_certificate() {
        # Stop nginx briefly so certbot can bind to 80
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone -d "$FQDN" --non-interactive --agree-tos --register-unsafely-without-email
        systemctl start nginx 2>/dev/null || true
    }

    run_step "Installing Certbot" install_certbot
    run_step "Obtaining Let's Encrypt certificate" obtain_certificate || abort_with_log "Failed to obtain SSL certificate. Make sure $FQDN points to this server and port 80 is open."
fi

# ── Nginx ────────────────────────────────────────────────────

step "Configuring Nginx"

configure_nginx() {
    local octane_port=8000

    if $USE_SSL; then
        cat > /etc/nginx/sites-available/skyport.conf <<NGINX_CONF
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${FQDN};

    ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root ${INSTALL_DIR}/public;
    client_max_body_size 256m;

    location / {
        proxy_pass http://127.0.0.1:${octane_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
NGINX_CONF
    else
        cat > /etc/nginx/sites-available/skyport.conf <<NGINX_CONF
server {
    listen ${LISTEN_PORT};
    server_name _;

    root ${INSTALL_DIR}/public;
    client_max_body_size 256m;

    location / {
        proxy_pass http://127.0.0.1:${octane_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
NGINX_CONF
    fi

    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/skyport.conf /etc/nginx/sites-enabled/skyport.conf
    nginx -t
    systemctl restart nginx
}

run_step "Configuring Nginx" configure_nginx || abort_with_log "Nginx configuration failed."

# ── Systemd services ─────────────────────────────────────────

step "Creating systemd services"

create_services() {
    cat > /etc/systemd/system/skyport-panel.service <<SERVICE
[Unit]
Description=Skyport Panel (Octane)
After=network.target

[Service]
User=${PANEL_USER}
Group=${PANEL_GROUP}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/php artisan octane:start --server=swoole --host=127.0.0.1 --port=8000
ExecReload=/usr/bin/php artisan octane:reload
Restart=always
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
SERVICE

    cat > /etc/systemd/system/skyport-queue.service <<SERVICE
[Unit]
Description=Skyport Queue Worker
After=network.target skyport-panel.service

[Service]
User=${PANEL_USER}
Group=${PANEL_GROUP}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/php artisan queue:work --tries=3 --timeout=60
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

    cat > /etc/systemd/system/skyport-ssr.service <<SERVICE
[Unit]
Description=Skyport Inertia SSR
After=network.target

[Service]
User=${PANEL_USER}
Group=${PANEL_GROUP}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/php artisan inertia:start-ssr
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable skyport-panel skyport-queue skyport-ssr
    systemctl restart skyport-panel skyport-queue skyport-ssr
}

run_step "Creating and starting services" create_services

# Wait for services to stabilize
sleep 3

# Verify services
FAILED_SERVICES=""
for svc in skyport-panel skyport-queue skyport-ssr; do
    if ! systemctl is-active --quiet "$svc"; then
        FAILED_SERVICES="$FAILED_SERVICES $svc"
    fi
done

if [[ -n "$FAILED_SERVICES" ]]; then
    warn "Some services may still be starting:$FAILED_SERVICES"
    info "Check with: systemctl status <service>"
else
    success "All services are running"
fi

# ── Done ─────────────────────────────────────────────────────

trap - ERR

step "Installation complete"

echo ""
echo -e "  ${ORANGE}╭──────────────────────────────────────────────────────╮${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${WHITE}Skyport Panel is now running!${RESET}                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}URL:${RESET}   ${ORANGE_DARK}${APP_URL}${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Admin:${RESET} ${ORANGE_DARK}${ADMIN_EMAIL}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Services:${RESET}                                          ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}systemctl status skyport-panel${RESET}                 ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}systemctl status skyport-queue${RESET}                 ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}systemctl status skyport-ssr${RESET}                   ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Logs:${RESET} ${DIM}${LOG_FILE}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
