# lowakernel

![lowakernel logo](lowakernel_logo.png)

Changed name from detkernel to lowakernel, because my dog's name is Lowa and I love her too much.

A custom Linux kernel built specifically for AMD-powered ThinkPads. Strips everything that doesn't belong: Intel, NVIDIA, legacy drivers, dead protocols, server-only subsystems etc., leaving a leaner, more responsive kernel tuned for the hardware that's actually in your machine.

Faster boot. Better responsiveness. Slightly better performance. Lower power consumption.

> **Note:** lowakernel may work on other AMD-based laptops or desktops, but is only tested and supported on ThinkPads. Intel ThinkPads are not supported at all, all Intel drivers are removed on purpose. Use on other hardware at your own risk.

---

## Supported models

| Model | CPU Generation |
|-------|---------------|
| ThinkPad T495 | AMD Zen1 |
| ThinkPad T14 / T14s G1-G6 | AMD Zen2-Zen5 |
| ThinkPad T16 G1-G3 | AMD Zen3-Zen5 |
| ThinkPad P14s G1-G6 | AMD Zen2-Zen5 |
| ThinkPad P15v G1-G3 | AMD Zen3 |
| ThinkPad L14 / L15 G1-G4 | AMD Zen2-Zen5 |

Community-confirmed

| Model | CPU Generation |
|-------|---------------|
| ThinkPad E14 G6 | AMD Zen3 (7030 series) |

Have a model that isn't listed or isn't confirmed? Reports welcome, open an issue.

---

## Variants

### lowakernel-universal
Built with `-march=x86-64-v3`, works on all AMD Zen1+ ThinkPads (T495 and newer). 300 Hz tick rate, same as stock zen. The safe choice if you're not sure which one to pick.

### lowakernel-zen5
Built with `-march=znver5`, for Zen5 (Ryzen AI 300 series) only. On top of universal:
- 1000 Hz tick rate for lower latency
- BBRv3 TCP congestion control by default
- NTSYNC built in, so it's always there for Wine/Proton without any extra setup

Recommended for: ThinkPad T14 G5-G6, T14s G5-G6, T16 G3, P14s G5-G6.

### lowadetcom
My personal build, made for exactly one machine: **ThinkPad P14s Gen 6 AMD** (Ryzen AI 7 PRO 350, Radeon 860M). Same as zen5, plus:
- only the MediaTek MT7925 WiFi driver, every other WiFi driver is gone
- amdgpu built into the kernel instead of being a module
- no touchscreen or pen drivers

Don't use it on anything else. Arch only (see below why).

---

## Installation

