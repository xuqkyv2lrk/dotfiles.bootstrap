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
    local system_version="" system_product=""

    # Prefer sysfs — always available, no dmidecode needed (critical on NixOS installer ISO)
    if [[ -r /sys/class/dmi/id/product_version ]]; then
        system_version="$(cat /sys/class/dmi/id/product_version 2>/dev/null)"
    elif command -v dmidecode &>/dev/null; then
        system_version="$(sudo dmidecode -s system-version 2>/dev/null)"
    fi

    if [[ -r /sys/class/dmi/id/product_name ]]; then
        system_product="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    elif command -v dmidecode &>/dev/null; then
        system_product="$(sudo dmidecode -s system-product-name 2>/dev/null)"
    fi

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

# get_packages
# Reads the flat package list from a packages.yaml file.
# Parameters:
#   $1 - path to packages.yaml
function get_packages() {
    local packages_yaml="${1}"
    yq '.packages[]' "${packages_yaml}"
}

# find_systemd_boot_entries
# Returns the systemd-boot loader entries directory, or empty string if not found.
function find_systemd_boot_entries() {
    local esp=""

    if command -v bootctl &>/dev/null && bootctl is-installed &>/dev/null; then
        esp="$(bootctl --print-esp-path 2>/dev/null)"
    fi

    if [[ -z "${esp}" ]]; then
        local mount_point
        for mount_point in /boot /efi /boot/efi; do
            if [[ -d "${mount_point}/loader/entries" ]]; then
                esp="${mount_point}"
                break
            fi
        done
    fi

    if [[ -n "${esp}" && -d "${esp}/loader/entries" ]]; then
        printf "%s/loader/entries" "${esp}"
    fi
}

# add_kernel_parameter
# Appends a kernel parameter to systemd-boot or GRUB. Idempotent.
# Parameters:
#   $1 - kernel parameter (e.g. "mem_sleep_default=s2idle")
#   $2 - distro (arch | ubuntu)
function add_kernel_parameter() {
    local param="${1}"
    local distro="${2}"
    local entries_dir
    entries_dir="$(find_systemd_boot_entries)"

    if [[ -n "${entries_dir}" ]]; then
        local updated=0
        local entry
        for entry in "${entries_dir}"/*.conf; do
            [[ "${entry}" == *fallback* ]] && continue
            if [[ -z "$(grep -w "${param}" "${entry}" 2>/dev/null)" ]]; then
                sudo sed -i "/^options / s/$/ ${param}/" "${entry}"
                print_success "Added '${param}' to ${entry}"
                updated=1
            fi
        done
        [[ "${updated}" -eq 0 ]] && print_warning "'${param}' already present in systemd-boot entries"
    elif [[ -f /etc/default/grub ]]; then
        if [[ -z "$(grep -w "${param}" /etc/default/grub 2>/dev/null)" ]]; then
            sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${param} /" \
                /etc/default/grub
            case "${distro}" in
                ubuntu) sudo update-grub ;;
                *)      sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
            esac
            print_success "Added '${param}' to GRUB config"
        else
            print_warning "'${param}' already present in GRUB config"
        fi
    else
        print_warning "No supported bootloader found. Add '${param}' manually."
    fi
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
        ubuntu) sudo apt-get update && sudo apt-get upgrade -y --allow-downgrades ;;
        *)
            print_error "system_update: unsupported distro: ${distro}"
            return 1
            ;;
    esac
}
