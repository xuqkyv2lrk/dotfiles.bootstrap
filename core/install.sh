#!/usr/bin/env bash
# Core dotfiles installer.
# Installs base packages and wires dotfiles.core via stow.
# Sourced by bootstrap.sh — do not execute directly.

# install_core
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - hardware identifier
function install_core() {
    local distro="${1}"
    local hardware="${2}"

    print_step "Installing core"

    _clone_core
    _install_core_packages "${distro}"
    _stow_core
    _configure_core "${distro}" "${hardware}"

    print_success "Core installation complete."
}

function _clone_core() {
    local dest="${HOME}/.dotfiles.core"

    if [[ ! -d "${dest}" ]]; then
        print_info "Cloning dotfiles.core"
        git clone "https://gitlab.com/wd2nf8gqct/dotfiles.core.git" "${dest}"
    else
        print_info "dotfiles.core already present, skipping clone"
    fi
}

function _install_core_packages() {
    local distro="${1}"
    # TODO: migrate package installation from dotfiles.core provision.sh
    print_info "Installing core packages (${distro})"
}

function _stow_core() {
    local dest="${HOME}/.dotfiles.core"

    print_info "Wiring dotfiles.core via stow"
    cd "${dest}"
    stow --target="${HOME}" -- zsh vim tmux git bat btop delta \
        fastfetch foot ncmpcpp ncspot ohmyposh yazi
    cd - >/dev/null
}

function _configure_core() {
    local distro="${1}"
    local hardware="${2}"
    # TODO: migrate hardware-specific config from dotfiles.core provision.sh
    print_info "Applying core configuration (${distro}, ${hardware})"
}
