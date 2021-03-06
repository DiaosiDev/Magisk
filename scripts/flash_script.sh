#!/sbin/sh
##########################################################################################
#
# Magisk Boot Image Patcher
# by topjohnwu
# 
# This zip will patch your boot image with Magisk support
#
##########################################################################################

if [ -z "$BOOTMODE" ]; then
  BOOTMODE=false
fi

TMPDIR=/tmp
($BOOTMODE) && TMPDIR=/dev/tmp

INSTALLER=$TMPDIR/magisk

COREDIR=/magisk/.core

# Boot Image Variables
CHROMEDIR=$INSTALLER/chromeos
NEWBOOT=$TMPDIR/boottmp/new-boot.img
UNPACKDIR=$TMPDIR/boottmp/bootunpack
RAMDISK=$TMPDIR/boottmp/ramdisk

# Default permissions
umask 022

##########################################################################################
# Flashable update-binary preparation
##########################################################################################

OUTFD=$2
ZIP=$3

readlink /proc/$$/fd/$OUTFD 2>/dev/null | grep /tmp >/dev/null
if [ "$?" -eq "0" ]; then
  OUTFD=0

  for FD in `ls /proc/$$/fd`; do
    readlink /proc/$$/fd/$FD 2>/dev/null | grep pipe >/dev/null
    if [ "$?" -eq "0" ]; then
      ps | grep " 3 $FD " | grep -v grep >/dev/null
      if [ "$?" -eq "0" ]; then
        OUTFD=$FD
        break
      fi
    fi
  done
fi

mkdir -p $INSTALLER
cd $INSTALLER
unzip -o "$ZIP"

##########################################################################################
# Functions
##########################################################################################

ui_print() {
  if ($BOOTMODE); then
    echo "$1"
  else 
    echo -n -e "ui_print $1\n" >> /proc/self/fd/$OUTFD
    echo -n -e "ui_print\n" >> /proc/self/fd/$OUTFD
  fi
}

