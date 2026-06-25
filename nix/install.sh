#!/usr/bin/env bash
# NixOS installer.
# Runs from the NixOS installer ISO after the target disk is partitioned,
# formatted, mounted at /mnt, and nixos-generate-config --root /mnt has run.
# Sourced by bootstrap.sh — do not execute directly.

readonly NIX_CLONE_DIR="/tmp/dotfiles.nix"

# install_nix
# Parameters:
#   $1 - hardware identifier (from detect_hardware in common.sh)
function install_nix() {
    local hardware="${1}"

    if [[ ! -f "/mnt/etc/nixos/hardware-configuration.nix" ]]; then
        print_error "No hardware config found at /mnt/etc/nixos/hardware-configuration.nix"
        print_info "Ensure /mnt is mounted and run: nixos-generate-config --root /mnt"
        return 1
    fi

    print_step "Installing NixOS configuration"

    _clone_nix

    # Prompt for hostname and username upfront
    local hostname
    read -rp "$(printf "${BLUE}[INFO]${RESET} Hostname: ")" hostname
    if [[ -z "${hostname}" ]]; then
        print_error "Hostname is required"
        return 1
    fi

    local nix_user
    read -rp "$(printf "${BLUE}[INFO]${RESET} Username: ")" nix_user
    if [[ -z "${nix_user}" ]]; then
        print_error "Username is required"
        return 1
    fi

    # WM selection
    local wm
    print_step "Select a desktop environment or window manager:"
    select wm_choice in "Hyprland" "Niri" "Sway" "River" "GNOME" "GNOME + PaperWM" "None (headless/server)"; do
        case "${wm_choice}" in
            "Hyprland")               wm="hyprland";      break ;;
            "Niri")                   wm="niri";           break ;;
            "Sway")                   wm="sway";           break ;;
            "River")                  wm="river";          break ;;
            "GNOME")                  wm="gnome";          break ;;
            "GNOME + PaperWM")        wm="gnome-paperwm";  break ;;
            "None (headless/server)") wm="none";           break ;;
            *) print_error "Invalid option. Please try again." ;;
        esac
    done

    printf "\n"

    # GPU detection
    local gpu
    gpu="$(detect_gpu)"
    if [[ "${gpu}" == "nvidia" ]]; then
        print_info "NVIDIA GPU detected — nvidia.nix module will be included"
    else
        print_info "No NVIDIA GPU detected — skipping nvidia.nix module"
    fi

    if _host_exists "${hostname}"; then
        print_info "Host '${hostname}' found in flake.nix — skipping host scaffold"
    else
        print_info "New host '${hostname}' — scaffolding configuration"
        _scaffold_new_host "${hostname}" "${hardware}" "${nix_user}" "${wm}" "${gpu}"
        _add_flake_entry "${hostname}" "${nix_user}" "${wm}"
    fi

    if _user_exists "${nix_user}"; then
        print_info "User '${nix_user}' found in home/ — checking imports"
        case "${wm}" in
            hyprland|niri|sway|river) _patch_user_noctalia "${nix_user}" ;;
        esac
        [[ "${gpu}" == "nvidia" ]] && _patch_user_nvidia "${nix_user}"
    else
        print_info "New user '${nix_user}' — scaffolding home config"
        _scaffold_new_user "${nix_user}" "${wm}" "${gpu}"
    fi

    _copy_hardware_config "${hostname}"

    printf "\n"
    print_step "Ready to install NixOS — hostname: ${hostname}, user: ${nix_user}, wm: ${wm}"
    read -rp "$(printf "${BLUE}[INFO]${RESET} Proceed with nixos-install? [y/N]: ")" confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { print_info "Aborted."; return 0; }

    _run_nixos_install "${hostname}" "${nix_user}"
}

function _clone_nix() {
    if [[ ! -d "${NIX_CLONE_DIR}" ]]; then
        print_info "Cloning dotfiles.nix"
        git clone "https://gitlab.com/wd2nf8gqct/dotfiles.nix.git" "${NIX_CLONE_DIR}"
    else
        print_info "dotfiles.nix already present at ${NIX_CLONE_DIR}"
    fi
}

function _host_exists() {
    local hostname="${1}"
    [[ -n "$(grep "nixosConfigurations\.${hostname}" "${NIX_CLONE_DIR}/flake.nix" 2>/dev/null)" ]]
}

