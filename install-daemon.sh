#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  skyportd Daemon Installer
# ──────────────────────────────────────────────────────────────

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow running via curl pipe by downloading lib first
if [[ ! -f "$INSTALLER_DIR/lib/ui.sh" ]]; then
    INSTALLER_DIR=$(mktemp -d)
    mkdir -p "$INSTALLER_DIR/lib"
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/ui.sh" -o "$INSTALLER_DIR/lib/ui.sh"
fi

source "$INSTALLER_DIR/lib/ui.sh"

INSTALL_DIR="/etc/skyportd"
DAEMON_USER="root"

# ── Preflight ────────────────────────────────────────────────

banner "Daemon Installer                                        "

check_root
check_os

echo ""
> /tmp/skyport-install.log

# ── Architecture detection ───────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARTIFACT="skyportd-linux-x86_64" ;;
    aarch64) ARTIFACT="skyportd-linux-aarch64" ;;
    riscv64) ARTIFACT="skyportd-linux-riscv64" ;;
    *)
        error "Unsupported architecture: $ARCH"
        info "Supported: x86_64, aarch64, riscv64"
        exit 1
        ;;
esac

success "Architecture: $ARCH ($ARTIFACT)"

# ── Release channel ──────────────────────────────────────────

step "Release channel"

CHANNEL_CHOICE=$(ask_choice "Which release channel?" "Stable (latest release — recommended)" "Bleeding edge (main branch)")

if [[ "$CHANNEL_CHOICE" == "2" ]]; then
    CHANNEL="edge"
    warn "Bleeding edge uses the latest commit on main."
    warn "This may contain bugs or incomplete features."
    warn "Building from source requires Rust and may take several minutes."
    echo ""
    if ! ask_yes_no "Continue with bleeding edge?" "n"; then
        info "Switching to stable."
        CHANNEL="stable"
    fi
else
    CHANNEL="stable"
fi

success "Channel: $CHANNEL"

# ── Docker check ─────────────────────────────────────────────

step "Docker"

check_docker() {
    if command -v docker &>/dev/null; then
        local version
        version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        success "Docker found: $version"
        return 0
    fi
    return 1
}

if ! check_docker; then
    info "Docker is required for running game servers."
    echo ""

    if ask_yes_no "Install Docker?" "y"; then
        install_docker() {
            curl -fsSL https://get.docker.com | sh
        }
        run_step "Installing Docker" install_docker
    else
        warn "Docker is not installed. skyportd will not be able to manage servers."
    fi
fi

# ── Confirm ──────────────────────────────────────────────────

step "Installation summary"

info "Channel:    ${CHANNEL}"
info "Binary:     ${ARTIFACT}"
info "Install to: ${INSTALL_DIR}"
echo ""

if ! ask_yes_no "Begin installation?" "y"; then
    info "Installation cancelled."
    exit 0
fi

# ── Install daemon ───────────────────────────────────────────

step "Installing skyportd"

install_daemon_stable() {
    local tag
    tag=$(latest_github_release "skyportsh/skyportd")

    if [[ -z "$tag" ]]; then
        error "No stable release found. Try bleeding edge instead."
        exit 1
    fi

    local url="https://github.com/skyportsh/skyportd/releases/download/${tag}/${ARTIFACT}"

    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$url" -o "$INSTALL_DIR/skyportd"
    chmod +x "$INSTALL_DIR/skyportd"
}

install_daemon_edge() {
    # Install Rust if needed
    if ! command -v cargo &>/dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    local build_dir
    build_dir=$(mktemp -d)
    git clone --depth 1 https://github.com/skyportsh/skyportd.git "$build_dir"
    cd "$build_dir"
    cargo build --release
    mkdir -p "$INSTALL_DIR"
    cp target/release/skyportd "$INSTALL_DIR/skyportd"
    chmod +x "$INSTALL_DIR/skyportd"
    rm -rf "$build_dir"
}

if [[ "$CHANNEL" == "stable" ]]; then
    run_step "Downloading skyportd ($CHANNEL)" install_daemon_stable
else
    run_step "Building skyportd from source (this may take a while)" install_daemon_edge
fi

# ── Default config ───────────────────────────────────────────

setup_config() {
    mkdir -p "$INSTALL_DIR/config"
    mkdir -p "$INSTALL_DIR/volumes"

    if [[ ! -f "$INSTALL_DIR/config/default.toml" ]]; then
        cat > "$INSTALL_DIR/config/default.toml" <<'TOML'
[daemon]
name = "skyportd"
uuid = "00000000-0000-0000-0000-000000000000"
tick_interval = "5s"
shutdown_timeout = "30s"

[panel]
url = "http://127.0.0.1:8000"
configuration_token = ""

[logging]
level = "info"
format = "pretty"

[runtime]
worker_threads = 0
TOML
    fi
}

run_step "Setting up configuration" setup_config

# ── Systemd service ──────────────────────────────────────────

step "Creating systemd service"

create_service() {
    cat > /etc/systemd/system/skyportd.service <<SERVICE
[Unit]
Description=skyportd — Skyport Daemon
After=docker.service network.target
Wants=docker.service

[Service]
User=${DAEMON_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/skyportd
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable skyportd
}

run_step "Creating skyportd service" create_service

# ── Configuration prompt ─────────────────────────────────────

step "Daemon configuration"

info "skyportd needs to be configured with your panel URL"
info "and a one-time configuration token."
echo ""

if ask_yes_no "Configure skyportd now?" "y"; then
    PANEL_URL=$(ask "Panel URL" "https://panel.example.com")
    CONFIG_TOKEN=$(ask "Configuration token (from panel)")

    if [[ -n "$PANEL_URL" && -n "$CONFIG_TOKEN" ]]; then
        cat > "$INSTALL_DIR/config/local.toml" <<TOML
[panel]
url = "${PANEL_URL}"
configuration_token = "${CONFIG_TOKEN}"
TOML
        success "Configuration saved. skyportd will enroll on first start."

        info "Starting skyportd..."
        systemctl start skyportd
        sleep 3

        if systemctl is-active --quiet skyportd; then
            success "skyportd is running!"
        else
            warn "skyportd may still be configuring. Check logs:"
            info "journalctl -u skyportd -f"
        fi
    else
        warn "Missing values. You can configure later with:"
        info "skyportd --configure"
    fi
else
    info "You can configure later by running:"
    info "  cd ${INSTALL_DIR} && ./skyportd --configure"
    echo ""
    info "Or start the service (it will prompt if a terminal is attached):"
    info "  systemctl start skyportd"
fi

# ── Done ─────────────────────────────────────────────────────

step "Installation complete"

echo ""
echo -e "  ${ORANGE}╭──────────────────────────────────────────────────────╮${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${WHITE}skyportd is installed!${RESET}                             ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Binary:${RESET}    ${ORANGE_DARK}${INSTALL_DIR}/skyportd${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Config:${RESET}    ${ORANGE_DARK}${INSTALL_DIR}/config/${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Volumes:${RESET}   ${ORANGE_DARK}${INSTALL_DIR}/volumes/${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Service:${RESET}                                            ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}systemctl status skyportd${RESET}                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}journalctl -u skyportd -f${RESET}                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Reconfigure:${RESET}                                        ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}cd ${INSTALL_DIR} && ./skyportd --configure${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Logs:${RESET} ${DIM}/tmp/skyport-install.log${RESET}                  ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
