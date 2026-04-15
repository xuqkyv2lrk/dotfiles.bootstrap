#!/usr/bin/env bash
# NixOS installer.
# Clones dotfiles.nix and triggers nixos-rebuild + home-manager switch.
# Sourced by bootstrap.sh — do not execute directly.

# install_nix
# Parameters:
#   $1 - hardware identifier (from detect_hardware in common.sh)
function install_nix() {
    local hardware="${1}"

    print_step "Installing NixOS configuration"

    local hostname
    hostname="$(hostname)"

    _clone_nix

    if ! _select_nix_host "${hostname}" "${hardware}"; then
        print_warning "Rerun ./bootstrap.sh once the host config has been added."
        return 1
    fi

    _rebuild_nix "${hostname}"

    print_success "NixOS configuration applied."
}

function _clone_nix() {
    local dest="${HOME}/.dotfiles.nix"

    if [[ ! -d "${dest}" ]]; then
        print_info "Cloning dotfiles.nix"
        git clone "https://gitlab.com/wd2nf8gqct/dotfiles.nix.git" "${dest}"
    else
        print_info "dotfiles.nix already present, skipping clone"
    fi
}

# _select_nix_host
# Verifies a nixosConfiguration exists for the current hostname.
# If not, generates hardware-configuration.nix and prints scaffolding guidance.
# Returns 1 if no host config exists (rebuild cannot proceed).
# Parameters:
#   $1 - hostname
#   $2 - hardware identifier
function _select_nix_host() {
    local hostname="${1}"
    local hardware="${2}"
    local dest="${HOME}/.dotfiles.nix"

    if [[ -n "$(grep "nixosConfigurations\.${hostname}" "${dest}/flake.nix" 2>/dev/null)" ]]; then
        print_info "Found NixOS config for '${hostname}'"
        return 0
    fi

    print_warning "No NixOS config found for hostname '${hostname}'"
    print_step "Generating hardware configuration"

    local host_dir="${dest}/hosts/${hostname}"
    mkdir -p "${host_dir}"
    sudo nixos-generate-config --show-hardware-config > "${host_dir}/hardware-configuration.nix"
    print_success "Hardware config written to hosts/${hostname}/hardware-configuration.nix"

    local hardware_module=""
    case "${hardware}" in
        "ThinkPad T480s") hardware_module="modules/nixos/hardware/thinkpad-t480s.nix" ;;
        "ROG")            hardware_module="modules/nixos/hardware/asus-rog.nix" ;;
        "XPS 13 9350")    hardware_module="modules/nixos/hardware/dell-xps-13-9350.nix" ;;
    esac

    printf "\n"
    print_info "Next steps:"
    printf "  1. Add a nixosConfigurations.%s entry in flake.nix\n" "${hostname}"
    printf "  2. Create hosts/%s/configuration.nix\n" "${hostname}"
    printf "     Import: ./hardware-configuration.nix\n"
    if [[ -n "${hardware_module}" ]]; then
        printf "     Import: ../../%s\n" "${hardware_module}"
    fi
    printf "\n"

    return 1
}

function _rebuild_nix() {
    local hostname="${1}"
    local dest="${HOME}/.dotfiles.nix"

    print_info "Running nixos-rebuild switch"
    sudo nixos-rebuild switch --flake "${dest}#${hostname}"
}
