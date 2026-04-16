#!/usr/bin/env bash
# Desktop interface installer.
# Installs DE packages and wires dotfiles.di via stow.
# Sourced by bootstrap.sh — do not execute directly.

readonly DI_DIR="${HOME}/.dotfiles.di"
readonly DI_PACKAGES_YAML="${SCRIPT_DIR}/di/packages.yaml"

# DE-specific option flags set by _select_de and consumed by downstream functions
USE_PAPERWM="false"

# install_di
# Main entry point. Orchestrates full desktop interface installation.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - hardware identifier
function install_di() {
    local distro="${1}"
    local hardware="${2}"

    print_step "Installing desktop interface"

    _clone_di

    local desktop_interface
    _select_de "${distro}" desktop_interface

    print_step "Installing ${desktop_interface} on ${distro}"

    _install_di_deps "${distro}"
    _install_local_pkgbuilds "${distro}" "${desktop_interface}"
    _configure_pre_install "${distro}" "${desktop_interface}"
    _install_di_packages "${distro}"
    _install_desktop_packages "${distro}" "${desktop_interface}"
    _configure_nvidia_for_niri "${desktop_interface}" "${distro}"
    _stow_di "${distro}" "${desktop_interface}"
    _configure_desktop_interface "${distro}" "${desktop_interface}"

    if [[ "${desktop_interface}" == "gnome" && "${USE_PAPERWM}" == "true" ]]; then
        _install_paperwm
    fi

    _configure_usb_audio
    _configure_di_hardware "${hardware}"

    print_success "Desktop interface installation complete."
}

function _clone_di() {
    if [[ ! -d "${DI_DIR}" ]]; then
        print_info "Cloning dotfiles.di"
        git clone --recurse-submodules \
            "https://gitlab.com/wd2nf8gqct/dotfiles.di.git" "${DI_DIR}"
    else
        print_info "dotfiles.di already present, skipping clone"
    fi
}

# _select_de
# Prompts the user to select a desktop interface and DE-specific options.
# Sets USE_PAPERWM as a side effect.
# On Ubuntu, asks how to configure the existing GNOME or whether to install Niri.
# On Arch, presents the full DE list from packages.yaml.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - nameref variable to receive the selected DE
function _select_de() {
    local distro="${1}"
    local -n _de_result="${2}"

    if [[ "${distro}" == "ubuntu" ]]; then
        print_step "How would you like to configure your desktop?"
        printf "${TEXT}Ubuntu includes GNOME by default.${RESET}\n"
        select de in "Configure GNOME (+ optional PaperWM)" "Install Niri (Wayland compositor)" "Skip"; do
            case "${de}" in
                "Configure GNOME (+ optional PaperWM)")
                    _de_result="gnome"
                    _prompt_paperwm
                    return
                    ;;
                "Install Niri (Wayland compositor)")
                    _de_result="niri"
                    return
                    ;;
                "Skip")
                    print_info "Skipping desktop configuration"
                    exit 0
                    ;;
                *) print_error "Invalid option. Please try again." ;;
            esac
        done
    else
        print_step "Do you want to install a desktop interface?"
        select choice in "Yes" "No"; do
            case "${choice}" in
                "Yes")
                    print_step "Please select a desktop interface:"
                    local options
                    mapfile -t options < <(yq -e '.desktop_packages | keys | .[]' \
                        "${DI_PACKAGES_YAML}" 2>/dev/null | tr -d '"')
                    select de in "${options[@]}"; do
                        if [[ -n "${de}" ]]; then
                            _de_result="${de}"
                            case "${de}" in
                                gnome) _prompt_paperwm ;;
                            esac
                            return
                        else
                            print_error "Invalid option. Please try again."
                        fi
                    done
                    ;;
                "No")
                    print_info "Skipping desktop interface installation"
                    exit 0
                    ;;
                *) print_error "Invalid option. Please try again." ;;
            esac
        done
    fi
}

function _prompt_paperwm() {
    print_step "Would you like to install PaperWM?"
    select pw_choice in "Yes" "No"; do
        case "${pw_choice}" in
            "Yes") USE_PAPERWM="true";  return ;;
            "No")  USE_PAPERWM="false"; return ;;
            *)     print_error "Invalid option. Please try again." ;;
        esac
    done
}


# _install_di_deps
# Installs build tools required by the DE installation process.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _install_di_deps() {
    local distro="${1}"
    local dep

    print_step "Installing di dependencies"

    declare -A deps=(
        ["git"]="git"
        ["stow"]="stow"
        ["cmake"]="cmake"
        ["meson"]="meson"
    )

    for dep in "${!deps[@]}"; do
        if ! command -v "${deps[${dep}]}" &>/dev/null; then
            install_package "${dep}" "${distro}"
        fi
    done

    # yq — Ubuntu needs a manual install
    if ! command -v yq &>/dev/null; then
        if [[ "${distro}" == "ubuntu" ]]; then
            print_info "Installing yq"
            sudo curl -fsSL -o /usr/local/bin/yq \
                "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
            sudo chmod +x /usr/local/bin/yq
        else
            install_package "yq" "${distro}"
        fi
    fi
}