function _user_exists() {
    local nix_user="${1}"
    [[ -f "${NIX_CLONE_DIR}/home/${nix_user}.nix" ]]
}

function _patch_user_noctalia() {
    local nix_user="${1}"
    local dest="${NIX_CLONE_DIR}/home/${nix_user}.nix"

    if [[ -n "$(grep "noctalia" "${dest}" 2>/dev/null)" ]]; then
        print_info "  noctalia.nix already present"
        return
    fi

    sed -i 's|./modules/base.nix|./modules/base.nix\n    ./modules/noctalia.nix|' "${dest}"
    print_success "Patched home/${nix_user}.nix — added missing noctalia.nix import"
}

function _patch_user_nvidia() {
    local nix_user="${1}"
    local dest="${NIX_CLONE_DIR}/home/${nix_user}.nix"

    if [[ -n "$(grep "nvidia" "${dest}" 2>/dev/null)" ]]; then
        print_info "  nvidia.nix already present"
        return
    fi

    sed -i 's|^  \];|    ./modules/nvidia.nix\n  ];|' "${dest}"
    print_success "Patched home/${nix_user}.nix — added nvidia.nix import"
}

# _scaffold_new_user
# Generates home/<user>.nix with the appropriate module imports for the selected DE/WM.
# Parameters:
#   $1 - username
#   $2 - desktop (hyprland | niri | sway | river | gnome | gnome-paperwm | none)
#   $3 - gpu (nvidia | none)
function _scaffold_new_user() {
    local nix_user="${1}"
    local wm="${2}"
    local gpu="${3:-none}"
    local dest="${NIX_CLONE_DIR}/home/${nix_user}.nix"

    {
        printf "{ ... }:\n"
        printf "{\n"
        printf "  imports = [\n"
        printf "    ./modules/base.nix\n"
        case "${wm}" in
            hyprland|niri|sway|river)
                printf "    ./modules/noctalia.nix\n"
                printf "    ./modules/%s.nix\n" "${wm}"
                ;;
            gnome)
                printf "    ./modules/gnome.nix\n"
                ;;
            gnome-paperwm)
                printf "    ./modules/gnome.nix\n"
                printf "    ./modules/paperwm.nix\n"
                ;;
        esac
        [[ "${gpu}" == "nvidia" ]] && printf "    ./modules/nvidia.nix\n"
        printf "  ];\n\n"
        printf "  home.username      = \"%s\";\n" "${nix_user}"
        printf "  home.homeDirectory = \"/home/%s\";\n" "${nix_user}"
        printf "  home.stateVersion  = \"25.11\";\n"
        printf "}\n"
    } > "${dest}"

    print_success "Scaffolded home/${nix_user}.nix"
    local imports="base.nix"
    case "${wm}" in
        hyprland|niri|sway|river) imports="base.nix, noctalia.nix, ${wm}.nix" ;;
        gnome)               imports="base.nix, gnome.nix" ;;
        gnome-paperwm)       imports="base.nix, gnome.nix, paperwm.nix" ;;
    esac
    [[ "${gpu}" == "nvidia" ]] && imports="${imports}, nvidia.nix"
    print_info "  imports: ${imports}"
}

function _copy_hardware_config() {
    local hostname="${1}"
    local dest="${NIX_CLONE_DIR}/hosts/${hostname}"

    mkdir -p "${dest}"
    cp "/mnt/etc/nixos/hardware-configuration.nix" "${dest}/hardware-configuration.nix"
    print_success "Copied hardware config to hosts/${hostname}/hardware-configuration.nix"
}


