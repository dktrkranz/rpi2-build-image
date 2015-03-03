#!/bin/sh

########################################################################
# rpi2-build-image
# Copyright (C) 2015 Ryan Finnie <ryan@finnie.org>
# Copyright (C) 2015 Luca Falavigna <dktrkranz@debian.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.
########################################################################

set -e
set -x

RELEASE=jessie
BASEDIR=rpi2/${RELEASE}
BUILDDIR=${BASEDIR}/build

# Don't clobber an old build
if [ -e "$BUILDDIR" ]; then
  echo "$BUILDDIR exists, not proceeding"
  exit 1
fi

# Set up environment
export TZ=CET
R=${BUILDDIR}/chroot
mkdir -p $R

# Install dependencies
apt-get -y install debootstrap qemu-user-static dosfstools rsync bmap-tools

# Base debootstrap
debootstrap --arch=armhf --foreign --include=apt-transport-https,ca-certificates $RELEASE $R ftp://ftp.debian.org/debian
cp /usr/bin/qemu-arm-static $R/usr/bin
chroot $R /debootstrap/debootstrap --second-stage

# Mount required filesystems
mount -t proc none $R/proc
mount -t sysfs none $R/sys

# Set up initial sources.list
cat <<EOM >$R/etc/apt/sources.list
deb http://ftp.debian.org/debian ${RELEASE} main contrib non-free
#deb-src http://ftp.debian.org/debian ${RELEASE} main contrib non-free

deb http://ftp.debian.org/debian/ ${RELEASE}-updates main contrib non-free
#deb-src http://ftp.debian.org/debian/ ${RELEASE}-updates main contrib non-free

deb http://security.debian.org/ ${RELEASE}/updates main contrib non-free
#deb-src http://security.debian.org/ ${RELEASE}/updates main contrib non-free

deb https://repositories.collabora.co.uk/debian ${RELEASE} rpi2
EOM
chroot $R apt-get update
chroot $R apt-get -y -u dist-upgrade

# XFCE desktop
chroot $R tasksel --new-install install xfce-desktop --debconf-apt-progress --logstderr

# Kernel installation
# Install flash-kernel last so it doesn't try (and fail) to detect the
# platform in the chroot.
chroot $R apt-get -y --force-yes --no-install-recommends install linux-image-3.18.0-trunk-rpi2
chroot $R apt-get -y --force-yes install flash-kernel
VMLINUZ="$(ls -1 $R/boot/vmlinuz-* | sort | tail -n 1)"
[ -z "$VMLINUZ" ] && exit 1
mkdir -p $R/boot/firmware
cp $VMLINUZ $R/boot/firmware/kernel7.img

# Set up fstab
cat <<EOM >$R/etc/fstab
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               ext4    defaults,noatime  0       1
/dev/mmcblk0p1  /boot/firmware  vfat    defaults          0       2
EOM

# Set up hosts
echo rpi2-${RELEASE} >$R/etc/hostname
cat <<EOM >$R/etc/hosts
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       rpi2-${RELEASE}
EOM

# Set up default user (password: "raspberry")
chroot $R adduser --gecos "Raspberry PI user" --add_extra_groups --disabled-password pi
chroot $R usermod -a -G sudo -p '$6$YW2hsnbl$XnsgzVfApHqR8IWV8NyNLYttCy4d/lolIhxopgnn3my29eEHdiuZ27VRF6bRCeGSD22zl4KptWdd.Vxjw2c0N/' pi

# Set up root password (password: "raspberry")
chroot $R usermod -p '$6$YW2hsnbl$XnsgzVfApHqR8IWV8NyNLYttCy4d/lolIhxopgnn3my29eEHdiuZ27VRF6bRCeGSD22zl4KptWdd.Vxjw2c0N/' root

# Clean cached downloads
chroot $R apt-get clean

# Set up interfaces
cat <<EOM >$R/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug eth0
iface eth0 inet dhcp
EOM

# Set up firmware config
cat <<EOM >$R/boot/firmware/config.txt
# For more options and information see
# http://www.raspberrypi.org/documentation/configuration/config-txt.md
# Some settings may impact device functionality. See link above for details

# uncomment if you get no picture on HDMI for a default "safe" mode
#hdmi_safe=1

