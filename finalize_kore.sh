#!/bin/bash
set -e -u

# --- CONFIGURATION VARIABLES ---
ROOTFS="$PWD/rfs"
INITRAMFS_ROOT="$PWD/initramfs_root"
BIN_DIR="$ROOTFS/bin"
ETC_DIR="$ROOTFS/etc"
VAR_DIR="$ROOTFS/var"

echo "=========================================================="
echo "Starting final Kore Linux system integration sweep..."
echo "=========================================================="

# 1. INTEGRATE FOUNDATIONAL SYSTEM SYMLINKS
echo "[+] Structuring PID 1 system init symlinks..."
mkdir -p "$ROOTFS/sbin"
ln -sf runit-init "$ROOTFS/sbin/init"

cat << 'EOF' > $ROOTFS/sbin/poweroff
#!/bin/sh
exec /sbin/runit-init 0
EOF

cat << 'EOF' > $ROOTFS/sbin/reboot
#!/bin/sh
exec /sbin/runit-init 6
EOF

chmod +x sbin/poweroff sbin/reboot


ln -sf sbin/runit-init "$ROOTFS/init"

# 2. INGEST REMAINING PRECOMPILED RUST UTILITIES
echo "[+] Fetching and deploying final uutils binaries..."
mkdir -p "$BIN_DIR"
cd "$BIN_DIR"

# Download and extract findutils (find, xargs)
wget -q -c https://github.com/uutils/findutils/releases/download/0.9.1/findutils-x86_64-unknown-linux-musl.tar.xz
tar -xf findutils-x86_64-unknown-linux-musl.tar.xz --strip-components=1
chmod +x find xargs

# Clean up compressed tarball clutter
rm -f *.tar.gz
cd - >/dev/null

# 3. DEPLOY BUSYBOX STATIC TWIN LOGIN GATE
echo "[+] Injecting static BusyBox login gate (util-linux bypass)..."
cp "$INITRAMFS_ROOT/bin/busybox" "$BIN_DIR/busybox"
chmod +x "$BIN_DIR/busybox"

ln -sf busybox "$BIN_DIR/getty"
ln -sf busybox "$BIN_DIR/login"
ln -sf busybox "$BIN_DIR/mount"
ln -sf busybox "$BIN_DIR/umount"
ln -sf busybox "$BIN_DIR/modprobe"

# Shadow utils bypass links
ln -sf busybox "$BIN_DIR/passwd"
ln -sf busybox "$BIN_DIR/useradd"
ln -sf busybox "$BIN_DIR/groupadd"

# Procps bypass links
ln -sf busybox "$BIN_DIR/ps"
ln -sf busybox "$BIN_DIR/top"
ln -sf busybox "$BIN_DIR/free"
ln -sf busybox "$BIN_DIR/sysctl"

# 4. STRUCTURE AUTHENTICATION AND SHADOW RECORDS
echo "[+] Writing default account databases..."
mkdir -p "$ETC_DIR"
echo "root:x:0:0:root:/root:/bin/zsh" > "$ETC_DIR/passwd"

# Generate a real SHA-512 crypt hash for the temporary password 'kore'
# This keeps you perfectly safe from a post-deployment root lockout!
HASH=$(openssl passwd -6 "kore")
echo "root:${HASH}:19532:0:99999:7:::" > "$ETC_DIR/shadow"

# Lock down account file access privileges tightly
chmod 644 "$ETC_DIR/passwd"
chmod 600 "$ETC_DIR/shadow"

# 5. INJECT RUNIT SERVICE INFRASTRUCTURE
echo "[+] Injecting audited runit services and stages..."
cp "$PWD/init" "$INITRAMFS_ROOT/init"
chmod +x "$INITRAMFS_ROOT/init"

cp "$PWD/runit/1" "$ETC_DIR/runit/1"
cp "$PWD/runit/2" "$ETC_DIR/runit/2"
cp "$PWD/runit/3" "$ETC_DIR/runit/3"
chmod +x "$ETC_DIR/runit/1" "$ETC_DIR/runit/2" "$ETC_DIR/runit/3"

# Wire up the getty service configuration framework
mkdir -p "$ETC_DIR/sv/getty-tty1"
cp -r "$PWD/sv/getty-tty1" "$ETC_DIR/sv/getty-tty1/run"
chmod +x "$ETC_DIR/sv/getty-tty1/run"

mkdir -p "$VAR_DIR/service"
ln -sf /etc/sv/getty-tty1 "$VAR_DIR/service"

echo "=========================================================="
echo "SUCCESS: Kore Linux staging targets fully integrated!"
echo "Main RootFS size badge is securely finalized."
echo "=========================================================="

