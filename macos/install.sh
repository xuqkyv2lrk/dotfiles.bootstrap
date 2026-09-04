#!/usr/bin/env bash
# macOS (Apple Silicon) installer.
# Installs Homebrew, packages, and wires dotfiles.core via stow.
# Sourced by bootstrap.sh — do not execute directly.

readonly CORE_DIR="${HOME}/.dotfiles.core"
readonly DI_DIR="${HOME}/.dotfiles.di"
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
    _setup_shell_env_macos
    _setup_taps
    _install_bootstrap_prereqs
    _install_gnu_tools
    system_update "macos"
    _clone_core
    _clone_di
    _clone_utility_scripts
    _install_macos_packages
    _create_working_dirs
    _install_binaries_macos
    _install_dev_toolchain_macos
    _install_rust
    _install_media_tools_macos
    _stow_core
    _stow_di_macos
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
    # NONINTERACTIVE: skip the "Press RETURN to continue" prompt (still asks for
    # the sudo password once, which is unavoidable on a first install).
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

# _install_bootstrap_prereqs
# Installs tools directly (not via the yq-driven package loop) so they're
# guaranteed present: yq parses packages.yaml, stow wires the dotfiles, git
# clones the repos, shellcheck lints this repo. All are also listed in
# packages.yaml (harmless — the package loop skips anything already installed).
function _install_bootstrap_prereqs() {
    print_step "Installing bootstrap prerequisites"

    local pkg
    for pkg in yq stow git curl shellcheck; do
        if ! brew list "${pkg}" &>/dev/null 2>&1; then
            print_info "Installing ${pkg}"
            brew install "${pkg}"
        fi
    done
}

# _setup_shell_env_macos
# Writes a marker-delimited managed block to ~/.zprofile with the macOS-only
# shell setup that dotfiles.core doesn't provide:
#   - `brew shellenv` — puts /opt/homebrew/{bin,sbin} on PATH. Nothing else
#     persists this; without it a fresh login shell can't find brew or anything
#     it installed.
#   - GNU userland (gnubin dirs for every formula in _install_gnu_tools's
#     gnu_packages array) ahead of the macOS BSD/ancient tools.
#   - HOMEBREW_CASK_OPTS=--no-quarantine (apps launch without the "unverified
#     developer" prompt), HOMEBREW_NO_ASK=1 (no per-install [Y/n]),
#     HOMEBREW_NO_ENV_HINTS=1 (no hint blurbs).
# ~/.zprofile is deliberate: dotfiles.core stows ~/.zshenv and ~/.zshrc, so
# _stow_core's `stow --adopt` + `git restore` would wipe anything written there.
# It doesn't manage ~/.zprofile. (setopt interactivecomments and the
# cargo/go/atuin PATH entries already live in dotfiles.core's zsh config.)
function _setup_shell_env_macos() {
    print_step "Configuring shell environment (~/.zprofile)"

    # dotfiles.core's ~/.zshenv puts config/cache/data under XDG paths. The
    # bootstrap runs in bash and never sources that, so mirror the ones that
    # change where tools look — most importantly XDG_CONFIG_HOME, which decides
    # whether `brew trust` writes to ~/.config/homebrew/ or ~/.homebrew/. Without
    # this, _setup_taps trusts taps in a location the user's shell never reads.
    export XDG_CONFIG_HOME="${HOME}/.config"
    export XDG_CACHE_HOME="${HOME}/.cache"
    export XDG_DATA_HOME="${HOME}/.local/share"
    mkdir -p "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}" "${XDG_DATA_HOME}"

    local zprofile="${HOME}/.zprofile"
    local begin="# >>> dotfiles.bootstrap (macOS) >>>"
    local end="# <<< dotfiles.bootstrap (macOS) <<<"

    # Replace any previous managed block rather than appending a new one.
    if [[ -f "${zprofile}" ]] && grep -qF "${begin}" "${zprofile}"; then
        local tmp
        tmp="$(mktemp)"
        sed "\|^${begin}\$|,\|^${end}\$|d" "${zprofile}" > "${tmp}"
        mv "${tmp}" "${zprofile}"
    fi

    cat >> "${zprofile}" <<EOF
${begin}
# Homebrew — brew + everything it installs on PATH
eval "\$(/opt/homebrew/bin/brew shellenv)"

# GNU userland ahead of the macOS BSD tools
for _g in coreutils findutils gnu-sed grep gawk gnu-tar gnu-which gnu-indent gpatch make ed; do
    _gb="/opt/homebrew/opt/\${_g}/libexec/gnubin"
    [[ -d "\${_gb}" ]] && path=("\${_gb}" \$path)
done
unset _g _gb

# Homebrew behaviour: trust casks (no quarantine), no prompts, no hints
export HOMEBREW_CASK_OPTS="--no-quarantine"
export HOMEBREW_NO_ASK=1
export HOMEBREW_NO_ENV_HINTS=1
${end}
EOF

    # Apply to the current bootstrap process too.
    export HOMEBREW_CASK_OPTS="--no-quarantine"
    export HOMEBREW_NO_ASK=1
    export HOMEBREW_NO_ENV_HINTS=1

    print_success "Shell environment configured"
}