getvar() {
  local VARNAME=$1
  local VALUE=$(eval echo \$"$VARNAME");
  for FILE in /dev/.magisk /data/.magisk /cache/.magisk /system/.magisk; do
    if [ -z "$VALUE" ]; then
      LINE=$(cat $FILE 2>/dev/null | grep "$VARNAME=")
      if [ ! -z "$LINE" ]; then
        VALUE=${LINE#*=}
      fi
    fi
  done
  eval $VARNAME=\$VALUE
}

find_boot_image() {
  if [ -z "$BOOTIMAGE" ]; then
    for PARTITION in kern-a KERN-A android_boot ANDROID_BOOT kernel KERNEL boot BOOT lnx LNX; do
      BOOTIMAGE=`readlink /dev/block/by-name/$PARTITION || readlink /dev/block/platform/*/by-name/$PARTITION || readlink /dev/block/platform/*/*/by-name/$PARTITION`
      if [ ! -z "$BOOTIMAGE" ]; then break; fi
    done
  fi
  if [ -z "$BOOTIMAGE" ]; then
    FSTAB="/etc/recovery.fstab"
    [ ! -f "$FSTAB" ] && FSTAB="/etc/recovery.fstab.bak"
    [ -f "$FSTAB" ] && BOOTIMAGE=`grep -E '\b/boot\b' "$FSTAB" | grep -oE '/dev/[a-zA-Z0-9_./-]*'`
  fi
}

is_mounted() {
  if [ ! -z "$2" ]; then
    cat /proc/mounts | grep $1 | grep $2, >/dev/null
  else
    cat /proc/mounts | grep $1 >/dev/null
  fi
  return $?
}

mount_image() {
  if [ ! -d "$2" ]; then
    mount -o rw,remount rootfs /
    mkdir -p $2 2>/dev/null
    ($BOOTMODE) && mount -o ro,remount rootfs /
    [ ! -d "$2" ] && return 1
  fi
  if (! is_mounted $2); then
    LOOPDEVICE=
    for LOOP in 0 1 2 3 4 5 6 7; do
      if (! is_mounted $2); then
        LOOPDEVICE=/dev/block/loop$LOOP
        if [ ! -f "$LOOPDEVICE" ]; then
          mknod $LOOPDEVICE b 7 $LOOP 2>/dev/null
        fi
        losetup $LOOPDEVICE $1
        if [ "$?" -eq "0" ]; then
          mount -t ext4 -o loop $LOOPDEVICE $2
          if (! is_mounted $2); then
            /system/bin/toolbox mount -t ext4 -o loop $LOOPDEVICE $2
          fi
          if (! is_mounted $2); then
            /system/bin/toybox mount -t ext4 -o loop $LOOPDEVICE $2
          fi
        fi
        if (is_mounted $2); then
          ui_print "- Mounting $1 to $2"
          break;
        fi
      fi
    done
  fi
}

grep_prop() {
  REGEX="s/^$1=//p"
  shift
  FILES=$@
  if [ -z "$FILES" ]; then
    FILES='/system/build.prop'
  fi
  cat $FILES 2>/dev/null | sed -n $REGEX | head -n 1
}

file_contain() {
  grep "$1" "$2" >/dev/null 2>&1
  return $?
}

unpack_boot() {
  rm -rf $UNPACKDIR $RAMDISK 2>/dev/null
  mkdir -p $UNPACKDIR
  mkdir -p $RAMDISK
  cd $UNPACKDIR
  LD_LIBRARY_PATH=$SYSTEMLIB $BINDIR/bootimgtools --extract $1

  [ ! -f $UNPACKDIR/ramdisk.gz ] && return 1

  cd $RAMDISK
  gunzip -c < $UNPACKDIR/ramdisk.gz | cpio -i
}

repack_boot() {
  if (! $SUPERSU); then
    cd $RAMDISK
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > $UNPACKDIR/ramdisk.gz
  fi
  cd $UNPACKDIR
  LD_LIBRARY_PATH=$SYSTEMLIB $BINDIR/bootimgtools --repack $BOOTIMAGE
  if [ -f chromeos ]; then
    cp -af $CHROMEDIR /data/magisk
    echo " " > config
    echo " " > bootloader
    LD_LIBRARY_PATH=$SYSTEMLIB $CHROMEDIR/futility vbutil_kernel --pack new-boot.img.signed --keyblock $CHROMEDIR/kernel.keyblock --signprivate $CHROMEDIR/kernel_data_key.vbprivk --version 1 --vmlinuz new-boot.img --config config --arch arm --bootloader bootloader --flags 0x1
    rm -f new-boot.img
    mv new-boot.img.signed new-boot.img
  fi
  if ($SAMSUNG); then
    SAMSUNG_CHECK=$(cat new-boot.img | grep SEANDROIDENFORCE)
    if [ $? -ne 0 ]; then
      echo -n "SEANDROIDENFORCE" >> new-boot.img
    fi
  fi
  if ($LGE_G); then
    # Prevent secure boot error on LG G2/G3.
    # Just for know, It's a pattern which bootloader verifies at boot. Thanks to LG hackers.
    echo -n -e "\x41\xa9\xe4\x67\x74\x4d\x1d\x1b\xa4\x29\xf2\xec\xea\x65\x52\x79" >> new-boot.img
  fi
  mv new-boot.img $NEWBOOT
}

remove_system_su() {
  if [ -f /system/bin/su -o -f /system/xbin/su ] && [ ! -f /su/bin/su ]; then
    ui_print "! System installed root detected, mount rw :("
    mount -o rw,remount /system
    # SuperSU
    if [ -e /system/bin/.ext/.su ]; then
      mv -f /system/bin/app_process32_original /system/bin/app_process32 2>/dev/null
      mv -f /system/bin/app_process64_original /system/bin/app_process64 2>/dev/null
      mv -f /system/bin/install-recovery_original.sh /system/bin/install-recovery.sh 2>/dev/null
      cd /system/bin
      if [ -e app_process64 ]; then
        ln -sf app_process64 app_process
      else
        ln -sf app_process32 app_process
      fi
    fi
    rm -rf /system/.pin /system/bin/.ext /system/etc/.installed_su_daemon /system/etc/.has_su_daemon \
    /system/xbin/daemonsu /system/xbin/su /system/xbin/sugote /system/xbin/sugote-mksh /system/xbin/supolicy \
    /system/bin/app_process_init /system/bin/su /cache/su /system/lib/libsupol.so /system/lib64/libsupol.so \
    /system/su.d /system/etc/install-recovery.sh /system/etc/init.d/99SuperSUDaemon /cache/install-recovery.sh \
    /system/.supersu /cache/.supersu /data/.supersu \
    /system/app/Superuser.apk /system/app/SuperSU /cache/Superuser.apk  2>/dev/null
  fi
}

##########################################################################################
# Detection
##########################################################################################

ui_print "*****************************"
ui_print "MAGISK_VERSION_STUB"
ui_print "*****************************"

if [ ! -d "$INSTALLER/common" ]; then
  ui_print "! Failed: Unable to extract zip file!"
  exit 1
fi

ui_print "- Mounting /system(ro), /cache, /data"
mount -o ro /system 2>/dev/null
mount /cache 2>/dev/null
mount /data 2>/dev/null

if [ ! -f '/system/build.prop' ]; then
  ui_print "! Failed: /system could not be mounted!"
  exit 1
fi

if [ -z "$NOOVERRIDE" ]; then
  # read override variables
  getvar KEEPVERITY
  getvar KEEPFORCEENCRYPT
  getvar BOOTIMAGE
fi

if [ -z "$KEEPVERITY" ]; then
  # we don't keep dm-verity by default
  KEEPVERITY=false
fi
if [ -z "$KEEPFORCEENCRYPT" ]; then
  # we don't keep forceencrypt by default
  KEEPFORCEENCRYPT=false
fi

# Check if system root is installed and remove
remove_system_su

SAMSUNG=false
SAMSUNG_CHECK=$(cat /system/build.prop | grep "ro.build.fingerprint=" | grep -i "samsung")
if [ $? -eq 0 ]; then
  SAMSUNG=true
fi

LGE_G=false
RBRAND=$(grep_prop ro.product.brand)
RMODEL=$(grep_prop ro.product.device)
if [ "$RBRAND" = "lge" ] || [ "$RBRAND" = "LGE" ];  then 
  if [ "$RMODEL" = "*D80*" ] || 
     [ "$RMODEL" = "*S98*" ] || 
     [ "$RMODEL" = "*D85*" ] ||
     [ "$RMODEL" = "*F40*" ]; then
    LGE_G=true
    ui_print "! Bump device detected"
  fi
fi

API=$(grep_prop ro.build.version.sdk)
ABI=$(grep_prop ro.product.cpu.abi | cut -c-3)
ABI2=$(grep_prop ro.product.cpu.abi2 | cut -c-3)
ABILONG=$(grep_prop ro.product.cpu.abi)

ARCH=arm
IS64BIT=false
if [ "$ABI" = "x86" ]; then ARCH=x86; fi;
if [ "$ABI2" = "x86" ]; then ARCH=x86; fi;
if [ "$ABILONG" = "arm64-v8a" ]; then ARCH=arm64; IS64BIT=true; fi;
if [ "$ABILONG" = "x86_64" ]; then ARCH=x64; IS64BIT=true; fi;


if [ "$API" -lt "21" ]; then
  ui_print "! Magisk is only for Lollipop 5.0+ (SDK 21+)"
  exit 1
fi

ui_print "- Device platform: $ARCH"

BINDIR=$INSTALLER/$ARCH
chmod -R 755 $CHROMEDIR/futility $BINDIR

SYSTEMLIB=/system/lib
($IS64BIT) && SYSTEMLIB=/system/lib64

find_boot_image
if [ -z "$BOOTIMAGE" ]; then
  ui_print "! Unable to detect boot image"
  exit 1
fi

##########################################################################################
# Environment
##########################################################################################

ui_print "- Constructing environment"

if (is_mounted /data); then
  rm -rf /data/magisk 2>/dev/null
  mkdir -p /data/magisk
  cp -af $BINDIR/busybox $BINDIR/sepolicy-inject $BINDIR/resetprop $BINDIR/bootimgtools \
         $INSTALLER/common/init.magisk.rc $INSTALLER/common/magic_mask.sh /data/magisk
  cp -af $INSTALLER/common/magisk.apk /data/magisk.apk
  chmod -R 755 /data/magisk
  chcon -h u:object_r:system_file:s0 /data/magisk /data/magisk/*
  PATH=/data/busybox:$PATH
else
  rm -rf /cache/data_bin 2>/dev/null
  mkdir -p /cache/data_bin
  cp -af $BINDIR/busybox $BINDIR/sepolicy-inject $BINDIR/resetprop $BINDIR/bootimgtools \
         $INSTALLER/common/custom_ramdisk_patch.sh $INSTALLER/common/init.magisk.rc \
         $INSTALLER/common/magic_mask.sh /cache/data_bin
  cp -af $INSTALLER/common/magisk.apk /cache/magisk.apk
  chmod -R 755 /cache/data_bin
fi

# Temporary busybox for installation
mkdir -p $TMPDIR/busybox
$BINDIR/busybox --install -s $TMPDIR/busybox
rm -f $TMPDIR/busybox/su $TMPDIR/busybox/sh $TMPDIR/busybox/reboot
PATH=$TMPDIR/busybox:$PATH


##########################################################################################
# Image
##########################################################################################

# Fix SuperSU.....
($BOOTMODE) && $BINDIR/sepolicy-inject --live "allow fsck * * *"

if (is_mounted /data); then
  IMG=/data/magisk.img
else
  IMG=/cache/magisk.img
  ui_print "- Data unavailable, use cache workaround"
fi

if [ -f $IMG ]; then
  ui_print "- $IMG detected!"
else
  ui_print "- Creating $IMG"
  make_ext4fs -l 64M -a /magisk -S $INSTALLER/common/file_contexts_image $IMG
fi

mount_image $IMG /magisk
if (! is_mounted /magisk); then
  ui_print "! Magisk image mount failed..."
  exit 1
fi
MAGISKLOOP=$LOOPDEVICE

# Core folders and scripts
mkdir -p $COREDIR/magiskhide $COREDIR/post-fs-data.d $COREDIR/service.d 2>/dev/null
cp -af $INSTALLER/common/magiskhide/. $BINDIR/magiskhide $COREDIR/magiskhide
chmod -R 755 $COREDIR/magiskhide $COREDIR/post-fs-data.d $COREDIR/service.d
chown -R 0.0 $COREDIR/magiskhide $COREDIR/post-fs-data.d $COREDIR/service.d

##########################################################################################
# Boot image patch
##########################################################################################

ui_print "- Found Boot Image: $BOOTIMAGE"

rm -rf $TMPDIR/boottmp 2>/dev/null
mkdir -p $TMPDIR/boottmp

ui_print "- Unpacking boot image"
unpack_boot $BOOTIMAGE
if [ $? -ne 0 ]; then
  ui_print "! Unable to unpack boot image"
  exit 1;
fi

ORIGBOOT=
SUPERSU=false
[ -f sbin/launch_daemonsu.sh ] && SUPERSU=true

if ($SUPERSU); then

  ##############################
  # SuperSU installation process
  ##############################

  ui_print "- SuperSU patched boot detected!"
  ui_print "- Adding auto patch script for SuperSU"
  cp -af $INSTALLER/common/custom_ramdisk_patch.sh /data/custom_ramdisk_patch.sh
  if (is_mounted /data); then
    SUIMG=/data/su.img
  else
    SUIMG=/cache/su.img
  fi
  mount_image $SUIMG /su
  if (! is_mounted /su); then
    ui_print "! SU image mount failed..."
    ui_print "! Please immediately flash SuperSU now"
    ui_print "! Installation will complete after flashing SuperSU"
    exit 1
  fi
  SUPERSULOOP=$LOOPDEVICE
  gunzip -c < $UNPACKDIR/ramdisk.gz > $UNPACKDIR/ramdisk
  ui_print "- Using sukernel to restore ramdisk"
  # Restore ramdisk
  LD_LIBRARY_PATH=$SYSTEMLIB /su/bin/sukernel --cpio-restore $UNPACKDIR/ramdisk $UNPACKDIR/ramdisk.orig
  if [ $? -ne 0 ]; then
    LD_LIBRARY_PATH=$SYSTEMLIB /su/bin/sukernel --restore $UNPACKDIR/ramdisk $TMPDIR/boottmp/stock_boot.img
    if [ $? -ne 0 ]; then
      ui_print "! Unable to restore ramdisk"
      exit 1
    fi
    LD_LIBRARY_PATH=$SYSTEMLIB /su/bin/sukernel --bootimg-extract-ramdisk $TMPDIR/boottmp/stock_boot.img $UNPACKDIR/ramdisk.orig.gz
    LD_LIBRARY_PATH=$SYSTEMLIB /su/bin/sukernel --ungzip $UNPACKDIR/ramdisk.orig.gz $UNPACKDIR/ramdisk.orig
  fi
  if [ ! -f $UNPACKDIR/ramdisk.orig ]; then
    ui_print "! Unable to restore ramdisk"
    exit 1
  fi
  rm -f $TMPDIR/boottmp/stock_boot.img $UNPACKDIR/ramdisk.orig.gz $UNPACKDIR/ramdisk.gz 2>/dev/null
  ui_print "- Patching ramdisk with sukernel"
  sh /data/custom_ramdisk_patch.sh $UNPACKDIR/ramdisk
  LD_LIBRARY_PATH=$SYSTEMLIB /su/bin/sukernel --cpio-backup $UNPACKDIR/ramdisk.orig $UNPACKDIR/ramdisk $UNPACKDIR/ramdisk
  gzip -9 < $UNPACKDIR/ramdisk > $UNPACKDIR/ramdisk.gz
  rm -f $UNPACKDIR/ramdisk $UNPACKDIR/ramdisk.orig

else

  ##############################
  # Magisk installation process
  ##############################

  # Ramdisk restore
  if [ -d ".backup" ]; then
    # This implies Magisk is already installed, and ramdisk backup exists
    ui_print "- Restoring ramdisk with ramdisk backup"
    cp -af .backup/. .
    rm -rf magisk init.magisk.rc sbin/magic_mask.sh 2>/dev/null
    ORIGBOOT=false
  elif [ -d "magisk" ]; then
    mv -f /data/stock_boot_*.gz /data/stock_boot.img.gz 2>/dev/null
    gzip -d /data/stock_boot.img.gz 2>/dev/null
    rm -f /data/stock_boot.img.gz 2>/dev/null
    [ -f /data/stock_boot.img ] && ORIGBOOT=/data/stock_boot.img
    # If Magisk is installed and no SuperSU and no ramdisk backups,
    # we restore previous stock boot image backups
    if [ ! -z $ORIGBOOT ]; then
      ui_print "- Restoring boot image with backup"
      unpack_boot $ORIGBOOT
    fi
    # Removing possible modifications
    rm -rf magisk init.magisk.rc sbin/magic_mask.sh sbin/su init.xposed.rc sbin/mount_xposed.sh 2>/dev/null
    ORIGBOOT=false
  fi

  # Backups
  ui_print "- Creating ramdisk backup"
  mkdir .backup 2>/dev/null
  cp -af *fstab* verity_key sepolicy .backup 2>/dev/null
  if [ -z $ORIGBOOT ]; then
    ui_print "- Creating boot image backup"
    if (is_mounted /data); then
      dd if=$BOOTIMAGE of=/data/stock_boot.img
    else
      dd if=$BOOTIMAGE of=/cache/stock_boot.img
    fi
  fi

  # MagiskSU
  ui_print "- Installing MagiskSU"
  mkdir -p $COREDIR/su 2>/dev/null
  cp -af $BINDIR/su $INSTALLER/common/magisksu.sh $COREDIR/su
  chmod 755 $COREDIR/su/su $COREDIR/su/magisksu.sh
  chown -R 0.0 $COREDIR/su/su $COREDIR/su/magisksu.sh

  # Patch ramdisk
  ui_print "- Patching ramdisk"

  # Add magisk entrypoints
  for RC in init*.rc; do
    if file_contain "import /init.environ.rc" $RC && ! file_contain "import /init.magisk.rc" $RC; then
      [ ! -f .backup/$RC ] && cp -af $RC .backup
      sed -i "/import \/init\.environ\.rc/iimport /init.magisk.rc" $RC
    fi
    if file_contain "selinux.reload_policy" $RC; then
      [ ! -f .backup/$RC ] && cp -af $RC .backup
      sed -i "/selinux.reload_policy/d" $RC
    fi
  done

  for FSTAB in *fstab*; do
    [ -L $FSTAB ] && continue
    if (! $KEEPVERITY); then
      sed -i "s/,support_scfs//g" $FSTAB
      sed -i 's/,\{0,1\}verify\(=[^,]*\)\{0,1\}//g' $FSTAB
    fi
    if (! $KEEPFORCEENCRYPT); then
      sed -i "s/forceencrypt/encryptable/g" $FSTAB
      sed -i "s/forcefdeorfbe/encryptable/g" $FSTAB
    fi
  done
  if (! $KEEPVERITY); then
    rm verity_key 2>/dev/null
  fi

  # minimal sepolicy patches
  LD_LIBRARY_PATH=$SYSTEMLIB $BINDIR/sepolicy-inject --load sepolicy --save sepolicy --minimal

  # Add new items
  mkdir -p magisk 2>/dev/null
  cp -af $INSTALLER/common/init.magisk.rc init.magisk.rc
  cp -af $INSTALLER/common/magic_mask.sh sbin/magic_mask.sh

  chmod 0755 magisk
  chmod 0750 init.magisk.rc sbin/magic_mask.sh
  chown 0.0 magisk init.magisk.rc sbin/magic_mask.sh
fi

ui_print "- Repacking boot image"
repack_boot

BOOTSIZE=`blockdev --getsize64 $BOOTIMAGE 2>/dev/null`
NEWSIZE=`ls -l $NEWBOOT | awk '{print $5}'`
if [ "$NEWSIZE" -gt "$BOOTSIZE" ]; then
  ui_print "! Boot partition space insufficient"
  ui_print "! Remove ramdisk backups and try again"
  rm -rf $RAMDISK/.backup $NEWBOOT 2>/dev/null
  repack_boot
  NEWSIZE=`ls -l $NEWBOOT | awk '{print $5}'`
  if [ "$NEWSIZE" -gt "$BOOTSIZE" ]; then
    ui_print "! Boot partition size still too small..."
    ui_print "! Unable to install Magisk"
    exit 1
  fi
fi

chmod 644 $NEWBOOT

ui_print "- Flashing new boot image"
[ ! -L $BOOTIMAGE ] && dd if=/dev/zero of=$BOOTIMAGE bs=4096 2>/dev/null
dd if=$NEWBOOT of=$BOOTIMAGE bs=4096

cd /

if (! $BOOTMODE); then
  ui_print "- Unmounting partitions"
  umount /magisk
  losetup -d $MAGISKLOOP
  rmdir /magisk
  if ($SUPERSU); then
    umount /su
    losetup -d $SUPERSULOOP
    rmdir /su
  fi
  umount /system
fi

ui_print "- Done"
exit 0
