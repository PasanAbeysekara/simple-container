#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status

# Define the root filesystem for the container
# If no argument is provided, default to /tmp/mycontainer_root
ROOTFS=${1:-/tmp/mycontainer_root}

echo "Setting up container root filesystem at: $ROOTFS"

# Create essential directories inside the container's root filesystem
# We create common lib paths directly, as busybox might expect them.
mkdir -p "$ROOTFS"/{bin,proc,dev}
mkdir -p "$ROOTFS"/{lib,lib64} # Ensure /lib and /lib64 exist
mkdir -p "$ROOTFS"/lib/x86_64-linux-gnu # Common path for libc on 64-bit systems

# --- DYNAMIC LIBRARY SETUP (Crucial for dynamically linked busybox) ---
# Most modern busybox binaries are dynamically linked. This means they depend on
# shared libraries from the host system (like the C standard library and the dynamic linker).
# We need to copy these essential libraries into the container's root filesystem
# so that programs like 'sh' (busybox) can execute properly within the chroot environment.
# The 'execv failed: No such file or directory' error often means the dynamic linker
# or a required library is missing from the *chrooted* path.

echo "Copying essential dynamic libraries for busybox..."

# 1. Determine the path to the dynamic linker on the host system.
# This is the actual file you need to copy.
HOST_DYNAMIC_LINKER=$(readlink -f $(ldd /usr/bin/busybox | grep -o '/lib.*/ld-linux.*\.so\.[0-9]' | head -1))

# 2. Determine the path where busybox expects the dynamic linker *inside the chroot*.
# This comes from the 'interpreter' field in 'file /usr/bin/busybox' output.
# For your case, it's /lib64/ld-linux-x86-64.so.2
EXPECTED_LINKER_IN_CHROOT="/lib64/$(basename "$HOST_DYNAMIC_LINKER")"

# 3. Determine the path to libc.so.6 on the host system.
HOST_LIBC_SO=$(ldd /usr/bin/busybox | grep -o '/lib.*/libc\.so\.6' | head -1)
LIBC_DIR=$(dirname "$HOST_LIBC_SO") # Get the directory for libc, where libresolv will also go

# 4. Determine the path to libresolv.so.2 on the host system.
# It usually resides in the same directory as libc.so.6
HOST_LIBRESOLV_SO="$LIBC_DIR/libresolv.so.2"

# Create the target directories within the container's rootfs for these libraries
# Ensure the parent directory for the expected linker path exists inside rootfs
mkdir -p "$ROOTFS$(dirname "$EXPECTED_LINKER_IN_CHROOT")"
# Ensure the parent directory for libc and libresolv exists inside rootfs
mkdir -p "$ROOTFS$LIBC_DIR"

# Copy the dynamic linker from host to its *expected* path within the chroot
echo "  Copying dynamic linker from $HOST_DYNAMIC_LINKER to $ROOTFS$EXPECTED_LINKER_IN_CHROOT"
cp -f "$HOST_DYNAMIC_LINKER" "$ROOTFS$EXPECTED_LINKER_IN_CHROOT"

# Copy the C standard library from host to its *expected* path within the chroot
echo "  Copying libc from $HOST_LIBC_SO to $ROOTFS$HOST_LIBC_SO"
cp -f "$HOST_LIBC_SO" "$ROOTFS$HOST_LIBC_SO"

# Copy libresolv.so.2 from host to its *expected* path within the chroot
echo "  Copying libresolv.so.2 from $HOST_LIBRESOLV_SO to $ROOTFS$HOST_LIBRESOLV_SO"
cp -f "$HOST_LIBRESOLV_SO" "$ROOTFS$HOST_LIBRESOLV_SO"

# --- END DYNAMIC LIBRARY SETUP ---

# Copy the busybox binary to the /bin directory inside the container's root filesystem
cp -f /usr/bin/busybox "$ROOTFS"/bin/busybox

# Change the directory to the /bin directory inside the container's root filesystem
# This makes it easier to create symbolic links relative to this directory.
cd "$ROOTFS"/bin

# Create symbolic links for common shell commands using busybox
# Using 'ln -sf' to force overwrite existing links, making the script idempotent.
ln -sf busybox sh
ln -sf busybox ifconfig
ln -sf busybox ping
ln -sf busybox ls
ln -sf busybox ps
ln -sf busybox cat
ln -sf busybox mount
ln -sf busybox umount
ln -sf busybox mkdir
ln -sf busybox rm
ln -sf busybox cp
ln -sf busybox mv
ln -sf busybox echo
ln -sf busybox grep
ln -sf busybox head
ln -sf busybox tail
ln -sf busybox touch
ln -sf busybox find
ln -sf busybox df
ln -sf busybox du
ln -sf busybox hostname
ln -sf busybox sleep
ln -sf busybox ip

# Change back to the initial directory to ensure subsequent commands are not affected
cd - > /dev/null

# Create essential device nodes inside the container's /dev directory
# We use 'rm -f' before 'mknod' to ensure idempotency and prevent 'File exists' errors.

sudo rm -f "$ROOTFS"/dev/null
sudo mknod -m 666 "$ROOTFS"/dev/null c 1 3

sudo rm -f "$ROOTFS"/dev/zero
sudo mknod -m 666 "$ROOTFS"/dev/zero c 1 5

sudo rm -f "$ROOTFS"/dev/tty
sudo mknod -m 666 "$ROOTFS"/dev/tty c 5 0

sudo rm -f "$ROOTFS"/dev/random
sudo mknod -m 666 "$ROOTFS"/dev/random c 1 8

sudo rm -f "$ROOTFS"/dev/urandom
sudo mknod -m 666 "$ROOTFS"/dev/urandom c 1 9

echo "✅ Container root filesystem setup complete ($ROOTFS). Essential binaries, libraries, and device nodes are in place."

# Educational Notes:
# - Device nodes are special files that provide an interface to hardware devices or virtual devices.
# - `mknod` is used to create these special files.
# - The `-m` flag sets the permissions for the device node (e.g., 666 for read/write access to all users).
# - The `c` indicates that these are character devices (data is handled as a stream of characters).
# - Major number: Identifies the driver associated with the device (e.g., 1 for memory devices).
# - Minor number: Identifies the specific device handled by the driver (e.g., 3 for /dev/null).
# - busybox provides a "Swiss Army knife" of essential Linux utilities in a single executable,
#   ideal for minimal environments like containers.
