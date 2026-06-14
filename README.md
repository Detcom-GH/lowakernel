![detkernel logo](detkernel_logo.png)

# detkernel

A custom Linux kernel built specifically for AMD-powered ThinkPads. Strips everything that doesn't belong — Intel, NVIDIA, legacy drivers, other vendor-specific features, dead protocols, server-only subsystems — leaving a leaner, more responsive kernel tuned for the hardware that's actually in your machine.

Faster boot. Better responsiveness. Slightly better performance. Lower power consumption.

> **Note:** detkernel may work on other AMD-based laptops or desktops, but is only tested and supported on ThinkPads. Use on other hardware at your own risk.

---

## Supported models

| Model | CPU Generation |
|-------|---------------|
| ThinkPad T495 | AMD Zen1 |
| ThinkPad T14 / T14s G1–G6 | AMD Zen2–Zen5 |
| ThinkPad T16 G1–G3 | AMD Zen3–Zen5 |
| ThinkPad P14s G1–G6 | AMD Zen2–Zen5 |
| ThinkPad P15v G1–G3 | AMD Zen3 |
| ThinkPad L14 / L15 G1–G4 | AMD Zen2–Zen5 |

---

## Variants

### detkernel-universal
Built with `-march=x86-64-v3`, compatible with all AMD Zen1+ ThinkPads (T495 and newer). The safe choice if you're unsure which variant to use.
Includes NTSYNC (NT synchronization primitives for Wine/Proton) as a module

### detkernel-zen5
Built with `-march=znver5`, optimized specifically for Zen5 (Ryzen AI 300 series). Includes additional tuning:
- 500 Hz tick rate for lower latency
- BBRv3 TCP congestion control by default
- NTSYNC (NT synchronization primitives for Wine/Proton)

Recommended for: ThinkPad T14 G5–G6, T14s G5–G6, T16 G3, P14s G5–G6.

---

## Installation

Download the release for your bootloader from the [Releases](https://github.com/Detcom-GH/detkernel/releases) page.

### systemd-boot

Copy the `.efi` file to your EFI partition:

```
sudo cp detkernel-universal.efi /boot/EFI/Linux/
```

Reboot and select **detkernel** from the boot menu.

That's it — no additional configuration needed. The `.efi` file is a Unified Kernel Image (UKI) that contains the kernel, initramfs, and microcode in a single file.

### GRUB

Copy the kernel and initramfs to your boot partition:

```
sudo cp vmlinuz-detkernel-universal /boot/
sudo cp initramfs-detkernel-universal.img /boot/
```

Add an entry to `/etc/grub.d/40_custom`:

```
menuentry "detkernel-universal" {
    search --no-floppy --fs-uuid --set=root YOUR_UUID
    linux /boot/vmlinuz-detkernel-universal root=UUID=YOUR_UUID rw quiet
    initrd /boot/initramfs-detkernel-universal.img
}
```

Replace `YOUR_UUID` with your root partition UUID (find it with `blkid`), then update GRUB:

```
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### rEFInd

Copy the kernel and initramfs to your boot partition:

```
sudo cp vmlinuz-detkernel-universal /boot/
sudo cp initramfs-detkernel-universal.img /boot/
```

Add a stanza to `/boot/refind_linux.conf` or create a manual entry in `refind.conf`:

```
"detkernel-universal" "root=UUID=YOUR_UUID rw quiet initrd=/boot/initramfs-detkernel-universal.img"
```

Replace `YOUR_UUID` with your root partition UUID.

---

## Uninstall

### systemd-boot

```
sudo rm /boot/EFI/Linux/detkernel-universal.efi
```

### GRUB / rEFInd

```
sudo rm /boot/vmlinuz-detkernel-universal
sudo rm /boot/initramfs-detkernel-universal.img
```

Remove the boot entry you added, then update your bootloader config.

---

## License

GPL-2.0 — same as the Linux kernel.
