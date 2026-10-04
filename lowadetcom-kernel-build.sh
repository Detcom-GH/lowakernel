#!/usr/bin/env bash
# lowadetcom kernel build script
# this one is ONLY for my own laptop, dont use it anywhere else lol
# thinkpad p14s gen6, ryzen ai 7 pro 350, radeon 860m (krackan)
# everything hardcoded to my hardware: only mt7925 wifi, only alc257 codec,
# amdgpu built in (=y) with only my gpu firmware, znver5, 1000hz, bbrv3
# if it breaks i just boot one of the other 3 kernels haha

set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_NAME="lowadetcom"
JOBS=$(nproc)
BUILD_DIR="$HOME/kernel-build"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

# ---------------------------------------------------------------
check_deps() {
  info "Checking dependencies..."
  local missing=()
  for dep in git make gcc bc flex bison zstd pahole; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done
  pkg-config --exists libelf 2>/dev/null || missing+=("libelf")

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing: ${missing[*]}"
    if command -v pacman &>/dev/null; then
      sudo pacman -S --needed base-devel bc pahole zstd openssl
    elif command -v apt &>/dev/null; then
      sudo apt install -y build-essential bc dwarves libelf-dev zstd libssl-dev
    elif command -v dnf &>/dev/null; then
      sudo dnf install -y gcc make bc dwarves elfutils-libelf-devel zstd openssl-devel
    else
      error "Install manually: ${missing[*]}"
    fi
  fi
  success "Dependencies OK"
}

# ---------------------------------------------------------------
fetch_source() {
  [[ -d "$BUILD_DIR/linux-zen" ]] || error "linux-zen not found at $BUILD_DIR/linux-zen"
  cd "$BUILD_DIR/linux-zen"

  # grab fresh tags first, otherwise we only ever see what was fetched last time
  # (thats why it kept building 7.2.7 when 7.2.8 was already out lol)
  info "Fetching zen tags..."
  timeout 120 git fetch --tags --quiet 2>/dev/null \
    || warn "git fetch failed, using local tags only"

  # sed -n 1p instead of head -1 on purpose. head quits early, git tag gets
  # SIGPIPE, pipefail + set -e kill the script silently. that was the
  # "dies right after Dependencies OK, works on the 3rd try" mystery
  local branch
  if [[ -n "$KERNEL_VERSION" ]]; then
    branch=$(git tag --sort=-version:refname \
      | grep "^v${KERNEL_VERSION}" | grep "\-zen" | sed -n 1p)
    [[ -z "$branch" ]] && error "Tag for $KERNEL_VERSION not found in local repo"
  else
    branch=$(git tag --sort=-version:refname \
      | grep "^v[0-9]" | grep "\-zen[0-9]" | grep -v "rc\|test" | sed -n 1p)
  fi
  [[ -z "$branch" ]] && error "No zen tags found in local repo"

  info "Tag: ${branch}"
  local current
  current=$(git describe --tags 2>/dev/null || echo "none")
  if [[ "$current" != "$branch" ]]; then
    git checkout Makefile 2>/dev/null || true
    info "Checkout ${branch}..."
    git checkout "$branch"
  fi

  sed -i 's/^EXTRAVERSION.*/EXTRAVERSION =/' Makefile
  success "Source: $(git describe --tags) → EXTRAVERSION cleared"
}

