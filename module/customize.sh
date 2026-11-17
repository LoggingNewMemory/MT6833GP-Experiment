#!/system/bin/sh

ui_print "- Installing TECNO LH8n Triple UnderVolt, EAS & PPM Policy Tuning"
ui_print "- Version: v2.3"
ui_print "- Targets: CPU (-50mV), GPU (-50mV), DVFSRC Vcore (-75mV), EAS & PPM Arbitration"
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

# ==============================================================================
# Step 1: Deploy CPU & GPU DVFS modules to Preinit
# ==============================================================================
ui_print "- Deploying CPU (-50mV) & GPU (-50mV) preinit modules..."

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

if [ -f "$MODPATH/preinit/kmod/Upower.ko" ]; then
    cp "$MODPATH/preinit/kmod/Upower.ko" /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/Upower.ko
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

# ==============================================================================
# Step 2: Bare-Metal Partition Patching for DVFSRC Vcore (vendor_boot)
# ==============================================================================
ui_print "- Checking vendor_boot partition for DVFSRC Vcore..."

SLOT=$(getprop ro.boot.slot_suffix)
if [ -z "$SLOT" ]; then
    SLOT="_$(getprop ro.boot.slot)"
fi
[ "$SLOT" = "_" ] && SLOT=""

VB_DEV="/dev/block/by-name/vendor_boot${SLOT}"
if [ ! -e "$VB_DEV" ]; then
    VB_DEV="/dev/block/bootdevice/by-name/vendor_boot${SLOT}"
fi

MAGISKBOOT="$MODPATH/tools/magiskboot"
chmod 755 "$MAGISKBOOT" 2>/dev/null

if [ -e "$VB_DEV" ] && [ -x "$MAGISKBOOT" ] && [ -f "$MODPATH/kmod/mtk-dvfsrc.ko" ]; then
    BACKUP_DIR="/data/adb/lh8n_backup"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="${BACKUP_DIR}/vendor_boot_stock${SLOT}.img"

    if [ ! -f "$BACKUP_FILE" ]; then
        ui_print "- Creating stock backup of vendor_boot..."
        dd if="$VB_DEV" of="$BACKUP_FILE" bs=1M 2>/dev/null
        ui_print "- Stock backup preserved: $BACKUP_FILE"
    else
        ui_print "- Stock backup already exists: $BACKUP_FILE"
    fi

    ui_print "- Patching vendor_boot ramdisk (DVFSRC Vcore capped @ 650mV)..."
    WORK_DIR="/data/local/tmp/vb_patch_$$"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || true

    dd if="$VB_DEV" of=vendor_boot.img bs=1M 2>/dev/null
    "$MAGISKBOOT" unpack vendor_boot.img >/dev/null 2>&1

    CPIO_PATH=""
    if [ -f "vendor_ramdisk/ramdisk.cpio" ]; then
        CPIO_PATH="vendor_ramdisk/ramdisk.cpio"
    elif [ -f "ramdisk.cpio" ]; then
        CPIO_PATH="ramdisk.cpio"
    fi

    if [ -n "$CPIO_PATH" ]; then
        # Replace DVFSRC modules (core driver, regulator clamp, helper table) with 650mV-capped suite
        "$MAGISKBOOT" cpio "$CPIO_PATH" "add 0644 lib/modules/mtk-dvfsrc.ko $MODPATH/kmod/mtk-dvfsrc.ko" >/dev/null 2>&1
        if [ -f "$MODPATH/kmod/mtk-dvfsrc-regulator.ko" ]; then
            "$MAGISKBOOT" cpio "$CPIO_PATH" "add 0644 lib/modules/mtk-dvfsrc-regulator.ko $MODPATH/kmod/mtk-dvfsrc-regulator.ko" >/dev/null 2>&1
        fi
        if [ -f "$MODPATH/kmod/mtk-dvfsrc-helper.ko" ]; then
            "$MAGISKBOOT" cpio "$CPIO_PATH" "add 0644 lib/modules/mtk-dvfsrc-helper.ko $MODPATH/kmod/mtk-dvfsrc-helper.ko" >/dev/null 2>&1
        fi
        "$MAGISKBOOT" repack vendor_boot.img new-boot.img >/dev/null 2>&1

        if [ -f "new-boot.img" ] && [ $(stat -c%s new-boot.img 2>/dev/null || echo 0) -gt 10000000 ]; then
            ui_print "- Writing patched vendor_boot to $VB_DEV..."
            dd if=new-boot.img of="$VB_DEV" bs=1M 2>/dev/null
            sync; sync; sync
            ui_print "- DVFSRC Vcore successfully patched to 650.00 mV (-75.00 mV)!"
        else
            ui_print "! Warning: Repacked boot image check failed. vendor_boot untouched."
        fi
    else
        ui_print "! Warning: Unable to locate ramdisk.cpio. Skipping vendor_boot patch."
    fi

    cd /
    rm -rf "$WORK_DIR"
else
    ui_print "! Notice: vendor_boot device or tools not found. Skipping Vcore partition patch."
fi

# ==============================================================================
# Step 3: Set module file permissions
# ==============================================================================
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/tools/magiskboot" 0 0 0755
set_perm "$MODPATH/tools/patch_powerhint" 0 0 0755
set_perm "$MODPATH/preinit/bin/mount_dvfs" 0 0 0755

# ==============================================================================
# Step 4: Generate dynamic PowerHAL powerhint patch from installed ROM
# ==============================================================================
ui_print "- Inspecting ROM PowerHAL configuration..."
PATCHER="$MODPATH/tools/patch_powerhint"
SRC_JSON="/vendor/etc/powerhint.json"
TARGET_DIR="$MODPATH/system/vendor/etc"
TARGET_JSON="$TARGET_DIR/powerhint.json"
VENDOR_DIR="$MODPATH/vendor/etc"
VENDOR_JSON="$VENDOR_DIR/powerhint.json"
MD5_FILE="$MODPATH/.powerhint_src_md5"

chmod 755 "$PATCHER" 2>/dev/null

if [ -f "$SRC_JSON" ] && [ -x "$PATCHER" ]; then
    mkdir -p "$TARGET_DIR" "$VENDOR_DIR"
    if "$PATCHER" "$SRC_JSON" "$TARGET_JSON"; then
        cp "$TARGET_JSON" "$VENDOR_JSON"
        chmod 644 "$TARGET_JSON" "$VENDOR_JSON"
        md5sum "$SRC_JSON" 2>/dev/null | awk '{print $1}' > "$MD5_FILE"
        ui_print "- Dynamic powerhint.json successfully generated from ROM!"
    else
        ui_print "! Warning: Failed to patch /vendor/etc/powerhint.json; skipping overlay."
    fi
else
    ui_print "- No /vendor/etc/powerhint.json found or patcher missing; skipping overlay."
fi

ui_print "- All components installed successfully!"
ui_print "- Reboot to apply CPU (-50mV), GPU (-50mV), and Vcore (-75mV)."
