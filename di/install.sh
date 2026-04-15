#!/usr/bin/env bash
# Desktop interface installer.
# Installs DE packages and wires dotfiles.di via stow.
# Sourced by bootstrap.sh — do not execute directly.

# install_di
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - hardware identifier
function install_di() {
    local distro="${1}"
    local hardware="${2}"

    print_step "Installing desktop interface"

    _clone_di
    _select_de
    _install_di_packages "${distro}"
    _stow_di
    _configure_di "${distro}" "${hardware}"

    print_success "Desktop interface installation complete."
}

function _clone_di() {
    local dest="${HOME}/.dotfiles.di"

    if [[ ! -d "${dest}" ]]; then
        print_info "Cloning dotfiles.di"
        git clone --recurse-submodules \
            "https://gitlab.com/wd2nf8gqct/dotfiles.di.git" "${dest}"
    else
        print_info "dotfiles.di already present, skipping clone"
    fi
}

function _select_de() {
    # TODO: migrate DE selection menu from dotfiles.di install.sh
    print_info "DE selection: TODO"
}

function _install_di_packages() {
    local distro="${1}"
    # TODO: migrate DE package installation from dotfiles.di install.sh
    print_info "Installing DE packages (${distro})"
}

function _stow_di() {
    local dest="${HOME}/.dotfiles.di"

    print_info "Wiring dotfiles.di via stow"
    cd "${dest}"
    stow --target="${HOME}" -- hyprland niri sway gnome quickshell
    cd - >/dev/null
}

function _configure_di() {
    local distro="${1}"
    local hardware="${2}"
    # TODO: migrate hardware/DE-specific config from dotfiles.di install.sh
    print_info "Applying DE configuration (${distro}, ${hardware})"
}