# _install_local_pkgbuilds
# Builds and installs PKGBUILDs from pkgbuilds/ whose name appears in the
# active DE's package list. Arch-only.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - desktop interface
function _install_local_pkgbuilds() {
    local distro="${1}"
    local desktop_interface="${2}"
    local pkgbuilds_dir="${DI_DIR}/pkgbuilds"

    [[ "${distro}" != "arch" ]] && return 0
    [[ -d "${pkgbuilds_dir}" ]] || return 0

    local active_packages
    mapfile -t active_packages < <(
        yq -e ".packages[]" "${DI_PACKAGES_YAML}" 2>/dev/null
        yq -e ".desktop_packages.${desktop_interface}[]" "${DI_PACKAGES_YAML}" 2>/dev/null
    )

    local pkgbuild_dir pkg_name pkg match
    for pkgbuild_dir in "${pkgbuilds_dir}"/*/; do
        pkg_name="$(basename "${pkgbuild_dir}")"
        match="false"
        for pkg in "${active_packages[@]}"; do
            if [[ "${pkg//\"/}" == "${pkg_name}" ]]; then
                match="true"
                break
            fi
        done
        [[ "${match}" == "false" ]] && continue

        if pacman -Qi "${pkg_name}" &>/dev/null; then
            print_info "Local package ${pkg_name} already installed, skipping"
        else
            print_step "Building local PKGBUILD: ${pkg_name}"
            (cd "${pkgbuild_dir}" && makepkg -si --noconfirm)
        fi
    done
}

# _configure_pre_install
# Performs distro/DE-specific configuration before the main package loop.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - desktop interface
function _configure_pre_install() {
    local distro="${1}"
    local desktop_interface="${2}"

    case "${desktop_interface}" in
        gnome)
            mkdir -p "${HOME}/.local/share/gnome-shell"
            ;;
        hyprland|niri|sway)
            if [[ "${desktop_interface}" == "sway" ]]; then
                print_info "Installing swaysome"
                cargo install --locked --root "${HOME}" swaysome
            fi
            if [[ "${distro}" == "ubuntu" && "${desktop_interface}" == "niri" ]]; then
                _install_niri_stack_ubuntu
            fi
            ;;
        *)
            print_error "Unsupported desktop interface: ${desktop_interface}"
            ;;
    esac
}

# _install_di_packages
# Installs base packages defined in di's packages.yaml.
# Parameters:
#   $1 - distro (arch | ubuntu)
function _install_di_packages() {
    local distro="${1}"

    print_step "Installing di base packages"

    local packages pkg
    mapfile -t packages < <(yq -e ".packages[]" "${DI_PACKAGES_YAML}" 2>/dev/null)
    packages=("${packages[@]//\"/}")

    for pkg in "${packages[@]}"; do
        local pkg_name
        pkg_name="$(get_package_name "${pkg}" "${distro}" "${DI_PACKAGES_YAML}")"
        pkg_name="${pkg_name//\"/}"
        [[ "${pkg_name}" == "skip" ]] && continue
        install_package "${pkg_name}" "${distro}"
    done
}

# _install_desktop_packages
# Installs DE-specific packages, filtering out those replaced by Noctalia/Quickshell.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - desktop interface
function _install_desktop_packages() {
    local distro="${1}"
    local desktop_interface="${2}"

    print_step "Installing ${desktop_interface} packages"

    local packages pkg
    mapfile -t packages < <(yq -e ".desktop_packages.${desktop_interface}[]" \
        "${DI_PACKAGES_YAML}" 2>/dev/null)
    packages=("${packages[@]//\"/}")

    local qs_replaces=()
    mapfile -t qs_replaces < <(yq -e ".replaces[]" \
        "${DI_DIR}/quickshell/manifest.json" 2>/dev/null)
    qs_replaces=("${qs_replaces[@]//\"/}")

    for pkg in "${packages[@]}"; do
        local skip="false" replaced
        for replaced in "${qs_replaces[@]}"; do
            if [[ "${pkg}" == "${replaced}" ]]; then
                skip="true"
                break
            fi
        done
        [[ "${skip}" == "true" ]] && continue

        local pkg_name
        pkg_name="$(get_package_name "${pkg}" "${distro}" "${DI_PACKAGES_YAML}")"
        pkg_name="${pkg_name//\"/}"
        [[ "${pkg_name}" == "skip" ]] && continue
        install_package "${pkg_name}" "${distro}"
    done

    # Quickshell-specific packages
    local qs_packages qs_pkg
    mapfile -t qs_packages < <(yq -e ".desktop_packages.quickshell[]" \
        "${DI_PACKAGES_YAML}" 2>/dev/null)
    qs_packages=("${qs_packages[@]//\"/}")
    for qs_pkg in "${qs_packages[@]}"; do
        install_package "${qs_pkg}" "${distro}"
    done
}

# _stow_di
# Wires dotfiles.di into $HOME via stow, filtering Quickshell-replaced packages.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - desktop interface
function _stow_di() {
    local distro="${1}"
    local desktop_interface="${2}"

    print_step "Wiring dotfiles.di via stow"

    local qs_replaces=()
    mapfile -t qs_replaces < <(yq -e ".replaces[]" \
        "${DI_DIR}/quickshell/manifest.json" 2>/dev/null)
    qs_replaces=("${qs_replaces[@]//\"/}")

    # Remove pre-existing catppuccin gtk-4.0 symlinks so stow can take ownership
    rm -f "${HOME}/.config/gtk-4.0/gtk.css" \
          "${HOME}/.config/gtk-4.0/gtk-dark.css" \
          "${HOME}/.config/gtk-4.0/assets" 2>/dev/null || true

    local dir dirname skip replaced
    for dir in "${DI_DIR}/${desktop_interface}"/*/; do
        dirname="$(basename "${dir}")"
        [[ "${dirname}" == _* ]] && continue

        skip="false"
        for replaced in "${qs_replaces[@]}"; do
            if [[ "${dirname}" == "${replaced}" ]]; then
                skip="true"
                break
            fi
        done
        [[ "${skip}" == "true" ]] && continue

        stow --adopt -v -t "${HOME}" -d "${DI_DIR}/${desktop_interface}" "${dirname}"
    done
    git -C "${DI_DIR}/${desktop_interface}" restore */ 2>/dev/null || true

    print_info "Wiring quickshell configs"
    [[ -d "${DI_DIR}/quickshell/quickshell" ]] && \
        stow --adopt -v -t "${HOME}" -d "${DI_DIR}/quickshell" quickshell
    [[ -d "${DI_DIR}/quickshell/noctalia-shell" ]] && \
        stow --adopt -v -t "${HOME}" -d "${DI_DIR}/quickshell" noctalia
    git -C "${DI_DIR}/quickshell" restore */ 2>/dev/null || true

    if [[ "${desktop_interface}" != "gnome" ]]; then
        local compositor_config_dir
        case "${desktop_interface}" in
            hyprland) compositor_config_dir="hypr" ;;
            *)        compositor_config_dir="${desktop_interface}" ;;
        esac
        _generate_autostart "${compositor_config_dir}"
    fi

    print_success "dotfiles.di wired"
}

