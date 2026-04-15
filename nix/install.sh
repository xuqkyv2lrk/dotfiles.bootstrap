#!/usr/bin/env bash
# NixOS installer.
# Clones dotfiles.nix and triggers nixos-rebuild + home-manager switch.
# Sourced by bootstrap.sh — do not execute directly.

# install_nix
# Parameters:
#   $1 - hardware identifier
function install_nix() {
    local hardware="${1}"

    print_step "Installing NixOS configuration"

    local hostname
    hostname="$(hostname)"

    _clone_nix
    _select_nix_host "${hostname}" "${hardware}"
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

function _select_nix_host() {
    local hostname="${1}"
    local hardware="${2}"
    # TODO: hardware detection → NixOS module selection
    # e.g. detect ROG → enable hardware.asus module
    #      detect ThinkPad → enable ThinkPad-specific params
    print_info "Selecting NixOS host config for ${hostname} (${hardware})"
}

function _rebuild_nix() {
    local hostname="${1}"
    local dest="${HOME}/.dotfiles.nix"

    print_info "Running nixos-rebuild switch"
    sudo nixos-rebuild switch --flake "${dest}#${hostname}"
}