# _setup_taps
# Taps the third-party repos this installer pulls from and trusts each one.
# Homebrew 6 refuses to load formulae/casks from an untrusted third-party tap
# and warns on every brew invocation until it's trusted — so this runs before
# any other brew command. `brew trust <tap>` trusts the whole tap (all current
# and future formulae/casks). On older Homebrew without the trust requirement
# `brew trust` is absent, so the call is guarded.
function _setup_taps() {
    print_step "Tapping and trusting Homebrew repositories"

    local trust_supported="false"
    brew help trust &>/dev/null && trust_supported="true"

    local tap
    for tap in \
        homeport/tap \
        fluxcd/tap \
        siderolabs/tap \
        hashicorp/tap \
        jandedobbeleer/oh-my-posh \
        nikitabobko/tap; do
        brew tap "${tap}"
        if [[ "${trust_supported}" == "true" ]]; then
            brew trust "${tap}" || print_warning "Failed to trust ${tap}"
        fi
    done
}

# _install_gnu_tools
# Installs the GNU userland tools that ship a "gnubin" dir (unprefixed
# binaries under libexec/gnubin, kept out of the normal keg so they don't
# collide with the BSD versions until the caller opts in via PATH) to
# replace the BSD/ancient versions shipped with macOS. Prepends the gnubin
# paths to PATH so scripts get predictable GNU behaviour without requiring
# g-prefixed commands.
function _install_gnu_tools() {
    print_step "Installing GNU userland tools"

    local gnu_packages=(
        coreutils   # GNU ls, cp, mv, etc  → /opt/homebrew/opt/coreutils/libexec/gnubin
        findutils   # GNU find, xargs      → /opt/homebrew/opt/findutils/libexec/gnubin
        gnu-sed     # GNU sed              → /opt/homebrew/opt/gnu-sed/libexec/gnubin
        grep        # GNU grep             → /opt/homebrew/opt/grep/libexec/gnubin
        gawk        # GNU awk              → /opt/homebrew/opt/gawk/libexec/gnubin
        gnu-tar     # GNU tar              → /opt/homebrew/opt/gnu-tar/libexec/gnubin
        gnu-which   # GNU which            → /opt/homebrew/opt/gnu-which/libexec/gnubin
        gnu-indent  # GNU indent           → /opt/homebrew/opt/gnu-indent/libexec/gnubin
        gpatch      # GNU patch            → /opt/homebrew/opt/gpatch/libexec/gnubin
        make        # GNU make (macOS ships 3.81) → /opt/homebrew/opt/make/libexec/gnubin
        ed          # GNU ed               → /opt/homebrew/opt/ed/libexec/gnubin
        # diffutils (GNU diff/cmp/sdiff) is NOT here — it isn't keg-only and
        # has no gnubin dir; it symlinks straight into /opt/homebrew/bin and
        # shadows BSD diff via the plain PATH. It lives in packages.yaml.
    )

    local pkg
    for pkg in "${gnu_packages[@]}"; do
        install_package "${pkg}" "macos"
    done

    # Prepend all gnubin dirs so GNU tools shadow BSD ones in this session
    local gnubin_dirs=(
        "/opt/homebrew/opt/coreutils/libexec/gnubin"
        "/opt/homebrew/opt/findutils/libexec/gnubin"
        "/opt/homebrew/opt/gnu-sed/libexec/gnubin"
        "/opt/homebrew/opt/grep/libexec/gnubin"
        "/opt/homebrew/opt/gawk/libexec/gnubin"
        "/opt/homebrew/opt/gnu-tar/libexec/gnubin"
        "/opt/homebrew/opt/gnu-which/libexec/gnubin"
        "/opt/homebrew/opt/gnu-indent/libexec/gnubin"
        "/opt/homebrew/opt/gpatch/libexec/gnubin"
        "/opt/homebrew/opt/make/libexec/gnubin"
        "/opt/homebrew/opt/ed/libexec/gnubin"
    )

    local dir
    for dir in "${gnubin_dirs[@]}"; do
        [[ -d "${dir}" ]] && export PATH="${dir}:${PATH}"
    done

    # Persistence for future shells is handled by _setup_shell_env_macos
    # (~/.zprofile), not ~/.zshenv — see the note there.

    print_success "GNU tools installed and prepended to PATH"
}

