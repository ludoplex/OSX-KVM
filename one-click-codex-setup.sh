#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_SIZE="${DISK_SIZE:-256G}"
MACOS_SHORTNAME="${MACOS_SHORTNAME:-sonoma}"
CODEX_DMG_PATH="${CODEX_DMG_PATH:-$REPO_ROOT/Codex.dmg}"
CODEX_DMG_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
CODEX_ISO_PATH="${CODEX_ISO_PATH:-$REPO_ROOT/CodexTools.iso}"
INSTALL_DEPS=0
AUTO_START=1
FORCE_CODEX_DOWNLOAD=0
SKIP_HW_TUNE=0
SKIP_CODEX_MEDIA=0

need_arg() {
    if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "[!] Missing value for option: $1" >&2
        exit 1
    fi
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

One-click OSX-KVM setup + Codex app install media preparation:
  1) Optionally installs host dependencies (Debian/Ubuntu)
  2) Fetches macOS recovery installer (BaseSystem.dmg -> BaseSystem.img)
  3) Downloads Codex.dmg and builds CodexTools.iso for in-guest installation
  4) Creates mac_hdd_ng.img if missing
  5) Detects host CPU/RAM and tunes VM resources
  6) Boots the VM with CodexTools.iso attached (unless --no-start)

Options:
  --macos <shortname>      macOS version for fetch-macOS-v2.py (default: $MACOS_SHORTNAME)
  --disk-size <size>       VM disk size, e.g. 256G
  --codex-dmg <path>       local Codex.dmg path (default: $CODEX_DMG_PATH)
  --codex-dmg-url <url>    Codex DMG URL
  --codex-iso <path>       generated ISO path (default: $CODEX_ISO_PATH)
  --force-codex-download   always re-download Codex.dmg
  --skip-codex-media       don't prepare/attach CodexTools.iso
  --install-deps           install dependencies via apt-get
  --skip-hw-tune           disable CPU/RAM auto tuning
  --no-start               prepare only, do not launch VM
  -h, --help               show this help
USAGE
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[!] Missing required command: $1" >&2
        return 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    mkdir -p "$(dirname "$output")"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        echo "[!] Need curl or wget for downloads." >&2
        exit 1
    fi
}

prepare_macos_base() {
    if [[ ! -f "$REPO_ROOT/BaseSystem.dmg" ]]; then
        echo "[*] Fetching macOS base system: $MACOS_SHORTNAME"
        "$REPO_ROOT/fetch-macOS-v2.py" --shortname="$MACOS_SHORTNAME"
    fi

    if [[ ! -s "$REPO_ROOT/BaseSystem.dmg" ]]; then
        echo "[!] BaseSystem.dmg is missing or empty" >&2
        exit 1
    fi

    echo "[*] Converting BaseSystem.dmg -> BaseSystem.img"
    dmg2img -i "$REPO_ROOT/BaseSystem.dmg" "$REPO_ROOT/BaseSystem.img"
}

prepare_codex_media() {
    if [[ $FORCE_CODEX_DOWNLOAD -eq 1 || ! -f "$CODEX_DMG_PATH" ]]; then
        echo "[*] Downloading Codex.dmg"
        download_file "$CODEX_DMG_URL" "$CODEX_DMG_PATH"
    fi

    if [[ ! -s "$CODEX_DMG_PATH" ]]; then
        echo "[!] Codex.dmg is missing or empty: $CODEX_DMG_PATH" >&2
        exit 1
    fi

    local workdir
    workdir="$(mktemp -d)"
    cp "$CODEX_DMG_PATH" "$workdir/Codex.dmg"
    cp "$REPO_ROOT/scripts/install_codex_in_macos.sh" "$workdir/install_codex_in_macos.sh"

    echo "[*] Building CodexTools.iso for in-guest install"
    genisoimage -quiet -J -R -V CodexTools -o "$CODEX_ISO_PATH" "$workdir/Codex.dmg" "$workdir/install_codex_in_macos.sh"
    rm -rf "$workdir"
}