# ---------------------------------------------------------------
apply_config() {
  info "Applying config..."

  local running_kernel
  running_kernel=$(uname -r)
  if [[ "$running_kernel" != *"-zen"* || "$running_kernel" == *"lowakernel"* || "$running_kernel" == *"lowadetcom"* ]]; then
    error "You're running ${running_kernel}. Boot into vanilla linux-zen first, the base config must come from a stock zen kernel, not from an already-stripped one."
  fi

  if [[ -f /proc/config.gz ]]; then
    info "Base: /proc/config.gz (current kernel: ${running_kernel})"
    zcat /proc/config.gz > .config
  else
    error "/proc/config.gz not found. Boot into zen kernel first."
  fi

  scripts/config --set-str LOCALVERSION ""
  scripts/config --disable LOCALVERSION_AUTO

  # efi stub, obviously needed for uki to work
  scripts/config --enable  EFI
  scripts/config --enable  EFI_STUB
  scripts/config --enable  EFI_MIXED
  scripts/config --enable  EFIVAR_FS

  # zstd everywhere, faster than xz and good enough
  scripts/config --enable  KERNEL_ZSTD
  scripts/config --disable KERNEL_GZIP
  scripts/config --disable KERNEL_BZIP2
  scripts/config --disable KERNEL_LZMA
  scripts/config --disable KERNEL_XZ
  scripts/config --disable KERNEL_LZO
  scripts/config --disable KERNEL_LZ4
  scripts/config --enable  MODULE_COMPRESS_ZSTD
  scripts/config --disable MODULE_COMPRESS_XZ
  scripts/config --disable MODULE_COMPRESS_GZIP

  # 1000hz - best responsiveness, worth it when plugged in / on external monitor
  # costs a bit more battery than zen's 300hz default but zen5 handles it fine
  scripts/config --disable HZ_100
  scripts/config --disable HZ_250
  scripts/config --disable HZ_300
  scripts/config --enable  HZ_1000

  # amd stuff, keep all of it
  scripts/config --enable  CPU_SUP_AMD
  scripts/config --enable  MICROCODE_AMD
  scripts/config --enable  X86_MCE_AMD
  scripts/config --enable  X86_AMD_PSTATE
  scripts/config --enable  AMD_PMC
  scripts/config --enable  AMD_IOMMU
  scripts/config --enable  PINCTRL_AMD

  # bye intel
  scripts/config --disable CPU_SUP_INTEL
  scripts/config --disable MICROCODE_INTEL
  scripts/config --disable X86_MCE_INTEL

  # no i915 or xe, we dont have intel gpu
  scripts/config --disable DRM_I915
  scripts/config --disable DRM_I915_GVT
  scripts/config --disable DRM_I915_GVT_KVMGT
  scripts/config --disable DRM_XE

  # no nvidia either
  scripts/config --disable DRM_NOUVEAU

  # amdgpu BUILT IN (=y) this time. usually breaks renderD128 because firmware
  # loads before rootfs is mounted, but we handle that with a firmware drop-in
  # below so the fw is inside the initramfs. risky, if black screen just boot
  # another kernel and set this back to --module
  scripts/config --enable  DRM_AMDGPU
  scripts/config --enable  DRM_AMD_DC
  scripts/config --enable  DRM_AMD_DC_DCN
  scripts/config --enable  DRM_AMD_DC_FP
  scripts/config --enable  HSA_AMD

  # old gpu junk nobody uses anymore
  scripts/config --disable DRM_AST
  scripts/config --disable DRM_MGAG200
  scripts/config --disable DRM_R128
  scripts/config --disable DRM_RADEON
  scripts/config --disable DRM_SAVAGE
  scripts/config --disable DRM_SIS
  scripts/config --disable DRM_TDFX
  scripts/config --disable DRM_VIA
  scripts/config --disable DRM_VOODOO

  # bbrv3 for better wifi latency/throughput
  # its in zen source already, just need to enable and set as default
  scripts/config --enable  TCP_CONG_BBR
  scripts/config --enable  DEFAULT_BBR

  # ntsync - makes wine/proton games less stuttery
  scripts/config --enable  NTSYNC

  # WIFI: my laptop has mediatek mt7925 and nothing else, so thats all we keep.
  # killing intel/qualcomm/realtek wifi that the other variants carry for
  # compatibility with other thinkpads. i dont need them, its my machine.
  scripts/config --disable IWLWIFI
  scripts/config --disable IWLMVM
  scripts/config --disable IWLDVM
  scripts/config --disable ATH11K
  scripts/config --disable ATH11K_PCI
  scripts/config --disable ATH12K
  scripts/config --disable ATH12K_PCI
  scripts/config --disable RTW89
  scripts/config --disable RTW89_8852AE
  scripts/config --disable RTW89_PCI
  scripts/config --disable MT7921_COMMON
  scripts/config --disable MT7921E

  # the one wifi driver i actually use
  scripts/config --enable  MT76_CORE
  scripts/config --enable  MT76_CONNAC_LIB
  scripts/config --enable  MT7925_COMMON
  scripts/config --enable  MT7925E

  # old wifi drivers, none of this runs on thinkpads
  scripts/config --disable BRCMFMAC
  scripts/config --disable BRCMSMAC
  scripts/config --disable RT2800PCI
  scripts/config --disable USB_ZD1201
  scripts/config --disable ZD1211RW
  scripts/config --disable PRISM54
  scripts/config --disable HOSTAP
  scripts/config --disable ATMEL
  scripts/config --disable AIRO
  scripts/config --disable AIRO_CS
  scripts/config --disable PCMCIA_WL3501
  scripts/config --disable RT2400PCI
  scripts/config --disable RT2500PCI
  scripts/config --disable RT2500USB
  scripts/config --disable RT61PCI
  scripts/config --disable RT73USB
  scripts/config --disable RTL8180
  scripts/config --disable RTL8187
  scripts/config --disable ADM8211
  scripts/config --disable LIBERTAS
  scripts/config --disable LIBERTAS_USB
  scripts/config --disable LIBERTAS_CS
  scripts/config --disable IPW2100
  scripts/config --disable IPW2200
  scripts/config --disable HERMES
  scripts/config --disable SPECTRUM_CS
  scripts/config --disable ORINOCO_USB

  # r8169 is in every thinkpad, keep it. rest is garbage
  scripts/config --enable  R8169
  scripts/config --disable TR
  scripts/config --disable FDDI
  scripts/config --disable HIPPI
  scripts/config --disable NET_SB1000
  scripts/config --disable HAMACHI
  scripts/config --disable YELLOWFIN
  scripts/config --disable WINBOND_840
  scripts/config --disable SUNDANCE
  scripts/config --disable TLAN
  scripts/config --disable LANCE
  scripts/config --disable DEPCA
  scripts/config --disable HP100
  scripts/config --disable PCMCIA_PCNET
  scripts/config --disable PCMCIA_SMC91C92
  scripts/config --disable PCMCIA_XIRCOM
  scripts/config --disable NET_VENDOR_XIRCOM
  scripts/config --disable NET_VENDOR_SEEQ
  scripts/config --disable NET_VENDOR_RACAL
  scripts/config --disable NET_VENDOR_NATSEMI
  scripts/config --disable NET_VENDOR_ADAPTEC

  # audio - realtek codec + amd acp + usb audio for external interfaces
  scripts/config --enable  SND_HDA_CODEC_REALTEK
  scripts/config --enable  SND_HDA_CODEC_HDMI
  scripts/config --enable  SND_HDA_INTEL
  scripts/config --enable  SND_USB_AUDIO
  scripts/config --enable  SND_SOC_AMD_ACP
  scripts/config --enable  SND_SOC_AMD_ACP3x
  scripts/config --enable  SND_SOC_AMD_ACP5x
  scripts/config --enable  SND_SOC_AMD_ACP6x
  scripts/config --enable  SND_SOC_AMD_ACP63
  scripts/config --enable  SND_SOC_AMD_ACP70
  scripts/config --enable  SOUNDWIRE_AMD

  # intel audio, not needed
  scripts/config --disable SND_SOC_INTEL_SST_ACPI
  scripts/config --disable SND_SOC_INTEL_USER_FRIENDLY_LONG_NAMES
  scripts/config --disable SND_SOC_INTEL_MACH
  scripts/config --disable SND_SOC_INTEL_AVS
  scripts/config --disable SND_SOC_INTEL_SOF_MACH
  scripts/config --disable SND_SOC_SOF_INTEL_TOPLEVEL
  scripts/config --disable SND_SOC_SOF_INTEL_HIFI2
  scripts/config --disable SND_SOC_SOF_BAYTRAIL
  scripts/config --disable SND_SOC_SOF_BROADWELL
  scripts/config --disable SND_SOC_SOF_IPC3
  scripts/config --disable SND_INTEL_NHLT
  scripts/config --disable SND_INTEL_DSP_CONFIG

  # remove hda codecs we dont have. keeping realtek and hdmi
  scripts/config --disable SND_HDA_CODEC_ANALOG
  scripts/config --disable SND_HDA_CODEC_SIGMATEL
  scripts/config --disable SND_HDA_CODEC_VIA
  scripts/config --disable SND_HDA_CODEC_CONEXANT
  scripts/config --disable SND_HDA_CODEC_CA0110
  scripts/config --disable SND_HDA_CODEC_CA0132
  scripts/config --disable SND_HDA_CODEC_CIRRUS
  scripts/config --disable SND_HDA_CODEC_CS8409
  scripts/config --disable SND_HDA_CODEC_IDT
  scripts/config --disable SND_HDA_CODEC_INTELHDMI
  scripts/config --disable SND_HDA_CODEC_NVHDMI
  scripts/config --disable SND_HDA_CODEC_SI3054

  # specific usb audio drivers we dont need
  # note: snd-usb-audio stays! thats the generic uac2 driver
  scripts/config --disable SND_USB_6FIRE
  scripts/config --disable SND_USB_CAIAQ
  scripts/config --disable SND_USB_HIFACE
  scripts/config --disable SND_USB_UA101
  scripts/config --disable SND_USB_POD
  scripts/config --disable SND_USB_PODHD
  scripts/config --disable SND_USB_TONEPORT
  scripts/config --disable SND_USB_VARIAX
  scripts/config --disable SND_BCD2000

  # random usb stuff that doesnt belong here
  scripts/config --disable USB_ATM
  scripts/config --disable USB_SPEEDTOUCH
  scripts/config --disable USB_CXACRU
  scripts/config --disable USB_UEAGLE_ATM
  scripts/config --disable USB_C67X00
  scripts/config --disable USB_ISP116X_HCD
  scripts/config --disable USB_ISP1362_HCD
  scripts/config --disable USB_SL811_HCD
  scripts/config --disable USB_R8A66597_HCD
  scripts/config --disable USB_HWA_HCD
  scripts/config --disable USB_IMM_CBI
  scripts/config --disable USB_ADUTUX
  scripts/config --disable USB_APPLEDISPLAY
  scripts/config --disable USB_IOWARRIOR
  scripts/config --disable USB_ISIGHT_FW
  scripts/config --disable USB_LEGOUSBTOWER
  scripts/config --disable USB_TRANCEVIBRATOR
  scripts/config --disable USB_IDMOUSE
  scripts/config --disable USB_CHAOSKEY

  # server raid controllers lol
  scripts/config --disable SCSI_AACRAID
  scripts/config --disable SCSI_AIC7XXX
  scripts/config --disable SCSI_AIC79XX
  scripts/config --disable SCSI_AIC94XX
  scripts/config --disable SCSI_ADVANSYS
  scripts/config --disable SCSI_ARCMSR
  scripts/config --disable SCSI_BUSLOGIC
  scripts/config --disable SCSI_ESAS2R
  scripts/config --disable SCSI_MPT3SAS
  scripts/config --disable SCSI_MPI3MR
  scripts/config --disable SCSI_MEGARAID
  scripts/config --disable SCSI_MEGARAID_SAS
  scripts/config --disable SCSI_HPSA
  scripts/config --disable SCSI_HPTIOP
  scripts/config --disable SCSI_SMARTPQI
  scripts/config --disable SCSI_SRP
  scripts/config --disable SCSI_MVSAS
  scripts/config --disable SCSI_MVUMI
  scripts/config --disable SCSI_ISCI
  scripts/config --disable SCSI_ISCSI_ATTRS
  scripts/config --disable SCSI_LPFC
  scripts/config --disable SCSI_QLA_FC
  scripts/config --disable SCSI_QLA_ISCSI
  scripts/config --disable SCSI_BFA
  scripts/config --disable SCSI_FNIC
  scripts/config --disable SCSI_3W_9XXX
  scripts/config --disable SCSI_3W_SAS
  scripts/config --disable SCSI_STEX
  scripts/config --disable SCSI_PM8001
  scripts/config --disable SCSI_PMCRAID
  scripts/config --disable SCSI_IPS
  scripts/config --disable SCSI_IPR

  # root filesystems built IN (=y), not modules. this is important: initramfs
  # has to mount root before it can load any modules, so if your root fs is a
  # module and it didnt make it into the initramfs, you get dropped to an
  # emergency shell with "cant mount real root". building them in fixes that
  # for good, costs a couple mb. learned this the hard way from a btrfs user lol
  scripts/config --enable  EXT4_FS
  scripts/config --enable  BTRFS_FS
  scripts/config --enable  XFS_FS
  scripts/config --enable  F2FS_FS
  # vfat too since thats the EFI system partition
  scripts/config --enable  VFAT_FS
  scripts/config --enable  FAT_FS

  # nvme built in too. every supported thinkpad boots off nvme, and if the
  # driver is a module that missed the initramfs, the disk is just invisible
  # and you get "device UUID not found". root fs =y doesnt help if theres no disk
  scripts/config --enable  NVME_CORE
  scripts/config --enable  BLK_DEV_NVME

  # old filesystems nobody uses. ext4/xfs/btrfs/f2fs/ntfs3 stay
  scripts/config --disable ADFS_FS
  scripts/config --disable AFFS_FS
  scripts/config --disable HFS_FS
  scripts/config --disable HFSPLUS_FS
  scripts/config --disable BEFS_FS
  scripts/config --disable BFS_FS
  scripts/config --disable EFS_FS
  scripts/config --disable CRAMFS
  scripts/config --disable ROMFS_FS
  scripts/config --disable MINIX_FS
  scripts/config --disable OMFS_FS
  scripts/config --disable HPFS_FS
  scripts/config --disable QNX4FS_FS
  scripts/config --disable QNX6FS_FS
  scripts/config --disable SYSV_FS
  scripts/config --disable UFS_FS
  scripts/config --disable JFFS2_FS
  scripts/config --disable UBIFS_FS
  scripts/config --disable REISERFS_FS
  scripts/config --disable JFS_FS
  scripts/config --disable OCFS2_FS

  # serial joysticks from 1998 or whatever
  scripts/config --disable JOYSTICK_ANALOG
  scripts/config --disable JOYSTICK_A3D
  scripts/config --disable JOYSTICK_ADI
  scripts/config --disable JOYSTICK_COBRA
  scripts/config --disable JOYSTICK_GF2K
  scripts/config --disable JOYSTICK_GRIP
  scripts/config --disable JOYSTICK_GRIP_MP
  scripts/config --disable JOYSTICK_GUILLEMOT
  scripts/config --disable JOYSTICK_INTERACT
  scripts/config --disable JOYSTICK_SIDEWINDER
  scripts/config --disable JOYSTICK_TMDC
  scripts/config --disable JOYSTICK_IFORCE_USB
  scripts/config --disable JOYSTICK_IFORCE_232
  scripts/config --disable JOYSTICK_WARRIOR
  scripts/config --disable JOYSTICK_MAGELLAN
  scripts/config --disable JOYSTICK_SPACEORB
  scripts/config --disable JOYSTICK_SPACEBALL
  scripts/config --disable JOYSTICK_STINGER
  scripts/config --disable JOYSTICK_TWIDJOY
  scripts/config --disable JOYSTICK_ZHENHUA
  scripts/config --disable TABLET_SERIAL_WACOM4
  scripts/config --disable TABLET_ACECAD

  # no touchscreen and no pen on my laptop. the drivers/input/touchscreen pile
  # is all tablet and embedded stuff anyway (goodix, silead etc), and wacom is
  # for the pen. BUT my touchpad (elan, on i2c) goes through hid-multitouch,
  # same driver touchscreens use, so that one stays or the touchpad dies lol
  scripts/config --disable INPUT_TOUCHSCREEN
  scripts/config --disable HID_WACOM
  scripts/config --module  HID_MULTITOUCH
  scripts/config --module  I2C_HID_ACPI
  scripts/config --enable  I2C_DESIGNWARE_PLATFORM

  # xen is for servers not laptops
  scripts/config --disable XEN
  scripts/config --disable XEN_DOM0
  scripts/config --disable XEN_SAVE_RESTORE
  scripts/config --disable XEN_BALLOON
  scripts/config --disable XEN_SCRUB_PAGES
  scripts/config --disable XEN_DEV_EVTCHN
  scripts/config --disable XEN_BACKEND
  scripts/config --disable XEN_NETDEV_FRONTEND
  scripts/config --disable XEN_BLKDEV_FRONTEND
  scripts/config --disable XEN_PCIDEV_FRONTEND
  scripts/config --disable XEN_FBDEV_FRONTEND
  scripts/config --disable XEN_KEYBOARD_FRONTEND
  scripts/config --disable XEN_CONSOLE
  scripts/config --disable XEN_XENBUS_FRONTEND

  # infiniband lmao
  scripts/config --disable INFINIBAND
  scripts/config --disable INFINIBAND_USER_MAD
  scripts/config --disable INFINIBAND_USER_ACCESS
  scripts/config --disable INFINIBAND_ADDR_TRANS

  # isdn, its 2026
  scripts/config --disable ISDN
  scripts/config --disable ISDN_CAPI
  scripts/config --disable PHONE

  # server watchdogs
  scripts/config --disable ITCO_WDT
  scripts/config --disable IBMASR
  scripts/config --disable WDTPCI
  scripts/config --disable I6300ESB_WDT
  scripts/config --disable HP_WATCHDOG
  scripts/config --disable HPWDT
  scripts/config --disable MEI_WDT

  # staging drivers are usually broken anyway
  scripts/config --disable STAGING

  # thinkpad specific stuff, obviously keep
  scripts/config --enable  THINKPAD_ACPI
  scripts/config --enable  HID_LENOVO

  # vendor laptop drivers for stuff we dont have
  for opt in \
    DELL_LAPTOP DELL_WMI DELL_SMO8800 \
    HP_ACCEL HP_WMI \
    ASUS_LAPTOP ASUS_WMI ASUS_NB_WMI \
    ACER_WMI ACERHDF \
    SONY_LAPTOP SONYPI \
    TOSHIBA_ACPI \
    SAMSUNG_LAPTOP \
    MSI_WMI MSI_LAPTOP \
    PANASONIC_LAPTOP \
    LG_LAPTOP \
    GIGABYTE_WMI \
    HUAWEI_WMI \
    APPLE_PROPERTIES APPLE_GMUX \
    SYSTEM76_ACPI; do
    scripts/config --disable "$opt" 2>/dev/null || true
  done

  # hid vendor drivers, not lenovo so bye
  for opt in \
    HID_APPLE HID_ASUS HID_DELL_ACCESSORIES \
    HID_HP HID_SAMSUNG HID_SONY HID_TOSHIBA; do
    scripts/config --disable "$opt" 2>/dev/null || true
  done

  # kvm amd yes, intel no
  scripts/config --enable  KVM_AMD
  scripts/config --disable KVM_INTEL

  # appletalk lol
  scripts/config --disable NET_APPLETALK
  scripts/config --disable X25
  scripts/config --disable LAPB
  scripts/config --disable ATM
  scripts/config --disable NET_FC
  scripts/config --disable AX25
  scripts/config --disable NETROM
  scripts/config --disable ROSE
  scripts/config --disable DECNET
  scripts/config --disable ECONET
  scripts/config --disable WAN

  # debug off, otherwise modules get massive
  scripts/config --enable  DEBUG_INFO_NONE
  scripts/config --disable DEBUG_INFO_DWARF5
  scripts/config --disable DEBUG_INFO_DWARF4
  scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
  scripts/config --disable DEBUG_INFO_BTF
  scripts/config --disable DEBUG_INFO_BTF_MODULES
  scripts/config --disable DEBUG_INFO_COMPRESSED_ZLIB
  scripts/config --disable KASAN
  scripts/config --disable UBSAN
  scripts/config --disable LOCKDEP
  scripts/config --disable FTRACE

  make ARCH=x86_64 LOCALVERSION="-${KERNEL_NAME}" olddefconfig

  # Post-olddefconfig checks
  local efi_stub
  efi_stub=$(scripts/config -s EFI_STUB 2>/dev/null || echo "n")
  [[ "$efi_stub" == "y" ]] && success "EFI_STUB: on" \
    || error "EFI_STUB is off after olddefconfig!"

  local amdgpu_val
  amdgpu_val=$(scripts/config -s DRM_AMDGPU 2>/dev/null || echo "?")
  [[ "$amdgpu_val" == "y" ]] \
    && success "DRM_AMDGPU=y (built in, my firmware goes in initramfs)" \
    || error "DRM_AMDGPU=${amdgpu_val} after olddefconfig (expected y for this build)"

  local hz_val
  hz_val=$(scripts/config -s HZ 2>/dev/null || echo "?")
  [[ "$hz_val" == "1000" ]] \
    && success "HZ=1000" \
    || warn "HZ=${hz_val} (expected 1000)"

  local bbr_val bbr_default_val
  bbr_val=$(scripts/config -s TCP_CONG_BBR 2>/dev/null || echo "?")
  bbr_default_val=$(scripts/config -s DEFAULT_TCP_CONG 2>/dev/null || echo "?")
  [[ "$bbr_val" == "y" && "$bbr_default_val" == "bbr" ]] \
    && success "BBRv3: on and default" \
    || warn "TCP_CONG_BBR=${bbr_val}, DEFAULT_TCP_CONG=${bbr_default_val} (expected y / bbr)"

  local ntsync_val
  ntsync_val=$(scripts/config -s NTSYNC 2>/dev/null || echo "?")
  [[ "$ntsync_val" == "y" || "$ntsync_val" == "m" ]] \
    && success "NTSYNC: on" \
    || warn "NTSYNC=${ntsync_val}"

  local dbg_val
  dbg_val=$(scripts/config -s DEBUG_INFO_NONE 2>/dev/null || echo "?")
  [[ "$dbg_val" == "y" ]] \
    && success "DEBUG_INFO_NONE=y" \
    || warn "DEBUG_INFO_NONE=${dbg_val}, modules may be bloated"

  # make sure root filesystems really ended up built in, not reverted to =m by
  # olddefconfig. if root fs is a module the initramfs might fail to mount root
  local fs_ok=1
  for fs in EXT4_FS BTRFS_FS XFS_FS F2FS_FS NVME_CORE BLK_DEV_NVME; do
    local v
    v=$(scripts/config -s "$fs" 2>/dev/null || echo "?")
    if [[ "$v" != "y" ]]; then
      warn "${fs}=${v} (wanted y, root on this fs could fail to mount)"
      fs_ok=0
    fi
  done
  [[ "$fs_ok" == "1" ]] && success "root filesystems + nvme built in (=y)"

  # touchpad chain: amd i2c controller -> i2c-hid -> hid-multitouch.
  # if any of these got dropped, no touchpad. hard stop, not a warning
  for tp in I2C_DESIGNWARE_PLATFORM I2C_HID_ACPI HID_MULTITOUCH; do
    local tv
    tv=$(scripts/config -s "$tp" 2>/dev/null || echo "?")
    [[ "$tv" == "y" || "$tv" == "m" ]] \
      || error "${tp}=${tv}, touchpad would be dead. fix config before building"
  done
  success "touchpad chain ok (i2c designware, i2c-hid, hid-multitouch)"

  local kver
  kver=$(make LOCALVERSION="-${KERNEL_NAME}" kernelrelease 2>/dev/null)
  success "Building: ${kver}"
}