# _scaffold_new_host
# Generates a hosts/<hostname>/configuration.nix from the appropriate hardware profile.
# Parameters:
#   $1 - hostname
#   $2 - hardware identifier
#   $3 - username
#   $4 - window manager (hyprland | niri | sway | river | none)
#   $5 - gpu (nvidia | none)
function _scaffold_new_host() {
    local hostname="${1}"
    local hardware="${2}"
    local nix_user="${3}"
    local wm="${4}"
    local gpu="${5:-none}"
    local dest="${NIX_CLONE_DIR}/hosts/${hostname}/configuration.nix"
    mkdir -p "${NIX_CLONE_DIR}/hosts/${hostname}"

    local hardware_import=""
    case "${hardware}" in
        "ThinkPad T480s") hardware_import="../../modules/nixos/hardware/thinkpad-t480s.nix" ;;
        "ROG")            hardware_import="../../modules/nixos/hardware/asus-rog.nix" ;;
        "XPS 13 9350")    hardware_import="../../modules/nixos/hardware/dell-xps-13-9350.nix" ;;
    esac

    {
        printf "{ pkgs, ... }:\n"
        printf "{\n"
        printf "  imports = [\n"
        printf "    ./hardware-configuration.nix\n"
        printf "    ../../modules/nixos/common.nix\n"
        if [[ -n "${hardware_import}" ]]; then
            printf "    %s\n" "${hardware_import}"
        fi
        if [[ "${gpu}" == "nvidia" ]]; then
            printf "    ../../modules/nixos/hardware/nvidia.nix\n"
        fi
        printf "    ../../modules/nixos/audio.nix\n"
        printf "  ];\n\n"
        printf "  boot.loader.systemd-boot.enable = true;\n"
        printf "  boot.loader.efi.canTouchEfiVariables = true;\n"
        printf "  boot.kernelPackages = pkgs.linuxPackages_latest;\n\n"
        printf "  services.btrfs.autoScrub.enable = true;\n\n"
        printf "  zramSwap = { enable = true; algorithm = \"zstd\"; };\n\n"
        printf "  networking.hostName = \"%s\";\n" "${hostname}"
        printf "  networking.networkmanager.enable = true;\n\n"
        printf "  time.timeZone = \"America/New_York\";\n\n"
        printf "  services.libinput.enable = true;\n"
        printf "  services.printing.enable = true;\n"
        printf "  services.openssh.enable = true;\n"
        printf "  services.upower.enable = true;\n\n"
        printf "  hardware.bluetooth.enable = true;\n"
        printf "  hardware.bluetooth.powerOnBoot = true;\n\n"
        printf "  fonts.packages = with pkgs; [\n"
        printf "    noto-fonts\n"
        printf "    noto-fonts-cjk-sans\n"
        printf "    noto-fonts-color-emoji\n"
        printf "    nerd-fonts.jetbrains-mono\n"
        printf "  ];\n\n"
        case "${wm}" in
            hyprland) printf "  programs.hyprland.enable = true;\n\n" ;;
            niri)     printf "  programs.niri.enable = true;\n\n" ;;
            sway)     printf "  programs.sway.enable = true;\n\n" ;;
            river)    printf "  programs.river-classic.enable = true;\n\n" ;;
        esac
        printf "  virtualisation.docker    = { enable = true; enableOnBoot = true; };\n"
        printf "  virtualisation.libvirtd.enable = true;\n"
        printf "  programs.virt-manager.enable = true;\n\n"
        printf "  nixpkgs.config.allowUnfree = true;\n\n"
        printf "  users.users.%s = {\n" "${nix_user}"
        printf "    isNormalUser = true;\n"
        printf "    extraGroups  = [ \"wheel\" \"networkmanager\" \"video\" \"audio\" \"libvirtd\" \"dialout\" ];\n"
        printf "    shell        = pkgs.zsh;\n"
        printf "  };\n\n"
        printf "  environment.systemPackages = with pkgs; [ vim git wget curl pciutils ];\n\n"
        printf "  programs.zsh.enable = true;\n\n"
        printf "  # First NixOS version installed on this machine — do not change.\n"
        printf "  system.stateVersion = \"25.11\";\n"
        printf "}\n"
    } > "${dest}"

    print_success "Scaffolded hosts/${hostname}/configuration.nix"
    if [[ -n "${hardware_import}" ]]; then
        print_info "  Hardware module: ${hardware_import}"
    else
        print_warning "  Hardware '${hardware}' has no module — edit configuration.nix if needed"
    fi
    [[ "${gpu}" == "nvidia" ]] && print_info "  GPU module: modules/nixos/hardware/nvidia.nix"
    case "${wm}" in
        none) print_info "  Compositor: none (headless)" ;;
        *)    print_info "  Compositor: programs.${wm}.enable" ;;
    esac
    print_info "  User: ${nix_user}"
}