auto_tune_resources() {
    local host_threads host_mem_mib vm_threads vm_mem_mib vm_cores
    host_threads=$(nproc)
    host_mem_mib=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

    (( host_threads < 2 )) && host_threads=2
    (( host_mem_mib < 4096 )) && host_mem_mib=4096

    vm_threads=$(( host_threads / 2 ))
    (( vm_threads < 2 )) && vm_threads=2
    (( vm_threads > 8 )) && vm_threads=8

    vm_mem_mib=$(( host_mem_mib / 2 ))
    (( vm_mem_mib < 4096 )) && vm_mem_mib=4096
    (( vm_mem_mib > 16384 )) && vm_mem_mib=16384

    vm_cores=$vm_threads
    (( vm_cores > 4 )) && vm_cores=4

    export ALLOCATED_RAM="${ALLOCATED_RAM:-$vm_mem_mib}"
    export CPU_THREADS="${CPU_THREADS:-$vm_threads}"
    export CPU_CORES="${CPU_CORES:-$vm_cores}"
    export CPU_SOCKETS="${CPU_SOCKETS:-1}"

    echo "[*] Host detected: ${host_threads} threads, ${host_mem_mib} MiB RAM"
    echo "[*] VM tuned to : ${ALLOCATED_RAM} MiB RAM, ${CPU_THREADS} threads, ${CPU_CORES} cores, ${CPU_SOCKETS} socket"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --macos)
            need_arg "$@"; MACOS_SHORTNAME="$2"; shift 2 ;;
        --disk-size)
            need_arg "$@"; DISK_SIZE="$2"; shift 2 ;;
        --codex-dmg)
            need_arg "$@"; CODEX_DMG_PATH="$2"; shift 2 ;;
        --codex-dmg-url)
            need_arg "$@"; CODEX_DMG_URL="$2"; shift 2 ;;
        --codex-iso)
            need_arg "$@"; CODEX_ISO_PATH="$2"; shift 2 ;;
        --force-codex-download)
            FORCE_CODEX_DOWNLOAD=1; shift ;;
        --skip-codex-media)
            SKIP_CODEX_MEDIA=1; shift ;;
        --install-deps)
            INSTALL_DEPS=1; shift ;;
        --skip-hw-tune)
            SKIP_HW_TUNE=1; shift ;;
        --no-start)
            AUTO_START=0; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [[ ! "$DISK_SIZE" =~ ^[1-9][0-9]*[GM]$ ]]; then
    echo "[!] Invalid --disk-size value: $DISK_SIZE (expected 128G, 256G, 16384M, etc.)" >&2
    exit 1
fi

if [[ $INSTALL_DEPS -eq 1 ]]; then
    require_cmd sudo
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y qemu-system uml-utilities virt-manager git wget \
            libguestfs-tools p7zip-full make dmg2img tesseract-ocr tesseract-ocr-eng \
            genisoimage vim net-tools screen qemu-utils curl
    else
        echo "[!] --install-deps currently supports apt-get hosts only" >&2
        exit 1
    fi
fi

require_cmd dmg2img
require_cmd qemu-img
require_cmd genisoimage
require_cmd "$REPO_ROOT/fetch-macOS-v2.py"

prepare_macos_base

if [[ ! -f "$REPO_ROOT/mac_hdd_ng.img" ]]; then
    echo "[*] Creating mac_hdd_ng.img (${DISK_SIZE})"
    qemu-img create -f qcow2 "$REPO_ROOT/mac_hdd_ng.img" "$DISK_SIZE"
else
    echo "[*] Reusing existing mac_hdd_ng.img"
fi

if [[ $SKIP_CODEX_MEDIA -eq 0 ]]; then
    prepare_codex_media
    export EXTRA_CDROM_IMAGE="$CODEX_ISO_PATH"
else
    echo "[*] Codex media preparation skipped (--skip-codex-media)"
fi

if [[ $SKIP_HW_TUNE -eq 0 ]]; then
    auto_tune_resources
else
    echo "[*] Hardware auto-tuning skipped (--skip-hw-tune)"
fi

cat <<EOFMSG

[+] Setup complete.

Inside macOS installer / desktop:
  1) Open the "CodexTools" media
  2) Run: sh /Volumes/CodexTools/install_codex_in_macos.sh

EOFMSG

if [[ $AUTO_START -eq 1 ]]; then
    exec "$REPO_ROOT/OpenCore-Boot.sh"
fi

echo "[*] Skipped VM start (--no-start). Run ./OpenCore-Boot.sh when ready."