# ---------------------------------------------------------------
build_kernel() {
  info "Compiling ($JOBS threads)..."

  # znver5 - only for zen5 hardware, gives better perf on ryzen ai 300
  export KCFLAGS="-O2 -pipe -march=znver5 -mtune=znver5"
  export KCPPFLAGS="$KCFLAGS"

  make ARCH=x86_64 \
       LOCALVERSION="-${KERNEL_NAME}" \
       KCFLAGS="$KCFLAGS" \
       KCPPFLAGS="$KCPPFLAGS" \
       -j"$JOBS" \
       2>&1 | tee "$BUILD_DIR/build-lowadetcom.log"

  local release
  release=$(cat include/config/kernel.release)
  [[ "$release" == *"-${KERNEL_NAME}-${KERNEL_NAME}"* ]] && \
    error "Duplicate in kernel.release: ${release}"

  success "Done: ${release}"
}

# ---------------------------------------------------------------
install_kernel() {
  local kver
  kver=$(cat include/config/kernel.release)
  info "Installing ${kver}..."

  sudo cp -v arch/x86_64/boot/bzImage "/boot/vmlinuz-${kver}"
  sudo cp -v System.map               "/boot/System.map-${kver}"
  sudo cp -v .config                  "/boot/config-${kver}"

  sudo make LOCALVERSION="-${KERNEL_NAME}" modules_install
  success "Kernel files installed"

  # don't touch the shared /etc/mkinitcpio.conf, other kernels use it too.
  # make our own copy instead and point this kernel's preset at it.
  local own_conf="/etc/mkinitcpio-${KERNEL_NAME}.conf"
  [[ -f /etc/mkinitcpio.conf ]] || error "/etc/mkinitcpio.conf not found, is mkinitcpio installed? (this script currently targets Arch-based systems for UKI generation)"
  # keep existing copy so manual edits survive rebuilds
  [[ -f "$own_conf" ]] || sudo cp /etc/mkinitcpio.conf "$own_conf"
  if ! grep -qE "^HOOKS=.*\bkms\b" "$own_conf"; then
    warn "kms hook missing, adding before 'block' in ${own_conf}"
    sudo sed -i 's/\(HOOKS=(.*\)\(block\)/\1kms \2/' "$own_conf"
  fi
  if grep -qE "^MODULES=.*\bamdgpu\b" "$own_conf"; then
    warn "Removing manual amdgpu from MODULES (kms hook handles it)"
    sudo sed -i 's/\bamdgpu[[:space:]]*//' "$own_conf"
  fi

  # legacy cleanup: old shared drop-in leaked into every kernel's initramfs
  sudo rm -f /etc/mkinitcpio.conf.d/lowakernel-amdgpu-fw.conf /etc/mkinitcpio.conf.d/detkernel-amdgpu-fw.conf
  if find "/lib/modules/${kver}" -name "amdgpu.ko*" -print -quit 2>/dev/null | grep -q .; then
    # this shouldnt happen in this build, amdgpu is supposed to be =y here
    warn "amdgpu built as a module?? this personal build wants it =y, check config"
  else
    # amdgpu is =y (on purpose here). since the driver loads before rootfs is
    # mounted, its firmware MUST be inside the initramfs or the gpu wont init.
    # my gpu (radeon 860m / krackan) needs these exact families. NOTE vcn is
    # 4_0_5 not 5_0, the ip block version (vcn_v4_0_5 in dmesg) maps to that file.
    # and vpe_6_1, forgot it the first time and got a black screen lol. checked
    # against /sys/kernel/debug/dri/*/amdgpu_firmware_info this time
    info "amdgpu is built-in, adding only my gpu's firmware to ${own_conf}"
    local fw_list
    fw_list=$(cd /lib/firmware && \
      find amdgpu/ \( \
             -name "gc_11_5_*" -o \
             -name "psp_14_0_*" -o \
             -name "sdma_6_1_*" -o \
             -name "vcn_4_0_*" -o \
             -name "vcn_5_0_*" -o \
             -name "vpe_6_1_*" -o \
             -name "umsch_mm_4_0_*" -o \
             -name "dcn_*" -o \
             -name "dmub_*" -o \
             -name "isp_*" \
           \) 2>/dev/null | sort | sed 's|^|  /lib/firmware/|')
    if [[ -z "$fw_list" ]]; then
      error "no matching amdgpu firmware found?? not appending empty FILES, would break boot"
    fi
    # drop the block from the previous build first, otherwise they pile up
    # every rebuild. anything between the markers gets replaced
    sudo sed -i '/^# lowadetcom-fw-begin$/,/^# lowadetcom-fw-end$/d' "$own_conf"
    # also kill any manual FILES+= vpe hotfix line, its in the list now
    sudo sed -i '/^FILES+=(.*vpe_6_1/d' "$own_conf"
    printf '# lowadetcom-fw-begin\nFILES=(\n%s\n)\n# lowadetcom-fw-end\n' "$fw_list" | sudo tee -a "$own_conf" > /dev/null
    success "Added $(echo "$fw_list" | wc -l) firmware files for my GPU"
  fi

  sudo tee "/etc/mkinitcpio.d/${KERNEL_NAME}.preset" > /dev/null <<EOF
ALL_kver="/boot/vmlinuz-${kver}"
ALL_config="${own_conf}"

PRESETS=('default')

default_uki="/boot/EFI/Linux/${KERNEL_NAME}.efi"
EOF

  # without /etc/kernel/cmdline the UKI has no root= and won't boot
  [[ -f /etc/kernel/cmdline ]] || \
    error "/etc/kernel/cmdline missing, UKI would be built without a cmdline. Create it first: echo \"root=UUID=... rw\" | sudo tee /etc/kernel/cmdline"

  grep -qE "^HOOKS=.*\bmicrocode\b" "$own_conf" || \
    warn "microcode hook missing in ${own_conf}, UKI will boot without CPU microcode updates"

  info "Generating UKI..."
  sudo mkinitcpio -p "${KERNEL_NAME}"

  local efi_type
  efi_type=$(file "/boot/EFI/Linux/${KERNEL_NAME}.efi" 2>/dev/null)
  if echo "$efi_type" | grep -q "PE32+"; then
    success "UKI: /boot/EFI/Linux/${KERNEL_NAME}.efi (PE32+ EFI)"
  else
    error "Not a PE32+ EFI file: ${efi_type}"
  fi

  # release prep for other p14s gen6 owners. no prebuilt uki (it would carry
  # MY root partition in the cmdline). instead: vmlinuz, modules, config, and a
  # small mkinitcpio config that adds the gpu firmware. amdgpu is built in here,
  # so without that firmware in the initramfs you get a black screen, ask me how
  # i know lol
  echo ""
  read -rp "  Prepare release files for GitHub? [y/N] " rel_ans
  if [[ "${rel_ans,,}" == "y" ]]; then
    local rel_dir="$HOME/Downloads/release-${kver}"
    info "Preparing release files in ${rel_dir}..."
    mkdir -p "$rel_dir"

    sudo cp "/boot/vmlinuz-${kver}" "${rel_dir}/vmlinuz-${KERNEL_NAME}"
    sudo cp "/boot/config-${kver}" "${rel_dir}/config-${KERNEL_NAME}"
    sudo tar -C /lib/modules --exclude="${kver}/build" --exclude="${kver}/source" \
      -caf "${rel_dir}/modules-${KERNEL_NAME}.tar.zst" "${kver}"

    # firmware list is built on the users machine when mkinitcpio runs, so it
    # works whatever compression their linux-firmware uses
    cat > "${rel_dir}/mkinitcpio-${KERNEL_NAME}.conf" << 'CONF'
# mkinitcpio config for lowadetcom (thinkpad p14s gen6 amd, radeon 860m only)
# amdgpu is built into this kernel, so its firmware must be inside the
# initramfs or the gpu wont start. takes your normal config and adds only the
# krackan gpu firmware on top
source /etc/mkinitcpio.conf
for _fw in /usr/lib/firmware/amdgpu/{gc_11_5_,psp_14_0_,sdma_6_1_,vcn_4_0_,vpe_6_1_,dcn_3_5,umsch_mm_4_0_,isp_4_1_}*; do
  [[ -e "$_fw" ]] && FILES+=("$_fw")
done
unset _fw
CONF

    sudo chown -R "$(id -un):$(id -gn)" "$rel_dir"

    local top
    top=$(tar -tf "${rel_dir}/modules-${KERNEL_NAME}.tar.zst" | sed -n 1p | cut -d/ -f1)
    [[ "$top" == "$kver" ]] \
      || error "modules tarball top folder is '${top}', expected '${kver}'"

    success "Release files ready:"
    ls -lh "$rel_dir"
  fi
}

