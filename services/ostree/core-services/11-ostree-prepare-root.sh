if [ -e /etc/initrd-release ]
then
  /usr/lib/ostree/ostree-prepare-root /sysroot
fi
