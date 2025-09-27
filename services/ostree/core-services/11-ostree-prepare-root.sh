if [ -e /etc/initrd-release ]
then
  /usr/lib/bootc/initramfs-setup /sysroot
fi
