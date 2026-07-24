# SG2002-Wireless-Android-Auto-Dongle
My port of [WirelessAndroidAutoDongle](https://github.com/nisargjhaveri/WirelessAndroidAutoDongle) (AAWG) to the Sophgo SG2002, running on a Sipeed LicheeRV Nano Wireless board. AAWG was originally built for Raspberry Pi, so this is every change needed to get it running on a different chip (RISC-V), different C library (musl instead of glibc), and a different vendor SDK (Sipeed's `LicheeRV-Nano-Build`).

**Status:** fully working as of July 2026. Phone pairs over Bluetooth, hands off to WiFi, dongle shows as a USB accessory to the head unit, Android Auto shows up on screen and connects, amazing!

This README is a guide, but may have some missing or broken parts but this is how I got mine to work.

## What you need first

- A Linux machine or VM.
- The board itself (LicheeRV Nano) or a SG2002 dev board or simular, a microSD card, and a way to flash it ([balenaEtcher](https://www.balena.io/etcher/) or [Rufus](https://rufus.ie/en/))
- A USB-to-TTL serial adapter for the debug console, super handy for debug.

## 1. Set up the build environment (Standard stuff)

```bash
sudo apt update
sudo apt install -y git docker.io mtools
sudo usermod -aG docker $USER
```
Log out and back in for the group change to apply! DO NOT SKIP THIS.

```bash
git clone https://github.com/sipeed/LicheeRV-Nano-Build --depth=1
cd LicheeRV-Nano-Build
git clone https://github.com/sophgo/host-tools --depth=1

cd host/ubuntu
docker build -t licheervnano-build-ubuntu .
cd ../..
```

## 2. Get into the build container

```bash
docker run -it -v $(pwd):/build licheervnano-build-ubuntu bash
```

## 3. Build the stock image first

I wouldn't skip this - it proves the toolchain and your setup actually working before you add anything on top on the buid. Up to you...
```bash
git config --global --add safe.directory /build
cd /build
source build/cvisetup.sh
defconfig sg2002_licheervnano_sd
build_all
```
This takes a while the first time but when it's it'll spit out an `.img` file. Flash it and confirm it boots before moving on. The LicheeNano creates a Network adapter which you can connect to via SSH,
The default login/ password is: root

## 4. Apply the kernel patch

This adds USB accessory-mode support, which the SG2002 kernel doesn't include by default.

Copy the new driver files into place:
```bash
cp -r patches/kernel/new-files/drivers/usb/gadget/function/f_accessory.c  linux_5.10/drivers/usb/gadget/function/
cp -r patches/kernel/new-files/include/linux/usb/f_accessory.h            linux_5.10/include/linux/usb/
cp -r patches/kernel/new-files/include/uapi/linux/usb/f_accessory.h       linux_5.10/include/uapi/linux/usb/
```
Apply the patch that wires them into the kernel's build/config system:
```bash
cd linux_5.10
patch -p1 < ../patches/kernel/sg2002-f_accessory-modified-files.patch
cd ..
```
Add these lines to `linux_5.10/build/sg2002_licheervnano_sd/.config` (or the board's kernel defconfig, `build/boards/sg200x/sg2002_licheervnano_sd/linux/sg2002_licheervnano_sd_defconfig`):
```
CONFIG_USB_F_ACC=y
CONFIG_USB_CONFIGFS_F_ACC=y
CONFIG_USB_CONFIGFS_UEVENT=y
# CONFIG_BT_BNEP is not set
```

## 5. Get AAWG's own daemon into the build

Clone AAWG somewhere and grab its `aawg` and `dbus-cxx-custom` packages:
```bash
git clone https://github.com/nisargjhaveri/WirelessAndroidAutoDongle --depth=1 /tmp/aawg-src
cp -r /tmp/aawg-src/aa_wireless_dongle/package/aawg            buildroot/package/
cp -r /tmp/aawg-src/aa_wireless_dongle/package/dbus-cxx-custom  buildroot/package/
cp -r /tmp/aawg-src/aa_wireless_dongle/board/common/rootfs_overlay  ./aawg-rootfs-overlay
```

Fix the source path in `buildroot/package/aawg/aawg.mk` - it assumes a different project layout than this one:
```bash
sed -i 's|AAWG_SITE = .*|AAWG_SITE = /build/buildroot/package/aawg/src|' buildroot/package/aawg/aawg.mk
```

Force C++17, which the source needs but the Makefile never explicitly requests:
```bash
sed -i 's|EXTRA_CXXFLAGS += \$(shell|EXTRA_CXXFLAGS += -std=c++17 \$(shell|' buildroot/package/aawg/src/Makefile
```

Add the missing include (musl needs it explicitly, glibc doesn't):
```bash
sed -i '/#include <sys\/socket.h>/a #include <sys/time.h>' buildroot/package/aawg/src/proxyHandler.cpp
```

Register both packages with Buildroot - open `buildroot/package/Config.in`, find the line `source "package/dbus/Config.in"`, and add right after it:
```
source "package/aawg/Config.in"
source "package/dbus-cxx-custom/Config.in"
```

## 6. Apply the rootfs fixes

These are all real fixes for problems found getting everything to boot and run together. Copy the pre-fixed versions from this repo straight over Sipeed's defaults:

```bash
cp patches/rootfs-changes/S92usb_gadget      aawg-rootfs-overlay/etc/init.d/S92usb_gadget
cp patches/rootfs-changes/interfaces         aawg-rootfs-overlay/etc/network/interfaces
cp patches/rootfs-changes/dnsmasq.conf       aawg-rootfs-overlay/etc/dnsmasq.conf
```

Set up the post-build permission fix (init scripts kept losing their executable bit somewhere in the pipeline, so this force-corrects them every build):
```bash
cp patches/rootfs-changes/fix-permissions.sh buildroot/board/cvitek/SG200X/fix-permissions.sh
chmod +x buildroot/board/cvitek/SG200X/fix-permissions.sh
```

Disable Sipeed's own wifi script, since AAWG needs to own the wifi interface exclusively (their script races AAWG for control otherwise):
```bash
chmod -x buildroot/board/cvitek/SG200X/overlay/etc/init.d/S30wifi
```

Set a real wifi password and device name suffix (Change as needed!) - AAWG ships with both commented out, and leaving the password unset causes it to mismatch itself between reboots:
```bash
sed -i 's/#AAWG_WIFI_PASSWORD=ConnectAAWirelessDongle/AAWG_WIFI_PASSWORD=ConnectAAWirelessDongle/' aawg-rootfs-overlay/etc/aawgd.conf
sed -i 's/#AAWG_UNIQUE_NAME_SUFFIX=/AAWG_UNIQUE_NAME_SUFFIX=CauseICan/' aawg-rootfs-overlay/etc/aawgd.conf
```

## 7. Config changes

Everything below gets added to `buildroot/configs/cvitek_SG200X_musl_riscv64_defconfig`. Full list with comments is in `patches/rootfs-changes/defconfig-additions.txt` - either paste the whole block in with a text editor like Nano, or:
```bash
cat patches/rootfs-changes/defconfig-additions.txt | grep -v '^#' | grep '=' >> buildroot/configs/cvitek_SG200X_musl_riscv64_defconfig
```

Then find the existing `BR2_ROOTFS_OVERLAY` line and change it to include both overlays:
```bash
sed -i 's|BR2_ROOTFS_OVERLAY="\$(TOPDIR)/board/cvitek/SG200X/overlay"|BR2_ROOTFS_OVERLAY="$(TOPDIR)/board/cvitek/SG200X/overlay /build/aawg-rootfs-overlay"|' buildroot/configs/cvitek_SG200X_musl_riscv64_defconfig
```

## 8. Build it

For the very first build with all of this, do a clean build so nothing's left over from the stock image:
```bash
cd /build
make -C buildroot clean
source build/cvisetup.sh
defconfig sg2002_licheervnano_sd
build_all
```
Let it finish completely, it will take a while.

## 9. Flash it

Find the image:
```bash
find install -iname "*.img"
```
Grab that fresh `.img` file, pick your SD card, flash it.

## 10. First boot

Put the SD card in the board, connect your serial adapter if you've got one and listen on 115200 on UART.
Log in as `root` (blank password or `root`, depending on the image). Once you're in, a few sanity checks:
```bash
ps | grep -E "dbus|bluetoothd|aawgd|hostapd|dnsmasq"
cat /sys/kernel/config/usb_gadget/g0/UDC
```
The first should show all five running. The second should come back empty (confirms the USB port isn't stuck on Sipeed's default gadget).


## 11. Pair and test

Pair your phone to the dongle over Bluetooth like any other device, then plug the dongle into your head unit's USB port. Give it a bit - it goes through Bluetooth handshake, then WiFi handoff, then the USB accessory switch, before Android Auto actually shows up on screen.

## Known issues

- Sometimes takes a while to connect, or has a small hiccup around a minute after boot. Haven't tracked down if it's wifi channel interference or something settling on the chip itself.
- The SD card partition size is still whatever Sipeed originally set it to, bigger than it needs to be now that the image is smaller after stripping unused packages. Works fine, just wastes some space.
- If you kill the daemon abruptly it can leave some Bluetooth state behind that causes a hiccup on the next start. Not a real problem in normal use.

## What's actually in `patches/`

```
kernel/
  sg2002-f_accessory-modified-files.patch   the kernel patch itself
  new-files/                                the new driver + header files it needs
rootfs-changes/
  S92usb_gadget          USB gadget setup, with the fix for the g0 conflict
  interfaces             network config, with the hostapd argument order fixed
  dnsmasq.conf           with bind-interfaces added so it doesn't fight for the DHCP port
  fix-permissions.sh     post-build script that keeps init scripts executable
  defconfig-additions.txt   every config line change, all in one place
```