# _generate_autostart
# Generates a compositor-specific autostart.sh.
# Parameters:
#   $1 - compositor config dir name (hypr | niri | sway)
function _generate_autostart() {
    local compositor="${1}"
    local config_dir="${HOME}/.config/${compositor}"
    local script="${config_dir}/autostart.sh"

    mkdir -p "${config_dir}"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n\n'
        printf '# Compositor-specific\n'

        case "${compositor}" in
            hypr)
                printf '/usr/bin/lxqt-policykit-agent &\n'
                printf '%s/.config/hypr/scripts/xdg_portal_hyprland.sh &\n' "${HOME}"
                printf 'hypridle &\n'
                printf '%s/.config/hypr/scripts/monitor_hotplug.sh &\n' "${HOME}"
                ;;
            niri)
                printf '/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &\n'
                printf '/usr/lib/xdg-desktop-portal-gtk &\n'
                printf 'xwayland-satellite &\n'
                ;;
            sway)
                printf 'lxqt-policykit-agent &\n'
                printf '/usr/bin/xdg-user-dirs-update &\n'
                printf '/usr/libexec/sway-systemd/wait-sni-ready && systemctl --user start sway-xdg-autostart.target\n'
                ;;
        esac

        printf '\n# Shell\n'
        printf 'qs -p %s/quickshell/noctalia-shell &\n' "${DI_DIR}"
    } > "${script}"

    chmod +x "${script}"
    print_success "Generated autostart: ${script}"
}

# _install_colloid_catppuccin
# Installs Colloid GTK and icon themes with all Catppuccin colour variants.
function _install_colloid_catppuccin() {
    local gtk_repo="https://github.com/vinceliuice/Colloid-gtk-theme.git"
    local icon_repo="https://github.com/vinceliuice/Colloid-icon-theme.git"
    local gtk_dir="/tmp/Colloid-gtk-theme"
    local icon_dir="/tmp/Colloid-icon-theme"

    rm -rf "${gtk_dir}" "${icon_dir}"
    trap 'rm -rf "${gtk_dir}" "${icon_dir}"' EXIT

    print_info "Cloning Colloid GTK theme"
    git clone --depth=1 "${gtk_repo}" "${gtk_dir}" >/dev/null 2>&1
    cd "${gtk_dir}"
    ./install.sh --tweaks catppuccin -t all -s standard compact -c dark -l fixed \
        | grep -E "Installing|ERROR|Cloning" \
        | while IFS= read -r line; do print_info "${line}"; done

    print_info "Cloning Colloid icon theme"
    git clone --depth=1 "${icon_repo}" "${icon_dir}" >/dev/null 2>&1
    cd "${icon_dir}"
    ./install.sh -s catppuccin -t all \
        | grep -E "Installing|ERROR|Cloning" \
        | while IFS= read -r line; do print_info "${line}"; done

    gsettings set org.gnome.desktop.interface gtk-theme "Colloid-Purple-Dark-Compact-Catppuccin"
    gsettings set org.gnome.desktop.interface icon-theme "Colloid-Purple-Catppuccin-Dark"
    gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"

    cd - >/dev/null
    rm -rf "${gtk_dir}" "${icon_dir}"
    trap - EXIT
}

# _configure_catppuccin_gtk
# Links Catppuccin Mocha Lavender GTK4 theme files and applies GNOME settings.
function _configure_catppuccin_gtk() {
    local theme_dir="/usr/share/themes/catppuccin-mocha-lavender-standard+default/gtk-4.0"
    local gtk4_config="${HOME}/.config/gtk-4.0"

    print_step "Applying Catppuccin Mocha Lavender GTK4 theme"

    mkdir -p "${gtk4_config}"
    ln -sf "${theme_dir}/gtk.css"      "${gtk4_config}/gtk.css"
    ln -sf "${theme_dir}/gtk-dark.css" "${gtk4_config}/gtk-dark.css"
    ln -sf "${theme_dir}/assets"       "${gtk4_config}/assets"

    gsettings set org.gnome.desktop.interface gtk-theme    "catppuccin-mocha-lavender-standard+default" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme   "Papirus-Dark" 2>/dev/null || true

    print_success "GTK4 Catppuccin theme applied"
}

# _install_paperwm
# Installs the PaperWM GNOME Shell extension and applies dotfile dconf settings.
function _install_paperwm() {
    local src_dir="${HOME}/.local/share/paperwm"
    local settings_dir="${DI_DIR}/gnome/_settings"

    if [[ ! -d "${src_dir}" ]]; then
        print_info "Cloning PaperWM"
        git clone --depth=1 https://github.com/paperwm/PaperWM.git "${src_dir}"
    fi

    print_info "Installing PaperWM"
    (cd "${src_dir}" && make install)

    if [[ -f "${settings_dir}/paperwm.ini" ]]; then
        print_info "Applying PaperWM dconf settings"
        dconf load /org/gnome/shell/extensions/paperwm/ < "${settings_dir}/paperwm.ini"
    fi

    if [[ -f "${settings_dir}/paperwm-user.css" ]]; then
        mkdir -p "${HOME}/.config/paperwm"
        cp "${settings_dir}/paperwm-user.css" "${HOME}/.config/paperwm/user.css"
    fi

    print_success "PaperWM installed and configured"
}

# _detect_hidpi_screen
# Detects HiDPI screen via xrandr and returns recommended scale factor.
# Returns: 100 | 125 | 150 | 175 | 200 (or empty if detection fails)
function _detect_hidpi_screen() {
    if ! command -v xrandr &>/dev/null; then
        printf ""
        return
    fi

    local output
    output="$(xrandr --current 2>/dev/null | grep " connected primary" | head -1)"
    [[ -z "${output}" ]] && output="$(xrandr --current 2>/dev/null | grep " connected" | head -1)"
    [[ -z "${output}" ]] && { printf ""; return; }

    local resolution physical_width
    resolution="$(printf "%s" "${output}" | grep -oP '\d+x\d+' | head -1)"
    physical_width="$(printf "%s" "${output}" | grep -oP '\d+mm x \d+mm' | head -1 \
        | cut -d'x' -f1 | grep -oP '\d+')"

    [[ -z "${resolution}" || -z "${physical_width}" ]] && { printf ""; return; }

    local width_px width_inches dpi
    width_px="$(printf "%s" "${resolution}" | cut -d'x' -f1)"
    width_inches="$(echo "scale=2; ${physical_width} / 25.4" | bc)"
    dpi="$(echo "scale=0; ${width_px} / ${width_inches}" | bc)"

    if   [[ "${dpi}" -ge 180 ]]; then printf "200"
    elif [[ "${dpi}" -ge 160 ]]; then printf "175"
    elif [[ "${dpi}" -ge 140 ]]; then printf "150"
    elif [[ "${dpi}" -ge 110 ]]; then printf "125"
    else                               printf "100"
    fi
}

