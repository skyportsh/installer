#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  Skyport Panel Installer
# ──────────────────────────────────────────────────────────────

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow running via curl pipe by downloading lib first
if [[ ! -f "$INSTALLER_DIR/lib/ui.sh" ]]; then
    INSTALLER_DIR=$(mktemp -d)
    mkdir -p "$INSTALLER_DIR/lib"
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/ui.sh" -o "$INSTALLER_DIR/lib/ui.sh"
fi

source "$INSTALLER_DIR/lib/ui.sh"

INSTALL_DIR="/var/www/skyport"
PANEL_USER="www-data"
PANEL_GROUP="www-data"

# ── Preflight ────────────────────────────────────────────────

banner "Panel Installer                                         "

check_root
check_os

echo ""
> /tmp/skyport-install.log

# ── Release channel ──────────────────────────────────────────

step "Release channel"

CHANNEL_CHOICE=$(ask_choice "Which release channel?" "Stable (latest release — recommended)" "Bleeding edge (main branch)")

if [[ "$CHANNEL_CHOICE" == "2" ]]; then
    CHANNEL="edge"
    warn "Bleeding edge uses the latest commit on main."
    warn "This may contain bugs or incomplete features."
    echo ""
    if ! ask_yes_no "Continue with bleeding edge?" "n"; then
        info "Switching to stable."
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
    APP_URL="https://${FQDN}"
    USE_SSL=true
    info "Will configure Nginx + Let's Encrypt for $FQDN"
else
    LISTEN_PORT=$(ask "Port to listen on" "8080")
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
else
    DB_CONNECTION="sqlite"
    DB_HOST="" DB_PORT="" DB_DATABASE="" DB_USERNAME="" DB_PASSWORD=""
fi

success "Database: $DB_CONNECTION"

# ── Admin user ───────────────────────────────────────────────

step "Administrator account"

ADMIN_NAME=$(ask "Admin name" "Admin")
ADMIN_EMAIL=$(ask "Admin email" "admin@example.com")
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
    apt-get install -y curl gnupg2 ca-certificates lsb-release unzip git nginx
}

run_step "Installing base packages" install_base_packages

install_php_packages() {
    source /etc/os-release

    if [[ "$ID" == "ubuntu" ]]; then
        apt-get install -y software-properties-common
        add-apt-repository -y ppa:ondrej/php
    else
        # Debian — use sury.org
        apt-get install -y apt-transport-https
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg 2>/dev/null || true
        local codename
        codename=$(lsb_release -sc)
        # Debian 13 (trixie) may not have a sury release yet — fall back to bookworm
        if ! curl -fsSL "https://packages.sury.org/php/dists/${codename}/Release" >/dev/null 2>&1; then
            codename="bookworm"
        fi
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${codename} main" > /etc/apt/sources.list.d/sury-php.list
    fi

    apt-get update -y
    apt-get install -y \
        php8.4-cli \
        php8.4-common \
        php8.4-curl \
        php8.4-mbstring \
        php8.4-xml \
        php8.4-zip \
        php8.4-bcmath \
        php8.4-sqlite3 \
        php8.4-mysql \
        php8.4-swoole \
        php8.4-readline \
        php8.4-gd \
        php8.4-intl
}

run_step "Installing PHP 8.4 + Swoole" install_php_packages

# ── Composer ─────────────────────────────────────────────────

install_composer() {
    if ! command -v composer &>/dev/null; then
        curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi
}

run_step "Installing Composer" install_composer

# ── Bun ──────────────────────────────────────────────────────

install_bun() {
    if ! command -v bun &>/dev/null; then
        curl -fsSL https://bun.sh/install | bash
    fi
    # Symlink to system path
    if [[ -f "$HOME/.bun/bin/bun" ]]; then
        ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
    fi
}

run_step "Installing Bun" install_bun
export PATH="/usr/local/bin:$HOME/.bun/bin:$PATH"

# ── Node.js (for SSR) ───────────────────────────────────────

install_node() {
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
    fi
}

run_step "Installing Node.js (SSR runtime)" install_node

# ── Download panel ───────────────────────────────────────────

step "Downloading Skyport Panel"

