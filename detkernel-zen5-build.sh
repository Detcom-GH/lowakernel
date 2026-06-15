#!/usr/bin/env bash
# detkernel-zen5 build script
# for ryzen ai 300 thinkpads only (t14 g5-g6, t16 g3, p14s g5-g6)
# dont run this on older hardware, use universal instead
# extras over universal: znver5, 500hz tick, bbrv3, ntsync

set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_NAME="detkernel-zen5"
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

  local branch
  if [[ -n "$KERNEL_VERSION" ]]; then
    branch=$(git tag --sort=-version:refname \
      | grep "^v${KERNEL_VERSION}" | grep "\-zen" | head -1)
    [[ -z "$branch" ]] && error "Tag for $KERNEL_VERSION not found in local repo"
  else
    branch=$(git tag --sort=-version:refname \
      | grep "^v[0-9]" | grep "\-zen[0-9]" | grep -v "rc\|test" | head -1)
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

  if [[ -f /proc/config.gz ]]; then
    info "Base: /proc/config.gz (current kernel)"
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

  # 500hz - better than 300hz zen default, not as crazy as xanmod 1000hz
  # sweet spot for a laptop imo
  scripts/config --disable HZ_100
  scripts/config --disable HZ_250
  scripts/config --disable HZ_300
  scripts/config --enable  HZ_500
  scripts/config --set-val HZ 500

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

  # amdgpu as module! not builtin, breaks renderD128 on boot
  scripts/config --module  DRM_AMDGPU
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
  scripts/config --set-str DEFAULT_TCP_CONG bbr

  # ntsync - makes wine/proton games less stuttery
  scripts/config --enable  NTSYNC

  # intel wifi for older thinkpads
  scripts/config --enable  IWLWIFI
  scripts/config --enable  IWLMVM
  scripts/config --disable IWLDVM
  scripts/config --disable IWLWIFI_DEBUG

  # qualcomm for the newer ones
  scripts/config --enable  ATH11K
  scripts/config --enable  ATH11K_PCI
  scripts/config --disable ATH11K_DEBUG
  scripts/config --enable  ATH12K
  scripts/config --enable  ATH12K_PCI

  # mediatek, L series and newer T14
  scripts/config --enable  MT76_CORE
  scripts/config --enable  MT76_CONNAC_LIB
  scripts/config --enable  MT7921_COMMON
  scripts/config --enable  MT7921E
  scripts/config --enable  MT7925_COMMON
  scripts/config --enable  MT7925E

  # realtek wifi in some L14/L15
  scripts/config --enable  RTW89
  scripts/config --enable  RTW89_8852AE
  scripts/config --enable  RTW89_PCI

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
  [[ "$amdgpu_val" == "m" ]] \
    && success "DRM_AMDGPU=m" \
    || error "DRM_AMDGPU=${amdgpu_val} after olddefconfig (expected m)"

  local hz_val
  hz_val=$(scripts/config -s HZ 2>/dev/null || echo "?")
  [[ "$hz_val" == "500" ]] \
    && success "HZ=500" \
    || warn "HZ=${hz_val} (expected 500)"

  local bbr_val
  bbr_val=$(scripts/config -s TCP_CONG_BBR 2>/dev/null || echo "?")
  [[ "$bbr_val" == "y" ]] \
    && success "BBRv3: on (default)" \
    || warn "TCP_CONG_BBR=${bbr_val}"

  local ntsync_val
  ntsync_val=$(scripts/config -s NTSYNC 2>/dev/null || echo "?")
  [[ "$ntsync_val" == "y" || "$ntsync_val" == "m" ]] \
    && success "NTSYNC: on" \
    || warn "NTSYNC=${ntsync_val}"

  local dbg_val
  dbg_val=$(scripts/config -s DEBUG_INFO_NONE 2>/dev/null || echo "?")
  [[ "$dbg_val" == "y" ]] \
    && success "DEBUG_INFO_NONE=y" \
    || warn "DEBUG_INFO_NONE=${dbg_val} — modules may be bloated"

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
       2>&1 | tee "$BUILD_DIR/build-zen5.log"

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

  local mkinitcpio_conf="/etc/mkinitcpio.conf"
  if [[ -f "$mkinitcpio_conf" ]]; then
    if ! grep -qE "^HOOKS=.*\bkms\b" "$mkinitcpio_conf"; then
      warn "kms hook missing — adding before 'block'"
      sudo sed -i 's/\(HOOKS=(.*\)\(block\)/\1kms \2/' "$mkinitcpio_conf"
    fi
    if grep -qE "^MODULES=.*\bamdgpu\b" "$mkinitcpio_conf"; then
      warn "Removing manual amdgpu from MODULES (kms hook handles it)"
      sudo sed -i 's/\bamdgpu[[:space:]]*//' "$mkinitcpio_conf"
    fi
  fi

  local fw_dropin="/etc/mkinitcpio.conf.d/detkernel-amdgpu-fw.conf"
  if find "/lib/modules/${kver}" -name "amdgpu.ko*" -quit 2>/dev/null; then
    sudo rm -f "$fw_dropin"
    success "amdgpu: module (=m) — no firmware drop-in needed"
  else
    warn "amdgpu is built-in (=y) — creating firmware drop-in for initramfs"
    local fw_list
    fw_list=$(find /lib/firmware/amdgpu/ \( -name "*.bin" -o -name "*.bin.zst" \) \
              2>/dev/null | sort | sed 's/^/  /')
    sudo mkdir -p /etc/mkinitcpio.conf.d
    printf 'FILES=(\n%s\n)\n' "$fw_list" | sudo tee "$fw_dropin" > /dev/null
    warn "Created: ${fw_dropin} (temporary — fix DRM_AMDGPU=m and rebuild)"
  fi

  sudo tee "/etc/mkinitcpio.d/${KERNEL_NAME}.preset" > /dev/null <<EOF
ALL_kver="/boot/vmlinuz-${kver}"

PRESETS=('default')

default_uki="/boot/EFI/Linux/${KERNEL_NAME}.efi"
EOF

  info "Generating UKI..."
  sudo mkinitcpio -p "${KERNEL_NAME}"

  local efi_type
  efi_type=$(file "/boot/EFI/Linux/${KERNEL_NAME}.efi" 2>/dev/null)
  if echo "$efi_type" | grep -q "PE32+"; then
    success "UKI: /boot/EFI/Linux/${KERNEL_NAME}.efi (PE32+ EFI)"
  else
    error "Not a PE32+ EFI file: ${efi_type}"
  fi
}

# ---------------------------------------------------------------
main() {
  echo -e "\n${BOLD}${CYAN}╔════════════════════════════════════════════════════╗"
  echo -e "║  detkernel-zen5 — AMD ThinkPad Kernel Builder      ║"
  echo -e "║  Target: AMD ThinkPads with Zen5 CPU only, znver5  ║"
  echo -e "║  T14 G5-G6 · T14s G5-G6 · T16 G3 · P14s G5-G6    ║"
  echo -e "║  Ryzen AI 300 series only                          ║"
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
  success "detkernel-zen5 installed!"
  echo -e "  UKI:  /boot/EFI/Linux/${KERNEL_NAME}.efi"
  echo -e "  Log:  $BUILD_DIR/build-zen5.log"
  echo -e "  ${CYAN}Reboot and select detkernel-zen5${NC}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════${NC}"
}

main "$@"