# _install_hyprland_suite
# Installs Hyprland and components on Ubuntu via the official installer.
# Parameters: list of components (e.g. hyprland hypridle hyprlock hyprpaper)
function _install_hyprland_suite() {
    local components=("$@")
    print_info "Installing Hyprland suite on Ubuntu: ${components[*]}"
    if ! command -v Hyprland &>/dev/null; then
        curl -sSL https://raw.githubusercontent.com/JaKooLit/Ubuntu-Hyprland/main/install.sh \
            | bash -s -- --quiet
    else
        print_info "Hyprland already installed, skipping"
    fi
}

# ─── Ubuntu Niri Stack ────────────────────────────────────────────────────────

# _build_libwayland_ubuntu
# Builds libwayland >= 1.23 from source. Ubuntu 24.04 ships 1.22.0 which is
# missing wl_client_set_max_buffer_size, required by niri >= 25.x.
function _build_libwayland_ubuntu() {
    local installed_ver
    installed_ver="$(pkg-config --modversion wayland-server 2>/dev/null || printf "0")"
    local required_ver="1.23.0"

    if dpkg --compare-versions "${installed_ver}" ge "${required_ver}" 2>/dev/null; then
        print_info "libwayland ${installed_ver} already satisfies >= ${required_ver}, skipping"
        return
    fi

    print_info "Building libwayland ${required_ver} from source"
    sudo apt-get install -y libffi-dev libxml2-dev wayland-protocols

    local wayland_ver="1.23.1"
    local build_dir="/tmp/wayland-build"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    curl -fsSL "https://gitlab.freedesktop.org/wayland/wayland/-/releases/${wayland_ver}/downloads/wayland-${wayland_ver}.tar.xz" \
        -o "${build_dir}/wayland.tar.xz"
    tar -xf "${build_dir}/wayland.tar.xz" -C "${build_dir}" --strip-components=1
    cd "${build_dir}"
    meson setup build \
        --prefix=/usr/local \
        --libdir=/usr/local/lib/x86_64-linux-gnu \
        -Dtests=false \
        -Ddocumentation=false
    ninja -C build
    sudo ninja -C build install
    sudo ldconfig
    cd - >/dev/null
    rm -rf "${build_dir}"
    print_success "libwayland ${wayland_ver} installed"
}

# _install_niri_build_deps_ubuntu
# Installs system packages required to build the niri stack from source.
# Enables noble-updates if missing so -dev packages match security-patched runtimes.
function _install_niri_build_deps_ubuntu() {
    print_info "Installing niri stack build dependencies"

    # noble-updates must be enabled so -dev packages match their security-patched
    # and HWE-updated runtimes. Without it apt sees noble/main -dev versions but
    # has newer runtimes installed, causing strict = version dep failures.
    if ! grep -rq "noble-updates" \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list \
            /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        print_info "noble-updates not configured — enabling it"
        sudo tee /etc/apt/sources.list.d/noble-updates.sources >/dev/null <<'EOF'
Types: deb
URIs: http://us.archive.ubuntu.com/ubuntu/
Suites: noble-updates noble-backports
Components: main restricted universe multiverse
EOF
    fi

    sudo apt-get update -y
    sudo apt-get install -y \
        build-essential cmake meson ninja-build pkg-config git \
        libwayland-dev libxkbcommon-dev libinput-dev libudev-dev \
        libgbm-dev libdrm-dev libseat-dev libegl-dev libgles-dev \
        libdbus-1-dev libsystemd-dev libpipewire-0.3-dev \
        libpango1.0-dev libpangocairo-1.0-0 libdisplay-info-dev libclang-dev \
        wayland-protocols libgdk-pixbuf2.0-dev libpam0g-dev \
        libx11-dev libxcb1-dev libxcb-shape0-dev libxcb-render0-dev \
        scdoc libxcb-cursor-dev unzip python3-pip seatd
}

# _build_niri_ubuntu
# Builds niri via cargo, registers its GDM session, installs systemd user units,
# and writes the niri-session launcher.
function _build_niri_ubuntu() {
    if command -v niri &>/dev/null; then
        print_info "niri already installed, skipping"
        return
    fi

    print_info "Building niri"
    cargo install --locked --git https://github.com/YaLTeR/niri.git niri

    local systemd_user_dir="${HOME}/.config/systemd/user"
    mkdir -p "${systemd_user_dir}"

    cat > "${systemd_user_dir}/niri.service" <<'NIRI_SERVICE'
[Unit]
Description=A scrollable-tiling Wayland compositor
BindsTo=graphical-session.target
Before=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
Wants=xdg-desktop-autostart.target
Before=xdg-desktop-autostart.target

[Service]
Slice=session.slice
Type=notify
Environment=LIBSEAT_BACKEND=seatd
ExecStart=%h/.cargo/bin/niri --session
NIRI_SERVICE

    cat > "${systemd_user_dir}/niri-shutdown.target" <<'NIRI_SHUTDOWN'
[Unit]
Description=Shutdown running niri session
DefaultDependencies=no
StopWhenUnneeded=true
Conflicts=graphical-session.target graphical-session-pre.target
After=graphical-session.target graphical-session-pre.target
NIRI_SHUTDOWN

    systemctl --user daemon-reload 2>/dev/null || true

    sudo tee /usr/local/bin/niri-session >/dev/null <<'NIRI_SESSION'
#!/usr/bin/env bash
set -euo pipefail

if systemctl --user -q is-active niri.service 2>/dev/null; then
    printf 'A niri session is already running.\n' >&2
    exit 1
fi

export PATH="${HOME}/.cargo/bin:${PATH}"
systemctl --user reset-failed 2>/dev/null || true
systemctl --user import-environment \
    PATH HOME USER LOGNAME SHELL \
    XDG_RUNTIME_DIR XDG_SESSION_ID XDG_SEAT XDG_VTNR XDG_SESSION_TYPE \
    DBUS_SESSION_BUS_ADDRESS LANG LANGUAGE SSH_AUTH_SOCK 2>/dev/null || true
dbus-update-activation-environment --all 2>/dev/null || true
systemctl --user --wait start niri.service
systemctl --user start --job-mode=replace-irreversibly niri-shutdown.target 2>/dev/null || true
systemctl --user unset-environment \
    WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP NIRI_SOCKET \
    2>/dev/null || true
NIRI_SESSION
    sudo chmod +x /usr/local/bin/niri-session

    sudo systemctl enable --now seatd.service
    sudo usermod -aG video,render "${USER}"

    local session_dir="/usr/share/wayland-sessions"
    sudo mkdir -p "${session_dir}"
    if [[ ! -f "${session_dir}/niri.desktop" ]]; then
        printf '[Desktop Entry]\nName=Niri\nComment=A scrollable-tiling Wayland compositor\nExec=niri-session\nType=Application\n' \
            | sudo tee "${session_dir}/niri.desktop" >/dev/null
    fi

    print_success "niri installed"
}

