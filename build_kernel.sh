#!/bin/bash
set -e -u

# --- CONFIGURATION SETTINGS ---
JOBS=16
STAGE1CC="/build/slimcc/slimcc"
INITRAMFS_ROOT="/build/initramfs_root"
KERNEL_VERSION="7.1.1" # Tailor this version string to your target branch!

echo "=========================================================="
echo "Starting Kore Linux SlimCC Kernel Compilation Pipeline..."
echo "=========================================================="

# 1. FETCH THE CLEAN UPSTREAM KERNEL TARBALL
# We pull a stable LTS release branch straight from the Linux Kernel Archives
KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
if [ ! -f "$KERNEL_TAR" ]; then
    echo "[+] Downloading Linux Kernel source archive..."
    wget -c "https://cdn.kernel.org/pub/linux/kernel/v7.x/${KERNEL_TAR}"
fi

# 2. EXTRACT AND ENTER THE BASE SOURCE TREE
echo "[+] Extracting pristine kernel workspace..."
rm -rf "linux-${KERNEL_VERSION}"
tar -xf "$KERNEL_TAR"
cd "linux-${KERNEL_VERSION}"

# 3. DEPLOY YOUR VERIFIED HARDWARE HARDWARE BASELINE CONFIGURATION
echo "[+] Injecting your hardware .config file..."
if [ -f "../kernel.config" ]; then
    cp ../kernel.config .config
elif [ -f "../.config" ]; then
    cp ../.config .config
else
    echo "[-] ERROR: Missing hardware .config template file inside /build context!"
    exit 1
fi

# 4. programmatic ENFORCEMENT OF DETECTED INTRAMFS SETTINGS
# This explicitly rewrites your config variables to force the build engine 
# to ingest your updated static BusyBox + Cryptsetup layout during compile time!
echo "[+] Merging embedded initramfs source tree configurations..."
sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE="'"${INITRAMFS_ROOT}"'"|g' .config
sed -i 's|^# CONFIG_INITRAMFS_SOURCE is not set||g' .config

# Prepare and synchronize the configuration layout schemas
make oldconfig

# 5. EXECUTE THE MULTI-THREADED SLIMCC BUILD RUN
echo "[+] Starting 16-thread compilation pass via slimcc..."
# We pass CC explicitly to force every compilation pass through your C23 toolchain
CC="${STAGE1CC}" make -j"${JOBS}"

echo "=========================================================="
echo "SUCCESS: Your monolithic slimcc kernel bzImage is ready!"
echo "Target: arch/x86/boot/bzImage"
echo "=========================================================="

