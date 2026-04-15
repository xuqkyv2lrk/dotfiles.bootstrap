#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a new machine with dotfiles and system packages.
# Detects distro and hardware, installs packages, clones and wires dotfiles.
# Usage: bootstrap.sh [OPTIONS]

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

function main() {
    parse_arguments "$@"

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
        unsupported|unknown)
            print_error "Unsupported distro: ${distro}"
            exit 1
            ;;
    esac

    print_success "Bootstrap complete."
}

main "$@"
