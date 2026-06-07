#!/bin/bash
# 🎯 MT7902 WiFi & Bluetooth Automatic Fix for Linux
# =================================================
# This script automates the process of fixing the MediaTek MT7902 driver
# issues on modern Linux kernels (like 6.19+).
#
# 📖 USER GUIDE:
# 1. Open your terminal in the directory where this script is located.
# 2. Make the script executable:
#    chmod +x fix_my_wifi.sh
# 3. Run the script with sudo:
#    sudo ./fix_my_wifi.sh
#
# 🛠️ WHAT THIS SCRIPT DOES:
# - Installs build dependencies (gcc, make, kernel headers).
# - Compiles the WiFi and Bluetooth drivers for your specific kernel.
# - Installs the drivers into a safe system directory (/lib/modules/mt7902_custom).
# - Sets up a systemd service to ensure WiFi works after every reboot.
#
# ⚠️ PREREQUISITES:
# - An active internet connection (via Ethernet or USB tethering) is required 
#   the first time you run this to download kernel headers.
# =================================================

set -e

# Variables declaration
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KERNEL_MM=$(uname -r | cut -d'.' -f1,2)
REQUESTED_LINUX_DIR="$SCRIPT_DIR/linux-$KERNEL_MM"

select_linux_dir() {
    local requested_dir=$1
    local candidate candidate_version selected_dir

    if [ -n "${MT7902_LINUX_DIR:-}" ]; then
        if [[ "$MT7902_LINUX_DIR" = /* ]]; then
            echo "$MT7902_LINUX_DIR"
        else
            echo "$SCRIPT_DIR/$MT7902_LINUX_DIR"
        fi
        return 0
    fi

    if [ -d "$requested_dir" ]; then
        echo "$requested_dir"
        return 0
    fi

    while IFS= read -r candidate; do
        [ -d "$candidate/drivers/bluetooth" ] || continue
        [ -d "$candidate/drivers/net/wireless/mediatek/mt76" ] || continue

        selected_dir="$candidate"
        candidate_version=${candidate##*/linux-}
        if [ "$(printf '%s\n%s\n' "$KERNEL_MM" "$candidate_version" | sort -V | head -n1)" = "$KERNEL_MM" ]; then
            echo "$candidate"
            return 0
        fi
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name 'linux-[0-9]*' | sort -V)

    [ -n "$selected_dir" ] && echo "$selected_dir"
    return 0
}

LINUX_DIR=$(select_linux_dir "$REQUESTED_LINUX_DIR")
BT_DIR="$LINUX_DIR/drivers/bluetooth"
WIFI_DIR="$LINUX_DIR/drivers/net/wireless/mediatek/mt76" # SIXSEVENNN (cringe)
CUSTOM_MODULE_DIR="/lib/modules/mt7902_custom"
FIRMWARE_DIR="/lib/firmware/mediatek"

# Usage Check: Ensure script is run with sudo
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root (use sudo)."
    echo "Usage: sudo ./fix_my_wifi.sh"
    exit 1
fi

echo "🚀 Starting MT7902 Fix..."

if [ -z "$LINUX_DIR" ] || [ ! -d "$LINUX_DIR" ]; then
    echo "❌ No usable bundled driver source found under $SCRIPT_DIR"
    exit 1
fi

if [ "$LINUX_DIR" != "$REQUESTED_LINUX_DIR" ]; then
    echo "⚠️ Exact driver source not found for kernel $(uname -r): $REQUESTED_LINUX_DIR"
    echo "➡️ Using bundled source instead: $LINUX_DIR"
else
    echo "📁 Using driver source: $LINUX_DIR"
fi

if command -v apt &> /dev/null; then
    apt-get update
    apt-get install -y build-essential linux-headers-$(uname -r) bc clang llvm lld
elif command -v pacman &> /dev/null; then
    pacman -Sy --needed --noconfirm base-devel linux-headers bc clang llvm lld
elif command -v dnf &> /dev/null; then
    dnf install -y @development-tools kernel-devel-$(uname -r) bc clang llvm lld
