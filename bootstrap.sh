#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a new machine with dotfiles and system packages.
# Detects distro and hardware, installs packages, clones and wires dotfiles.
# Usage: bootstrap.sh [OPTIONS]
#        bash <(curl -fsSL dots.ethi.cz/boot)

readonly BOOTSTRAP_REPO="https://gitlab.com/wd2nf8gqct/dotfiles.bootstrap.git"
readonly BOOTSTRAP_CLONE_DIR="${BOOTSTRAP_CLONE_DIR:-/tmp/dotfiles.bootstrap}"

# Run straight from curl there is no checkout beside this file, so fetch the repo and
# hand over to its copy of the script. lib/common.sh is not loaded yet, hence the
# inline colors.
function self_bootstrap() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
    [[ -n "${here}" && -f "${here}/lib/common.sh" ]] && return 0

    printf '\033[38;2;203;166;247m==>\033[0m %s\n' "No local checkout; fetching dotfiles.bootstrap"

    local args=""
    [[ $# -gt 0 ]] && args="$(printf ' %q' "$@")"
    local fetch_and_run
    fetch_and_run="if [[ -d '${BOOTSTRAP_CLONE_DIR}/.git' ]]; then"
    fetch_and_run+=" git -C '${BOOTSTRAP_CLONE_DIR}' pull --ff-only;"
    fetch_and_run+=" else git clone '${BOOTSTRAP_REPO}' '${BOOTSTRAP_CLONE_DIR}'; fi"
    # Prompts must read the keyboard even when the script itself arrived on stdin
    # (curl | bash); only switch when stdin is not a terminal and /dev/tty can be opened
    fetch_and_run+=" && if [[ ! -t 0 ]] && { : < /dev/tty; } 2>/dev/null; then"
    fetch_and_run+=" exec bash '${BOOTSTRAP_CLONE_DIR}/bootstrap.sh'${args} < /dev/tty;"
    fetch_and_run+=" else exec bash '${BOOTSTRAP_CLONE_DIR}/bootstrap.sh'${args}; fi"

    if command -v git >/dev/null; then
        exec bash -c "${fetch_and_run}"
    fi

    # The NixOS installer has no git; nix/install.sh needs it too, so stay inside the shell
    if command -v nix-shell >/dev/null; then
        exec nix-shell -p git --run "${fetch_and_run}"
    elif command -v pacman >/dev/null; then
        # -Syu: refreshing the database without upgrading is an unsupported partial upgrade
        sudo pacman -Syu --needed --noconfirm git
    elif command -v apt-get >/dev/null; then
        sudo apt-get update && sudo apt-get install -y git
    else
        printf '\033[38;2;243;139;168m[ERROR]\033[0m %s\n' "git is required; install it and re-run" >&2
        exit 1
    fi
    exec bash -c "${fetch_and_run}"
}

self_bootstrap "$@"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MINIMAL_MODE="false"
SKIP_DI="false"

function parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --minimal|--server)
                MINIMAL_MODE="true"
                shift
                ;;
            --no-di)
                SKIP_DI="true"
                shift
                ;;
            --help|-h)
                printf "Usage: %s [OPTIONS]\n\n" "${0}"
                printf "Options:\n"
                printf "  --minimal, --server  Install only CLI tools, skip GUI apps\n"
                printf "  --no-di              Skip desktop interface installation\n"
                printf "  --help, -h           Show this help message\n"
                exit 0
                ;;
            *)
                print_error "Unknown option: ${1}"
                printf "Use --help for usage information\n" >&2
                exit 1
                ;;
        esac
    done
}

function _ensure_yq_ubuntu() {
    [[ "$(detect_distro)" != "ubuntu" ]] && return
    if [[ -z "$(yq --version 2>/dev/null | grep 'mikefarah')" ]]; then
        print_info "Installing yq 4.x (Ubuntu ships incompatible 3.x)"
        sudo curl -fsSL -o /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        sudo chmod +x /usr/local/bin/yq
        hash -r
    fi
}

function main() {
    parse_arguments "$@"

    _ensure_yq_ubuntu

    local distro
    local hardware
    distro="$(detect_distro)"
    hardware="$(detect_hardware)"

    print_step "Detected distro: ${distro}"
    print_step "Detected hardware: ${hardware}"

    case "${distro}" in
        arch|ubuntu)
            # shellcheck source=core/install.sh
            source "${SCRIPT_DIR}/core/install.sh"
            install_core "${distro}" "${hardware}"

            if [[ "${SKIP_DI}" != "true" && "${MINIMAL_MODE}" != "true" ]]; then
                # shellcheck source=di/install.sh
                source "${SCRIPT_DIR}/di/install.sh"
                install_di "${distro}" "${hardware}"
            fi
            ;;
        nixos)
            # shellcheck source=nix/install.sh
            source "${SCRIPT_DIR}/nix/install.sh"
            install_nix "${hardware}"
            ;;
        macos)
            # shellcheck source=macos/install.sh
            source "${SCRIPT_DIR}/macos/install.sh"
            install_macos "${hardware}"
            ;;
        unsupported|unknown)
            print_error "Unsupported distro: ${distro}"
            exit 1
            ;;
    esac

    print_success "Bootstrap complete."
}

main "$@"