Grab the files for your variant from the [Releases](https://github.com/Detcom-GH/lowakernel/releases) page:

- `vmlinuz-lowakernel-universal` (the kernel)
- `modules-lowakernel-universal.tar.zst` (the drivers, WiFi, sound and so on live here)

The examples below use universal. For zen5 just swap `universal` for `zen5` everywhere.

Releases don't have a ready `.efi` (UKI) file anymore. A UKI has the kernel command line baked in, including the root partition, so a prebuilt one only boots on the machine it was built on. You build your own in one command instead, see below.

### Step 1: modules (everyone)

```bash
sudo tar -C /lib/modules -xaf modules-lowakernel-universal.tar.zst
ls /lib/modules | grep lowakernel
```

The second command shows the exact kernel version, something like `7.2.9-lowakernel-universal`. Some steps below need it, they call it `KERNEL_VERSION`.

On Debian, Ubuntu and friends you need `zstd` installed for this (`sudo apt install zstd`).

### Step 2: your distro

#### Arch (and Arch-based)

Copy the kernel:

```bash
sudo cp vmlinuz-lowakernel-universal /boot/
```

Create a mkinitcpio preset, so the initramfs (or UKI) gets rebuilt automatically when microcode or firmware updates. Make the file `/etc/mkinitcpio.d/lowakernel-universal.preset` with your editor (`sudo nano ...`) and put this in it.

If you boot UKIs with systemd-boot:

```
ALL_kver="/boot/vmlinuz-lowakernel-universal"
PRESETS=('default')
default_uki="/boot/EFI/Linux/lowakernel-universal.efi"
```

For everything else (GRUB, rEFInd, Limine, systemd-boot without UKI):

```
ALL_kver="/boot/vmlinuz-lowakernel-universal"
PRESETS=('default')
default_image="/boot/initramfs-lowakernel-universal.img"
```

Then build it:

```bash
sudo mkinitcpio -p lowakernel-universal
```

The UKI version uses your `/etc/kernel/cmdline`, which you already have if you boot UKIs. Now the bootloader:

**systemd-boot with UKI:** nothing else to do, it shows up in the menu by itself.

**systemd-boot without UKI:** create `/boot/loader/entries/lowakernel-universal.conf`. Easiest is to copy the `options` line from one of the files already in that folder:

```
title   lowakernel universal
linux   /vmlinuz-lowakernel-universal
initrd  /initramfs-lowakernel-universal.img
options root=UUID=YOUR_UUID rw quiet
```

**GRUB:** it finds the new kernel by itself:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

**rEFInd:** add a line to `/boot/refind_linux.conf`:

```
"lowakernel-universal" "root=UUID=YOUR_UUID rw quiet initrd=/boot/initramfs-lowakernel-universal.img"
```

**Limine:** add an entry to your `limine.conf` (this assumes `/boot` is your EFI partition, the usual Arch setup):

```
/lowakernel-universal
    protocol: linux
    path: boot():/vmlinuz-lowakernel-universal
    module_path: boot():/initramfs-lowakernel-universal.img
    cmdline: root=UUID=YOUR_UUID rw quiet
```

Find `YOUR_UUID` with `blkid`, it's the UUID of your root partition.

#### Fedora (GRUB or systemd-boot)

Fedora's own tool does everything at once: copies the kernel, builds the initramfs with dracut and adds the boot entry.

```bash
sudo kernel-install add KERNEL_VERSION vmlinuz-lowakernel-universal
```

Fedora has Secure Boot on by default, so check the Secure Boot section below.

#### Debian, Ubuntu, Zorin, Mint (GRUB)

```bash
sudo cp vmlinuz-lowakernel-universal /boot/vmlinuz-KERNEL_VERSION
sudo update-initramfs -c -k KERNEL_VERSION
sudo update-grub
```

The kernel has to be named `vmlinuz-KERNEL_VERSION` here, that's how GRUB pairs it with the initramfs.

#### lowadetcom

Arch only, because amdgpu is built into this one, so the GPU firmware has to go into the initramfs or you get a black screen. The release has `mkinitcpio-lowadetcom.conf` for that. Do everything like in the Arch section, with two differences:

```bash
sudo cp mkinitcpio-lowadetcom.conf /etc/
```

and add this line to the preset:

```
ALL_config="/etc/mkinitcpio-lowadetcom.conf"
```

---

## Secure Boot

lowakernel isn't signed with a distro key, so it won't boot with Secure Boot on out of the box. Two options:

**Option 1: turn Secure Boot off** in your BIOS/UEFI settings. Simplest.

**Option 2: sign it with your own key (MOK)** and keep Secure Boot on.

Install sbsigntools:

```bash
# Arch (-based)
sudo pacman -S sbsigntools

# Fedora (-based)
sudo dnf install sbsigntools

# Debian (-based)
sudo apt install sbsigntool
```

Make a key once and enroll it:

```bash
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.key -out MOK.crt \
  -days 3650 -subj "/CN=lowakernel MOK/" -nodes
sudo mokutil --import MOK.crt
```

Then sign whatever you boot. The UKI if you use one:

```bash
sudo sbsign --key MOK.key --cert MOK.crt \
  --output /boot/EFI/Linux/lowakernel-universal.efi \
  /boot/EFI/Linux/lowakernel-universal.efi
```

Or the kernel itself if you don't (use the path where your kernel ended up):

```bash
sudo sbsign --key MOK.key --cert MOK.crt \
  --output /boot/vmlinuz-lowakernel-universal \
  /boot/vmlinuz-lowakernel-universal
```

Reboot, follow the MOK prompt, done. Keep in mind a UKI gets rebuilt when microcode updates, and then it has to be signed again. If you want that automatic, look at `sbctl`.

---

## Uninstall

**Arch:**

```bash
sudo rm /etc/mkinitcpio.d/lowakernel-universal.preset
sudo rm /boot/vmlinuz-lowakernel-universal
sudo rm -f /boot/EFI/Linux/lowakernel-universal.efi /boot/initramfs-lowakernel-universal.img
sudo rm -rf /lib/modules/*-lowakernel-universal
```

Then remove the boot entry you added (if any) and for GRUB run `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

**Fedora:**

```bash
sudo kernel-install remove KERNEL_VERSION
sudo rm -rf /lib/modules/KERNEL_VERSION
```

**Debian / Ubuntu:**

```bash
sudo update-initramfs -d -k KERNEL_VERSION
sudo rm /boot/vmlinuz-KERNEL_VERSION
sudo rm -rf /lib/modules/KERNEL_VERSION
sudo update-grub
```

---

## License

GPL-2.0, same as the Linux kernel.

lowakernel is built on top of [zen-kernel](https://github.com/zen-kernel/zen-kernel), which itself tracks upstream [Linux](https://kernel.org/).

This project doesn't patch the kernel source, it's a build script that applies config options on top of zen-kernel's source tree.
