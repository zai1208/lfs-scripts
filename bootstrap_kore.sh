#!/bin/bash
set -e -u

# --- KORE LINUX BOOTSTRAP CONFIGURATION ---
JOBS=16
ROOTFS=$PWD/rfs
INITRAMFS_ROOT=$PWD/initramfs_root
STAGE1CC=$PWD/slimcc/slimcc

export PKG_CONFIG=false

# --- DIRECTORY STRUCTURE INITIALISATION ---
# Prepare the core OS trees for both runtime and the initramfs workspace
mkdir -p "$ROOTFS"/{bin,lib,usr/include,usr/share,var/lib/kpm,etc/runit}
mkdir -p "$INITRAMFS_ROOT"/{bin,sbin,lib,etc,proc,sys,dev,mnt,root}

# --- HELPERS AND NETWORKING FUNCTIONS ---
wget_timeout_noretry() {
  wget -c -T30 -t2 "$@"
}

wget_loop() {
  local URL="$1"
  while ! wget_timeout_noretry "$URL" -O "$2"; do
    URL=$(echo "$URL" | sed -e 's|mirrors.edge.kernel.org|ftp.gnu.org|g')
    URL=$(echo "$URL" | sed -e 's|ftpmirror.gnu.org|mirrors.edge.kernel.org|g')
  done
}

get_src() {
  mkdir -p "$2"
  local F="$2".tar.gz
  if [ ! -f "$F" ]; then
    wget_loop "$1" "$F"
  fi
  tar -xf "$F" -C "$2" --strip-components=1
}

fix_configure() {
  find . -name 'configure' -exec sed -i 's/^\s*lt_prog_compiler_wl=$/lt_prog_compiler_wl=-Wl,/g' {} +
  find . -name 'configure' -exec sed -i 's/^\s*lt_prog_compiler_pic=$/lt_prog_compiler_pic=-fPIC/g' {} +
  find . -name 'configure' -exec sed -i 's/^\s*lt_prog_compiler_static=$/lt_prog_compiler_static=-static/g' {} +
}

configure_gnu_static() {
  fix_configure
  CC="$STAGE1CC" sh ./configure LDFLAGS=--static --disable-shared --build=x86_64-linux-musl --disable-nls "$@"
}

# --- CORE TOOLCHAIN STAGES ---

build_bootstrap_cc() {
  (
    cd slimcc
    mkdir -p "$ROOTFS"/lib/slimcc/
    cp -r ./slimcc_headers/include "$ROOTFS"/lib/slimcc/
    sed 's|ROOT_DIR|'\"$ROOTFS\"'|g' platform/linux-musl-bootstrap.c > platform.c
    make
  )
}

build_musl() {
get_src https://musl.libc.org/releases/musl-1.2.6.tar.gz musl_src
  (
    cd musl_src
    rm -rf src/complex/ include/complex.h
    CC="$STAGE1CC" AR=ar RANLIB=ranlib sh ./configure --target=x86_64-linux-musl --prefix="$ROOTFS" --includedir="$ROOTFS"/usr/include --syslibdir="$ROOTFS"/lib
    make -j"$JOBS"
    make install
    ln -sf "$ROOTFS"/lib/libc.so "$ROOTFS"/lib/ld-musl-x86_64.so.1
  )
}

build_linux_headers() {
get_src https://github.com/sabotage-linux/kernel-headers/archive/refs/tags/v4.19.88-2.tar.gz kernel_hdr_src
  (
    cd kernel_hdr_src
    make ARCH=x86_64 prefix= DESTDIR="$ROOTFS"/usr install
  )
}

build_binutils() {
get_src https://ftpmirror.gnu.org/gnu/binutils/binutils-2.46.1.tar.gz binutils_src
  (
    cd binutils_src
    sed -i 's|^# define __attribute__(x)$||g' include/ansidecl.h
    configure_gnu_static --without-zstd --prefix="$ROOTFS" --includedir="$ROOTFS"/usr/include
    make -j"$JOBS"
    make install
  )
}

build_cc() {
  (
    cd slimcc
    sed 's|ROOT_DIR|'\"\"'|g' platform/linux-musl-bootstrap.c > platform.c
    "$STAGE1CC" scripts/amalgamation.c -static -o "$ROOTFS"/bin/cc
    ln -sf cc "$ROOTFS"/bin/gcc
  )
}