function _build_xwayland_satellite_ubuntu() {
    if command -v xwayland-satellite &>/dev/null; then
        print_info "xwayland-satellite already installed, skipping"
        return
    fi
    print_info "Building xwayland-satellite"
    cargo install --locked --git https://github.com/Supreeeme/xwayland-satellite.git xwayland-satellite
}

function _build_wlsunset_ubuntu() {
    if command -v wlsunset &>/dev/null; then
        print_info "wlsunset already installed, skipping"
        return
    fi
    print_info "Building wlsunset"
    local build_dir="/tmp/wlsunset-build"
    rm -rf "${build_dir}"
    git clone --depth=1 https://git.sr.ht/~kennylevinsen/wlsunset "${build_dir}"
    cd "${build_dir}"
    meson setup build --prefix=/usr
    ninja -C build
    sudo ninja -C build install
    cd - >/dev/null
    rm -rf "${build_dir}"
}

function _install_cliphist_ubuntu() {
    if command -v cliphist &>/dev/null; then
        print_info "cliphist already installed, skipping"
        return
    fi
    print_info "Installing cliphist"
    GOBIN="${HOME}/.local/bin" go install go.senan.xyz/cliphist@latest
}

function _install_bluetui_ubuntu() {
    if command -v bluetui &>/dev/null; then
        print_info "bluetui already installed, skipping"
        return
    fi
    print_info "Installing bluetui"
    cargo install --locked --root "${HOME}" bluetui
}

function _install_dart_sass_ubuntu() {
    if command -v sass &>/dev/null; then
        print_info "dart-sass already installed, skipping"
        return
    fi
    print_info "Installing dart-sass"
    local latest_tag tmp_dir
    latest_tag="$(curl -s https://api.github.com/repos/sass/dart-sass/releases/latest \
        | grep '"tag_name"' | cut -d '"' -f4)"
    tmp_dir="$(mktemp -d)"
    curl -L "https://github.com/sass/dart-sass/releases/download/${latest_tag}/dart-sass-${latest_tag}-linux-x64.tar.gz" \
        | tar xz -C "${tmp_dir}"
    sudo install -m 755 "${tmp_dir}/dart-sass/sass" /usr/local/bin/sass
    rm -rf "${tmp_dir}"
}

# _install_catppuccin_gtk_ubuntu
# Installs Catppuccin Mocha Lavender GTK theme to /usr/share/themes.
function _install_catppuccin_gtk_ubuntu() {
    local theme_dir="/usr/share/themes/catppuccin-mocha-lavender-standard+default"
    if [[ -d "${theme_dir}" ]]; then
        print_info "catppuccin-gtk already installed, skipping"
        return
    fi
    print_info "Installing catppuccin-gtk-theme-mocha"
    local build_dir="/tmp/catppuccin-gtk-build"
    rm -rf "${build_dir}"
    git clone --depth=1 https://github.com/catppuccin/gtk.git "${build_dir}"
    cd "${build_dir}"
    pip3 install --quiet --user --break-system-packages -r requirements.txt
    sudo python3 install.py mocha lavender --dest /usr/share/themes
    cd - >/dev/null
    rm -rf "${build_dir}"
}

