#!/system/bin/sh
MODDIR=${0%/*}

# Reset any failed boot counter and re-enable preinit if disabled
if [ -x /data/adb/ksu/bin/ksud ]; then
    /data/adb/ksu/bin/ksud module preinit reset 2>/dev/null
fi

# Ensure preinit binaries always have execute permissions
if [ -d "/metadata/vold/ksu/preinit/lh8n_undervolt/bin" ]; then
    chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/bin/* 2>/dev/null
fi
if [ -f "$MODDIR/preinit/bin/mount_dvfs" ]; then
    chmod 755 "$MODDIR/preinit/bin/mount_dvfs" 2>/dev/null
fi

# Ensure preinit files are populated and synchronized
mkdir -p /metadata/vold/ksu/preinit/lh8n_undervolt/bin
mkdir -p /metadata/vold/ksu/preinit/lh8n_undervolt/kmod

if [ -f "$MODDIR/preinit/bin/mount_dvfs" ]; then
    cp "$MODDIR/preinit/bin/mount_dvfs" /metadata/vold/ksu/preinit/lh8n_undervolt/bin/mount_dvfs
    chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/bin/mount_dvfs
fi

if [ -f "$MODDIR/preinit/kmod/CPU_DVFS.ko" ]; then
    cp "$MODDIR/preinit/kmod/CPU_DVFS.ko" /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/CPU_DVFS.ko
    chmod 644 /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/CPU_DVFS.ko
fi

if [ -f "$MODDIR/preinit/kmod/mtk_gpufreq_mt6833.ko" ]; then
    cp "$MODDIR/preinit/kmod/mtk_gpufreq_mt6833.ko" /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/mtk_gpufreq_mt6833.ko
    chmod 644 /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/mtk_gpufreq_mt6833.ko
fi

if [ -f "$MODDIR/preinit/kmod/Upower.ko" ]; then
    cp "$MODDIR/preinit/kmod/Upower.ko" /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/Upower.ko
    chmod 644 /metadata/vold/ksu/preinit/lh8n_undervolt/kmod/Upower.ko
fi

if [ -f "$MODDIR/preinit/preinit.conf" ]; then
    cp "$MODDIR/preinit/preinit.conf" /metadata/vold/ksu/preinit/lh8n_undervolt/preinit.conf
    chmod 644 /metadata/vold/ksu/preinit/lh8n_undervolt/preinit.conf
fi

if [ -f /metadata/vold/ksu/preinit/.manifest ]; then
    sed -i "s|644\tbin/mount_dvfs|755\tbin/mount_dvfs|" /metadata/vold/ksu/preinit/.manifest 2>/dev/null
    chmod 644 /metadata/vold/ksu/preinit/.manifest 2>/dev/null
fi

# Enforce strict root-only ownership and non-writable permissions for KernelSU preinit
chown -R 0:0 /metadata/vold/ksu/preinit/lh8n_undervolt
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/bin
chmod 755 /metadata/vold/ksu/preinit/lh8n_undervolt/kmod

# Dynamic PowerHAL powerhint.json Patcher
# Automatically adapts to whatever powerhint.json the installed ROM provides
PATCHER="$MODDIR/tools/patch_powerhint"
SRC_JSON="/vendor/etc/powerhint.json"
TARGET_DIR="$MODDIR/system/vendor/etc"
TARGET_JSON="$TARGET_DIR/powerhint.json"
VENDOR_DIR="$MODDIR/vendor/etc"
VENDOR_JSON="$VENDOR_DIR/powerhint.json"
MD5_FILE="$MODDIR/.powerhint_src_md5"

if [ -f "$SRC_JSON" ] && [ -x "$PATCHER" ]; then
    CUR_MD5=$(md5sum "$SRC_JSON" 2>/dev/null | awk '{print $1}')
    OLD_MD5=$(cat "$MD5_FILE" 2>/dev/null || echo "")

    if [ "$CUR_MD5" != "$OLD_MD5" ] || [ ! -f "$TARGET_JSON" ]; then
        mkdir -p "$TARGET_DIR" "$VENDOR_DIR"
        if "$PATCHER" "$SRC_JSON" "$TARGET_JSON" >/dev/null 2>&1; then
            cp "$TARGET_JSON" "$VENDOR_JSON"
            chmod 644 "$TARGET_JSON" "$VENDOR_JSON"
            echo "$CUR_MD5" > "$MD5_FILE"
        fi
    fi
fi

# Bind-mount patched powerhint.json early so PowerHAL reads patched configuration at boot
if [ -f "$VENDOR_JSON" ]; then
    mount -o bind "$VENDOR_JSON" /vendor/etc/powerhint.json 2>/dev/null
fi