build_bash() {
get_src https://ftpmirror.gnu.org/gnu/bash/bash-5.3.tar.gz bash_src
(
 cd bash_src
 configure_gnu_static --enable-static-link --disable-readline --without-bash-malloc
 make $JOBS
 cp ./bash "$ROOTFS"/bin/
)
}

build_gmake() {
get_src https://ftpmirror.gnu.org/gnu/make/make-4.4.1.tar.gz gmake_src
  (
    cd gmake_src
    configure_gnu_static MAKEINFO=true --prefix="$ROOTFS"
    make -j"$JOBS" install
  )
}

# --- KORE LINUX DISTRO ENGINE (NIM TO C) ---

# build_kpm() {
# (
#   cd kpm_c_src
#   NIM_HEADERS="/usr/lib/nim" 
#
#   # 1. Neutralize musl's '__inline' redefine within the local staging folder 
#   # We copy musl's features.h locally and strip out the conflicting macro line
#   mkdir -p ./usr/include
#   cp "$ROOTFS"/usr/include/features.h ./usr/include/features.h
#   sed -i 's|#define __inline inline||g' ./usr/include/features.h
#
#   # 2. Force the primary entry module to load first
#   echo '#include "@mkpm.nim.c"' > kpm_amalgamation.c
#
#   # 3. Append the remaining C modules
#   for file in *.c; do
#     if [ "$file" != "kpm_amalgamation.c" ] && [ "$file" != "@mkpm.nim.c" ]; then
#       echo "#include \"$file\"" >> kpm_amalgamation.c
#     fi
#   done
#
#   # 4. Compile cleanly by giving priority to our local include directory override path
#   # We use -I. to force slimcc to read our modified features.h first!
#   "$STAGE1CC" -static -O2 \
#     -fms-anon-struct \
#     -fdisable-visibility \
#     -ffake-always-inline \
#     -I. -I"$NIM_HEADERS" -I"$ROOTFS"/usr/include kpm_amalgamation.c -o "$ROOTFS"/bin/kpm
#
#   chmod +x "$ROOTFS"/bin/kpm
#   rm -rf ./usr
# )
# }

# --- TRACKED MODERN USERLAND USERSPACE ---

build_dash() {
  get_src https://git.kernel.org/pub/scm/utils/dash/dash.git/snapshot/dash-0.5.13.4.tar.gz dash_src
  (
    cd dash_src

    # FIX: Generate the ./configure script from configure.ac
    sh ./autogen.sh

    configure_gnu_static --enable-static
    make -j"$JOBS"
    cp ./src/dash "$ROOTFS"/bin/dash
    ln -sf dash "$ROOTFS"/bin/sh
  )
}


build_zsh() {
  get_src https://sourceforge.net/projects/zsh/files/zsh/5.9.1/zsh-5.9.1.tar.xz/download zsh_src
  (
    cd zsh_src

    # FIX: Use -isystem to expose the entire host header pool safely for just this build!
    export CFLAGS="${CFLAGS:-} -std=gnu99 -isystem /usr/include -DHAVE_TERMCAP_H -DHAVE_CURSES_H -Wno-error=implicit-function-declaration"
    export LIBS="-lncursesw -lncurses"

    configure_gnu_static --enable-static --disable-dynamic --disable-gdbm --with-term-lib="ncursesw"
    make -j"$JOBS"
    cp ./Src/zsh "$ROOTFS"/bin/zsh
  )

}

build_runit() {
  # 1. Fetch the latest version shown in the installation document
  get_src https://smarden.org/runit/runit-2.3.1.tar.gz runit_src
  (
    cd runit_src/runit-2.3.1

    # 2. Inject slimcc and your custom static/Ryzen optimization flags
    # We write directly into the configuration files in src/ as instructed
    echo "$STAGE1CC -O2 -march=native" > src/conf-cc
    echo "$STAGE1CC -static" > src/conf-ld

    # 3. Use runit's custom build script instead of standard 'make'
    # package/compile will build everything and place it in the command/ folder
    package/compile

    # 4. Manually install the binaries exactly where the document recommends
    # Moving init utilities to /sbin and supervision utilities to /bin
    mkdir -p "$ROOTFS"/sbin "$ROOTFS"/bin
    
    cp command/runit command/runit-init "$ROOTFS"/sbin/
    cp command/runsv command/runsvdir command/sv command/svlogd command/utmpset "$ROOTFS"/bin/
    
    # 5. Create the classic symlink for your EFISTUB initramfs /init entry pointpoint
    ln -sf /sbin/runit-init "$ROOTFS"/init
  )
}


