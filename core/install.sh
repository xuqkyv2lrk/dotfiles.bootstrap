#!/usr/bin/env bash
# Core dotfiles installer.
# Installs base packages, binaries, and wires dotfiles.core via stow.
# Sourced by bootstrap.sh — do not execute directly.

readonly CORE_DIR="${HOME}/.dotfiles.core"
readonly CORE_PACKAGES_YAML="${SCRIPT_DIR}/core/packages.yaml"

# Packages skipped in minimal/server mode
readonly CORE_SKIP_PACKAGES=(
    "firefox" "thunderbird" "foot" "bitwarden" "1password"
    "cava" "mpc" "mpd" "mpv" "ncmpcpp" "ncspot"
    "dnsmasq" "ebtables" "libvirt" "qemu" "virt-install" "virt-manager" "virt-viewer"
    "bluetooth" "wl-clipboard"
)

# install_core
# Main entry point. Orchestrates full core installation.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - hardware identifier
function install_core() {
    local distro="${1}"
    local hardware="${2}"

    print_step "Installing core"

    _clone_core
    _setup_repos "${distro}"
    system_update "${distro}"
    _install_core_packages "${distro}"
    _create_working_dirs
    _install_binaries
    _install_rust
    _install_media_tools "${distro}"
    _stow_core "${distro}"
    _install_tmux_plugins
    _create_nm_dispatcher
    _configure_hardware "${hardware}" "${distro}"
    _configure_uv1_audio
    _configure_sleep_state
    _post_install "${distro}"

    print_success "Core installation complete."
}

function _clone_core() {
    if [[ ! -d "${CORE_DIR}" ]]; then
        print_info "Cloning dotfiles.core"
        git clone "https://gitlab.com/wd2nf8gqct/dotfiles.core.git" "${CORE_DIR}"
    else
        print_info "dotfiles.core already present, skipping clone"
    fi
}

# _setup_repos
# Configures additional package repositories before installation.
# Arch: updates mirrors via reflector, installs yay, removes conflicting iptables.
# Ubuntu: adds 1Password repo, fastfetch PPA, and kubectl repo.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _setup_repos() {
    local distro="${1}"

    print_step "Configuring repositories"

    case "${distro}" in
        arch)
            print_info "Updating mirrors with reflector"
            sudo pacman -S --needed --noconfirm reflector
            sudo reflector --country US --latest 10 --protocol https \
                --sort age --download-timeout 10 \
                --save /etc/pacman.d/mirrorlist

            if ! command -v yay &>/dev/null; then
                print_info "Installing yay"
                sudo pacman -S --needed --noconfirm git base-devel
                git clone https://aur.archlinux.org/yay.git /tmp/yay
                cd /tmp/yay
                makepkg -si --noconfirm
                cd - >/dev/null
                rm -rf /tmp/yay
            fi

            # Remove iptables if present — conflicts with ebtables
            if [[ -n "$(yay -Qi iptables 2>/dev/null | grep "^Name")" ]]; then
                print_info "Removing conflicting package iptables"
                yay -Rdd --noconfirm iptables
            fi
            ;;

        ubuntu)
            if [[ "${MINIMAL_MODE}" != "true" ]]; then
                print_info "Adding 1Password repository"
                curl -sS https://downloads.1password.com/linux/keys/1password.asc \
                    | sudo gpg --dearmor --yes \
                        --output /usr/share/keyrings/1password-archive-keyring.gpg
                printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main\n' \
                    | sudo tee /etc/apt/sources.list.d/1password.list >/dev/null
                sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22
                curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
                    | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null
                sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
                curl -sS https://downloads.1password.com/linux/keys/1password.asc \
                    | sudo gpg --dearmor --yes \
                        --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
            fi

            print_info "Adding fastfetch PPA"
            sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch

            print_info "Adding kubectl repository"
            local latest_version
            local latest_minor
            latest_version="$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases/latest \
                | grep tag_name | cut -d '"' -f4)"
            latest_minor="$(printf "%s" "${latest_version}" | grep -oE 'v1\.[0-9]+')"
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/${latest_minor}/deb/Release.key" \
                | sudo gpg --dearmor --yes \
                    --output /etc/apt/keyrings/kubernetes-apt-keyring.gpg
            printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' \
                "${latest_minor}" \
                | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
            ;;
    esac
}

