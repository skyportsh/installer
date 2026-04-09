#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  Skyport Installer — shared UI helpers
# ──────────────────────────────────────────────────────────────

ORANGE='\033[38;2;240;90;36m'
ORANGE_DARK='\033[38;2;217;36;0m'
GRAY='\033[38;2;120;120;120m'
GRAY_DARK='\033[38;2;55;55;55m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'
RED='\033[38;2;220;50;50m'
GREEN='\033[38;2;80;200;120m'

LOG_FILE="/tmp/skyport-install.log"

banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${GRAY_DARK}╭──────────────────────────────────────────────────────────────╮${RESET}"
    echo -e "${GRAY_DARK}│${RESET}                                                              ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${ORANGE}███████╗${GRAY} ██╗  ██╗ ${ORANGE}██╗   ██╗${GRAY} ██████╗  ${ORANGE}██████╗ ${GRAY} ██████╗${RESET}   ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${ORANGE}██╔════╝${GRAY} ██║ ██╔╝ ${ORANGE}╚██╗ ██╔╝${GRAY} ██╔══██╗ ${ORANGE}██╔═══██╗${GRAY} ██╔══██╗${RESET}  ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${ORANGE}███████╗${GRAY} █████╔╝  ${ORANGE} ╚████╔╝ ${GRAY} ██████╔╝ ${ORANGE}██║   ██║${GRAY} ██████╔╝${RESET}  ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${ORANGE}╚════██║${GRAY} ██╔═██╗  ${ORANGE}  ╚██╔╝  ${GRAY} ██╔═══╝  ${ORANGE}██║   ██║${GRAY} ██╔══██╗${RESET}  ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${ORANGE}███████║${GRAY} ██║  ██╗ ${ORANGE}   ██║   ${GRAY} ██║      ${ORANGE}╚██████╔╝${GRAY} ██║  ██║${RESET}  ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${ORANGE}╚══════╝${GRAY} ╚═╝  ╚═╝ ${ORANGE}   ╚═╝   ${GRAY} ╚═╝       ${ORANGE}╚═════╝ ${GRAY} ╚═╝  ╚═╝${RESET}  ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}                                                              ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}│${RESET}   ${DIM}${GRAY}$1${RESET}"
    echo -e "${GRAY_DARK}│${RESET}                                                              ${GRAY_DARK}│${RESET}"
    echo -e "${GRAY_DARK}╰──────────────────────────────────────────────────────────────╯${RESET}"
    echo ""
}

info()    { echo -e "  ${GRAY}›${RESET} $1"; }
success() { echo -e "  ${ORANGE}✓${RESET} $1"; }
warn()    { echo -e "  ${ORANGE_DARK}!${RESET} ${ORANGE_DARK}$1${RESET}"; }
error()   { echo -e "  ${RED}✗${RESET} ${RED}$1${RESET}"; }
step()    { echo ""; echo -e "  ${ORANGE}─── ${WHITE}$1${RESET}"; echo ""; }

ask() {
    local prompt="$1" default="$2" __result
    if [[ -n "$default" ]]; then
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET} ${GRAY_DARK}[${ORANGE_DARK}${default}${GRAY_DARK}]${RESET}: " >&2
    else
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET}: " >&2
    fi
    read -r __result
    echo "${__result:-$default}"
}

ask_password() {
    local prompt="$1" __result
    echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET}: " >&2
    read -rs __result
    echo "" >&2
    echo "$__result"
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" __result
    if [[ "$default" == "y" ]]; then
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET} ${GRAY_DARK}[${ORANGE_DARK}Y/n${GRAY_DARK}]${RESET}: " >&2
    else
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET} ${GRAY_DARK}[${ORANGE_DARK}y/N${GRAY_DARK}]${RESET}: " >&2
    fi
    read -r __result
    [[ "${__result:-$default}" =~ ^[Yy] ]]
}

