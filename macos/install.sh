#!/usr/bin/env bash
# macOS (Apple Silicon) installer.
# Installs Homebrew, packages, and wires dotfiles.core via stow.
# Sourced by bootstrap.sh — do not execute directly.

readonly CORE_DIR="${HOME}/.dotfiles.core"
readonly MACOS_PACKAGES_YAML="${SCRIPT_DIR}/macos/packages.yaml"
readonly UTILITY_SCRIPTS_DIR="${HOME}/utility-scripts"

readonly MACOS_SKIP_PACKAGES=(
    "firefox" "thunderbird" "bitwarden" "1password"
    "cava" "mpc" "mpd" "mpv" "ncmpcpp" "ncspot"
    "dnsmasq" "qemu"
)

# install_macos
# Main entry point. Orchestrates full macOS installation.
# Parameters:
#   $1 - hardware identifier (Apple Silicon)
function install_macos() {
    local hardware="${1}"

    print_step "Installing on ${hardware}"

    _install_homebrew
    _setup_taps
    system_update "macos"
    _clone_core
    _clone_utility_scripts
    _install_macos_packages
    _create_working_dirs
    _install_binaries_macos
    _install_rust
    _install_media_tools_macos
    _stow_core
    _install_tmux_plugins
    _post_install_macos

    print_success "macOS installation complete."
}