install_uutils() {
  get_src https://github.com/uutils/coreutils/releases/download/0.9.0/coreutils-0.9.0-x86_64-unknown-linux-musl.tar.gz uutils_bin_src
  (
    cd uutils_bin_src
    cp coreutils "$ROOTFS"/bin/coreutils
    for applet in $(./coreutils --list); do
      # Avoid overwriting 'coreutils' or 'uutils' if it lists its own binary wrapper name
      if [ "$applet" != "coreutils" ] && [ "$applet" != "uutils" ]; then
        ln -sf coreutils "$applet"
      fi
    done
  )
}

build_libtls() {
get_src https://github.com/libressl/portable/releases/download/v4.2.1/libressl-4.2.1.tar.gz libtls_src
  (
    cd libtls_src
    sed -i 's|#if defined(__GNUC__)|#if 1|g' crypto/bn/arch/amd64/bn_arch.h
    configure_gnu_static --with-openssldir=/etc/ssl --enable-libtls-only
    make -j"$JOBS"
    mkdir -p "$ROOTFS"/etc/ssl
    cp ./cert.pem "$ROOTFS"/etc/ssl/
    cp ./openssl.cnf "$ROOTFS"/etc/ssl/
    cp ./x509v3.cnf "$ROOTFS"/etc/ssl/
  )
}

build_wget() {
get_src https://ftpmirror.gnu.org/gnu/wget/wget2-2.2.0.tar.gz wget_src
  (
    cd wget_src
    export OPENSSL_CFLAGS='-I'"$PWD"'/../libtls_src/include'
    export OPENSSL_LIBS='-L'"$PWD"'/../libtls_src/tls/.libs -ltls'
    configure_gnu_static --with-ssl=openssl PKG_CONFIG=false --without-gpgme
    make -j"$JOBS"
    cp ./src/wget2 "$ROOTFS"/bin/wget
  )
}

build_neovim() {
  get_src https://github.com/neovim/neovim/archive/refs/tags/v0.12.3.tar.gz neovim_src
  (
      mkdir -p "$ROOTFS"/usr/include/linux
      if [ -f "/build/kernel_hdr_src/generic/include/linux/errqueue.h" ]; then
	      cp /build/kernel_hdr_src/generic/include/linux/errqueue.h "$ROOTFS"/usr/include/linux/errqueue.h
      fi

      cd neovim_src

    # 2. Isolate the environment variables completely [pcc]
    LOCAL_CFLAGS_BAK="$CFLAGS"
    unset CFLAGS

    # 3. Assign the host compiler tools [pcc]
    export CC="/usr/bin/gcc"
    export CXX="/usr/bin/g++"

    # 4. FIX: Use CPATH to inject your header pool globally across all sub-projects!
    # This flows right through CMake's ExternalProject isolation layers seamlessly [pcc].
    export CPATH="$ROOTFS/usr/include"

    # 5. Pass your LFS path targets and flags safely via the global environment
    export CFLAGS="-B$ROOTFS/bin/ -static -fPIC -fno-lto"
    export CXXFLAGS="-B$ROOTFS/bin/ -static -fPIC -fno-lto"

    # 6. Keep your top-level CMake variables bare and unquoted [pcc]
    SLIM_CMAKE_ARGS="-DCMAKE_PREFIX_PATH=$ROOTFS/usr -DCMAKE_EXE_LINKER_FLAGS=-static"

    # 7. Trigger the multi-threaded compilation pipeline [pcc]
    make -j"$JOBS" CMAKE_BUILD_TYPE=Release \
      CC="$CC" \
      CMAKE_EXTRA_FLAGS="$SLIM_CMAKE_ARGS" \
      DEPS_CMAKE_FLAGS="$SLIM_CMAKE_ARGS"

    # 8. Deploy the final binary tree out to Kore Linux [pcc]
    make DESTDIR="$ROOTFS" install

    # 9. Clean up your environment changes [pcc]
    unset CPATH
    export CFLAGS="$LOCAL_CFLAGS_BAK"
  )
}

# --- STATIC INITRAMFS SECURITY PAYLOAD STAGES ---