ask_choice() {
    local prompt="$1"; shift; local options=("$@") i=1 __choice
    echo -e "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET}" >&2
    for opt in "${options[@]}"; do
        echo -e "    ${ORANGE_DARK}${i})${RESET} ${GRAY}${opt}${RESET}" >&2
        ((i++))
    done
    echo -ne "  ${ORANGE}›${RESET} ${GRAY}Choice${RESET}: " >&2
    read -r __choice
    if [[ "$__choice" -ge 1 && "$__choice" -le "${#options[@]}" ]] 2>/dev/null; then
        echo "$__choice"
    else
        echo "1"
    fi
}

spinner() {
    local pid=$1 label="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${ORANGE}%s${RESET} ${GRAY}%s${RESET}  " "${frames[$i]}" "$label" >&2
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    wait "$pid"; local exit_code=$?
    printf "\r" >&2
    if [[ $exit_code -eq 0 ]]; then
        success "$label"
    else
        error "$label — check $LOG_FILE for details"
    fi
    return $exit_code
}

run_step() {
    local label="$1"; shift
    echo "=== [$(date '+%H:%M:%S')] $label ===" >> "$LOG_FILE"
    "$@" >> "$LOG_FILE" 2>&1 &
    spinner $! "$label"
}

# Retry a command up to N times with delay
retry() {
    local attempts="$1" delay="$2" label="$3"; shift 3
    local i
    for ((i=1; i<=attempts; i++)); do
        if "$@" >> "$LOG_FILE" 2>&1; then
            return 0
        fi
        if [[ $i -lt $attempts ]]; then
            echo "  Attempt $i/$attempts failed for: $label — retrying in ${delay}s..." >> "$LOG_FILE"
            sleep "$delay"
        fi
    done
    return 1
}

run_step_retry() {
    local label="$1" attempts="$2" delay="$3"; shift 3
    echo "=== [$(date '+%H:%M:%S')] $label (up to $attempts attempts) ===" >> "$LOG_FILE"
    retry "$attempts" "$delay" "$label" "$@" &
    spinner $! "$label"
}

abort_with_log() {
    echo ""
    error "$1"
    error "See $LOG_FILE for full details."
    echo ""
    echo -e "  ${DIM}Last 15 lines of log:${RESET}"
    tail -15 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        echo -e "  ${GRAY_DARK}│${RESET} ${DIM}$line${RESET}"
    done
    echo ""
    exit 1
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect operating system."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "$ID" in
        ubuntu)
            case "$VERSION_ID" in
                22.04|24.04) ;;
                *) error "Ubuntu $VERSION_ID is not supported. Use 22.04 or 24.04."; exit 1 ;;
            esac ;;
        debian)
            case "$VERSION_ID" in
                11|12|13) ;;
                *) error "Debian $VERSION_ID is not supported. Use 11, 12, or 13."; exit 1 ;;
            esac ;;
        *) error "$PRETTY_NAME is not supported. Use Ubuntu 22/24 or Debian 11/12/13."; exit 1 ;;
    esac
    success "Detected $PRETTY_NAME"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This installer must be run as root."
        exit 1
    fi
}

check_disk_space() {
    local required_mb="$1" install_dir="$2"
    local available_mb
    available_mb=$(df -m "${install_dir%/*}" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "$available_mb" ]] && [[ "$available_mb" -lt "$required_mb" ]]; then
        error "Not enough disk space. Need ${required_mb}MB, have ${available_mb}MB."
        exit 1
    fi
    success "Disk space: ${available_mb}MB available"
}

check_memory() {
    local available_mb
    available_mb=$(free -m | awk '/Mem:/{print $7}')
    if [[ -n "$available_mb" ]] && [[ "$available_mb" -lt 256 ]]; then
        warn "Low memory: ${available_mb}MB available. Installation may be slow."
    fi
}

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

check_command() {
    command -v "$1" &>/dev/null
}

latest_github_release() {
    local repo="$1"
    curl -fsSL --retry 3 --retry-delay 2 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"\K[^"]+' || echo ""
}

ensure_curl() {
    if ! check_command curl; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl >/dev/null 2>&1
    fi
}