# _clone_repo
# Clones a git repo to a target dir, idempotently. Guards on the repo's .git so
# a leftover directory from an interrupted clone is wiped and retried rather than
# treated as done (or colliding with `git clone`).
# Parameters:
#   $1 - clone URL
#   $2 - target directory
#   $3 - label for log output
function _clone_repo() {
    local url="${1}" dir="${2}" label="${3}"

    if [[ -d "${dir}/.git" ]]; then
        print_info "${label} already present, skipping clone"
        return
    fi

    print_info "Cloning ${label}"
    rm -rf "${dir}"
    git clone "${url}" "${dir}"
}

function _clone_core() {
    _clone_repo "https://gitlab.com/wd2nf8gqct/dotfiles.core.git" "${CORE_DIR}" "dotfiles.core"
}

function _clone_di() {
    _clone_repo "https://gitlab.com/wd2nf8gqct/dotfiles.di.git" "${DI_DIR}" "dotfiles.di"
}

function _clone_utility_scripts() {
    _clone_repo "https://gitlab.com/wd2nf8gqct/utility-scripts.git" \
        "${UTILITY_SCRIPTS_DIR}" "utility-scripts"
    # setup.sh prompts "Add ~/.local/bin to your PATH? (Y/n)" with no flag to
    # skip it — feed it the (default) Y. PATH itself is handled either way:
    # _create_working_dirs adds ~/.local/bin for this run, and setup.sh appends
    # it to the shell rc.
    printf 'Y\n' | bash "${UTILITY_SCRIPTS_DIR}/setup.sh"
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

# _common_cask_app
# Bundle name of the .app a cask drops in /Applications, for the handful of apps
# an MDM/Jamf fleet commonly pushes before this ever runs. Empty for anything
# not tracked here — those fall through to `brew install --cask --adopt`.
function _common_cask_app() {
    case "${1}" in
        1password)       printf '1Password.app' ;;
        firefox)         printf 'Firefox.app' ;;
        google-chrome)   printf 'Google Chrome.app' ;;
        slack)           printf 'Slack.app' ;;
        zoom)            printf 'zoom.us.app' ;;
        docker)          printf 'Docker.app' ;;
        microsoft-teams) printf 'Microsoft Teams.app' ;;
        *)               printf '' ;;
    esac
}

function _brew_install_cask() {
    local cask="${1}"

    # Already managed by brew — nothing to do.
    brew list --cask "${cask}" &>/dev/null 2>&1 && return

    # Common MDM-pushed app already on disk (possibly a different version, so
    # --adopt below wouldn't take it) — leave the fleet copy alone.
    local app
    app="$(_common_cask_app "${cask}")"
    if [[ -n "${app}" && -d "/Applications/${app}" ]]; then
        print_info "Skipping ${cask} — /Applications/${app} already present (MDM-managed)"
        return
    fi

    print_info "Installing ${cask} (cask)"
    # --adopt: take over an identical pre-existing app instead of erroring out.
    # Returns non-zero on failure so the caller can retry / collect it.
    brew install --cask --adopt "${cask}"
}