download_panel() {
    if [[ -d "$INSTALL_DIR/.git" ]] || [[ -f "$INSTALL_DIR/artisan" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR"

    if [[ "$CHANNEL" == "stable" ]]; then
        local tag
        tag=$(latest_github_release "skyportsh/panel")
        if [[ -z "$tag" ]]; then
            git clone --depth 1 https://github.com/skyportsh/panel.git "$INSTALL_DIR"
        else
            curl -fsSL "https://github.com/skyportsh/panel/archive/refs/tags/${tag}.tar.gz" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
        fi
    else
        git clone --depth 1 https://github.com/skyportsh/panel.git "$INSTALL_DIR"
    fi
}

run_step "Downloading panel ($CHANNEL)" download_panel

# ── Install dependencies ─────────────────────────────────────

step "Installing application dependencies"

install_php_deps() {
    cd "$INSTALL_DIR"
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --optimize-autoloader
}

install_js_deps() {
    cd "$INSTALL_DIR"
    bun install
}

run_step "Installing PHP dependencies" install_php_deps
run_step "Installing JS dependencies" install_js_deps

# ── Configure environment ────────────────────────────────────

step "Configuring environment"

configure_env() {
    cd "$INSTALL_DIR"

    cp .env.example .env
    php artisan key:generate --no-interaction --force

    local env_args=(
        --url="$APP_URL"
        --db-connection="$DB_CONNECTION"
    )

    if [[ "$DB_CONNECTION" == "mysql" ]]; then
        env_args+=(
            --db-host="$DB_HOST"
            --db-port="$DB_PORT"
            --db-database="$DB_DATABASE"
            --db-username="$DB_USERNAME"
            --db-password="$DB_PASSWORD"
        )
    fi

    php artisan environment:setup "${env_args[@]}" --no-interaction

    if [[ "$DB_CONNECTION" == "sqlite" ]]; then
        touch database/database.sqlite
    fi

    # Set Octane server
    if grep -q "^OCTANE_SERVER=" .env; then
        sed -i "s/^OCTANE_SERVER=.*/OCTANE_SERVER=swoole/" .env
    else
        echo "OCTANE_SERVER=swoole" >> .env
    fi

    # Trust the local Nginx reverse proxy and set asset URL
    echo "TRUSTED_PROXIES=*" >> .env
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
        --name="$ADMIN_NAME" \
        --email="$ADMIN_EMAIL" \
        --password="$ADMIN_PASSWORD" \
        --admin \
        --no-interaction
}

run_step "Running database migrations" run_migrations
run_step "Generating route bindings" generate_wayfinder
run_step "Building frontend assets" build_assets
run_step "Creating admin user" create_admin_user

# ── Permissions ──────────────────────────────────────────────

set_permissions() {
    cd "$INSTALL_DIR"
    chown -R "$PANEL_USER:$PANEL_GROUP" .
    chmod -R 755 storage bootstrap/cache
    if [[ "$DB_CONNECTION" == "sqlite" ]]; then
        chown "$PANEL_USER:$PANEL_GROUP" database/database.sqlite
        chmod 664 database/database.sqlite
    fi
}

run_step "Setting file permissions" set_permissions

# ── SSL / Certbot ────────────────────────────────────────────

if $USE_SSL; then
    step "Setting up SSL"

    install_certbot() {
        apt-get install -y certbot python3-certbot-nginx
    }

    obtain_certificate() {
        certbot certonly --nginx -d "$FQDN" --non-interactive --agree-tos --register-unsafely-without-email
    }

    run_step "Installing Certbot" install_certbot
    run_step "Obtaining Let's Encrypt certificate" obtain_certificate
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
    listen 443 ssl http2;
    server_name ${FQDN};

    ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root ${INSTALL_DIR}/public;
    index index.php;

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
    index index.php;

    client_max_body_size 256m;

    location / {
        proxy_pass http://127.0.0.1:8000;
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
    systemctl reload nginx
}

run_step "Configuring Nginx" configure_nginx

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
    systemctl start skyport-panel skyport-queue skyport-ssr
}

run_step "Creating and starting services" create_services

# ── Done ─────────────────────────────────────────────────────

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
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Logs:${RESET} ${DIM}/tmp/skyport-install.log${RESET}                  ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
