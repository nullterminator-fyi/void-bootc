FROM ghcr.io/void-linux/void-glibc:latest AS builder

ENV BOOTC_ROOTFS_MOUNTPOINT=/mnt

# For trusting the repo
RUN mkdir -p "${BOOTC_ROOTFS_MOUNTPOINT}"/var/db/xbps/keys/
RUN cp -r /var/db/xbps/keys/* "${BOOTC_ROOTFS_MOUNTPOINT}"/var/db/xbps/keys/

# I will temporarily not bother with architectures
RUN XBPS_TARGET_ARCH="x86_64" \
xbps-install -S -y -r "${BOOTC_ROOTFS_MOUNTPOINT}" -R "https://repo-ci.voidlinux.org/current/" \
  base-system \
  ostree
# TODO: composefs

# Copy the final filesystem to a new root
FROM scratch AS runtime

COPY --from=builder /mnt /
# Taken from Void's image builder
RUN \
#  install -dm1777 tmp; \
  xbps-reconfigure -fa; \
  rm -rf /var/cache/xbps/*
