#!/bin/bash
set -e -u
# --- CONFIGURATION SETTINGS ---
CHROOT_DIR="$PWD/alpine_chroot"
ALPINE_VERSION="3.24.1" # Standard robust LTS baseline release
MINIROOTFS_TAR="alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"

echo "=========================================================="
echo "Kore Linux Bare-Metal Bootstrap: Deploying Sandbox Environment..."
echo "=========================================================="

# 1. DOWNLOAD THE OFFICIAL ALPINE MINIMAL ROOTFS
if [ ! -f "$MINIROOTFS_TAR" ]; then
  echo "[+] Fetching official Alpine minirootfs archive..."
  wget -c "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/${MINIROOTFS_TAR}"
fi

# 2. SETUP PRISTINE CHROOT SANDBOX ROOT
echo "[+] Structuring throwaway container root workspace..."
sudo rm -rf "$CHROOT_DIR"
mkdir -p "$CHROOT_DIR"
sudo tar -xf "$MINIROOTFS_TAR" -C "$CHROOT_DIR"

# 3. MAP INJECTABLE ASSETS INTO CHROOT /build CONTEXT
echo "[+] Copying Kore Linux configuration blueprints into sandbox..."
sudo mkdir -p "$CHROOT_DIR/build"

# Copy your orchestrated shell scripts and configurations right into the target folder path
sudo cp bootstrap_kore.sh finalize_kore.sh build_kernel.sh "$CHROOT_DIR/build/"
[ -f "kernel.config" ] && sudo cp kernel.config "$CHROOT_DIR/build/"
[ -f ".config" ] && sudo cp .config "$CHROOT_DIR/build/"

# If your pre-transpiled kpm C source code or slimcc folders sit locally, inject them seamlessly
[ -d "kpm_c_src" ] && sudo cp -r kpm_c_src "$CHROOT_DIR/build/"
[ -d "slimcc" ] && sudo cp -r slimcc "$CHROOT_DIR/build/"
[ -f "init" ] && sudo cp -r init "$CHROOT_DIR/build/"
[ -d "runit" ] && sudo cp -r runit "$CHROOT_DIR/build/"
[ -d "sv" ] && sudo cp -r sv "$CHROOT_DIR/build/"

# 4. MOUNT ESSENTIAL VIRTUAL HOST HIGHWAYS
echo "[+] Locking live kernel host pathways into the container..."
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /sys "$CHROOT_DIR/sys"
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
sudo cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf" # Satisfy DNS lookups for wget

# Clean up hook script to run safely if the master compilation hits an error
cleanup() {
  echo "[-] Unmounting container sandboxes lanes..."
  sudo umount -f "$CHROOT_DIR/dev/pts" || true
  sudo umount -f "$CHROOT_DIR/dev" || true
  sudo umount -f "$CHROOT_DIR/sys" || true
  sudo umount -f "$CHROOT_DIR/proc" || true
}
trap cleanup EXIT

# 5. EXECUTE THE COMPLETE 3-STAGE BOOTSTRAP PIPELINE VIA CHROOT HANDOFF
echo "[+] Initializing internal container package dependencies and running build scripts..."
sudo chroot "$CHROOT_DIR" /bin/sh -l -c "
    set -e -x
    # Update container package mirrors and install your verified core tools matrix
    apk update
    # --- UPDATE THIS EXACT LINE INSIDE YOUR run_all.sh WORKSPACE ---
apk add build-base git wget xz tar sed patch cmake bison flex automake autoconf openssl doxygen ncurses-static ncurses-dev util-linux-static util-linux-dev popt-static popt-dev python3 bash device-mapper-static device-mapper-dev linux-headers elfutils-dev openssl-dev

    
    # Enter the core build context and flag script permissions
    cd /build
    chmod +x bootstrap_kore.sh finalize_kore.sh build_kernel.sh
    
    # Trigger the 3-Stage build marathon sequentially!
    ./bootstrap_kore.sh
    ./finalize_kore.sh
    ./build_kernel.sh
"

echo "=========================================================="
echo "MASTER SUCCESS: Your entire Kore Linux build is finished!"
echo "Outputs fully compiled inside: $CHROOT_DIR/build/"
echo "Kernel path: $CHROOT_DIR/build/linux-*/arch/x86/boot/bzImage"
echo "RootFS path: $CHROOT_DIR/build/rfs"
echo "Initramfs path: $CHROOT_DIR/build/initramfs_root"
echo "=========================================================="