# ---------------------------------------------------------------
main() {
  echo -e "\n${BOLD}${CYAN}╔════════════════════════════════════════════════════╗"
  echo -e "║  lowadetcom  personal kernel, my laptop only       ║"
  echo -e "║  P14s Gen6 · Ryzen AI 7 PRO 350 · Radeon 860M     ║"
  echo -e "║  mt7925 wifi only · alc257 only · amdgpu=y         ║"
  echo -e "║  znver5 · 1000hz · bbrv3 · dont use this elsewhere ║"
  echo -e "╚════════════════════════════════════════════════════╝${NC}\n"

  [[ -n "$KERNEL_VERSION" ]] && \
    info "Version: $KERNEL_VERSION" || \
    info "Version: autodetect (latest zen tag)"
  echo ""

  check_deps
  fetch_source
  apply_config

  echo ""
  read -rp "  Launch menuconfig? [y/N] " ans
  [[ "${ans,,}" == "y" ]] && make LOCALVERSION="-${KERNEL_NAME}" menuconfig

  build_kernel
  install_kernel

  echo ""
  echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
  success "lowadetcom installed!"
  echo -e "  UKI:  /boot/EFI/Linux/${KERNEL_NAME}.efi"
  echo -e "  Log:  $BUILD_DIR/build-lowadetcom.log"
  echo -e "  ${CYAN}Reboot and select lowadetcom${NC}"
  echo -e "  ${YELLOW}if the screen stays black, amdgpu=y broke it, just boot another kernel${NC}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
}

main "$@"
