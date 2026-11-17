#!/system/bin/sh
# uninstall.sh - Cleanup and restore stock vendor_boot partition on module removal

SLOT=$(getprop ro.boot.slot_suffix)
if [ -z "$SLOT" ]; then
    SLOT="_$(getprop ro.boot.slot)"
fi
[ "$SLOT" = "_" ] && SLOT=""

VB_DEV="/dev/block/by-name/vendor_boot${SLOT}"
if [ ! -e "$VB_DEV" ]; then
    VB_DEV="/dev/block/bootdevice/by-name/vendor_boot${SLOT}"
fi

BACKUP_FILE="/data/adb/lh8n_backup/vendor_boot_stock${SLOT}.img"

# 1. Restore vendor_boot partition if backup exists
if [ -f "$BACKUP_FILE" ] && [ -e "$VB_DEV" ]; then
    dd if="$BACKUP_FILE" of="$VB_DEV" bs=1M 2>/dev/null
fi

# 2. Clean up preinit directory from /metadata
rm -rf /metadata/vold/ksu/preinit/lh8n_undervolt

# 3. Clean up backup directory if empty
rm -f "$BACKUP_FILE"
rmdir /data/adb/lh8n_backup 2>/dev/null

exit 0
