# x86_64 → aarch64 default package parity

Every package in Omarchy's default install on x86_64, its aarch64 counterpart,
which repository each side comes from, and why anything unusual is unusual.

Generated from `install/omarchy-base.packages`, `install/omarchy-other.packages`,
`install/omarchy-base-asahi.packages` and `install/omarchy-other-asahi.packages`,
joined against the live pacman sync databases for Arch, Arch Linux ARM, the Asahi
overlay, the `[omarchy]` repo and the third-party `[arch-mact2]` repo. Optional
installer packages are out of scope.

## Where packages come from

| Repository | x86_64 | aarch64 |
|---|---|---|
| `core` / `extra` | Arch Linux | Arch Linux ARM (ALARM) |
| `multilib` | Arch Linux | does not exist on ARM |
| `alarm` / `aur` | — | Arch Linux ARM's own small repos |
| `[asahi-alarm]` | — | Asahi overlay: kernel, mesa, firmware, widevine |
| `[omarchy]` | `pkgs.omarchy.org/stable/x86_64` | a pinned GitHub release of `omarchy-pkgs` |
| `[arch-mact2]` | third-party, added only on T2 Intel Macs | — |
| ISO bundle | — | six packages shipped as signed archives, installed with `pacman -U` |

Repository search order also differs. On x86_64 it is `core → extra → multilib → omarchy`.
On aarch64 it is `omarchy → asahi-alarm → core → extra → alarm → aur`, so our own
packages and the Asahi overlay take precedence over ALARM.

## Summary

- **216 rows.** 157 in the core desktop set, 59 in the platform & hardware set.
- **138 packages carry the same name on both sides**, and nearly all of them come
  from the same repository on each — Arch extra on x86, ALARM extra on aarch64.
- **24 packages come from our own `[omarchy]` repo on aarch64.** 19 of those are
  custom on x86 too; 5 (`obs-studio`, `obsidian`, `dotnet-runtime`, `pinta`,
  `qemu-user-static-binfmt`) come from Arch on x86 and simply have no aarch64
  build anywhere, so we build them ourselves.
- **3 packages are not served from any repo on aarch64.** `omarchy-nvim`,
  `ttf-jetbrains-mono-nerd-basic` and `quickshell-git` ship on the ISO as
  pre-built signed archives, are installed with `pacman -U`, and are held back
  from pacman and AUR updates.
- **3 renames**: `mise-bin`→`mise`, `nvim`→`neovim`, `quickshell`→`quickshell-git`.
  `nvim` is not really a rename — it is a virtual name that `neovim` provides.
- **10 aarch64-only additions**, all Apple Silicon platform pieces: the Asahi
  kernel, mesa with the Apple GPU driver, firmware extraction, widevine, rtkit.
- **42 x86-only packages**, all of them hardware or boot stacks that do not exist
  on Apple Silicon: NVIDIA and its EGL/multilib tail (9), Intel graphics, power
  and audio firmware (9), PC laptop and peripheral drivers (8), T2 Intel Mac (5),
  Limine + snapper (4), the stock and patched kernels (4), AMD Vulkan (1), the
  x86 speaker-tuning LV2 plugin (1) and `yay-debug` (1).

### Known lag

The published aarch64 `[omarchy]` release currently carries **33** packages while
the source tree builds **52**. The 19-package parity work has landed in the tree
but not yet been promoted, so a machine installed from the current pinned tag will
be short those packages until the next promotion.

## Core desktop set

