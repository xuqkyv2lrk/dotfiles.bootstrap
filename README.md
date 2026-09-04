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
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-555555?style=flat&logo=apple&logoColor=white" alt="macOS" /></a>
</p>
</div>

## What is this?

This is the entry point for setting up a new machine. It handles everything
that needs to happen before dotfiles are usable: detecting the distro and
hardware, installing packages, applying hardware-specific config, cloning the
dotfiles repos, and wiring them up.

The other repos are config only:

| Repo | Purpose |
|------|---------|
| [dotfiles.core](https://gitlab.com/wd2nf8gqct/dotfiles.core) | Program configs (zsh, vim, tmux, etc.) — stow to wire |
| [dotfiles.di](https://gitlab.com/wd2nf8gqct/dotfiles.di) | Desktop interface configs (Hyprland, Niri, Sway, GNOME, macOS) — stow to wire |
| [dotfiles.nix](https://gitlab.com/wd2nf8gqct/dotfiles.nix) | NixOS system config + Home Manager — self-contained |
| **dotfiles.bootstrap** (this repo) | Orchestration — detects, installs, clones, wires |

## Usage

### Arch / Ubuntu

```bash
git clone https://gitlab.com/wd2nf8gqct/dotfiles.bootstrap.git ~/.dotfiles.bootstrap
cd ~/.dotfiles.bootstrap
./bootstrap.sh
```

**Options**

```
--minimal, --server  Install only CLI tools, skip GUI apps
--no-di              Skip desktop interface installation
--help, -h           Show this help message
```

**Desktop interface selection**

The installer prompts for a desktop interface after installing core packages.
Available choices depend on distro:

| Distro | Options |
|--------|---------|
| Arch   | Hyprland, Niri, Sway, GNOME (+ optional PaperWM) |
| Ubuntu | GNOME (+ optional PaperWM), Niri |

[Noctalia](https://gitlab.com/wd2nf8gqct/dotfiles.di#noctalia) is always installed as the
shell layer across all Wayland compositors — it handles the bar, launcher,
notifications, lock screen, session, screenshots, and wallpapers.

### macOS (Apple Silicon)

```bash
git clone https://gitlab.com/wd2nf8gqct/dotfiles.bootstrap.git ~/.dotfiles.bootstrap
cd ~/.dotfiles.bootstrap
./bootstrap.sh
```

Bootstrap detects macOS, installs Homebrew, installs packages via brew, clones
dotfiles.core and dotfiles.di, and wires both via stow. Third-party taps are
trusted via `brew trust` (Homebrew 6 skips untrusted taps), and casks install
with `HOMEBREW_CASK_OPTS=--no-quarantine` so apps launch without the Gatekeeper
prompt. A dev toolchain (pnpm, sqlc, golangci-lint, PostGIS, PostgreSQL, Atlas,
mockgen, plus the `hashicorp/tap` tap) is installed alongside the base packages.

macOS-only shell setup that dotfiles.core doesn't provide — `brew shellenv` on
PATH, GNU userland ahead of the BSD tools, and the `HOMEBREW_*` toggles — is
written to a managed block in `~/.zprofile` (dotfiles.core stows `~/.zshenv`
and `~/.zshrc`, so writing there would be clobbered on the next stow).
Re-running `./bootstrap.sh` is safe and is the way to resume an interrupted run.

### NixOS

Bootstrap runs from the **NixOS installer ISO** — not after first boot. Partition,
format, and mount the disk first, then:

```bash
nixos-generate-config --root /mnt
git clone https://gitlab.com/wd2nf8gqct/dotfiles.bootstrap.git /tmp/dotfiles.bootstrap
cd /tmp/dotfiles.bootstrap
./bootstrap.sh
```

Bootstrap detects NixOS, clones dotfiles.nix, copies the hardware config, scaffolds
a host config if the hostname is new (opening an editor to wire in the flake entry),
then runs `nixos-install`. The repo is copied into the installed system before reboot
so any new files are ready to commit from `~/.dotfiles.nix` after first boot.

See the [dotfiles.nix README](https://gitlab.com/wd2nf8gqct/dotfiles.nix#base-installation-guide) for the
full disk setup walkthrough.

## Repository layout

`bootstrap.sh` is the entry point — it detects the distro and delegates to the appropriate installer under `core/`, `di/`, `macos/`, or `nix/`. `lib/common.sh` provides shared utilities (colors, distro and hardware detection, package installation helpers) used by all installers.

## License

BSD 3-Clause License. See [LICENSE](LICENSE) file.