function _install_homebrew() {
    if command -v brew &>/dev/null; then
        print_info "Homebrew already installed"
        eval "$(/opt/homebrew/bin/brew shellenv)"
        return
    fi

    print_info "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

function _setup_taps() {
    print_step "Tapping Homebrew repositories"
    brew tap homeport/tap
    brew tap fluxcd/tap
    brew tap siderolabs/tap
    brew tap jandedobbeleer/oh-my-posh
}

function _clone_core() {
    if [[ ! -d "${CORE_DIR}" ]]; then
        print_info "Cloning dotfiles.core"
        git clone "https://gitlab.com/wd2nf8gqct/dotfiles.core.git" "${CORE_DIR}"
    else
        print_info "dotfiles.core already present, skipping clone"
    fi
}

function _clone_utility_scripts() {
    if [[ ! -d "${UTILITY_SCRIPTS_DIR}" ]]; then
        print_info "Cloning utility-scripts"
        git clone "https://gitlab.com/wd2nf8gqct/utility-scripts.git" "${UTILITY_SCRIPTS_DIR}"
    else
        print_info "utility-scripts already present, skipping clone"
    fi
    bash "${UTILITY_SCRIPTS_DIR}/setup.sh"
}

# _should_skip_package
# Returns 0 (true) if a package should be skipped in minimal mode.
# Parameters:
#   $1 - package name
function _should_skip_package() {
    local package="${1}"

    [[ "${MINIMAL_MODE}" != "true" ]] && return 1

    local skip_pkg
    for skip_pkg in "${MACOS_SKIP_PACKAGES[@]}"; do
        if [[ "${package}" == "${skip_pkg}" ]]; then
            print_info "Skipping ${package} (minimal mode)"
            return 0
        fi
    done

    return 1
}

function _brew_install_cask() {
    local cask="${1}"
    if ! brew list --cask "${cask}" &>/dev/null 2>&1; then
        print_info "Installing ${cask} (cask)"
        brew install --cask "${cask}"
    fi
}

# _install_macos_packages
# Installs brew formulas and casks from macos/packages.yaml.
function _install_macos_packages() {
    print_step "Installing macOS packages"

    local package package_name
    while IFS= read -r package; do
        [[ -z "${package}" ]] && continue
        _should_skip_package "${package}" && continue
        package_name="$(get_package_name "${package}" "macos" "${MACOS_PACKAGES_YAML}")"
        [[ "${package_name}" == "skip" ]] && continue
        install_package "${package_name}" "macos"
    done < <(yq '.packages[]' "${MACOS_PACKAGES_YAML}")

    if [[ "${MINIMAL_MODE}" != "true" ]]; then
        local cask
        while IFS= read -r cask; do
            [[ -z "${cask}" ]] && continue
            _brew_install_cask "${cask}"
        done < <(yq '.casks[]' "${MACOS_PACKAGES_YAML}" 2>/dev/null)
    fi
}

function _create_working_dirs() {
    local required_dirs=(
        "${HOME}/bin"
        "${HOME}/notes/tome"
        "${HOME}/work/priming"
        "${HOME}/work/projects"
        "${HOME}/work/sandbox"
    )

    local dir
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            mkdir -p "${dir}"
            print_info "Created ${dir}"
        fi
    done

    export PATH="${HOME}/bin:${HOME}/.local/bin:${HOME}/.config/emacs/bin:${HOME}/.emacs.d/bin:${HOME}/.atuin/bin:${PATH}"
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

# _install_binaries_macos
# Installs tools available via Homebrew taps or direct download.
function _install_binaries_macos() {
    print_step "Installing binaries"

    install_package "awscli"      "macos"
    install_package "dyff"        "macos"
    install_package "oh-my-posh"  "macos"
    install_package "tfenv"       "macos"
    install_package "sops"        "macos"
    install_package "helm"        "macos"
    install_package "flux"        "macos"
    install_package "talosctl"    "macos"

    # doom emacs
    if ! command -v doom &>/dev/null; then
        print_info "Installing Doom Emacs"
        git clone --depth 1 --branch v2.1.1 \
            https://github.com/doomemacs/doomemacs "${HOME}/.emacs.d"
    fi

    # custom fonts from dotfiles.core — link into ~/Library/Fonts
    if [[ -d "${HOME}/.dotfiles.core/fonts/.fonts" ]]; then
        if [[ ! -L "${HOME}/Library/Fonts/dotfiles" ]]; then
            print_info "Installing fonts"
            mkdir -p "${HOME}/Library/Fonts"
            ln -sf "${HOME}/.dotfiles.core/fonts/.fonts" \
                "${HOME}/Library/Fonts/dotfiles"
        fi
    fi

    # glow config
    if [[ -d "${HOME}/.dotfiles.core/glow/.config/glow" ]]; then
        mkdir -p "${HOME}/.config/glow"
        if [[ ! -f "${HOME}/.config/glow/glow.yml" ]]; then
            print_info "Installing glow config"
            cat > "${HOME}/.config/glow/glow.yml" <<EOF
style: "${HOME}/.config/glow/catppuccin-mocha.json"
mouse: false
pager: false
width: 80
all: false
EOF
        fi
        if [[ ! -L "${HOME}/.config/glow/catppuccin-mocha.json" ]]; then
            ln -sf "${HOME}/.dotfiles.core/glow/.config/glow/catppuccin-mocha.json" \
                "${HOME}/.config/glow/catppuccin-mocha.json"
        fi
    fi
}

function _install_rust() {
    if command -v rustup &>/dev/null && command -v cargo &>/dev/null; then
        print_info "Rust already installed"
        rustup default stable
        return
    fi

    print_info "Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path
    # shellcheck source=/dev/null
    source "${HOME}/.cargo/env"
    rustup default stable

    if [[ -f "${HOME}/.zshenv" && -z "$(grep ".cargo" "${HOME}/.zshenv")" ]]; then
        printf '\n# Rust\n' >> "${HOME}/.zshenv"
        # shellcheck disable=SC2016
        printf 'path=("${HOME}/.cargo/bin" $path)\n' >> "${HOME}/.zshenv"
    fi
}

function _install_media_tools_macos() {
    print_step "Installing media tools"

    install_package "yt-dlp" "macos"

    if ! command -v ffmpeg-lh &>/dev/null; then
        print_info "Installing ffmpeg-lh"
        [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"
        cargo install --git https://github.com/indiscipline/ffmpeg-loudnorm-helper.git
    fi
}

# _stow_core
# Wires dotfiles.core into $HOME via stow.
function _stow_core() {
    print_step "Wiring dotfiles.core via stow"
    cd "${CORE_DIR}"
    stow --adopt -v */
    git restore */
    cd - >/dev/null
    print_success "dotfiles.core wired"
}

function _install_tmux_plugins() {
    print_info "Installing tmux plugins"
    if [[ ! -d "${HOME}/.tmux/plugins/tpm" ]]; then
        git clone "https://github.com/tmux-plugins/tpm" "${HOME}/.tmux/plugins/tpm"
    fi
    bash "${HOME}/.tmux/plugins/tpm/scripts/install_plugins.sh"
}

# _post_install_macos
# Post-installation: doom sync, bat cache, vim plugins, atuin, shell.
function _post_install_macos() {
    print_step "Running post-install configuration"

    # doom emacs sync
    local doom_bin=""
    if [[ -x "${HOME}/.config/emacs/bin/doom" ]]; then
        doom_bin="${HOME}/.config/emacs/bin/doom"
        export PATH="${HOME}/.config/emacs/bin:${PATH}"
    elif [[ -x "${HOME}/.emacs.d/bin/doom" ]]; then
        doom_bin="${HOME}/.emacs.d/bin/doom"
        export PATH="${HOME}/.emacs.d/bin:${PATH}"
    fi

    if [[ -n "${doom_bin}" ]]; then
        print_info "Running doom sync"
        "${doom_bin}" sync
    elif command -v doom &>/dev/null; then
        doom sync
    else
        print_warning "doom not found, skipping sync"
    fi

    print_info "Rebuilding bat cache"
    bat cache --build

    if [[ -f "${HOME}/.vim/autoload/plug.vim" ]]; then
        print_info "Installing vim plugins"
        vim +'PlugInstall --sync' +qa </dev/null
    fi

    print_info "Installing yazi packages"
    ya pkg install </dev/null

    # atuin
    if ! command -v atuin &>/dev/null; then
        print_info "Installing atuin"
        curl --proto '=https' --tlsv1.2 -LsSf \
            https://github.com/atuinsh/atuin/releases/latest/download/atuin-installer.sh \
            | sh -s -- --no-modify-path 2>/dev/null \
            || curl --proto '=https' --tlsv1.2 -LsSf \
                https://github.com/atuinsh/atuin/releases/latest/download/atuin-installer.sh \
                | sh

        [[ -d "${HOME}/.atuin/bin" ]] && export PATH="${HOME}/.atuin/bin:${PATH}"

        if [[ -f "${HOME}/.zshenv" && -z "$(grep "atuin/bin" "${HOME}/.zshenv")" ]]; then
            printf '\n# Atuin\n' >> "${HOME}/.zshenv"
            # shellcheck disable=SC2016
            printf 'path=("${HOME}/.atuin/bin" $path)\n' >> "${HOME}/.zshenv"
        fi
    fi

    # default shell — zsh is already default on macOS 10.15+, but ensure it
    if [[ "$(basename "${SHELL}")" != "zsh" ]]; then
        print_info "Changing default shell to zsh"
        chsh -s /bin/zsh
    fi

    print_success "Post-install configuration complete"
}