| Package (x86) | Package (aarch64) | Source (x86) | Source (aarch64) | Status | Notes |
|---|---|---|---|---|---|
| `aether` | `aether` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `alsa-utils` | `alsa-utils` | Arch extra | ALARM extra | Same |  |
| `asdcontrol` | `asdcontrol` | [omarchy] | [omarchy] | Custom (both) | The PKGBUILD declared `arch=('x86_64')` although the source is portable. Widened and now built for ARM. |
| `avahi` | `avahi` | Arch extra | ALARM extra | Same |  |
| `bash-completion` | `bash-completion` | Arch extra | ALARM extra | Same |  |
| `bat` | `bat` | Arch extra | ALARM extra | Same |  |
| `bluez` | `bluez` | Arch extra | ALARM extra | Same |  |
| `bluez-tools` | `bluez-tools` | Arch extra | ALARM extra | Same |  |
| `bluez-utils` | `bluez-utils` | Arch extra | ALARM extra | Same |  |
| `bolt` | `bolt` | Arch extra | ALARM extra | Same |  |
| `brightnessctl` | `brightnessctl` | Arch extra | ALARM extra | Same |  |
| `btop` | `btop` | Arch extra | ALARM extra | Same |  |
| `chromium` | `chromium` | Arch extra | ALARM extra | Same |  |
| `clang` | `clang` | Arch extra | ALARM extra | Same |  |
| `cliamp` | `cliamp` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `cups` | `cups` | Arch extra | ALARM extra | Same |  |
| `cups-filters` | `cups-filters` | Arch extra | ALARM extra | Same |  |
| `cups-pk-helper` | `cups-pk-helper` | Arch extra | ALARM extra | Same |  |
| `ddcutil` | `ddcutil` | Arch extra | ALARM extra | Same |  |
| `docker` | `docker` | Arch extra | ALARM extra | Same |  |
| `docker-buildx` | `docker-buildx` | Arch extra | ALARM extra | Same |  |
| `docker-compose` | `docker-compose` | Arch extra | ALARM extra | Same |  |
| `dosfstools` | `dosfstools` | Arch core | ALARM core | Same |  |
| `dotnet-runtime` | `dotnet-runtime` | Arch extra | [omarchy] | Built for ARM | Not in ALARM. Built from AUR `dotnet-core-bin`, renamed to Arch's split output names (dotnet-host / dotnet-runtime / dotnet-sdk / aspnet-runtime / + 2 targeting packs) so the rest of the tree needs no changes. |
| `dua-cli` | `dua-cli` | Arch extra | ALARM extra | Same |  |
| `evince` | `evince` | Arch extra | ALARM extra | Same |  |
| `exfatprogs` | `exfatprogs` | Arch extra | ALARM extra | Same |  |
| `expac` | `expac` | Arch extra | ALARM extra | Same |  |
| `eza` | `eza` | Arch extra | ALARM extra | Same |  |
| `fakeroot` | `fakeroot` | Arch core | ALARM core | Same |  |
| `fastfetch` | `fastfetch` | Arch extra | ALARM extra | Same |  |
| `fcitx5` | `fcitx5` | Arch extra | ALARM extra | Same |  |
| `fcitx5-gtk` | `fcitx5-gtk` | Arch extra | ALARM extra | Same |  |
| `fcitx5-qt` | `fcitx5-qt` | Arch extra | ALARM extra | Same |  |
| `fd` | `fd` | Arch extra | ALARM extra | Same |  |
| `ffmpegthumbnailer` | `ffmpegthumbnailer` | Arch extra | ALARM extra | Same |  |
| `fontconfig` | `fontconfig` | Arch extra | ALARM extra | Same |  |
| `foot` | `foot` | Arch extra | ALARM extra | Same |  |
| `fzf` | `fzf` | Arch extra | ALARM extra | Same |  |
| `git` | `git` | Arch extra | ALARM extra | Same |  |
| `gnome-keyring` | `gnome-keyring` | Arch extra | ALARM extra | Same |  |
| `gnome-themes-extra` | `gnome-themes-extra` | Arch extra | ALARM extra | Same |  |
| `grim` | `grim` | Arch extra | ALARM extra | Same |  |
| `gpu-screen-recorder` | `gpu-screen-recorder` | Arch extra | ALARM extra | Same | In ALARM extra all along - was simply missing from the ARM list. Replaces the interim `wf-recorder` substitute. Encodes on CPU on Apple Silicon; no hardware encoder path yet. |
| `gum` | `gum` | Arch extra | ALARM extra | Same |  |
| `gvfs-mtp` | `gvfs-mtp` | Arch extra | ALARM extra | Same |  |
| `gvfs-nfs` | `gvfs-nfs` | Arch extra | ALARM extra | Same |  |
| `gvfs-smb` | `gvfs-smb` | Arch extra | ALARM extra | Same |  |
| `herdr` | `herdr` | [omarchy] | [omarchy] | Custom (both) | PKGBUILD only existed upstream; ported into our fork and built for ARM. |
| `hyprland` | `hyprland` | Arch extra | ALARM extra | Same |  |
| `hyprland-guiutils` | `hyprland-guiutils` | Arch extra | ALARM extra | Same |  |
| `hyprland-preview-share-picker` | `hyprland-preview-share-picker` | [omarchy] | [omarchy] | Custom (both) | The PKGBUILD declared `arch=('x86_64')` although the source is portable. Widened and now built for ARM. |
| `hyprpicker` | `hyprpicker` | Arch extra | ALARM extra | Same |  |
| `hyprsunset` | `hyprsunset` | Arch extra | ALARM extra | Same |  |
| `imagemagick` | `imagemagick` | Arch extra | ALARM extra | Same |  |
| `imv` | `imv` | Arch extra | ALARM extra | Same |  |
| `inetutils` | `inetutils` | Arch core | ALARM core | Same |  |
| `inotify-tools` | `inotify-tools` | Arch extra | ALARM extra | Same |  |
| `inxi` | `inxi` | Arch extra | ALARM extra | Same |  |
| `networkmanager` | `networkmanager` | Arch extra | ALARM extra | Same |  |
| `jq` | `jq` | Arch extra | ALARM extra | Same |  |
| `kdenlive` | `kdenlive` | Arch extra | ALARM extra | Same |  |
| `kernel-modules-hook` | `kernel-modules-hook` | Arch extra | ALARM extra | Same |  |
| `lazydocker` | `lazydocker` | Arch extra | ALARM extra | Same |  |
| `lazygit` | `lazygit` | Arch extra | ALARM extra | Same |  |
| `less` | `less` | Arch core | ALARM core | Same |  |
| `libsecret` | `libsecret` | Arch core | ALARM core | Same |  |
| `libvips` | `libvips` | Arch extra | ALARM extra | Same |  |
| `libyaml` | `libyaml` | Arch extra | ALARM extra | Same |  |
| `libreoffice-fresh` | `libreoffice-fresh` | Arch extra | ALARM extra | Same | In ALARM extra (26.8) - was simply missing from the ARM list. |
| `llvm` | `llvm` | Arch extra | ALARM extra | Same |  |
| `localsend` | `localsend` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `lua51` | `lua51` | Arch extra | ALARM extra | Same |  |
| `luarocks` | `luarocks` | Arch extra | ALARM extra | Same |  |
| `man-db` | `man-db` | Arch core | ALARM core | Same |  |
| `mariadb-libs` | `mariadb-libs` | Arch extra | ALARM extra | Same |  |
| `mise-bin` | `mise` | [omarchy] | [omarchy] | Renamed | Renamed on ARM: the `-bin` AUR tarball is x86-only, so we build `mise` from source in [omarchy]. |
| `moonlight-qt` | `moonlight-qt` | Arch extra | ALARM extra | Same | In ALARM extra (6.1) - was simply missing from the ARM list. |
| `mpv` | `mpv` | Arch extra | ALARM extra | Same |  |
| `mpv-mpris` | `mpv-mpris` | Arch extra | ALARM extra | Same |  |
| `nautilus` | `nautilus` | Arch extra | ALARM extra | Same |  |
| `nautilus-python` | `nautilus-python` | Arch extra | ALARM extra | Same |  |
| `gnome-disk-utility` | `gnome-disk-utility` | Arch extra | ALARM extra | Same |  |
| `noto-fonts` | `noto-fonts` | Arch extra | ALARM extra | Same |  |
| `noto-fonts-cjk` | `noto-fonts-cjk` | Arch extra | ALARM extra | Same |  |
| `noto-fonts-emoji` | `noto-fonts-emoji` | Arch extra | ALARM extra | Same |  |
| `nss-mdns` | `nss-mdns` | Arch extra | ALARM extra | Same |  |
| `nvim` | `neovim` | Arch extra (virtual) | ALARM extra | Renamed | Not a real package on either side - `nvim` is a virtual name provided by `neovim`. The x86 list uses the alias, the ARM list spells out `neovim`. Same package. |
| `obs-studio` | `obs-studio` | Arch extra | [omarchy] | Built for ARM | Not in ALARM. Built from source for aarch64 with the browser source removed - there is no CEF for ARM - so no `obs-studio-browser` split. |
| `obsidian` | `obsidian` | Arch extra | [omarchy] | Built for ARM | No aarch64 build exists anywhere. ALARM has no `electron`, so our PKGBUILD repackages Obsidian's official arm64 tarball with its own bundled Electron. |
| `omacalc` | `omacalc` | [omarchy] | [omarchy] | Custom (both) | PKGBUILD only existed upstream; ported and built for ARM. Replaces the interim `gnome-calculator` substitute, so the calculator keybinding matches x86 again. |
| `omacut` | `omacut` | [omarchy] | [omarchy] | Custom (both) | Already built for ARM in [omarchy] - was simply missing from the ARM list. |
| `omawrite` | `omawrite` | [omarchy] | [omarchy] | Custom (both) | Already built for ARM in [omarchy] - was simply missing from the ARM list. |
| `omarchy-nvim` | `omarchy-nvim` | [omarchy] | ISO bundle (pacman -U) | Same | One of six packages shipped on the ISO as pre-built signed archives and installed with `pacman -U`, rather than served from a repo. Held back from pacman/AUR updates on ARM. |
| `pacman-contrib` | `pacman-contrib` | Arch extra | ALARM extra | Same |  |
| `pamixer` | `pamixer` | Arch extra | ALARM extra | Same |  |
| `pinta` | `pinta` | Arch extra | [omarchy] | Built for ARM | Depends on .NET. Built with `RuntimeIdentifier=linux-arm64` against a self-contained arm64 SDK tarball pulled in as `source_aarch64`. |
| `plocate` | `plocate` | Arch extra | ALARM extra | Same |  |
| `plymouth` | `plymouth` | Arch extra | ALARM extra | Same |  |
| `postgresql-libs` | `postgresql-libs` | Arch extra | ALARM extra | Same |  |
| `power-profiles-daemon` | `power-profiles-daemon` | Arch extra | ALARM extra | Same |  |
| `python-gobject` | `python-gobject` | Arch extra | ALARM extra | Same |  |
| `python-poetry-core` | `python-poetry-core` | Arch extra | ALARM extra | Same |  |
| `ttfx` | `ttfx` | [omarchy] | [omarchy] | Custom (both) | PKGBUILD only existed upstream; ported and built for ARM. Replaces the interim `python-terminaltexteffects` substitute. |
| `qemu-user-static-binfmt` | `qemu-user-static-binfmt` | Arch extra | [omarchy] | Built for ARM | Not in ALARM. Repackaged from Debian trixie's `qemu-user` .deb, which is genuinely static. On ARM the binfmt handlers register x86_64 and i386 only - registering aarch64 on an aarch64 host would loop. |
| `qrencode` | `qrencode` | Arch extra | ALARM extra | Same |  |
| `qt6-imageformats` | `qt6-imageformats` | Arch extra | ALARM extra | Same | In ALARM extra (6.11) - was simply missing from the ARM list. |
| `quickshell` | `quickshell-git` | Arch extra | ISO bundle (pacman -U) | Renamed | ARM uses the `-git` build instead. `quickshell-git` is not in the ARM repo - it is one of six packages shipped on the ISO as a pre-built signed archive, installed with `pacman -U` and held back from updates. |
| `ripgrep` | `ripgrep` | Arch extra | ALARM extra | Same |  |
| `ruby` | `ruby` | Arch extra | ALARM extra | Same |  |
| `tensaku` | `tensaku` | [omarchy] | [omarchy] | Custom (both) | The PKGBUILD declared `arch=('x86_64')` although the source is portable. Widened and now built for ARM. Also replaced an interim ARM substitute. |
| `sddm` | `sddm` | Arch extra | ALARM extra | Same |  |
| `slurp` | `slurp` | Arch extra | ALARM extra | Same |  |
| `socat` | `socat` | Arch extra | ALARM extra | Same |  |
| `starship` | `starship` | Arch extra | ALARM extra | Same |  |
| `sushi` | `sushi` | Arch extra | ALARM extra | Same |  |
| `system-config-printer` | `system-config-printer` | Arch extra | ALARM extra | Same |  |
| `tesseract` | `tesseract` | Arch extra | ALARM extra | Same |  |
| `tesseract-data-eng` | `tesseract-data-eng` | Arch extra | ALARM extra | Same |  |
| `tldr` | `tldr` | Arch extra | ALARM extra | Same |  |
| `tree-sitter-cli` | `tree-sitter-cli` | Arch extra | ALARM extra | Same |  |
| `tmux` | `tmux` | Arch extra | ALARM extra | Same |  |
| `tobi-try` | `tobi-try` | [omarchy] | [omarchy] | Custom (both) | The PKGBUILD declared `arch=('x86_64')` although the content is arch-neutral. Now `arch=('any')` and available on ARM. |
| `ttf-ia-writer` | `ttf-ia-writer` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `ttf-jetbrains-mono-nerd-basic` | `ttf-jetbrains-mono-nerd-basic` | [omarchy] | ISO bundle (pacman -U) | Same | One of six packages shipped on the ISO as pre-built signed archives and installed with `pacman -U`, rather than served from a repo. Held back from pacman/AUR updates on ARM. |
| `tzupdate` | `tzupdate` | [omarchy] | [omarchy] | Custom (both) | The PKGBUILD declared `arch=('x86_64')` although the source is portable. Widened and now built for ARM. |
| `udiskie` | `udiskie` | Arch extra | ALARM extra | Same |  |
| `ufw` | `ufw` | Arch extra | ALARM extra | Same |  |
| `ufw-docker` | `ufw-docker` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `unzip` | `unzip` | Arch extra | ALARM extra | Same |  |
| `usage` | `usage` | Arch extra | ALARM extra | Same |  |
| `uwsm` | `uwsm` | Arch extra | ALARM extra | Same |  |
| `whois` | `whois` | Arch extra | ALARM extra | Same |  |
| `wireless-regdb` | `wireless-regdb` | Arch core | ALARM core | Same |  |
| `wireplumber` | `wireplumber` | Arch extra | ALARM extra | Same |  |
| `wl-clipboard` | `wl-clipboard` | Arch extra | ALARM extra | Same |  |
| `wtype` | `wtype` | Arch extra | ALARM extra | Same |  |
| `woff2-font-awesome` | `woff2-font-awesome` | Arch extra | ALARM extra | Same |  |
| `xdg-desktop-portal-gtk` | `xdg-desktop-portal-gtk` | Arch extra | ALARM extra | Same |  |
| `xdg-desktop-portal-hyprland` | `xdg-desktop-portal-hyprland` | Arch extra | ALARM extra | Same |  |
| `xdg-terminal-exec` | `xdg-terminal-exec` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `xournalpp` | `xournalpp` | Arch extra | ALARM extra | Same |  |
| `yaru-icon-theme` | `yaru-icon-theme` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `yay` | `yay` | [omarchy] | [omarchy] | Custom (both) | Rebuilt from AUR and signed into our own repo for both architectures - it is not in Arch or ALARM. |
| `yt-dlp` | `yt-dlp` | Arch extra | ALARM extra | Same |  |
| `zbar` | `zbar` | Arch extra | ALARM extra | Same |  |
| `zoxide` | `zoxide` | Arch extra | ALARM extra | Same |  |
| — | `asahi-desktop-meta` | — | [asahi-alarm] | ARM-only | Asahi platform meta package - pulls the Apple Silicon desktop stack. |
| — | `asahi-fwextract` | — | [asahi-alarm] | ARM-only | Extracts Apple firmware (Wi-Fi, Bluetooth, display) from the macOS side of the disk. No x86 equivalent. |
| — | `linux-asahi` | — | [asahi-alarm] | ARM-only | The Asahi kernel. Replaces `linux` / `linux-t2` / `linux-ptl`. |
| — | `linux-asahi-headers` | — | [asahi-alarm] | ARM-only | Headers for the Asahi kernel. |
| — | `mesa` | — | [asahi-alarm] | ARM-only | Comes from the Asahi overlay, not ALARM - it carries the Apple GPU driver. On x86 mesa arrives as a dependency, not a listed package. |
| — | `mesa-demos` | — | ALARM extra | ARM-only | Listed explicitly on ARM to make GPU acceleration verifiable during bring-up. |
| — | `mesa-utils` | — | ALARM extra | ARM-only | Listed explicitly on ARM (`glxinfo` / `eglinfo`) to make GPU acceleration verifiable during bring-up. |
| — | `fwupd` | — | ALARM extra | ARM-only | Firmware updates; explicit on ARM because the Apple Silicon boot chain needs it. |
| — | `widevine` | — | [asahi-alarm] | ARM-only | DRM playback (Netflix, Spotify web). Ships in the Asahi overlay; on x86 it comes bundled with the browser. |
| — | `rtkit` | — | ALARM extra | ARM-only | Realtime scheduling for audio. Explicit on ARM because the Asahi speaker-protection filter chain depends on it. |