# _install_macos_packages
# Installs brew formulas and casks from macos/packages.yaml. Unlike
# core/packages.yaml (shared across arch/ubuntu/nixos, each with its own
# package manager and naming), this file only ever feeds Homebrew — so it
# lists real brew formula names directly and skips the exceptions/
# get_package_name indirection entirely.
function _install_macos_packages() {
    print_step "Installing macOS packages"

    local package
    while IFS= read -r package; do
        [[ -z "${package}" ]] && continue
        _should_skip_package "${package}" && continue
        install_package "${package}" "macos"
    done < <(yq '.packages[]' "${MACOS_PACKAGES_YAML}")

    if [[ "${MINIMAL_MODE}" != "true" ]]; then
        local cask
        local failed_casks=()
        while IFS= read -r cask; do
            [[ -z "${cask}" ]] && continue
            _brew_install_cask "${cask}" || failed_casks+=("${cask}")
        done < <(yq '.casks[]' "${MACOS_PACKAGES_YAML}" 2>/dev/null)

        # Cask downloads come straight from vendor sites/GitHub and drop
        # connections often — give the failures one more shot before giving up.
        if [[ "${#failed_casks[@]}" -gt 0 ]]; then
            print_warning "Retrying failed cask(s): ${failed_casks[*]}"
            local still_failed=()
            local fc
            for fc in "${failed_casks[@]}"; do
                _brew_install_cask "${fc}" || still_failed+=("${fc}")
            done
            if [[ "${#still_failed[@]}" -gt 0 ]]; then
                print_warning "Casks still failing — install manually later: ${still_failed[*]}"
            fi
        fi
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

    # Session PATH for the rest of this run. Persistence for future shells comes
    # from dotfiles.core's ~/.zshenv (~/bin, ~/.local/bin, ~/.cargo/bin,
    # $GOPATH/bin, ~/.atuin/bin, ~/.emacs.d/bin) plus ~/.zprofile for Homebrew.
    export PATH="${HOME}/bin:${HOME}/.local/bin:${HOME}/go/bin:${HOME}/.cargo/bin:${HOME}/.config/emacs/bin:${HOME}/.emacs.d/bin:${HOME}/.atuin/bin:${PATH}"
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

    # doom emacs — guard on the actual binary, not $PATH, and clear a partial
    # checkout so a re-run after an interrupted clone doesn't hit "destination
    # path already exists".
    if [[ ! -x "${HOME}/.emacs.d/bin/doom" ]]; then
        print_info "Installing Doom Emacs"
        rm -rf "${HOME}/.emacs.d"
        git clone --depth 1 --branch v2.1.1 \
            https://github.com/doomemacs/doomemacs "${HOME}/.emacs.d" \
            || print_warning "Doom Emacs clone failed — re-run bootstrap"
    fi

    # custom fonts from dotfiles.core. macOS ~/Library/Fonts must hold real
    # files, flat — CoreText won't follow a symlink or recurse subdirectories
    # (the .fonts tree is nested per-family), so copy each face in.
    local _fontsrc="${HOME}/.dotfiles.core/fonts/.fonts"
    if [[ -d "${_fontsrc}" ]]; then
        rm -f "${HOME}/Library/Fonts/dotfiles"   # remove the old broken symlink
        mkdir -p "${HOME}/Library/Fonts"
        local _copied=0 _f _dest
        while IFS= read -r -d '' _f; do
            _dest="${HOME}/Library/Fonts/$(basename "${_f}")"
            if [[ ! -f "${_dest}" || "${_f}" -nt "${_dest}" ]]; then
                cp -f "${_f}" "${_dest}"
                _copied=$((_copied + 1))
            fi
        done < <(find "${_fontsrc}" -type f \
            \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) -print0)
        [[ "${_copied}" -gt 0 ]] && print_info "Installed ${_copied} font file(s)"
    fi

    # glow config is a stow package in dotfiles.core (glow.yml +
    # catppuccin-mocha.json) — _stow_core wires it. Nothing to do here.
}

# _install_dev_toolchain_macos
# Installs dev tools that aren't available (or current enough) as a plain brew
# formula. Brew formulas for this toolchain live in macos/packages.yaml; the
# hashicorp/tap tap is wired in _setup_taps.
function _install_dev_toolchain_macos() {
    print_step "Installing dev toolchain"

    # Atlas — database schema migrations. Both installers below can fail on a
    # flaky connection; a failure shouldn't abort the whole bootstrap (re-running
    # picks them up).
    if command -v atlas &>/dev/null; then
        print_info "Atlas already installed"
    else
        print_info "Installing Atlas"
        curl -sSf https://atlasgo.sh | sh -s -- --yes \
            || print_warning "Atlas install failed — re-run bootstrap or: curl -sSf https://atlasgo.sh | sh"
    fi

    # mockgen — generates mocks for sqlc-style query interfaces
    if command -v mockgen &>/dev/null; then
        print_info "mockgen already installed"
    elif command -v go &>/dev/null; then
        print_info "Installing mockgen"
        go install go.uber.org/mock/mockgen@latest \
            || print_warning "mockgen install failed (network?) — re-run bootstrap or: go install go.uber.org/mock/mockgen@latest"
    else
        print_warning "go not found, skipping mockgen"
    fi
}

