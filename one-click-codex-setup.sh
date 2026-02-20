#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_SIZE="${DISK_SIZE:-256G}"
DMG_PATH="${DMG_PATH:-codex.dmg}"
DMG_URL="${DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
INSTALL_DEPS=0
AUTO_START=1
FORCE_DOWNLOAD=0
SKIP_HW_TUNE=0

need_arg() {
    if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "[!] Missing value for option: $1" >&2
        exit 1
    fi
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dmg <path>] [--dmg-url <url>] [--disk-size <size>] [--install-deps] [--force-download] [--no-start] [--skip-hw-tune]

One-click OSX-KVM prep for Codex.dmg on Linux:
  1) Optionally installs host dependencies (Debian/Ubuntu)
  2) Downloads Codex.dmg automatically if missing
  3) Converts DMG to BaseSystem.img
  4) Creates mac_hdd_ng.img if missing
  5) Detects host CPU/RAM and tunes VM resources
  6) Boots the VM via OpenCore-Boot.sh (unless --no-start)

Defaults:
  DMG file: $DMG_PATH
  DMG URL : $DMG_URL

Examples:
  ./one-click-codex-setup.sh
  ./one-click-codex-setup.sh --force-download --no-start
  ./one-click-codex-setup.sh --dmg /tmp/Codex.dmg --disk-size 300G
USAGE
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[!] Missing required command: $1" >&2
        return 1
    fi
}

download_dmg() {
    local output="$1"
    mkdir -p "$(dirname "$output")"

    if command -v curl >/dev/null 2>&1; then
        echo "[*] Downloading Codex DMG via curl"
        curl -fL --retry 3 --retry-delay 2 -o "$output" "$DMG_URL"
    elif command -v wget >/dev/null 2>&1; then
        echo "[*] Downloading Codex DMG via wget"
        wget -O "$output" "$DMG_URL"
    else
        echo "[!] Need curl or wget to download DMG automatically." >&2
        echo "    Install one of them or pass --dmg /path/to/Codex.dmg" >&2
        exit 1
    fi
}

auto_tune_resources() {
    local host_threads host_mem_mib vm_threads vm_mem_mib vm_cores

    host_threads=$(nproc)
    host_mem_mib=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

    if [[ -z "$host_threads" || "$host_threads" -lt 2 ]]; then
        host_threads=2
    fi
    if [[ -z "$host_mem_mib" || "$host_mem_mib" -lt 4096 ]]; then
        host_mem_mib=4096
    fi

    vm_threads=$(( host_threads / 2 ))
    if [[ $vm_threads -lt 2 ]]; then vm_threads=2; fi
    if [[ $vm_threads -gt 8 ]]; then vm_threads=8; fi

    vm_mem_mib=$(( host_mem_mib / 2 ))
    if [[ $vm_mem_mib -lt 4096 ]]; then vm_mem_mib=4096; fi
    if [[ $vm_mem_mib -gt 16384 ]]; then vm_mem_mib=16384; fi

    vm_cores=$vm_threads
    if [[ $vm_cores -gt 4 ]]; then vm_cores=4; fi

    export ALLOCATED_RAM="${ALLOCATED_RAM:-$vm_mem_mib}"
    export CPU_THREADS="${CPU_THREADS:-$vm_threads}"
    export CPU_CORES="${CPU_CORES:-$vm_cores}"
    export CPU_SOCKETS="${CPU_SOCKETS:-1}"

    echo "[*] Host detected: ${host_threads} threads, ${host_mem_mib} MiB RAM"
    echo "[*] VM tuned to : ${ALLOCATED_RAM} MiB RAM, ${CPU_THREADS} threads, ${CPU_CORES} cores, ${CPU_SOCKETS} socket"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            need_arg "$@"
            DMG_PATH="$2"
            shift 2
            ;;
        --dmg-url)
            need_arg "$@"
            DMG_URL="$2"
            shift 2
            ;;
        --disk-size)
            need_arg "$@"
            DISK_SIZE="$2"
            shift 2
            ;;
        --install-deps)
            INSTALL_DEPS=1
            shift
            ;;
        --force-download)
            FORCE_DOWNLOAD=1
            shift
            ;;
        --skip-hw-tune)
            SKIP_HW_TUNE=1
            shift
            ;;
        --no-start)
            AUTO_START=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! "$DISK_SIZE" =~ ^[1-9][0-9]*[GM]$ ]]; then
    echo "[!] Invalid --disk-size value: $DISK_SIZE (expected values like 128G, 256G, 16384M)" >&2
    exit 1
fi

if [[ $INSTALL_DEPS -eq 1 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
        echo "[*] Installing dependencies with apt-get"
        sudo apt-get update
        sudo apt-get install -y qemu-system uml-utilities virt-manager git \
            wget libguestfs-tools p7zip-full make dmg2img tesseract-ocr \
            tesseract-ocr-eng genisoimage vim net-tools screen qemu-utils curl
    else
        echo "[!] --install-deps is currently supported only on Debian/Ubuntu (apt-get)." >&2
        echo "    Install dependencies manually and rerun without --install-deps." >&2
        exit 1
    fi
fi

require_cmd dmg2img
require_cmd qemu-img

DMG_ABS_PATH="$DMG_PATH"
if [[ "$DMG_ABS_PATH" != /* ]]; then
    DMG_ABS_PATH="$REPO_ROOT/$DMG_ABS_PATH"
fi

if [[ $FORCE_DOWNLOAD -eq 1 || ! -f "$DMG_ABS_PATH" ]]; then
    echo "[*] Local DMG not found or refresh requested: $DMG_ABS_PATH"
    download_dmg "$DMG_ABS_PATH"
fi

if [[ ! -s "$DMG_ABS_PATH" ]]; then
    echo "[!] DMG file is missing or empty: $DMG_ABS_PATH" >&2
    exit 1
fi

echo "[*] Preparing BaseSystem.img from: $DMG_ABS_PATH"
dmg2img -i "$DMG_ABS_PATH" "$REPO_ROOT/BaseSystem.img"

if [[ ! -f "$REPO_ROOT/mac_hdd_ng.img" ]]; then
    echo "[*] Creating mac_hdd_ng.img (${DISK_SIZE})"
    qemu-img create -f qcow2 "$REPO_ROOT/mac_hdd_ng.img" "$DISK_SIZE"
else
    echo "[*] Reusing existing mac_hdd_ng.img"
fi

if [[ $SKIP_HW_TUNE -eq 0 ]]; then
    auto_tune_resources
else
    echo "[*] Hardware auto-tuning skipped (--skip-hw-tune)"
fi

cat <<EOFMSG

[+] Setup complete.

Recommended host tweaks (run once if needed):
    sudo modprobe kvm; echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs

EOFMSG

if [[ $AUTO_START -eq 1 ]]; then
    echo "[*] Starting macOS installer VM"
    exec "$REPO_ROOT/OpenCore-Boot.sh"
fi

echo "[*] Skipped VM start (--no-start). Run ./OpenCore-Boot.sh when ready."
