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

info() {
    echo -e "  ${GRAY}›${RESET} $1"
}

success() {
    echo -e "  ${ORANGE}✓${RESET} $1"
}

warn() {
    echo -e "  ${ORANGE_DARK}!${RESET} ${ORANGE_DARK}$1${RESET}"
}

error() {
    echo -e "  ${RED}✗${RESET} ${RED}$1${RESET}"
}

step() {
    echo ""
    echo -e "  ${ORANGE}─── ${WHITE}$1${RESET}"
    echo ""
}

ask() {
    local prompt="$1"
    local default="$2"
    local __result

    if [[ -n "$default" ]]; then
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET} ${GRAY_DARK}[${ORANGE_DARK}${default}${GRAY_DARK}]${RESET}: " >&2
    else
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET}: " >&2
    fi

    read -r __result
    if [[ -z "$__result" ]]; then
        __result="$default"
    fi
    echo "$__result"
}

ask_password() {
    local prompt="$1"
    local __result

    echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET}: " >&2
    read -rs __result
    echo "" >&2
    echo "$__result"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local __result

    if [[ "$default" == "y" ]]; then
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET} ${GRAY_DARK}[${ORANGE_DARK}Y/n${GRAY_DARK}]${RESET}: " >&2
    else
        echo -ne "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET} ${GRAY_DARK}[${ORANGE_DARK}y/N${GRAY_DARK}]${RESET}: " >&2
    fi

    read -r __result
    __result="${__result:-$default}"

    [[ "$__result" =~ ^[Yy] ]]
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local i=1

    echo -e "  ${ORANGE}›${RESET} ${GRAY}${prompt}${RESET}" >&2
    for opt in "${options[@]}"; do
        echo -e "    ${ORANGE_DARK}${i})${RESET} ${GRAY}${opt}${RESET}" >&2
        ((i++))
    done

    local __choice
    echo -ne "  ${ORANGE}›${RESET} ${GRAY}Choice${RESET}: " >&2
    read -r __choice

    if [[ "$__choice" -ge 1 && "$__choice" -le "${#options[@]}" ]] 2>/dev/null; then
        echo "$__choice"
    else
        echo "1"
    fi
}

spinner() {
    local pid=$1
    local label="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${ORANGE}%s${RESET} ${GRAY}%s${RESET}  " "${frames[$i]}" "$label" >&2
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?
    printf "\r" >&2

    if [[ $exit_code -eq 0 ]]; then
        success "$label"
    else
        error "$label (exit code $exit_code — see /tmp/skyport-install.log)"
    fi

    return $exit_code
}

run_step() {
    local label="$1"
    shift
    "$@" >> /tmp/skyport-install.log 2>&1 &
    spinner $! "$label"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect operating system."
        exit 1
    fi

    source /etc/os-release

    case "$ID" in
        ubuntu)
            case "$VERSION_ID" in
                22.04|24.04) ;;
                *) error "Ubuntu $VERSION_ID is not supported. Use 22.04 or 24.04."; exit 1 ;;
            esac
            ;;
        debian)
            case "$VERSION_ID" in
                11|12|13) ;;
                *) error "Debian $VERSION_ID is not supported. Use 11, 12, or 13."; exit 1 ;;
            esac
            ;;
        *)
            error "$PRETTY_NAME is not supported. Use Ubuntu 22/24 or Debian 11/12/13."
            exit 1
            ;;
    esac

    success "Detected $PRETTY_NAME"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This installer must be run as root."
        exit 1
    fi
}

latest_github_release() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' || echo ""
}