## Platform & hardware set

| Package (x86) | Package (aarch64) | Source (x86) | Source (aarch64) | Status | Notes |
|---|---|---|---|---|---|
| `autoconf-archive` | `autoconf-archive` | Arch extra | ALARM extra | Same |  |
| `asusctl` | — | [omarchy] | — | x86-only | ASUS ROG laptop control daemon. |
| `base` | `base` | Arch core | ALARM core | Same |  |
| `base-devel` | `base-devel` | Arch core | ALARM core | Same |  |
| `broadcom-wl-dkms` | — | Arch extra | — | x86-only | Broadcom Wi-Fi DKMS driver for PC laptops. Apple Silicon Wi-Fi is in `linux-asahi`. |
| `btrfs-progs` | `btrfs-progs` | Arch core | ALARM core | Same |  |
| `dkms` | `dkms` | Arch extra | ALARM extra | Same | Kept on ARM even though every DKMS *driver* is dropped, because out-of-tree modules can still be built locally. |
| `egl-wayland` | — | Arch extra | — | x86-only | Pulled in for the NVIDIA EGL path; unnecessary on Asahi mesa. |
| `gst-plugin-pipewire` | `gst-plugin-pipewire` | Arch extra | ALARM extra | Same |  |
| `gtk4-layer-shell` | `gtk4-layer-shell` | Arch extra | ALARM extra | Same |  |
| `libpulse` | `libpulse` | Arch extra | ALARM extra | Same |  |
| `intel-ipu7-camera` | — | [omarchy] | — | x86-only | Intel IPU7 webcam stack. Not applicable. |
| `intel-lpmd` | — | Arch extra | — | x86-only | Intel low-power daemon. Not applicable. |
| `intel-media-driver` | — | Arch extra | — | x86-only | Intel VA-API driver. Not applicable. |
| `libva-intel-driver` | — | Arch extra | — | x86-only | Legacy Intel VA-API driver. Not applicable. |
| `libva-nvidia-driver` | — | Arch extra | — | x86-only | NVIDIA VA-API bridge. Not applicable. |
| `limine` | — | Arch extra | — | x86-only | Bootloader. Apple Silicon boots through m1n1 + U-Boot, so the whole Limine/snapper-hook stack is dropped. |
| `limine-mkinitcpio-hook` | — | [omarchy] | — | x86-only | Part of the Limine stack - not used on Apple Silicon. |
| `limine-snapper-sync` | — | [omarchy] | — | x86-only | Part of the Limine stack - not used on Apple Silicon. |
| `linux` | — | Arch core | — | x86-only | Stock Arch kernel. Replaced on ARM by `linux-asahi`. |
| `linux-firmware` | `linux-firmware` | Arch core | ALARM core | Same |  |
| `linux-headers` | — | Arch core | — | x86-only | Replaced on ARM by `linux-asahi-headers`. |
| `linux-ptl` | — | [omarchy] | — | x86-only | Omarchy's patched kernel variant, x86 only. Currently `skip_build: true`. |
| `linux-ptl-headers` | — | [omarchy] | — | x86-only | Headers for the x86-only patched kernel. |
| `macbook12-spi-driver-dkms` | — | [omarchy] | — | x86-only | SPI keyboard/trackpad driver for 2015-2017 Intel MacBooks. |
| `nvidia-580xx-dkms` | — | [omarchy] | — | x86-only | Legacy NVIDIA GPU driver. Not applicable. |
| `nvidia-dkms` | — | Arch extra (virtual) | — | x86-only | Virtual name provided by `nvidia-open-dkms` in Arch extra. NVIDIA hardware does not exist on Apple Silicon, so the whole stack is dropped. |
| `nvidia-open-dkms` | — | Arch extra | — | x86-only | NVIDIA GPU driver (open kernel modules). Not applicable. |
| `nvidia-580xx-utils` | — | [omarchy] | — | x86-only | Legacy NVIDIA userspace. Not applicable. |
| `nvidia-utils` | — | Arch extra | — | x86-only | NVIDIA userspace. Not applicable. |
| `lib32-nvidia-580xx-utils` | — | [omarchy] | — | x86-only | 32-bit legacy NVIDIA userspace from multilib. ALARM has no multilib at all. |
| `lib32-nvidia-utils` | — | Arch multilib | — | x86-only | 32-bit NVIDIA userspace from multilib. ALARM has no multilib at all. |
| `pipewire` | `pipewire` | Arch extra | ALARM extra | Same |  |
| `pipewire-alsa` | `pipewire-alsa` | Arch extra | ALARM extra | Same |  |
| `pipewire-jack` | `pipewire-jack` | Arch extra | ALARM extra | Same |  |
| `pipewire-pulse` | `pipewire-pulse` | Arch extra | ALARM extra | Same |  |
| `qt6-wayland` | `qt6-wayland` | Arch extra | ALARM extra | Same |  |
| `snapper` | — | Arch extra | — | x86-only | Btrfs snapshots are wired to the Limine boot menu, which does not exist on ARM. Dropped with the rest of that stack. |
| `sof-firmware` | — | Arch extra | — | x86-only | Intel Sound Open Firmware. Apple Silicon audio firmware comes via `asahi-fwextract`. |
| `thermald` | — | Arch extra | — | x86-only | Intel thermal daemon. Apple Silicon thermal management is in the kernel. |
| `webp-pixbuf-loader` | `webp-pixbuf-loader` | Arch extra | ALARM extra | Same | In ALARM extra - carried on both sides. |
| `yay-debug` | — | [omarchy] | — | x86-only | Debug symbols split of `yay`; only published for x86. |
| `tuxedo-drivers-nocompatcheck-dkms` | — | [omarchy] | — | x86-only | TUXEDO laptop drivers. |
| `yt6801-dkms` | — | [omarchy] | — | x86-only | Motorcomm YT6801 ethernet driver for PC motherboards. |
| `zram-generator` | `zram-generator` | Arch extra | ALARM extra | Same |  |
| `libvpl` | — | Arch extra | — | x86-only | Intel oneVPL video runtime. Not applicable. |
| `vpl-gpu-rt` | — | Arch extra | — | x86-only | Intel oneVPL GPU runtime. Not applicable. |
| `vulkan-intel` | — | Arch extra | — | x86-only | Intel GPU Vulkan driver. Replaced on ARM by `vulkan-asahi`. |
| `vulkan-radeon` | — | Arch extra | — | x86-only | AMD GPU Vulkan driver. No AMD hardware on Apple Silicon. |
| `vulkan-asahi` | `vulkan-asahi` | Arch extra | ALARM extra | Same | Apple GPU Vulkan driver - the ARM counterpart to `vulkan-intel` / `vulkan-radeon`. |
| `linux-firmware-marvell` | — | Arch core | — | x86-only | Marvell Wi-Fi firmware for Surface laptops. |
| `dell-xps-touchpad-haptics` | — | [omarchy] | — | x86-only | Dell XPS haptic touchpad driver. |
| `lsp-plugins-lv2` | — | Arch extra | — | x86-only | LV2 limiter used by the x86 speaker tunings. Apple Silicon uses the Asahi `triforce-lv2` / `bankstown` chain instead. |
| `apple-bcm-firmware` | — | [arch-mact2] | — | x86-only | From the third-party `[arch-mact2]` repo. T2-era Intel Mac Wi-Fi/BT firmware; on Apple Silicon this is extracted from macOS by `asahi-fwextract`. |
| `apple-t2-audio-config` | — | [arch-mact2] | — | x86-only | From the third-party `[arch-mact2]` repo. Apple Silicon uses the Asahi audio chain (`asahi-audio`, `speakersafetyd`, `triforce-lv2`) instead. |
| `linux-t2` | — | [arch-mact2] | — | x86-only | Comes from the third-party `[arch-mact2]` repo, which the x86 installer adds only when it detects T2 Mac hardware. Meaningless on Apple Silicon. |
| `linux-t2-headers` | — | [arch-mact2] | — | x86-only | From the third-party `[arch-mact2]` repo (T2 Intel Macs only). |
| `t2fanrd` | — | [arch-mact2] | — | x86-only | From the third-party `[arch-mact2]` repo. Apple Silicon thermal management lives in the kernel. |
| `qmk-hid` | — | [omarchy] | — | x86-only | Framework 16 keyboard firmware tool. |