# _should_skip_package
# Returns 0 (true) if a package should be skipped in minimal mode.
# Parameters:
#   $1 - package name
function _should_skip_package() {
    local package="${1}"

    [[ "${MINIMAL_MODE}" != "true" ]] && return 1

    local skip_pkg
    for skip_pkg in "${CORE_SKIP_PACKAGES[@]}"; do
        if [[ "${package}" == "${skip_pkg}" ]]; then
            print_info "Skipping ${package} (minimal mode)"
            return 0
        fi
    done

    return 1
}

# _install_core_packages
# Reads packages.yaml and installs each package.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _install_core_packages() {
    local distro="${1}"

    print_step "Installing core packages"

    local package
    while IFS= read -r package; do
        [[ -n "${package}" ]] && _install_package_core "${package}" "${distro}"
    done < <(get_packages "${CORE_PACKAGES_YAML}")
}

# _install_package_core
# Installs a single package, handling distro exceptions and special cases.
# Parameters:
#   $1 - package name
#   $2 - distro (arch | ubuntu)
function _install_package_core() {
    local package="${1}"
    local distro="${2}"

    _should_skip_package "${package}" && return

    local package_name
    package_name="$(get_package_name "${package}" "${distro}" "${CORE_PACKAGES_YAML}")"

    [[ "${package_name}" == "skip" ]] && return

    # Ubuntu special cases
    if [[ "${distro}" == "ubuntu" ]]; then
        case "${package_name}" in
            foot)
                _install_foot_ubuntu
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y foot-terminfo
                return
                ;;
            bitwarden)
                if [[ -z "$(dpkg -l bitwarden 2>/dev/null | grep "^ii")" ]]; then
                    print_info "Installing bitwarden (.deb)"
                    wget -O /tmp/Bitwarden-latest.deb \
                        "https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=deb"
                    sudo dpkg -i /tmp/Bitwarden-latest.deb || sudo apt-get -f install -y
                    rm /tmp/Bitwarden-latest.deb
                else
                    print_info "bitwarden already installed, skipping"
                fi
                return
                ;;
        esac
    fi

    install_package "${package_name}" "${distro}"
}

# _install_foot_ubuntu
# Installs foot terminal on Ubuntu. Tries apt first, falls back to source build.
# foot 1.17+ options are in the dotfiles — patched for Ubuntu's 1.16.x via
# _patch_foot_config_ubuntu after stow.
function _install_foot_ubuntu() {
    if command -v foot &>/dev/null; then
        print_info "foot already installed, skipping"
        return
    fi

    print_info "Installing foot"

    if sudo apt-get install -y foot 2>/dev/null; then
        print_success "foot installed via apt"
        return
    fi

    print_info "foot not in apt, building from source"
    sudo apt-get install -y \
        build-essential meson ninja-build pkg-config wayland-protocols \
        libwayland-dev libxkbcommon-dev libpixman-1-dev libfcft-dev libutf8proc-dev \
        libfontconfig1-dev libpam0g-dev scdoc

    git clone https://codeberg.org/dnkl/foot.git /tmp/foot
    cd /tmp/foot
    meson setup build
    ninja -C build
    sudo ninja -C build install
    cd - >/dev/null
    rm -rf /tmp/foot

    print_success "foot installed from source"
}

# _patch_foot_config_ubuntu
# Patches foot.ini for Ubuntu's foot 1.16.x after stow.
# foot 1.17 introduced resize-by-cells, cursor.unfocused-style, and
# [colors-dark]/[colors-light]. Ubuntu noble ships 1.16.2 and errors on these.
# stow symlinks ~/.config/foot — this replaces the symlink with real files so
# patches don't propagate back to the dotfiles source.
function _patch_foot_config_ubuntu() {
    local foot_dir="${HOME}/.config/foot"
    local config="${foot_dir}/foot.ini"
    local foot_version
    foot_version="$(foot --version 2>/dev/null | awk '{print $3}')"

    local major minor
    major="$(printf "%s" "${foot_version}" | cut -d. -f1)"
    minor="$(printf "%s" "${foot_version}" | cut -d. -f2)"

    if [[ "${major}" -gt 1 || ( "${major}" -eq 1 && "${minor}" -ge 17 ) ]]; then
        return 0
    fi

    print_info "foot ${foot_version} detected — patching config for 1.16.x compatibility"

    if [[ -L "${foot_dir}" ]]; then
        local stow_target
        stow_target="$(readlink -f "${foot_dir}")"
        local tmp_dir
        tmp_dir="$(mktemp -d)"
        cp -a "${stow_target}/." "${tmp_dir}/"
        rm "${foot_dir}"
        mv "${tmp_dir}" "${foot_dir}"
    fi

    [[ -f "${config}" ]] || return 0

    sed -i 's/^resize-by-cells=no/# resize-by-cells=no  # foot 1.17+; re-enable after upgrade/' "${config}"
    sed -i 's/^unfocused-style=none/# unfocused-style=none  # foot 1.17+; re-enable after upgrade/' "${config}"
    sed -i 's/^\[colors-dark\]/[colors] # was [colors-dark]; rename back after foot upgrade/' "${config}"

    print_success "foot config patched for 1.16.x"
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

    export PATH="${HOME}/bin:${HOME}/.emacs.d/bin:${HOME}/.atuin/bin:${PATH}"
}

