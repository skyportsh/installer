#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
#  skyportd Daemon Updater
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
LOG_FILE="/tmp/skyport-update.log"

trap 'abort_with_log "Update failed at line $LINENO."' ERR

banner "Daemon Updater                                          "

check_root
echo ""
> "$LOG_FILE"

# ── Check installation ───────────────────────────────────────

if [[ ! -x "$INSTALL_DIR/skyportd" ]]; then
    error "No skyportd binary found at $INSTALL_DIR/skyportd."
    exit 1
fi

CURRENT_VERSION=$("$INSTALL_DIR/skyportd" --help 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
success "Found skyportd ${CURRENT_VERSION}"

# ── Architecture ─────────────────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARTIFACT="skyportd-linux-x86_64" ;;
    aarch64) ARTIFACT="skyportd-linux-aarch64" ;;
    riscv64) ARTIFACT="skyportd-linux-riscv64" ;;
    *) error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ── Determine update source ─────────────────────────────────

step "Update source"

LATEST_TAG=$(latest_github_release "skyportsh/skyportd")

if [[ -n "$LATEST_TAG" ]]; then
    info "Latest release: $LATEST_TAG"
    UPDATE_MODE="release"
else
    info "No stable release found — will build from source."
    UPDATE_MODE="source"
fi

if ! ask_yes_no "Proceed with update?" "y"; then
    info "Update cancelled."
    exit 0
fi

# ── Back up ──────────────────────────────────────────────────

step "Preparing update"

backup_daemon() {
    local backup_dir="$INSTALL_DIR/backups"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$backup_dir"
    cp "$INSTALL_DIR/skyportd" "$backup_dir/skyportd_${timestamp}"
    cp -r "$INSTALL_DIR/config" "$backup_dir/config_${timestamp}"
    echo "Backed up to $backup_dir"
}

run_step "Backing up current binary and config" backup_daemon

# ── Stop service ─────────────────────────────────────────────

stop_daemon() {
    systemctl stop skyportd 2>/dev/null || true
}

run_step "Stopping skyportd" stop_daemon

# ── Download / build ─────────────────────────────────────────

step "Downloading update"

download_release() {
    curl -fsSL --retry 3 "https://github.com/skyportsh/skyportd/releases/download/${LATEST_TAG}/${ARTIFACT}" \
        -o "$INSTALL_DIR/skyportd"
    chmod +x "$INSTALL_DIR/skyportd"
}

build_from_source() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential pkg-config >> "$LOG_FILE" 2>&1
    if ! check_command cargo; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    local build_dir
    build_dir=$(mktemp -d)
    git clone --depth 1 https://github.com/skyportsh/skyportd.git "$build_dir"
    cd "$build_dir"
    cargo build --release
    cp target/release/skyportd "$INSTALL_DIR/skyportd"
    chmod +x "$INSTALL_DIR/skyportd"
    cd /
    rm -rf "$build_dir"
}

if [[ "$UPDATE_MODE" == "release" ]]; then
    run_step "Downloading ${LATEST_TAG}" download_release
else
    run_step "Building from source (this takes a while)" build_from_source
fi

if [[ ! -x "$INSTALL_DIR/skyportd" ]]; then
    abort_with_log "Binary not found after update."
fi

# ── Start service ────────────────────────────────────────────

step "Restarting"

start_daemon() {
    systemctl start skyportd
}

run_step "Starting skyportd" start_daemon

sleep 3
if systemctl is-active --quiet skyportd; then
    success "skyportd is running"
else
    warn "skyportd may still be starting. Check: journalctl -u skyportd -f"
fi

NEW_VERSION=$("$INSTALL_DIR/skyportd" --help 2>&1 | head -1 | awk '{print $2}' || echo "unknown")

# ── Done ─────────────────────────────────────────────────────

trap - ERR

step "Update complete"

echo ""
echo -e "  ${ORANGE}╭──────────────────────────────────────────────────────╮${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${WHITE}skyportd updated!${RESET}                                 ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Previous:${RESET} ${DIM}${CURRENT_VERSION}${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Current:${RESET}  ${ORANGE_DARK}${NEW_VERSION}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Backup:${RESET} ${DIM}${INSTALL_DIR}/backups/${RESET}"
echo -e "  ${ORANGE}│${RESET}   ${GRAY}Log:${RESET}    ${DIM}${LOG_FILE}${RESET}"
echo -e "  ${ORANGE}│${RESET}                                                      ${ORANGE}│${RESET}"
echo -e "  ${ORANGE}╰──────────────────────────────────────────────────────╯${RESET}"
echo ""