# _add_flake_entry
# Auto-inserts the new host entry into flake.nix, then opens it for review.
# Parameters:
#   $1 - hostname
#   $2 - username
#   $3 - window manager (hyprland | niri | sway | river | gnome | gnome-paperwm | none)
function _add_flake_entry() {
    local hostname="${1}"
    local nix_user="${2}"
    local wm="${3}"
    local flake_file="${NIX_CLONE_DIR}/flake.nix"
    local tmp_file
    tmp_file="$(mktemp)"

    local noctalia_line=""
    case "${wm}" in
        hyprland|niri|sway|river) noctalia_line=$'\n        ./modules/nixos/noctalia.nix' ;;
    esac

    local entry
    entry="$(printf '    nixosConfigurations.%s = nixpkgs.lib.nixosSystem {\n      system = "x86_64-linux";\n      specialArgs = { inherit inputs; };\n      modules = [\n        { nixpkgs.overlays = [ overlay ]; }\n        ./hosts/%s/configuration.nix\n        ./modules/nixos/common.nix\n        ./modules/nixos/nix.nix\n        ./modules/nixos/sddm.nix%s\n        silentsddm.nixosModules.default\n        home-manager.nixosModules.home-manager\n        {\n          home-manager.useGlobalPkgs       = true;\n          home-manager.useUserPackages     = true;\n          home-manager.backupFileExtension = "backup";\n          home-manager.users.%s           = import ./home/%s.nix;\n        }\n      ];\n    };' \
        "${hostname}" "${hostname}" "${noctalia_line}" "${nix_user}" "${nix_user}")"

    # Insert entry before the last '  };' in the file (closes the outputs block)
    awk -v entry="${entry}" '
    { lines[NR] = $0 }
    END {
        last = -1
        for (i = NR; i >= 1; i--) {
            if (lines[i] == "  };") { last = i; break }
        }
        for (i = 1; i <= NR; i++) {
            if (i == last) printf "\n%s\n\n", entry
            print lines[i]
        }
    }
    ' "${flake_file}" > "${tmp_file}"
    mv "${tmp_file}" "${flake_file}"

    print_success "Added ${hostname} entry to flake.nix"
    print_info "Opening flake.nix for review — verify the entry, then save and exit."
    printf "\n"
    read -rp "Press Enter to open flake.nix..."
    vim "${flake_file}"
}

# _run_nixos_install
# Parameters:
#   $1 - hostname
#   $2 - username
function _run_nixos_install() {
    local hostname="${1}"
    local nix_user="${2}"

    # Stage all new/modified files so Nix can see them when evaluating the flake.
    # Nix flakes only include git-tracked content — untracked files are invisible.
    print_info "Staging changes in dotfiles.nix so Nix can evaluate them"
    git -C "${NIX_CLONE_DIR}" add -A

    print_info "Running nixos-install"
    nixos-install --flake "${NIX_CLONE_DIR}#${hostname}"

    print_step "Setting password for ${nix_user}"
    nixos-enter --root /mnt -- passwd "${nix_user}"

    # Run home-manager activation inside the chroot while the installer still has
    # network. This ensures the desktop is fully configured on first boot — no
    # post-reboot rebuild required.
    print_step "Running home-manager activation for ${nix_user}"
    local hm_unit="/mnt/etc/systemd/system/home-manager-${nix_user}.service"
    if [[ -f "${hm_unit}" ]]; then
        local exec_start
        exec_start="$(grep '^ExecStart=' "${hm_unit}" | cut -d= -f2-)"
        if [[ -n "${exec_start}" ]]; then
            nixos-enter --root /mnt -- bash -c "${exec_start}" \
                || print_warning "Home-manager pre-activation failed — run nixos-rebuild after first boot"
        else
            print_warning "Could not parse ExecStart from ${hm_unit}"
        fi
    else
        print_warning "home-manager-${nix_user}.service not found — run nixos-rebuild after first boot"
    fi

    # Preserve the repo into the installed system so it survives the reboot
    # and any scaffolded or updated files are ready to commit.
    local installed_home="/mnt/home/${nix_user}"
    if [[ -d "${installed_home}" ]]; then
        cp -r "${NIX_CLONE_DIR}" "${installed_home}/.dotfiles.nix"
        nixos-enter --root /mnt -- chown -R "${nix_user}:users" "/home/${nix_user}/.dotfiles.nix"
        print_success "dotfiles.nix copied to ${installed_home}/.dotfiles.nix"
    else
        print_warning "Could not find ${installed_home} — dotfiles.nix was not copied."
        print_info "After rebooting, clone it manually:"
        printf "  git clone https://gitlab.com/wd2nf8gqct/dotfiles.nix.git ~/.dotfiles.nix\n"
    fi

    printf "\n"
    print_success "Installation complete — reboot when ready."
    print_info "After rebooting, commit any new or updated files in ~/.dotfiles.nix and push."
}