elif command -v zypper &> /dev/null; then
    zypper install -y -t pattern devel_basis
    zypper install -y kernel-default-devel bc clang llvm lld
elif command -v nix-shell &> /dev/null; then
    nix-shell -p linuxHeaders.$(uname -r) bc clang llvm lld    
else
    echo "⚠️ No supported package manager found (apt, pacman, dnf, zypper, nix-shell)." >&2
    echo "Please install make, gcc/clang, flex, bison, bc and kernel headers manually." >&2
    
fi

# Detect kernel compiler
if grep -qi "clang" /proc/version; then
    echo "🔍 Clang compiled kernel detected. Using Clang for module."
    COMPILER_ARGS=(CC=clang LD=ld.lld)
elif grep -qi "gcc" /proc/version; then
    echo "🔍 GCC compiled kernel detected. Using GCC for module."
    COMPILER_ARGS=(CC=gcc)
else
    COMPILER_ARGS=()
fi

# 1. Install Firmware
echo "📦 Installing MT7902 firmware..."
install -d "$FIRMWARE_DIR"
install -m 644 "$SCRIPT_DIR"/firmware/*.bin "$SCRIPT_DIR"/firmware/*.zst "$FIRMWARE_DIR"/

# 2. Compile WiFi Modules
echo "🛠️ Compiling WiFi modules..."
if [ -d "$WIFI_DIR" ]; then
	cd "$WIFI_DIR"
	make clean
	make "${COMPILER_ARGS[@]}" module_compile
else 
	echo "❌ WiFi driver source not found for this kernel version, stopping..."
	exit 1
fi

# 3. Compile Bluetooth Modules
echo "🛠️ Compiling Bluetooth modules..."
if [ -d "$BT_DIR" ]; then
    cd "$BT_DIR"
    make clean
    make "${COMPILER_ARGS[@]}" module_compile
else
    echo "❌ Bluetooth source not found for this kernel version, stopping..."
    exit 1
fi

# 4. Prepare and Copy Modules
echo "📂 Installing modules..."

install -d "$CUSTOM_MODULE_DIR"
cd "$WIFI_DIR"
install -m 644 mt76.ko mt76-connac-lib.ko mt792x-lib.ko "$CUSTOM_MODULE_DIR"/
install -m 644 mt7921/mt7921-common.ko mt7921/mt7921e.ko "$CUSTOM_MODULE_DIR"/
cd "$BT_DIR"
install -m 644 btmtk.ko btusb.ko "$CUSTOM_MODULE_DIR"/



# 5. Create/Update Setup Script
echo "📝 Configuring startup service..."
cat <<EOF | tee /usr/local/bin/mt7902-setup.sh
#!/bin/bash
set -e

# Unload conflicting modules
rmmod btusb btmtk mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null || true

# Load WiFi stack
modprobe cfg80211
modprobe mac80211

# Load custom MT7902 modules (WiFi)
insmod /lib/modules/mt7902_custom/mt76.ko
insmod /lib/modules/mt7902_custom/mt76-connac-lib.ko
insmod /lib/modules/mt7902_custom/mt792x-lib.ko
insmod /lib/modules/mt7902_custom/mt7921-common.ko
insmod /lib/modules/mt7902_custom/mt7921e.ko


if [ -f /lib/modules/mt7902_custom/btmtk.ko ]; then
    # Load Bluetooth stack
    modprobe bluetooth
    modprobe btrtl
    modprobe btintel
    modprobe btbcm

    # Load custom MT7902 modules (Bluetooth)
    insmod /lib/modules/mt7902_custom/btmtk.ko
    insmod /lib/modules/mt7902_custom/btusb.ko

    systemctl restart bluetooth || true
fi
EOF

chmod +x /usr/local/bin/mt7902-setup.sh

# 6. Create systemd service
cat <<EOF | tee /etc/systemd/system/mt7902.service
[Unit]
Description=Load custom MT7902 Bluetooth and Wi-Fi drivers
After=network-pre.target
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mt7902-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mt7902.service
systemctl restart mt7902.service

echo "✅ MT7902 is now active! Your WiFi should be working."