function _install_rust() {
    if command -v rustup &>/dev/null && command -v cargo &>/dev/null; then
        print_info "Rust already installed"
        rustup default stable
        return
    fi

    print_info "Installing rustup"
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path; then
        print_warning "rustup install failed — re-run bootstrap (Rust-dependent tools will be skipped this pass)"
        return
    fi
    # shellcheck source=/dev/null
    source "${HOME}/.cargo/env"
    rustup default stable
    # ~/.cargo/bin is already on PATH via dotfiles.core's ~/.zshenv.
}

function _install_media_tools_macos() {
    print_step "Installing media tools"

    install_package "yt-dlp" "macos"

    if ! command -v ffmpeg-lh &>/dev/null; then
        print_info "Installing ffmpeg-lh"
        [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"
        cargo install --git https://github.com/indiscipline/ffmpeg-loudnorm-helper.git \
            || print_warning "ffmpeg-lh install failed — re-run bootstrap"
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
    secure_gnupg_permissions
    print_success "dotfiles.core wired"
}

# _stow_di_macos
# Wires macOS-specific configs from dotfiles.di (aerospace). The packages
# live under dotfiles.di/macos/, so stow must be told the target is $HOME
# explicitly — its default (the parent of the stow dir) would be
# ~/.dotfiles.di, not ~.
function _stow_di_macos() {
    if [[ ! -d "${DI_DIR}/macos" ]]; then
        print_warning "dotfiles.di/macos not found, skipping di stow"
        return
    fi

    # Clean up output from an earlier run that stowed to the wrong target.
    rm -rf "${DI_DIR}/.config"

    print_step "Wiring dotfiles.di/macos via stow"
    cd "${DI_DIR}/macos"
    stow --adopt -v -t "${HOME}" */
    git restore */
    cd - >/dev/null
    print_success "dotfiles.di/macos wired (aerospace)"

    # First launch of AeroSpace. macOS will prompt for Accessibility; it also
    # needs Input Monitoring for the alt- hotkeys (System Settings › Privacy &
    # Security). Both grants only take effect after AeroSpace is restarted, and
    # a full logout/reboot is often required before the global hotkeys register.
    # Once permitted, aerospace.toml handles the rest via start-at-login.
    if [[ -d "/Applications/AeroSpace.app" ]] && ! pgrep -xq "AeroSpace"; then
        print_info "Launching AeroSpace — grant Accessibility AND Input Monitoring when asked"
        print_warning "AeroSpace hotkeys need a logout or reboot after granting permissions"
        open -a AeroSpace || print_warning "Could not launch AeroSpace — open it manually"
    fi
}

function _install_tmux_plugins() {
    print_info "Installing tmux plugins"
    if [[ ! -x "${HOME}/.tmux/plugins/tpm/tpm" ]]; then
        rm -rf "${HOME}/.tmux/plugins/tpm"
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
        # -es (Ex + batch) keeps vim off the alternate screen / out of raw mode.
        # Save and restore the tty regardless — a plugin's post-install hook can
        # still leave it in -onlcr (the "staircase" scrollback).
        local _stty
        _stty="$(stty -g 2>/dev/null || true)"
        vim -es -u "${HOME}/.vimrc" -i NONE \
            -c 'PlugInstall --sync' -c 'qa!' </dev/null >/dev/null 2>&1 || true
        [[ -n "${_stty}" ]] && stty "${_stty}" 2>/dev/null || true
    fi

    print_info "Installing yazi packages"
    ya pkg install </dev/null || print_warning "yazi package install failed"

    # atuin
    if ! command -v atuin &>/dev/null; then
        print_info "Installing atuin"
        curl --proto '=https' --tlsv1.2 -LsSf \
            https://github.com/atuinsh/atuin/releases/latest/download/atuin-installer.sh \
            | sh -s -- --no-modify-path 2>/dev/null \
            || curl --proto '=https' --tlsv1.2 -LsSf \
                https://github.com/atuinsh/atuin/releases/latest/download/atuin-installer.sh \
                | sh

        # ~/.atuin/bin is already on PATH via dotfiles.core's ~/.zshenv.
        [[ -d "${HOME}/.atuin/bin" ]] && export PATH="${HOME}/.atuin/bin:${PATH}"
    fi

    # default shell — zsh is already default on macOS 10.15+, but ensure it
    if [[ "$(basename "${SHELL}")" != "zsh" ]]; then
        print_info "Changing default shell to zsh"
        chsh -s /bin/zsh
    fi

    # Undo any tty damage (raw mode / -onlcr) left by a sub-step above.
    stty sane 2>/dev/null || true

    print_success "Post-install configuration complete"
}
