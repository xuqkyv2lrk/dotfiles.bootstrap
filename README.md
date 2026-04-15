<div align="center">
<h3>dotfiles.bootstrap</h3>
<p>Bootstraps a new machine with packages, hardware config, and dotfiles.</p>
<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-BSD%203--Clause-blue.svg" alt="License" /></a>
  <a href="https://gitlab.com/wd2nf8gqct/dotfiles.bootstrap"><img src="https://img.shields.io/badge/GitLab-Main-orange.svg?logo=gitlab" alt="GitLab" /></a>
  <a href="https://github.com/xuqkyv2lrk/dotfiles.bootstrap"><img src="https://img.shields.io/badge/GitHub-Mirror-black.svg?logo=github" alt="GitHub Mirror" /></a>
  <a href="https://codeberg.org/iw8knmadd5/dotfiles.bootstrap"><img src="https://img.shields.io/badge/Codeberg-Mirror-2185D0.svg?logo=codeberg" alt="Codeberg Mirror" /></a>
</p>
<p>
  <a href="https://archlinux.org"><img src="https://img.shields.io/badge/Arch%20Linux-1793D1?logo=arch-linux&logoColor=fff&style=flat" alt="Arch Linux" /></a>
  <a href="https://ubuntu.com"><img src="https://img.shields.io/badge/Ubuntu-E95420?style=flat&logo=ubuntu&logoColor=white" alt="Ubuntu" /></a>
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/NixOS-5277C3?logo=nixos&logoColor=white&style=flat" alt="NixOS" /></a>
</p>
</div>

## What is this?

This is the single entry point for setting up a new machine. It handles
everything that needs to happen before dotfiles are usable: detecting the
distro and hardware, installing packages, applying hardware-specific config,
cloning the dotfiles repos, and wiring them up.

The other repos are config only:

| Repo | Purpose |
|------|---------|
| [dotfiles.core](https://gitlab.com/wd2nf8gqct/dotfiles.core) | Program configs (zsh, vim, tmux, etc.) — stow to wire |
| [dotfiles.di](https://gitlab.com/wd2nf8gqct/dotfiles.di) | Desktop interface configs (Hyprland, Niri, Sway, GNOME) — stow to wire |
| [dotfiles.nix](https://gitlab.com/wd2nf8gqct/dotfiles.nix) | NixOS system config + Home Manager — self-contained |
| **dotfiles.bootstrap** (this repo) | Orchestration — detects, installs, clones, wires |

## Usage

```bash
git clone https://gitlab.com/wd2nf8gqct/dotfiles.bootstrap.git ~/.dotfiles.bootstrap
cd ~/.dotfiles.bootstrap
./bootstrap.sh
```

### Options

```
--minimal, --server  Install only CLI tools, skip GUI apps
--no-di              Skip desktop interface installation
--help, -h           Show this help message
```

## Repository layout

```
.
├── bootstrap.sh          # entry point — detect, clone, orchestrate
├── lib/
│   └── common.sh         # shared utilities: colors, distro/hardware detection,
│                         #   package installation helpers
├── core/
│   ├── install.sh        # installs core packages, wires dotfiles.core via stow
│   ├── packages.yaml     # package list with distro-specific exceptions
│   └── system_components/
│       └── xps_13_9350/  # hardware-specific assets (e.g. firmware files)
├── di/
│   ├── install.sh        # installs DE packages, wires dotfiles.di via stow
│   └── packages.yaml     # DE package list with distro-specific exceptions
└── nix/
    └── install.sh        # NixOS path — hardware module selection, nixos-rebuild
```

## License

BSD 3-Clause License. See [LICENSE](LICENSE) file.
