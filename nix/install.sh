#!/usr/bin/env bash
# NixOS installer.
# Clones dotfiles.nix and runs nixos-rebuild switch.
# Sourced by bootstrap.sh — do not execute directly.
#
# New host setup (hardware config generation, flake scaffolding) is documented
# in dotfiles.nix: https://gitlab.com/wd2nf8gqct/dotfiles.nix

# install_nix
function install_nix() {
    print_step "Installing NixOS configuration"

    local hostname
    hostname="$(hostname)"

    _clone_nix
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

function _rebuild_nix() {
    local hostname="${1}"
    local dest="${HOME}/.dotfiles.nix"

    print_info "Running nixos-rebuild switch"
    sudo nixos-rebuild switch --flake "${dest}#${hostname}"
}
