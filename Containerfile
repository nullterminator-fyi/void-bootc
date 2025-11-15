#             _     _        _                 _       
#            (_)   | |      | |               | |      
# __   _____  _  __| |______| |__   ___   ___ | |_ ___ 
# \ \ / / _ \| |/ _` |______| '_ \ / _ \ / _ \| __/ __|
#  \ V / (_) | | (_| |      | |_) | (_) | (_) | || (__ 
#   \_/ \___/|_|\__,_|      |_.__/ \___/ \___/ \__\___|
#                                                     
#                   By Null Terminator                 
#
# The goal of this OCI image is to have a minimal base
# for a bootable system that anyone can use as a ground
# for a Void based atomic distro. It will have it's own
# kernel build with FS_VERITY enabled, so keep that in
# mind if you want to use a different kernel.
#
# The image will be updated every week by GitHub actions.

#
# Stage 0: Package necessary software
#
FROM ghcr.io/void-linux/void-glibc:latest AS packager

# Clone the void-packages repo
RUN xbps-install -S -y git && \
    git clone https://github.com/void-linux/void-packages.git

WORKDIR void-packages

# Bring in the package recipes and set the configuration
RUN --mount=type=bind,dst=/extra-pkg,source=extra-pkg/ \
    cp -r /extra-pkg/* srcpkgs/ && \
    echo XBPS_CHROOT_CMD=uunshare >> etc/conf && \
    echo XBPS_ALLOW_CHROOT_BREAKOUT=yes >> etc/conf && \

# Build the packages, and cache mount them
RUN --mount=type=cache,dst=hostdir/binpkgs \
    ./xbps-src pkg linux6.12 && \
    ./xbps-src pkg composefs && \
    ./xbps-src pkg bootupd && \
    ./xbps-src pkg skopeo && \
    ./xbps-src pkg bootc

#
# Stage 1: Set up the image
#
FROM ghcr.io/void-linux/void-glibc:latest AS builder

ENV BOOTC_ROOTFS_MOUNTPOINT=/mnt

# For trusting the repo
RUN mkdir -p "${BOOTC_ROOTFS_MOUNTPOINT}"/var/db/xbps/keys/
RUN cp -r /var/db/xbps/keys/* "${BOOTC_ROOTFS_MOUNTPOINT}"/var/db/xbps/keys/

# Creating the base system
# I will temporarily not bother with architectures
RUN XBPS_TARGET_ARCH="x86_64" \
xbps-install -S -y -r "${BOOTC_ROOTFS_MOUNTPOINT}" -R "https://repo-ci.voidlinux.org/current/" \
  base-system \
  whois \
  strace \
  shadow \
  skopeo \
  systemd-boot \
  ostree && \
  xbps-reconfigure -fa -r ${BOOTC_ROOTFS_MOUNTPOINT}

# Prepare the builder
RUN XBPS_TARGET_ARCH="x86_64" \
xbps-install -S -y -R "https://repo-ci.voidlinux.org/current/" \
  base-devel \
  strace \
  shadow \
  ostree \
  git \
  curl \
  dracut \
# This is for bootupd
  openssl-devel \
# This is for bootc
  pkg-config \
  libzstd-devel \
  glib-devel \
  libostree-devel \
# Apparently, libarchive-devel is also a dependency for libostree pkg-config files now. Putting it as an extra dependency for extra measure.
  libarchive-devel \
  fuse3-devel \
  meson \
  go-md2man \
  findutils

# Copy extra files
COPY ./patches /extras/patches

# Building bootc & bootupd
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --profile minimal -y && \
    git clone https://github.com/bootc-dev/bootc.git /tmp/bootc && \
    cd /tmp/bootc && \
    # Pin a specific commit for now
    git checkout 8cf097171969f6fbee9a82225789c041b29221ff && \
    git apply /extras/patches/bootc/* && \
    CARGO_FEATURES="composefs-backend" PATH="/root/.cargo/bin:$PATH" make bin && \
    make DESTDIR=${BOOTC_ROOTFS_MOUNTPOINT} install-all && \
    make DESTDIR=${BOOTC_ROOTFS_MOUNTPOINT} install-initramfs-dracut && \
    git clone https://github.com/p5/coreos-bootupd.git -b sdboot-support /tmp/bootupd && \
    cd /tmp/bootupd && \
    /root/.cargo/bin/cargo build --release --bins --features systemd-boot && \
    make DESTDIR=${BOOTC_ROOTFS_MOUNTPOINT} install

RUN rm -rf "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/modules/" "${BOOTC_ROOTFS_MOUNTPOINT}/boot"
COPY --from=kernel /usr/lib/modules ${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/modules
COPY --from=kernel /boot ${BOOTC_ROOTFS_MOUNTPOINT}/boot

# Set up dracut
RUN sh -c 'export KERNEL_VERSION="$(basename "$(find ${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")" && \
    dracut --add debug --force -r "${BOOTC_ROOTFS_MOUNTPOINT}" --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION" "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/modules/$KERNEL_VERSION/initramfs.img" && \
    cp ${BOOTC_ROOTFS_MOUNTPOINT}/boot/vmlinuz-$KERNEL_VERSION "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/modules/$KERNEL_VERSION/vmlinuz"'

# patch core-services to not remount root directory as read-write
RUN cd ${BOOTC_ROOTFS_MOUNTPOINT}/etc/runit/ && \
    git apply /extras/patches/runit-void/*

COPY ./services /extras/services
# Move the services
RUN cd /extras/services && \
    install -Dpm0644 -t ${BOOTC_ROOTFS_MOUNTPOINT}/etc/runit/core-services/ ./*/core-services/* && \
    install -Dpm0755 -t ${BOOTC_ROOTFS_MOUNTPOINT}/etc/cron.d/ ./*/cron.d/* && \
    mkdir ${BOOTC_ROOTFS_MOUNTPOINT}/etc/sv/bootloader-update/ && \
    install -Dpm0755 -t ${BOOTC_ROOTFS_MOUNTPOINT}/etc/sv/bootloader-update/ ./bootupd/bootloader-update/*

# Setup a temporary root passwd (changeme) for dev purposes
# TODO: Replace this for a more robust option when in prod
RUN usermod -p "$(echo "changeme" | mkpasswd -s)" root

# Update useradd default to /var/home instead of /home for User Creation
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "${BOOTC_ROOTFS_MOUNTPOINT}/etc/default/useradd"

# Create the necessary folders, then symlink
RUN cd "${BOOTC_ROOTFS_MOUNTPOINT}" && \
    rm -rf var boot home root usr/local srv && \
    mkdir -p var && \
    ln -s /var/home home && \
    ln -s /var/roothome root && \
    ln -s /var/srv srv && \
    ln -s sysroot/ostree ostree && \
    ln -s /var/usrlocal usr/local && \
    mkdir -p sysroot boot

# Necessary for `bootc install`
RUN mkdir -p "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/ostree" && \
    printf  "[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n" | \
    tee "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/ostree/prepare-root.conf"

# Copy the final filesystem to a new root
FROM scratch AS runtime

COPY --from=builder /mnt /
# Taken from Void's image builder

RUN \
  install -dm1777 tmp; \
  rm -rf /var/cache/xbps/*

RUN bootc container lint