# uncomment this if your display has a black border of unused pixels visible
# and your display can output without overscan
#disable_overscan=1

# uncomment the following to adjust overscan. Use positive numbers if console
# goes off screen, and negative if there is too much border
#overscan_left=16
#overscan_right=16
#overscan_top=16
#overscan_bottom=16

# uncomment to force a console size. By default it will be display's size minus
# overscan.
#framebuffer_width=1280
#framebuffer_height=720

# uncomment if hdmi display is not detected and composite is being output
#hdmi_force_hotplug=1

# uncomment to force a specific HDMI mode (this will force VGA)
#hdmi_group=1
#hdmi_mode=1

# uncomment to force a HDMI mode rather than DVI. This can make audio work in
# DMT (computer monitor) modes
#hdmi_drive=2

# uncomment to increase signal to HDMI, if you have interference, blanking, or
# no display
#config_hdmi_boost=4

# uncomment for composite PAL
#sdtv_mode=2

#uncomment to overclock the arm. 700 MHz is the default.
#arm_freq=800
EOM
ln -sf firmware/config.txt $R/boot/config.txt
echo 'dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootwait' > $R/boot/firmware/cmdline.txt
ln -sf firmware/cmdline.txt $R/boot/cmdline.txt

# Load sound module on boot
mkdir -p $R/lib/modules-load.d/
cat <<EOM >$R/lib/modules-load.d/rpi2.conf
snd_bcm2835
bcm2708_rng
EOM

# Blacklist platform modules not applicable to the RPi2
mkdir -p $R/etc/modprobe.d/
cat <<EOM >$R/etc/modprobe.d/rpi2.conf
blacklist snd_soc_pcm512x_i2c
blacklist snd_soc_pcm512x
blacklist snd_soc_tas5713
blacklist snd_soc_wm8804
EOM

# Unmount mounted filesystems
umount -l $R/proc
umount -l $R/sys

# Clean up files
rm -f $R/etc/apt/sources.list.save
rm -f $R/etc/resolvconf/resolv.conf.d/original
rm -rf $R/run
mkdir -p $R/run
rm -f $R/etc/*-
rm -f $R/root/.bash_history
rm -rf $R/tmp/*
rm -f $R/var/lib/urandom/random-seed
[ -L $R/var/lib/dbus/machine-id ] || rm -f $R/var/lib/dbus/machine-id
rm -f $R/etc/machine-id

# Build the image file
# Currently hardcoded to a 3.75GiB image
DATE="$(date +%Y-%m-%d)"
dd if=/dev/zero of="$BASEDIR/${DATE}-debian-${RELEASE}.img" bs=1M count=1
dd if=/dev/zero of="$BASEDIR/${DATE}-debian-${RELEASE}.img" bs=1M count=0 seek=3840
sfdisk -f "$BASEDIR/${DATE}-debian-${RELEASE}.img" <<EOM
unit: sectors

1 : start=     2048, size=   131072, Id= c, bootable
2 : start=   133120, size=  7731200, Id=83
3 : start=        0, size=        0, Id= 0
4 : start=        0, size=        0, Id= 0
EOM
VFAT_LOOP="$(losetup -o 1M --sizelimit 64M -f --show $BASEDIR/${DATE}-debian-${RELEASE}.img)"
EXT4_LOOP="$(losetup -o 65M --sizelimit 3775M -f --show $BASEDIR/${DATE}-debian-${RELEASE}.img)"
mkfs.vfat "$VFAT_LOOP"
mkfs.ext4 "$EXT4_LOOP"
MOUNTDIR="$BUILDDIR/mount"
mkdir -p "$MOUNTDIR"
mount "$EXT4_LOOP" "$MOUNTDIR"
mkdir -p "$MOUNTDIR/boot/firmware"
mount "$VFAT_LOOP" "$MOUNTDIR/boot/firmware"
rsync -a "$R/" "$MOUNTDIR/"
umount "$MOUNTDIR/boot/firmware"
umount "$MOUNTDIR"
losetup -d "$EXT4_LOOP"
losetup -d "$VFAT_LOOP"
bmaptool create -o "$BASEDIR/${DATE}-debian-${RELEASE}.bmap" "$BASEDIR/${DATE}-debian-${RELEASE}.img"