# _install_papirus_catppuccin_ubuntu
# Installs Catppuccin Papirus folder icons from source.
function _install_papirus_catppuccin_ubuntu() {
    if [[ -f "/usr/share/icons/Papirus-Dark/places/22/folder-mocha-lavender.svg" ]]; then
        print_info "papirus-folders-catppuccin already installed, skipping"
        return
    fi
    print_info "Installing papirus-folders-catppuccin"
    local build_dir="/tmp/papirus-catppuccin-build"
    rm -rf "${build_dir}"
    git clone --depth=1 https://github.com/catppuccin/papirus-folders.git "${build_dir}"
    cd "${build_dir}"
    sudo cp -r src/* /usr/share/icons/Papirus/      2>/dev/null || true
    sudo cp -r src/* /usr/share/icons/Papirus-Dark/ 2>/dev/null || true
    sudo cp -r src/* /usr/share/icons/Papirus-Light/ 2>/dev/null || true
    papirus-folders -C cat-mocha-lavender --theme Papirus-Dark 2>/dev/null || true
    cd - >/dev/null
    rm -rf "${build_dir}"
}

# _install_pwvucontrol_ubuntu
# Installs pwvucontrol from source via meson — cargo install not supported.
# Patches the generated build.ninja to inject RUSTC explicitly since meson
# strips PATH and the cargo wrapper can't find rustc otherwise.
function _install_pwvucontrol_ubuntu() {
    if command -v pwvucontrol &>/dev/null; then
        print_info "pwvucontrol already installed, skipping"
        return
    fi
    print_info "Building pwvucontrol"
    sudo apt-get install -y libpipewire-0.3-dev libgtk-4-dev libadwaita-1-dev \
        libwireplumber-0.4-dev gettext

    local build_dir="/tmp/pwvucontrol-build"
    rm -rf "${build_dir}"
    git clone --depth=1 https://github.com/saivert/pwvucontrol.git "${build_dir}"
    cd "${build_dir}"

    local real_cargo_dir
    real_cargo_dir="$(dirname "$(~/.cargo/bin/rustup which cargo)")"
    PATH="${real_cargo_dir}:${PATH}" meson setup build --prefix=/usr
    sed -i "s|/usr/bin/env CARGO_HOME=${build_dir}/build/cargo-home|/usr/bin/env CARGO_HOME=${build_dir}/build/cargo-home RUSTC=${real_cargo_dir}/rustc|" \
        "${build_dir}/build/build.ninja"
    ninja -C build
    sudo ninja -C build install
    cd - >/dev/null
    rm -rf "${build_dir}"
}

# _install_noctalia_ubuntu
# Installs noctalia-shell (includes the quickshell runtime) from the official
# apt repo. Requires Ubuntu 25.04+ (Qt6 >= 6.6). Warns and skips on 24.04.
function _install_noctalia_ubuntu() {
    if command -v qs &>/dev/null; then
        print_info "noctalia-shell already installed, skipping"
        return
    fi

    local codename
    # shellcheck source=/dev/null
    codename="$(source /etc/os-release && printf "%s" "${VERSION_CODENAME:-}")"

    local noctalia_codename
    case "${codename}" in
        plucky)   noctalia_codename="plucky" ;;
        questing) noctalia_codename="questing" ;;
        *)
            print_warning "noctalia-shell requires Ubuntu 25.04+. Detected: ${codename}. Skipping."
            return
            ;;
    esac

    print_info "Installing noctalia-shell"
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkg.noctalia.dev/gpg.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/noctalia.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/noctalia.gpg] https://pkg.noctalia.dev/apt %s main\n' \
        "${noctalia_codename}" \
        | sudo tee /etc/apt/sources.list.d/noctalia.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y noctalia-shell
}

# _install_niri_stack_ubuntu
# Installs the full niri stack on Ubuntu for packages not in apt.
function _install_niri_stack_ubuntu() {
    print_step "Installing niri stack for Ubuntu"
    _install_niri_build_deps_ubuntu
    _build_libwayland_ubuntu
    _build_niri_ubuntu
    _build_xwayland_satellite_ubuntu
    _build_wlsunset_ubuntu
    _install_cliphist_ubuntu
    _install_bluetui_ubuntu
    _install_dart_sass_ubuntu
    _install_catppuccin_gtk_ubuntu
    _install_papirus_catppuccin_ubuntu
    _install_pwvucontrol_ubuntu
    _install_noctalia_ubuntu
    print_success "niri stack installation complete"
}

# ─── Display / Hardware ───────────────────────────────────────────────────────

# _configure_display_wakeup
# Installs udev rules that allow the system to wake from S0ix when an external
# display is connected (Thunderbolt/USB4, PCIe GPU, USB).
function _configure_display_wakeup() {
    local rules_file="/etc/udev/rules.d/99-niri-display-wakeup.rules"

    print_info "Configuring display hotplug wakeup sources"
    sudo tee "${rules_file}" >/dev/null <<'EOF'
# Wake system on Thunderbolt/USB4 device connect (USB-C monitors, docks)
ACTION=="add|change", SUBSYSTEM=="thunderbolt", ATTR{power/wakeup}="enabled"

# Wake system on PCIe display controller hotplug (HDMI/DisplayPort on integrated GPU)
ACTION=="add|change", SUBSYSTEM=="pci", ATTR{class}=="0x030000", ATTR{power/wakeup}="enabled"
ACTION=="add|change", SUBSYSTEM=="pci", ATTR{class}=="0x030200", ATTR{power/wakeup}="enabled"
ACTION=="add|change", SUBSYSTEM=="pci", ATTR{class}=="0x038000", ATTR{power/wakeup}="enabled"

# Wake system on USB device connect (USB-C hubs and display adapters)
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/wakeup}="enabled"
EOF
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=pci --subsystem-match=thunderbolt 2>/dev/null || true
    print_success "Display wakeup rules installed: ${rules_file}"
}

# _configure_nvidia_for_niri
# Configures kernel parameters and module settings when niri + NVIDIA GPU are detected.
# Parameters:
#   $1 - desktop interface
#   $2 - distro (arch | ubuntu)
function _configure_nvidia_for_niri() {
    local desktop_interface="${1}"
    local distro="${2}"

    [[ "${desktop_interface}" != "niri" ]] && return

    # Use command substitution to avoid SIGPIPE with set -o pipefail
    if [[ -z "$(lspci | grep -i 'vga.*nvidia')" ]]; then
        return
    fi

    print_step "NVIDIA GPU detected — configuring kernel parameters for Niri"

    local required_modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm"

    if [[ "${distro}" == "ubuntu" ]]; then
        if [[ -z "$(dpkg -l | grep "^ii.*nvidia-open")" ]]; then
            print_info "Installing NVIDIA open kernel modules"
            sudo apt-get install -y ubuntu-drivers-common
            sudo ubuntu-drivers install --gpgpu 2>/dev/null || sudo ubuntu-drivers autoinstall
        fi

        local initramfs_modules="/etc/initramfs-tools/modules"
        local updated=0 mod
        for mod in ${required_modules}; do
            if [[ -z "$(grep -w "${mod}" "${initramfs_modules}" 2>/dev/null)" ]]; then
                printf "%s\n" "${mod}" | sudo tee -a "${initramfs_modules}" >/dev/null
                updated=1
            fi
        done
        if [[ "${updated}" -eq 1 ]]; then
            print_success "Updated ${initramfs_modules} with NVIDIA modules"
            sudo update-initramfs -u
        fi
    else
        install_package "nvidia-dkms" "${distro}"
        local mkinitcpio_conf="/etc/mkinitcpio.conf"
        if [[ -f "${mkinitcpio_conf}" ]]; then
            local current_modules updated_modules
            current_modules="$(grep "^MODULES=" "${mkinitcpio_conf}" | sed 's/^MODULES=//' | tr -d '()')"
            updated_modules="${current_modules}"
            for mod in ${required_modules}; do
                if [[ -z "$(grep -w "${mod}" <<< "${current_modules}")" ]]; then
                    updated_modules="${updated_modules} ${mod}"
                fi
            done
            updated_modules="$(printf "%s" "${updated_modules}" | xargs)"
            if [[ "${updated_modules}" != "${current_modules}" ]]; then
                sudo sed -i "s|^MODULES=.*|MODULES=(${updated_modules})|" "${mkinitcpio_conf}"
                print_success "Updated MODULES in ${mkinitcpio_conf}"
                sudo mkinitcpio -P
            fi
        fi
    fi

    local entries_dir
    entries_dir="$(find_systemd_boot_entries)"
    if [[ -n "${entries_dir}" ]]; then
        local updated_any=0 entry
        for entry in "${entries_dir}"/*.conf; do
            [[ "${entry}" == *fallback* ]] && continue
            if [[ -z "$(grep "nvidia-drm.modeset=1" "${entry}")" ]] \
                || [[ -z "$(grep "nvidia-drm.fbdev=1" "${entry}")" ]]; then
                sudo sed -i '/^options / s/$/ quiet loglevel=3 rd.udev.log_level=3 nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' "${entry}"
                print_success "Appended NVIDIA boot flags to ${entry}"
                updated_any=1
            fi
        done
        [[ "${updated_any}" -eq 0 ]] && print_info "NVIDIA boot flags already present"
    elif [[ -f /etc/default/grub ]]; then
        if [[ -z "$(grep "nvidia-drm.modeset=1" /etc/default/grub)" ]] \
            || [[ -z "$(grep "nvidia-drm.fbdev=1" /etc/default/grub)" ]]; then
            sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvidia-drm.modeset=1 nvidia-drm.fbdev=1 /' \
                /etc/default/grub
            sudo grub-mkconfig -o /boot/grub/grub.cfg
            print_success "Appended NVIDIA boot flags to GRUB"
        fi
    fi

    printf 'options nvidia-drm modeset=1 fbdev=1\n' \
        | sudo tee /etc/modprobe.d/nvidia-drm.conf >/dev/null
    print_success "NVIDIA kernel modesetting configured. Reboot to apply."
}

# _configure_usb_audio
# Writes modprobe options for the Behringer UV1 USB audio interface.
# Note: quirk_flags vid:pid:flags format was dropped in kernel 6.x and is omitted.
function _configure_usb_audio() {
    print_info "Configuring USB audio modprobe options"
    printf 'options snd_usb_audio implicit_fb=1 ignore_ctl_error=1 autoclock=0\n' \
        | sudo tee /etc/modprobe.d/uv1-audio.conf >/dev/null
    print_success "Written /etc/modprobe.d/uv1-audio.conf"
}

# _configure_di_hardware
# DE-level hardware-specific post-setup. Currently a no-op for most hardware.
# Parameters:
#   $1 - hardware identifier
function _configure_di_hardware() {
    local hardware="${1}"
    case "${hardware}" in
        "ThinkPad T480s"|"ROG") ;;
        *) ;;
    esac
}

# _configure_desktop_interface
# Performs per-DE post-install configuration.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - desktop interface
#   $3 - scale factor (auto | <percentage>) — default: auto
function _configure_desktop_interface() {
    local distro="${1}"
    local desktop_interface="${2}"
    local scale_factor="${3:-auto}"
    local gpg_config_file="${HOME}/.gnupg/gpg-agent.conf"
    local pinentry_line="pinentry-program /usr/bin/pinentry-tty"

    # Clamshell — keep display on when docked, suspend on lid close otherwise
    print_info "Configuring clamshell settings"
    if [[ -f "/etc/systemd/logind.conf" ]]; then
        sudo sed -i 's/^#HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/'      /etc/systemd/logind.conf
        sudo sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=suspend/'                  /etc/systemd/logind.conf
        sudo sed -i 's/^#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=suspend/' /etc/systemd/logind.conf
    else
        printf 'HandleLidSwitchExternalPower=suspend\nHandleLidSwitch=suspend\nHandleLidSwitchDocked=ignore\n' \
            | sudo tee -a /etc/systemd/logind.conf >/dev/null
    fi

    # GPG pinentry-tty
    print_info "Configuring GPG pinentry"
    if [[ -f "${gpg_config_file}" ]]; then
        if [[ -n "$(grep "^pinentry-program" "${gpg_config_file}")" ]]; then
            sed -i "s|^pinentry-program.*|${pinentry_line}|" "${gpg_config_file}"
        else
            printf "%s\n" "${pinentry_line}" >> "${gpg_config_file}"
        fi
    else
        printf "%s\n" "${pinentry_line}" > "${gpg_config_file}"
    fi
    gpg-connect-agent reloadagent /bye >/dev/null 2>&1

    case "${desktop_interface}" in
        gnome)  _configure_gnome "${distro}" "${scale_factor}" ;;
        hyprland) _configure_hyprland "${distro}" ;;
        niri)   _configure_niri ;;
        sway)   _configure_sway ;;
        *)      print_error "Unsupported desktop interface: ${desktop_interface}" ;;
    esac
}

# _configure_gnome
# Applies dconf settings, keybindings, scaling, wallpaper, and GDM config.
# Parameters:
#   $1 - distro (arch | ubuntu)
#   $2 - scale factor (auto | <percentage>)
function _configure_gnome() {
    local distro="${1}"
    local scale_factor="${2}"
    local settings_dir="${DI_DIR}/gnome/_settings"

    print_step "Configuring GNOME"

    local gnome_categories=(
        "/org/gnome/desktop/interface/:interface.ini"
        "/org/gnome/desktop/wm/:wm.ini"
        "/org/gnome/nautilus/:nautilus.ini"
        "/org/gnome/desktop/input-sources/:input-sources.ini"
        "/org/gnome/settings-daemon/plugins/:plugins.ini"
        "/org/gnome/shell/extensions/:extensions.ini"
    )

    local category dconf_path file
    for category in "${gnome_categories[@]}"; do
        IFS=':' read -r dconf_path file <<< "${category}"
        if [[ -f "${settings_dir}/${file}" ]]; then
            dconf load "${dconf_path}" < "${settings_dir}/${file}"
            print_info "Imported ${file} → ${dconf_path}"
        else
            print_warning "${file} not found in ${settings_dir}"
        fi
    done

    if command -v gdbus &>/dev/null && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        gdbus call --session --dest org.gnome.Shell \
            --object-path /org/gnome/Shell \
            --method org.gnome.Shell.Extensions.ReloadExtensions 2>/dev/null || \
            print_warning "Could not reload extensions via D-Bus (may need manual GNOME Shell restart)"
    fi

    local e extension
    for e in "${HOME}"/.local/share/gnome-shell/extensions/*; do
        if [[ -d "${e}" ]]; then
            extension="$(basename "${e}")"
            gnome-extensions enable "${extension}" 2>/dev/null || \
                print_warning "Could not enable ${extension} (will be available after logout)"
            print_info "Enabled GNOME extension: ${extension}"
        fi
    done

    print_info "Configuring workspace keybindings"
    local i
    for i in {1..9}; do
        gsettings set org.gnome.shell.keybindings "switch-to-application-${i}" "[]"
        gsettings set org.gnome.desktop.wm.keybindings "switch-to-workspace-${i}" "['<Super>${i}']"
        gsettings set org.gnome.desktop.wm.keybindings "move-to-workspace-${i}" "['<Super><Shift>${i}']"
    done

    if [[ "${distro}" == "ubuntu" ]]; then
        gnome-extensions disable ding@rastersoft.com
        gnome-extensions disable "ubuntu-dock@ubuntu.com"
        print_info "Disabled desktop icons and dock"
    fi

    # Display scaling
    gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
    local target_scale
    if [[ "${scale_factor}" == "auto" ]]; then
        local detected_scale
        detected_scale="$(_detect_hidpi_screen)"
        target_scale="${detected_scale:-100}"
    else
        target_scale="${scale_factor}"
    fi

    if [[ "${target_scale}" != "100" ]]; then
        local scale_value
        scale_value="$(echo "scale=2; ${target_scale} / 100" | bc)"
        gsettings set org.gnome.desktop.interface text-scaling-factor "${scale_value}"
        print_info "Set scaling to ${target_scale}% (${scale_value})"
    fi

    # Wallpaper
    local wallpaper_file=""
    if [[ "${distro}" == "ubuntu" && -f "${HOME}/wallpaper_ubuntu.jpg" ]]; then
        wallpaper_file="${HOME}/wallpaper_ubuntu.jpg"
    elif [[ -f "${HOME}/wallpaper_${distro}.png" ]]; then
        wallpaper_file="${HOME}/wallpaper_${distro}.png"
    fi
    if [[ -n "${wallpaper_file}" ]]; then
        gsettings set org.gnome.desktop.background picture-uri      "file://${wallpaper_file}"
        gsettings set org.gnome.desktop.background picture-uri-dark "file://${wallpaper_file}"
        print_info "Set wallpaper: ${wallpaper_file}"
    fi

    # User avatar
    gdbus call --system --dest "org.freedesktop.Accounts" \
        --object-path "/org/freedesktop/Accounts/User$(id -u)" \
        --method "org.freedesktop.Accounts.User.SetIconFile" "${HOME}/avatar.png" \
        >/dev/null || true

    gsettings set org.gnome.desktop.interface gtk-theme "Adwaita-dark"

    if [[ "${distro}" != "ubuntu" ]]; then
        sudo systemctl set-default graphical.target
        sudo systemctl enable --now gdm
    fi

    # GDM Wayland
    local gdm_config="/etc/gdm3/custom.conf"
    [[ "${distro}" == "arch" ]] && gdm_config="/etc/gdm/custom.conf"
    if [[ -f "${gdm_config}" ]]; then
        sudo sed -i 's/^#WaylandEnable=false/WaylandEnable=true/' "${gdm_config}"
        sudo sed -i 's/^WaylandEnable=false/WaylandEnable=true/'  "${gdm_config}"
    fi

    local user_session_file="/var/lib/AccountsService/users/$(whoami)"
    if [[ -f "${user_session_file}" ]]; then
        if [[ -n "$(sudo grep "^XSession=" "${user_session_file}")" ]]; then
            sudo sed -i 's/^XSession=.*/XSession=gnome/' "${user_session_file}"
        else
            printf "XSession=gnome\n" | sudo tee -a "${user_session_file}" >/dev/null
        fi
        if [[ -n "$(sudo grep "^Session=" "${user_session_file}")" ]]; then
            sudo sed -i 's/^Session=.*/Session=/' "${user_session_file}"
        fi
    fi

    printf "\n${YELLOW}Please log out and back in for all GNOME changes to take effect.${RESET}\n"
}

