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
    local hostname
    hostname="$(hostname)"

    if [[ ! -f "/mnt/etc/nixos/hardware-configuration.nix" ]]; then
        print_error "No hardware config found at /mnt/etc/nixos/hardware-configuration.nix"
        print_info "Ensure /mnt is mounted and run: nixos-generate-config --root /mnt"
        return 1
    fi

    print_step "Installing NixOS configuration"

    _clone_nix

    local nix_user
    nix_user="$(_get_nix_user)"
    if [[ -z "${nix_user}" ]]; then
        print_error "Could not detect username from flake.nix"
        print_info "Expected a 'home-manager.users.<user>' entry in flake.nix"
        return 1
    fi
    print_info "Detected user from flake.nix: ${nix_user}"

    _copy_hardware_config "${hostname}"

    if ! _host_exists "${hostname}"; then
        _scaffold_new_host "${hostname}" "${hardware}" "${nix_user}"
        _add_flake_entry "${hostname}" "${nix_user}"
    fi

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

function _copy_hardware_config() {
    local hostname="${1}"
    local dest="${NIX_CLONE_DIR}/hosts/${hostname}"

    mkdir -p "${dest}"
    cp "/mnt/etc/nixos/hardware-configuration.nix" "${dest}/hardware-configuration.nix"
    print_success "Copied hardware config to hosts/${hostname}/hardware-configuration.nix"
}

function _host_exists() {
    local hostname="${1}"
    [[ -n "$(grep "nixosConfigurations\.${hostname}" "${NIX_CLONE_DIR}/flake.nix" 2>/dev/null)" ]]
}

# _get_nix_user
# Extracts the username from the home-manager.users.<user> entry in flake.nix.
function _get_nix_user() {
    grep -oP "home-manager\.users\.\K\w+" "${NIX_CLONE_DIR}/flake.nix" 2>/dev/null | head -1
}

# _scaffold_new_host
# Generates a hosts/<hostname>/configuration.nix from the appropriate hardware profile.
# Parameters:
#   $1 - hostname
#   $2 - hardware identifier
#   $3 - username
function _scaffold_new_host() {
    local hostname="${1}"
    local hardware="${2}"
    local nix_user="${3}"
    local dest="${NIX_CLONE_DIR}/hosts/${hostname}/configuration.nix"

    local hardware_import=""
    case "${hardware}" in
        "ThinkPad T480s") hardware_import="../../modules/nixos/hardware/thinkpad-t480s.nix" ;;
        "ROG")            hardware_import="../../modules/nixos/hardware/asus-rog.nix" ;;
        "XPS 13 9350")    hardware_import="../../modules/nixos/hardware/dell-xps-13-9350.nix" ;;
    esac

    {
        printf "{ config, lib, pkgs, inputs, ... }:\n"
        printf "{\n"
        printf "  imports = [\n"
        printf "    ./hardware-configuration.nix\n"
        if [[ -n "${hardware_import}" ]]; then
            printf "    %s\n" "${hardware_import}"
        fi
        printf "  ];\n\n"
        printf "  boot.loader.systemd-boot.enable = true;\n"
        printf "  boot.loader.systemd-boot.configurationLimit = 5;\n"
        printf "  boot.loader.efi.canTouchEfiVariables = true;\n"
        printf "  boot.kernelPackages = pkgs.linuxPackages_latest;\n\n"
        printf "  services.btrfs.autoScrub.enable = true;\n\n"
        printf "  zramSwap = { enable = true; algorithm = \"zstd\"; };\n\n"
        printf "  networking.hostName = \"%s\";\n" "${hostname}"
        printf "  networking.networkmanager.enable = true;\n\n"
        printf "  time.timeZone = \"America/New_York\";\n\n"
        printf "  services.pulseaudio.enable = false;\n"
        printf "  security.rtkit.enable = true;\n"
        printf "  services.pipewire = {\n"
        printf "    enable = true;\n"
        printf "    alsa.enable = true;\n"
        printf "    alsa.support32Bit = true;\n"
        printf "    pulse.enable = true;\n"
        printf "    jack.enable = true;\n"
        printf "  };\n\n"
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
        printf "  programs.hyprland.enable = true;\n\n"
        printf "  virtualisation.docker    = { enable = true; enableOnBoot = true; };\n"
        printf "  virtualisation.libvirtd.enable = true;\n"
        printf "  programs.virt-manager.enable = true;\n\n"
        printf "  nixpkgs.config.allowUnfree = true;\n\n"
        printf "  users.users.%s = {\n" "${nix_user}"
        printf "    isNormalUser = true;\n"
        printf "    extraGroups  = [ \"wheel\" \"networkmanager\" \"video\" \"audio\" \"libvirtd\" ];\n"
        printf "    shell        = pkgs.zsh;\n"
        printf "  };\n\n"
        printf "  environment.systemPackages = with pkgs; [ vim git wget curl pciutils ];\n\n"
        printf "  programs.zsh.enable = true;\n\n"
        printf "  nix.settings = {\n"
        printf "    experimental-features = [ \"nix-command\" \"flakes\" ];\n"
        printf "    auto-optimise-store   = true;\n"
        printf "  };\n\n"
        printf "  nix.gc = {\n"
        printf "    automatic = true;\n"
        printf "    dates     = \"weekly\";\n"
        printf "    options   = \"--delete-older-than 7d\";\n"
        printf "  };\n\n"
        printf "  # First NixOS version installed on this machine — do not change.\n"
        printf "  system.stateVersion = \"25.11\";\n"
        printf "}\n"
    } > "${dest}"

    print_success "Scaffolded hosts/${hostname}/configuration.nix"

    if [[ -z "${hardware_import}" ]]; then
        print_warning "Hardware '${hardware}' has no module — edit configuration.nix if needed."
    fi
}

# _add_flake_entry
# Prints the flake entry for the new host and opens flake.nix for editing.
# Parameters:
#   $1 - hostname
#   $2 - username
function _add_flake_entry() {
    local hostname="${1}"
    local nix_user="${2}"

    printf "\n"
    print_warning "New host detected — add this entry to flake.nix under nixosConfigurations:"
    printf "\n"
    printf "    nixosConfigurations.%s = nixpkgs.lib.nixosSystem {\n" "${hostname}"
    printf "      system = \"x86_64-linux\";\n"
    printf "      specialArgs = { inherit inputs; };\n"
    printf "      modules = [\n"
    printf "        ./hosts/%s/configuration.nix\n" "${hostname}"
    printf "        home-manager.nixosModules.home-manager\n"
    printf "        {\n"
    printf "          home-manager.useGlobalPkgs    = true;\n"
    printf "          home-manager.useUserPackages  = true;\n"
    printf "          home-manager.users.%s = import ./home/%s.nix;\n" "${nix_user}" "${nix_user}"
    printf "        }\n"
    printf "      ];\n"
    printf "    };\n"
    printf "\n"
    print_info "Opening the real flake.nix from your cloned dotfiles.nix repo."
    print_info "Other hosts (e.g. xiuhcoatl) are already in there — add the new"
    print_info "entry above into the nixosConfigurations block alongside them,"
    print_info "then save and exit to continue with nixos-install."
    printf "\n"
    read -rp "Press Enter to open flake.nix..."
    "${EDITOR:-vim}" "${NIX_CLONE_DIR}/flake.nix"
}

# _run_nixos_install
# Parameters:
#   $1 - hostname
#   $2 - username
function _run_nixos_install() {
    local hostname="${1}"
    local nix_user="${2}"

    print_info "Running nixos-install"
    nixos-install --flake "${NIX_CLONE_DIR}#${hostname}"

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
