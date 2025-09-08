# Before anything, I should properly build a custom composefs file in a custom rootful container, due to the nature of void-src.
FROM ghcr.io/void-linux/void-glibc-full:latest AS packager
COPY ./extra-pkg /extra-pkg
RUN xbps-install -S -y git bash

# Fetch the repo(I NEED TO CACHE THIS SO BADLY)
RUN git clone https://github.com/void-linux/void-packages.git && \
  cd void-packages

RUN cd void-packages && \
  cp -r /extra-pkg/composefs/ srcpkgs/ && \
  echo XBPS_CHROOT_CMD=uunshare >> etc/conf && \
  echo XBPS_ALLOW_CHROOT_BREAKOUT=yes >> etc/conf && \
  ./xbps-src pkg composefs

# Now to the actual image...
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
  ostree
# TODO: composefs

# Prepare the builder
RUN XBPS_TARGET_ARCH="x86_64" \
xbps-install -S -y -R "https://repo-ci.voidlinux.org/current/" \
  base-devel \
#  shadow \
  ostree \
  git \
  rust \
  cargo \
  dracut \
# This is for bootupd
  openssl-devel \
# This is for bootc
  pkg-config \
  libzstd-devel \
  glib-devel \
  libostree-devel \
# Apparently, libarchive-devel is also a dependency for libostree pkg-config files now. Putting it as an extra dependency for extra measure.
  libarchive-devel

# Copy extra package files from context to the build stage
COPY ./extra-pkg /extra-pkg

# Installing composefs from the packager stage
RUN --mount=type=cache,dst=/tmp,from=packager,source=/void-packages/hostdir/binpkgs cd /tmp && \
  xbps-install --repository . -S -y -r "${BOOTC_ROOTFS_MOUNTPOINT}" composefs

# Build bootc
RUN --mount=type=tmpfs,dst=/tmp cd /tmp && \
    git clone https://github.com/bootc-dev/bootc.git bootc && \
    cd bootc && \
    git fetch --all && \
    git switch origin/composefs-backend -d && \
    cargo build --release --bins && \
    install -Dpm0755 -t "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/dracut/modules.d/37composefs/" ./crates/initramfs/dracut/module-setup.sh && \
#    install -Dpm0644 -t "${BOOTC_ROOTFS_MOUNTPOINT}/usr/lib/systemd/system/" ./crates/initramfs/bootc-root-setup.service && \
    install -Dpm0755 -t "${BOOTC_ROOTFS_MOUNTPOINT}/usr/bin" ./target/release/bootc ./target/release/system-reinstall-bootc && \
    install -Dpm0755  ./target/release/bootc-initramfs-setup "${BOOTC_ROOTFS_MOUNTPOINT}"/usr/lib/bootc/initramfs-setup 

# Build boootupd
RUN --mount=type=tmpfs,dst=/tmp cd /tmp && \
    git clone https://github.com/p5/coreos-bootupd.git bootupd && \
    cd bootupd && \
    git fetch --all && \
    git switch origin/sdboot-support -d && \
    cargo build --release --bins --features systemd-boot && \
    install -Dpm0755 -t "${BOOTC_ROOTFS_MOUNTPOINT}/usr/bin" ./target/release/bootupd && \
    ln -s ./bootupd "${BOOTC_ROOTFS_MOUNTPOINT}/usr/bin/bootupctl"

# Copy the final filesystem to a new root
FROM scratch AS runtime

COPY --from=builder /mnt /
# Taken from Void's image builder
RUN \
  install -dm1777 tmp; \
  xbps-reconfigure -fa; \
  rm -rf /var/cache/xbps/*