build_static_busybox() {
  # 1. Pull down the official, pre-compiled static musl binary directly
  mkdir -p "$INITRAMFS_ROOT"/bin
  wget_loop https://www.busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox "$INITRAMFS_ROOT"/bin/busybox
  chmod +x "$INITRAMFS_ROOT"/bin/busybox

  # 2. Force BusyBox to deploy its entire applet symlink tree inside your initramfs
  # We navigate to the directory first to ensure the links map relatively
  (
    cd "$INITRAMFS_ROOT"/bin
    ./busybox --install -s .
  )
}


build_static_cryptsetup() {
  # 1. Compile minimal static JSON-C
  get_src https://s3.amazonaws.com/json-c_releases/releases/json-c-0.18.tar.gz json_src
  (
    cd json_src
    
    rm -rf build CMakeCache.txt CMakeFiles
    mkdir -p build
    cd build
    
    # FIX: Add the policy minimum override flag to satisfy modern CMake engines!
    cmake -DCMAKE_C_COMPILER="$STAGE1CC" \
          -DCMAKE_EXE_LINKER_FLAGS="-static" \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_INSTALL_PREFIX="$PWD/../dist" ..
          
    make -j"$JOBS" install
  )

  # 2. Compile raw static Cryptsetup binary
  get_src https://cdn.kernel.org/pub/linux/utils/cryptsetup/v2.8/cryptsetup-2.8.6.tar.xz crypt_src
  (
    cd crypt_src

    unset CFLAGS
    unset LDFLAGS
    unset LIBS

    export CC="/usr/bin/gcc"
    export CXX="/usr/bin/g++"

    # FIX: Supply BOTH variables so the script validation and the source files are happy!
    export CPATH="$PWD/../json_src/dist/include"
    export JSON_C_CFLAGS="-I$PWD/../json_src/dist/include"
    export JSON_C_LIBS="-L$PWD/../json_src/dist/lib -ljson-c"

    # Keep your compiler flags clean and system-isolated
    export CFLAGS="-B$ROOTFS/bin/ -static -no-pie -fno-lto -D_GNU_SOURCE -I/build/kernel_hdr_src/generic/include -isystem /usr/include -I/usr/include"
    export LDFLAGS="-B$ROOTFS/bin/ -L/usr/lib -static -no-pie -fno-lto"

    export LIBS="-ldevmapper -luuid -lpopt"

    export PKG_CONFIG="/usr/bin/pkg-config"
    export PKG_CONFIG_LIBDIR=/dev/null
    export PKG_CONFIG_PATH=/dev/null

    sh ./configure --disable-shared --build=x86_64-linux-musl --disable-nls \
                   --disable-ssh-token --disable-fido2-token --disable-asciidoc \
                   --with-crypto_backend=kernel --disable-blkid
                         
    make -j"$JOBS"
    cp /build/crypt_src/cryptsetup "$INITRAMFS_ROOT"/sbin/
    
    # Clean up environment state
    unset CPATH
  )
}

# --- EXECUTION ORCHESTRATION PIPELINE ---

# Stage 1: Build the Initial Toolchain
build_bootstrap_cc
build_musl
build_linux_headers
build_binutils

# Patch environment paths to prefer our target binaries
export CFLAGS="${CFLAGS:-} -B$ROOTFS/bin/ -march=native"

# Stage 2: Deploy Main System Tools
build_cc
build_gmake
# build_kpm

# --- COMMENTED OUT KPM ADOPT MODULE ---
# "$ROOTFS"/bin/kpm adopt --name="musl"     --version="1.2.6"  --path="$ROOTFS"/usr/include
# "$ROOTFS"/bin/kpm adopt --name="binutils" --version="2.46.1" --path="$ROOTFS"/bin
# "$ROOTFS"/bin/kpm adopt --name="slimcc"   --version="C23"    --path="$ROOTFS"/bin/cc

# Stage 3: Ingest Custom Kore Linux Userland
build_dash
build_zsh
build_runit
install_uutils
build_libtls
build_wget
build_neovim

# Stage 4: Manufacture Embedded Cryptographic Initramfs Tree
build_static_busybox
build_static_cryptsetup

echo "=========================================================="
echo "Kore Linux userspace compilation completed successfully!"
echo "Main RootFS: $ROOTFS"
echo "Initramfs Root: $INITRAMFS_ROOT"
echo "Ready to pass to CONFIG_INITRAMFS_SOURCE inside your kernel build tree."
echo "=========================================================="