# _install_binaries
# Installs tools not available via standard package managers.
function _install_binaries() {
    print_step "Installing binaries"

    # aws-cli
    if ! command -v aws &>/dev/null; then
        print_info "Installing aws-cli"
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
        unzip /tmp/awscliv2.zip -d /tmp/aws-install
        sudo /tmp/aws-install/aws/install
        rm -rf /tmp/awscliv2.zip /tmp/aws-install
    fi

    # dyff
    if ! command -v dyff &>/dev/null; then
        print_info "Installing dyff"
        curl -s --location https://git.io/JYfAY | bash
    fi

    # diff-so-fancy
    if ! command -v diff-so-fancy &>/dev/null; then
        print_info "Installing diff-so-fancy"
        git clone https://github.com/so-fancy/diff-so-fancy.git /tmp/diff-so-fancy
        sudo cp /tmp/diff-so-fancy/diff-so-fancy /usr/local/bin/
        sudo cp -r /tmp/diff-so-fancy/lib /usr/local/bin/
        rm -rf /tmp/diff-so-fancy
    fi

    # oh-my-posh
    if ! command -v oh-my-posh &>/dev/null; then
        print_info "Installing oh-my-posh"
        curl -s https://ohmyposh.dev/install.sh | bash -s
    fi

    # tfenv
    if ! command -v tfenv &>/dev/null; then
        print_info "Installing tfenv"
        git clone --depth 1 --filter=blob:none --sparse \
            https://github.com/tfutils/tfenv.git /tmp/tfenv
        cd /tmp/tfenv
        git sparse-checkout set bin
        mv bin/* "${HOME}/bin/"
        cd - >/dev/null
        rm -rf /tmp/tfenv
    fi

    # sops
    if ! command -v sops &>/dev/null; then
        print_info "Installing sops"
        local sops_version
        sops_version="$(curl -s https://api.github.com/repos/getsops/sops/releases/latest \
            | grep tag_name | cut -d '"' -f4)"
        curl -sLo /tmp/sops \
            "https://github.com/getsops/sops/releases/download/${sops_version}/sops-${sops_version}.linux.amd64"
        sudo install -m 755 /tmp/sops /usr/local/bin/sops
        rm /tmp/sops
    fi

    # yazi
    if ! command -v yazi &>/dev/null; then
        print_info "Installing yazi"
        local yazi_version
        yazi_version="$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest \
            | grep '"tag_name"' | cut -d '"' -f4)"
        local yazi_tmp
        yazi_tmp="$(mktemp -d)"
        curl -sL "https://github.com/sxyazi/yazi/releases/download/${yazi_version}/yazi-x86_64-unknown-linux-musl.zip" \
            -o "${yazi_tmp}/yazi.zip"
        unzip -q "${yazi_tmp}/yazi.zip" -d "${yazi_tmp}"
        sudo install -m 755 "${yazi_tmp}/yazi-x86_64-unknown-linux-musl/yazi" /usr/local/bin/yazi
        sudo install -m 755 "${yazi_tmp}/yazi-x86_64-unknown-linux-musl/ya" /usr/local/bin/ya
        rm -rf "${yazi_tmp}"
    fi

    # helm
    if ! command -v helm &>/dev/null; then
        print_info "Installing helm"
        curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    # flux
    if ! command -v flux &>/dev/null; then
        print_info "Installing flux"
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi

    # talosctl
    if ! command -v talosctl &>/dev/null; then
        print_info "Installing talosctl"
        curl -sL https://talos.dev/install | sh
    fi

    # doom emacs
    if ! command -v doom &>/dev/null; then
        print_info "Installing doom emacs"
        git clone --depth 1 https://github.com/doomemacs/doomemacs "${HOME}/.emacs.d"
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

# _install_media_tools
# Installs yt-dlp (Ubuntu only — Arch gets it via pacman) and ffmpeg-lh via cargo.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _install_media_tools() {
    local distro="${1}"

    print_step "Installing media tools"

    if [[ "${distro}" == "ubuntu" ]]; then
        if ! command -v yt-dlp &>/dev/null; then
            print_info "Installing yt-dlp"
            pip3 install --user yt-dlp
        fi
    fi

    if ! command -v ffmpeg-lh &>/dev/null; then
        print_info "Installing ffmpeg-lh"
        [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"
        cargo install --git https://github.com/indiscipline/ffmpeg-loudnorm-helper.git
    fi
}

function _install_tmux_plugins() {
    print_info "Installing tmux plugins"
    if [[ ! -d "${HOME}/.tmux/plugins/tpm" ]]; then
        git clone "https://github.com/tmux-plugins/tpm" "${HOME}/.tmux/plugins/tpm"
    fi
    bash "${HOME}/.tmux/plugins/tpm/scripts/install_plugins.sh"
}

# _create_nm_dispatcher
# Creates a NetworkManager dispatcher script for automatic timezone updates.
function _create_nm_dispatcher() {
    local dispatcher_file="/etc/NetworkManager/dispatcher.d/09-timezone.sh"

    [[ -f "${dispatcher_file}" ]] && return

    print_info "Creating NetworkManager timezone dispatcher"
    sudo mkdir -p "/etc/NetworkManager/dispatcher.d"
    sudo tee "${dispatcher_file}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

function log() {
    logger -t "timezone-update" "${1}"
}

function update_timezone() {
    local new_timezone
    new_timezone="$(curl --fail --silent --show-error "https://ipapi.co/timezone")"
    if [[ -n "${new_timezone}" ]]; then
        timedatectl set-timezone "${new_timezone}"
        log "Timezone updated to ${new_timezone}"
    else
        log "Failed to fetch timezone"
    fi
}

case "${2}" in
    connectivity-change) update_timezone ;;
esac
EOF
    sudo chmod +x "${dispatcher_file}"
    sudo systemctl enable --now NetworkManager-dispatcher
}

# _configure_uv1_audio
# Configures modprobe options for the Universal Audio UV1 interface.
function _configure_uv1_audio() {
    local conf_file="/etc/modprobe.d/uv1-audio.conf"

    [[ -f "${conf_file}" ]] && return

    print_info "Configuring UV1 audio interface"
    printf 'options snd_usb_audio implicit_fb=1 ignore_ctl_error=1 autoclock=0 quirk_flags=0x1397:0x0510:0x40\n' \
        | sudo tee "${conf_file}" >/dev/null

    if sudo modprobe -r snd-usb-audio 2>/dev/null && sudo modprobe snd-usb-audio 2>/dev/null; then
        print_success "UV1 audio configuration applied"
    else
        print_warning "UV1 config written but module reload failed (device may be in use)"
        print_warning "Unplug the UV1 and run: sudo modprobe -r snd-usb-audio && sudo modprobe snd-usb-audio"
    fi
}

# _configure_sleep_state
# Detects S0ix (Modern Standby) support and optionally enables it via kernel param.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _configure_sleep_state() {
    local distro="${1}"

    [[ "${MINIMAL_MODE}" == "true" ]] && return
    [[ ! -f /sys/power/mem_sleep ]] && return

    if [[ -n "$(grep "\[s2idle\]" /sys/power/mem_sleep 2>/dev/null)" ]]; then
        print_info "S0ix (Modern Standby) already active"
        return
    fi

    if [[ -z "$(grep "s2idle" /sys/power/mem_sleep 2>/dev/null)" ]]; then
        print_info "S0ix not supported on this hardware — keeping S3"
        return
    fi

    print_step "S0ix (Modern Standby) is supported on this hardware"
    printf "${TEXT}S0ix enables faster resume and wake-on-events (e.g. lid-open with external monitor).${RESET}\n"
    printf "${SUBTEXT}Trade-off: may increase battery drain on some hardware.${RESET}\n"

    select choice in "Enable S0ix (Modern Standby)" "Keep S3 (Suspend-to-RAM)"; do
        case "${choice}" in
            "Enable S0ix (Modern Standby)")
                add_kernel_parameter "mem_sleep_default=s2idle" "${distro}"
                print_success "S0ix enabled. Reboot to apply."
                return
                ;;
            "Keep S3 (Suspend-to-RAM)")
                print_info "Keeping S3 suspend"
                return
                ;;
            *)
                print_error "Invalid option. Please try again."
                ;;
        esac
    done
}

# _configure_hardware
# Applies hardware-specific configuration.
# Parameters:
#   $1 - hardware identifier
#   $2 - distro (arch | ubuntu)
function _configure_hardware() {
    local hardware="${1}"
    local distro="${2}"

    case "${hardware}" in
        "ThinkPad T480s") _configure_thinkpad_t480s ;;
        "ROG")            _configure_rog "${distro}" ;;
        "XPS 13 9350")    _configure_xps_13_9350 ;;
        *)                print_info "No hardware-specific configuration needed" ;;
    esac
}

function _configure_thinkpad_t480s() {
    print_info "Applying ThinkPad T480s config — disabling IR camera"
    sudo tee /etc/udev/rules.d/80-lenovo-ir-camera.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="04f2", ATTRS{idProduct}=="b615", ATTR{authorized}="0"
EOF
}

# _configure_rog
# Adds the ASUS Linux repo and installs ROG tooling on Arch.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _configure_rog() {
    local distro="${1}"

    if [[ "${distro}" != "arch" ]]; then
        print_warning "ROG-specific packages are only configured for Arch"
        return
    fi

    print_step "Configuring ASUS ROG"
    sudo pacman-key --recv-keys 8F654886F17D497FEFE3DB448B15A6B0E9A3FA35
    sudo pacman-key --lsign-key 8F654886F17D497FEFE3DB448B15A6B0E9A3FA35

    if [[ -z "$(grep "^\[g14\]" /etc/pacman.conf)" ]]; then
        printf '\n[g14]\nServer = https://arch.asus-linux.org\n' \
            | sudo tee -a /etc/pacman.conf >/dev/null
        yay -Syu
    fi

    sudo pacman -S --noconfirm asusctl supergfxctl rog-control-center
    sudo systemctl enable asusd
    sudo systemctl enable supergfxd
    print_success "ROG packages installed"
}

function _configure_xps_13_9350() {
    local firmware_src="${SCRIPT_DIR}/core/system_components/xps_13_9350/bluetooth/BCM4350C5_003.006.007.0095.1703.hcd"
    local firmware_dst="/lib/firmware/brcm/BCM4350C5-0a5c-6412.hcd"

    print_info "Installing Bluetooth firmware for XPS 13 9350"
    [[ ! -d "/lib/firmware/brcm" ]] && sudo mkdir -p /lib/firmware/brcm
    sudo cp -f "${firmware_src}" "${firmware_dst}"
    print_success "Bluetooth firmware installed"
}

# _stow_core
# Wires dotfiles.core into $HOME via stow.
# On Ubuntu, skips the foot package and patches foot.ini for 1.16.x compatibility.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _stow_core() {
    local distro="${1}"

    print_step "Wiring dotfiles.core via stow"
    cd "${CORE_DIR}"

    if [[ "${distro}" == "ubuntu" ]]; then
        local stow_pkgs
        mapfile -t stow_pkgs < <(find . -maxdepth 1 -mindepth 1 -type d \
            -name '[^.]*' ! -name 'foot' -printf '%f\n')
        stow --adopt -v "${stow_pkgs[@]}"
        git restore "${stow_pkgs[@]}"
        _patch_foot_config_ubuntu
    else
        stow --adopt -v */
        git restore */
    fi

    cd - >/dev/null
    print_success "dotfiles.core wired"
}

# _post_install
# Post-installation tasks: doom sync, bat cache, vim plugins, libvirtd, atuin, chsh.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _post_install() {
    local distro="${1}"

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

    # bat cache
    if [[ "${distro}" == "ubuntu" ]]; then
        if ! command -v bat &>/dev/null && command -v batcat &>/dev/null; then
            print_info "Symlinking batcat → bat"
            sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
        fi
    fi
    print_info "Rebuilding bat cache"
    bat cache --build

    # vim plugins
    if [[ -f "${HOME}/.vim/autoload/plug.vim" ]]; then
        print_info "Installing vim plugins"
        vim +'PlugInstall --sync' +qa
    fi

    # yazi packages
    print_info "Installing yazi packages"
    ya pkg install

    # libvirtd (skip in minimal mode)
    if [[ "${MINIMAL_MODE}" != "true" ]]; then
        print_info "Enabling libvirtd"
        sudo systemctl enable --now libvirtd
    fi

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

    # default shell → zsh
    if [[ "$(basename "${SHELL}")" != "zsh" ]]; then
        print_info "Changing default shell to zsh"
        sudo chsh -s "/bin/zsh" "$(whoami)"
    fi

    print_success "Post-install configuration complete"
}
