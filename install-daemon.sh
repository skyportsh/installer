#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  skyportd Daemon Installer
# ──────────────────────────────────────────────────────────────

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$INSTALLER_DIR/lib/ui.sh" ]]; then
    INSTALLER_DIR=$(mktemp -d)
    mkdir -p "$INSTALLER_DIR/lib"
    apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl >/dev/null 2>&1
    curl -fsSL "https://raw.githubusercontent.com/skyportsh/installer/main/lib/ui.sh" -o "$INSTALLER_DIR/lib/ui.sh"
fi
source "$INSTALLER_DIR/lib/ui.sh"

INSTALL_DIR="/etc/skyportd"
DAEMON_USER="root"

trap 'abort_with_log "Installation failed unexpectedly at line $LINENO."' ERR

# ── Preflight ────────────────────────────────────────────────

banner "Daemon Installer                                        "

check_root
check_os
check_disk_space 500 "$INSTALL_DIR"

echo ""
> "$LOG_FILE"

# ── Architecture ─────────────────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARTIFACT="skyportd-linux-x86_64" ;;
    aarch64) ARTIFACT="skyportd-linux-aarch64" ;;
    riscv64) ARTIFACT="skyportd-linux-riscv64" ;;
    *)
        error "Unsupported architecture: $ARCH"
        info "Supported: x86_64, aarch64, riscv64"
        exit 1 ;;
esac
success "Architecture: $ARCH"

# ── Existing installation ────────────────────────────────────

if [[ -f "$INSTALL_DIR/skyportd" ]]; then
    warn "An existing skyportd installation was found at $INSTALL_DIR."
    echo ""
    if ask_yes_no "Remove it and start fresh?" "n"; then
        systemctl stop skyportd 2>/dev/null || true
        rm -f "$INSTALL_DIR/skyportd"
        success "Removed existing binary."
    else
        error "Installation cancelled."
        exit 1
    fi
fi

# ── Release channel ──────────────────────────────────────────

step "Release channel"

CHANNEL_CHOICE=$(ask_choice "Which release channel?" "Stable (latest release — recommended)" "Bleeding edge (main branch)")
if [[ "$CHANNEL_CHOICE" == "2" ]]; then
    CHANNEL="edge"
    warn "Bleeding edge uses the latest commit on main."
    warn "Building from source requires Rust and may take several minutes."
    echo ""
    if ! ask_yes_no "Continue with bleeding edge?" "n"; then
        CHANNEL="stable"
    fi
else
    CHANNEL="stable"
fi
success "Channel: $CHANNEL"

# ── Docker ───────────────────────────────────────────────────

step "Docker"

if check_command docker; then
    local_docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    success "Docker found: $local_docker_version"
else
    info "Docker is required for running game servers."
    echo ""
    if ask_yes_no "Install Docker?" "y"; then
        install_docker() {
            curl -fsSL --retry 3 https://get.docker.com | sh
        }
        run_step "Installing Docker" install_docker
    else
        warn "Skipping Docker. skyportd will not be able to manage servers."
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

# ── Install ──────────────────────────────────────────────────

step "Installing skyportd"

install_daemon_stable() {
    local tag
    tag=$(latest_github_release "skyportsh/skyportd")
    if [[ -z "$tag" ]]; then
        echo "No stable release found, falling back to main branch." >> "$LOG_FILE"
        install_daemon_edge
        return
    fi
    local url="https://github.com/skyportsh/skyportd/releases/download/${tag}/${ARTIFACT}"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL --retry 3 "$url" -o "$INSTALL_DIR/skyportd"
    chmod +x "$INSTALL_DIR/skyportd"
}

install_daemon_edge() {
    if ! check_command cargo; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        # shellcheck source=/dev/null
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
    cd /
    rm -rf "$build_dir"
}

if [[ "$CHANNEL" == "stable" ]]; then
    run_step "Downloading skyportd" install_daemon_stable
else
    run_step "Building skyportd from source (this takes a while)" install_daemon_edge
fi

if [[ ! -x "$INSTALL_DIR/skyportd" ]]; then
    abort_with_log "skyportd binary not found after installation."
fi

# ── Config ───────────────────────────────────────────────────

setup_config() {
    mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/volumes"
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

# ── Systemd ──────────────────────────────────────────────────

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
StartLimitBurst=5
StartLimitIntervalSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable skyportd
}

run_step "Creating skyportd service" create_service

# ── Configuration ────────────────────────────────────────────

step "Daemon configuration"

info "skyportd needs a panel URL and configuration token to enroll."
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
        success "Configuration saved."
        info "Starting skyportd..."
        systemctl start skyportd
        sleep 4

        if systemctl is-active --quiet skyportd; then
            success "skyportd is running and enrolled!"
        else
            warn "skyportd may still be enrolling. Check logs:"
            info "journalctl -u skyportd -f"
        fi
    else
        warn "Missing values. Configure later with: cd $INSTALL_DIR && ./skyportd --configure"
    fi
else
    info "Configure later: cd ${INSTALL_DIR} && ./skyportd --configure"
fi

# ── Done ─────────────────────────────────────────────────────

trap - ERR

step "Installation complete"

echo ""
echo -e "  ${ORANGE}╭──────────────────────────────────────────────────────╮${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${WHITE}skyportd is installed!${RESET}                             ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Binary:${RESET}  ${ORANGE_DARK}${INSTALL_DIR}/skyportd${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Config:${RESET}  ${ORANGE_DARK}${INSTALL_DIR}/config/${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Volumes:${RESET} ${ORANGE_DARK}${INSTALL_DIR}/volumes/${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Commands:${RESET}                                           ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}systemctl status skyportd${RESET}                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}journalctl -u skyportd -f${RESET}                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}     ${DIM}cd ${INSTALL_DIR} && ./skyportd --configure${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
