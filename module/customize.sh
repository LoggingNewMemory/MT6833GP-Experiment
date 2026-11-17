#!/system/bin/sh

ui_print "- Installing TECNO LH8n UnderVolt & UnderClock"
ui_print "- Version: v1.7"
ui_print "- Author: Kana Wesley Yamada"

# 1. Check root environment (Preinit requires KernelSU or SukiSU)
if [ ! -x /data/adb/ksu/bin/ksud ]; then
    ui_print "! Error: KernelSU / SukiSU not detected!"
    ui_print "! This module requires early-boot preinit to swap kernel drivers."
    ui_print "! Magisk and APatch are not supported."
    abort "! Installation aborted: unsupported root environment."
fi

# 2. Check /metadata partition
if [ ! -d /metadata ]; then
    ui_print "! Error: /metadata partition not found or not mounted!"
    ui_print "! Preinit files must reside on /metadata to execute before init."
    abort "! Installation aborted: missing /metadata partition."
fi

# 3. Reset any failed preinit bootcounts so safe-mode doesn't block it
ui_print "- Checking KernelSU / SukiSU preinit capability..."
/data/adb/ksu/bin/ksud module preinit reset 2>/dev/null

# 4. Check kernel preinit support via ksud
PREINIT_STATUS=$(/data/adb/ksu/bin/ksud module preinit status 2>&1)
if echo "$PREINIT_STATUS" | grep -q "kernel does not run preinit"; then
    ui_print "! Error: Your kernel does not support module preinit!"
    ui_print "! The preinit hook is missing from your boot image/kernel."
    ui_print "! Please ask your kernel or ROM maintainer for a preinit-enabled build."
    abort "! Installation aborted: kernel lacks preinit support."
fi

if ! echo "$PREINIT_STATUS" | grep -q "preinit:"; then
    ui_print "! Error: Unable to verify preinit capability."
    ui_print "! Status: $PREINIT_STATUS"
    abort "! Installation aborted: preinit check failed."
fi

ui_print "- Preinit verified: supported and ready!"
ui_print "- Setting up CPU & GPU DVFS modules..."

# Setup preinit files in /metadata partition
mkdir -p /metadata/vold/ksu/preinit/lh8n_undervolt/bin
mkdir -p /metadata/vold/ksu/preinit/lh8n_undervolt/kmod

if [ -f "$MODPATH/preinit/bin/mount_dvfs" ]; then
    cp "$MODPATH/preinit/bin/mount_dvfs" /metadata/vold/ksu/preinit/lh8n_undervolt/bin/mount_dvfs
fi

if [ -f "$MODPATH/preinit/kmod/CPU_DVFS.ko" ]; then
    cp "$MODPATH/preinit/kmod/CPU_DVFS.ko" /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/CPU_DVFS.ko
fi

if [ -f "$MODPATH/preinit/kmod/mtk_gpufreq_mt6833.ko" ]; then
    cp "$MODPATH/preinit/kmod/mtk_gpufreq_mt6833.ko" /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/mtk_gpufreq_mt6833.ko
fi

if [ -f "$MODPATH/preinit/preinit.conf" ]; then
    cp "$MODPATH/preinit/preinit.conf" /metadata/vold/ksu/preinit/lh8n_undervolt/preinit.conf
fi

# Set strict permissions required by KernelSU preinit
chown -R 0:0 /metadata/vold/ksu/preinit/lh8n_undervolt
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/bin
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/bin/mount_dvfs 2>/dev/null
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/kmod
chmod 644 /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/* 2>/dev/null
chmod 644 /metadata/vold/ksu/preinit/lh8n_undervolt/preinit.conf 2>/dev/null

if [ -f /metadata/vold/ksu/preinit/.manifest ]; then
    sed -i "s|644\tbin/mount_dvfs|755\tbin/mount_dvfs|" /metadata/vold/ksu/preinit/.manifest 2>/dev/null
    chmod 644 /metadata/vold/ksu/preinit/.manifest 2>/dev/null
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/preinit/bin/mount_dvfs" 0 0 0755

ui_print "- Installation complete! Reboot to apply."
