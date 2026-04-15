#!/usr/bin/env bash
# Shared utilities for dotfiles.bootstrap scripts.
# Sourced by bootstrap.sh and sub-installers — do not execute directly.

# Catppuccin Mocha palette
readonly RED='\033[38;2;243;139;168m'
readonly GREEN='\033[38;2;166;227;161m'
readonly YELLOW='\033[38;2;249;226;175m'
readonly BLUE='\033[38;2;137;180;250m'
readonly MAUVE='\033[38;2;203;166;247m'
readonly TEAL='\033[38;2;148;226;213m'
readonly TEXT='\033[38;2;205;214;244m'
readonly SUBTEXT='\033[38;2;166;173;200m'
readonly RESET='\033[0m'

function print_info()    { printf "${BLUE}[INFO]${RESET} %s\n" "$*"; }
function print_success() { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
function print_warning() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*" >&2; }
function print_error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
function print_step()    { printf "${MAUVE}==>${RESET} %s\n" "$*"; }
function print_dry_run() { printf "${TEAL}[DRY-RUN]${RESET} %s\n" "$*"; }

# detect_distro
# Returns: arch | ubuntu | nixos | unsupported | unknown
function detect_distro() {
    if [[ ! -f "/etc/os-release" ]]; then
        printf "unknown"
        return
    fi

    local id
    # shellcheck source=/dev/null
    id="$(source "/etc/os-release" && printf "%s" "${ID}")"

    case "${id}" in
        arch)   printf "arch" ;;
        ubuntu) printf "ubuntu" ;;
        nixos)  printf "nixos" ;;
        *)      printf "unsupported" ;;
    esac
}

# detect_hardware
# Returns: ThinkPad T480s | ROG | XPS 13 9350 | unknown
function detect_hardware() {
    if ! command -v dmidecode &>/dev/null; then
        printf "unknown"
        return
    fi

    local system_version
    local system_product
    system_version="$(sudo dmidecode -s system-version 2>/dev/null)"
    system_product="$(sudo dmidecode -s system-product-name 2>/dev/null)"

    if [[ "${system_version}" == "ThinkPad T480s" ]]; then
        printf "ThinkPad T480s"
    elif [[ "${system_product}" == *"ROG"* ]]; then
        printf "ROG"
    elif [[ "${system_product}" == "XPS 13 9350" ]]; then
        printf "XPS 13 9350"
    else
        printf "unknown"
    fi
}

# get_package_name
# Resolves the distro-specific package name from packages.yaml exceptions.
# Parameters:
#   $1 - package name
#   $2 - distro (arch | ubuntu)
#   $3 - path to packages.yaml
function get_package_name() {
    local package="${1}"
    local distro="${2}"
    local packages_yaml="${3}"
    local exception

    exception="$(yq -e ".exceptions.${distro}.[] | select(has(\"${package}\")) | .\"${package}\"" \
        "${packages_yaml}" 2>/dev/null || true)"

    if [[ -n "${exception}" && "${exception}" != "null" ]]; then
        printf "%s" "${exception}"
    else
        printf "%s" "${package}"
    fi
}

# install_package
# Installs a single package via the appropriate package manager.
# Parameters:
#   $1 - package name
#   $2 - distro (arch | ubuntu)
function install_package() {
    local package="${1}"
    local distro="${2}"

    case "${distro}" in
        arch)
            if ! pacman -Qi "${package}" &>/dev/null; then
                print_info "Installing ${package}"
                sudo pacman -S --noconfirm --needed "${package}"
            fi
            ;;
        ubuntu)
            if ! dpkg -l "${package}" &>/dev/null; then
                print_info "Installing ${package}"
                sudo apt-get install -y "${package}"
            fi
            ;;
        *)
            print_error "install_package: unsupported distro: ${distro}"
            return 1
            ;;
    esac
}

# system_update
# Runs a full system update for the detected distro.
# Parameters:
#   $1 - distro (arch | ubuntu)
function system_update() {
    local distro="${1}"

    print_step "Updating system packages"
    case "${distro}" in
        arch)   sudo pacman -Syu --noconfirm ;;
        ubuntu) sudo apt-get update && sudo apt-get upgrade -y ;;
        *)
            print_error "system_update: unsupported distro: ${distro}"
            return 1
            ;;
    esac
}