# _configure_hyprland
# Parameters:
#   $1 - distro (arch | ubuntu)
function _configure_hyprland() {
    local distro="${1}"

    if [[ "${distro}" == "ubuntu" ]]; then
        _install_hyprland_suite hyprland hypridle hyprlock hyprpaper
    fi

    sudo sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf

    if ! command -v volumectl &>/dev/null; then
        print_info "Installing volumectl"
        curl -L "https://github.com/vially/volumectl/releases/download/v0.1.0/volumectl" \
            -o "${HOME}/bin/volumectl"
        chmod +x "${HOME}/bin/volumectl"
    fi

    if ! command -v lightctl &>/dev/null; then
        print_info "Installing lightctl"
        export GOBIN="${HOME}/bin"
        go install github.com/denysvitali/lightctl@latest
    fi

    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark

    systemctl --user enable --now idle.service 2>/dev/null || \
        print_warning "Could not enable idle.service — enable it manually after first login"
}

function _configure_niri() {
    _configure_catppuccin_gtk
    _configure_display_wakeup

    systemctl --user enable --now idle.service 2>/dev/null || \
        print_warning "Could not enable idle.service — enable it manually after first login"
}

function _configure_sway() {
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark

    systemctl --user enable --now idle.service 2>/dev/null || \
        print_warning "Could not enable idle.service — enable it manually after first login"
}
