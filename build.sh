#!/bin/bash
# ==============================================================================
# Build Script for MT6833 Undervolt & Underclock Module
# Author: Kana Wesley Yamada
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOCK_DIR="${SCRIPT_DIR}/stock"
OUT_DIR="${SCRIPT_DIR}/out"
MODULE_SRC="${SCRIPT_DIR}/module"

echo "================================================================="
echo "       MT6833GP-Experiment: Kernel Module Builder & Patcher       "
echo "================================================================="

# Check input stock modules
if [ ! -f "${STOCK_DIR}/CPU_DVFS.ko" ] || [ ! -f "${STOCK_DIR}/mtk_gpufreq_mt6833.ko" ]; then
    echo "[-] Error: Missing stock kernel modules in ${STOCK_DIR}/"
    echo "    Please extract stock modules from your device:"
    echo "      adb pull /vendor/lib/modules/CPU_DVFS.ko ${STOCK_DIR}/"
    echo "      adb pull /vendor/lib/modules/mtk_gpufreq_mt6833.ko ${STOCK_DIR}/"
    exit 1
fi

mkdir -p "${OUT_DIR}"

echo "[*] Step 1: Patching CPU_DVFS.ko (200MHz underclock + -50.00mV + EEM bypass)..."
python3 "${SCRIPT_DIR}/scripts/patch_dvfs.py" \
    -i "${STOCK_DIR}/CPU_DVFS.ko" \
    -o "${OUT_DIR}/CPU_DVFS.ko"

echo "[*] Step 2: Patching mtk_gpufreq_mt6833.ko (-50.00mV Mali-G57 OPPs)..."
python3 "${SCRIPT_DIR}/scripts/patch_gpufreq.py" \
    -i "${STOCK_DIR}/mtk_gpufreq_mt6833.ko" \
    -o "${OUT_DIR}/mtk_gpufreq_mt6833.ko"

# Step 2.5: Optional DVFSRC modules patch
if [ -d "${STOCK_DIR}/dvfsrc_modules" ] && [ -f "${STOCK_DIR}/dvfsrc_modules/mtk-dvfsrc.ko" ]; then
    echo "[*] Step 2.5: Patching DVFSRC ramdisk modules (650.00mV cap)..."
    mkdir -p "${OUT_DIR}/dvfsrc_modules"
    for mod in mtk-dvfsrc.ko mtk-dvfsrc-regulator.ko mtk-dvfsrc-helper.ko; do
        if [ -f "${STOCK_DIR}/dvfsrc_modules/${mod}" ]; then
            python3 "${SCRIPT_DIR}/scripts/patch_dvfsrc.py" \
                -i "${STOCK_DIR}/dvfsrc_modules/${mod}" \
                -o "${OUT_DIR}/dvfsrc_modules/${mod}"
        fi
    done
fi

# Step 2.7: EAS Energy Model & PPM Power Policy patch
if [ -f "${STOCK_DIR}/Upower.ko" ]; then
    echo "[*] Step 2.7: Patching Upower.ko (EAS energy model & PPM calibration)..."
    python3 "${SCRIPT_DIR}/scripts/patch_upower.py" \
        -i "${STOCK_DIR}/Upower.ko" \
        -o "${OUT_DIR}/Upower.ko"
fi

echo "[*] Step 3: Preparing module payload..."
TEMP_MODULE="$(mktemp -d)"
cp -r "${MODULE_SRC}/." "${TEMP_MODULE}/"

# Populate kernel modules
mkdir -p "${TEMP_MODULE}/vendor/lib/modules" \
         "${TEMP_MODULE}/system/vendor/lib/modules" \
         "${TEMP_MODULE}/preinit/kmod" \
         "${TEMP_MODULE}/kmod" \
         "${TEMP_MODULE}/tools"

cp "${OUT_DIR}/CPU_DVFS.ko" "${TEMP_MODULE}/vendor/lib/modules/"
cp "${OUT_DIR}/CPU_DVFS.ko" "${TEMP_MODULE}/system/vendor/lib/modules/"
cp "${OUT_DIR}/CPU_DVFS.ko" "${TEMP_MODULE}/preinit/kmod/"

cp "${OUT_DIR}/mtk_gpufreq_mt6833.ko" "${TEMP_MODULE}/vendor/lib/modules/"
cp "${OUT_DIR}/mtk_gpufreq_mt6833.ko" "${TEMP_MODULE}/system/vendor/lib/modules/"
cp "${OUT_DIR}/mtk_gpufreq_mt6833.ko" "${TEMP_MODULE}/preinit/kmod/"

if [ -f "${OUT_DIR}/Upower.ko" ]; then
    cp "${OUT_DIR}/Upower.ko" "${TEMP_MODULE}/vendor/lib/modules/"
    cp "${OUT_DIR}/Upower.ko" "${TEMP_MODULE}/system/vendor/lib/modules/"
    cp "${OUT_DIR}/Upower.ko" "${TEMP_MODULE}/preinit/kmod/"
fi

if [ -d "${OUT_DIR}/dvfsrc_modules" ]; then
    cp "${OUT_DIR}/dvfsrc_modules/"*.ko "${TEMP_MODULE}/kmod/"
fi

# Copy check_voltage tool into package
cp "${SCRIPT_DIR}/scripts/check_voltage.sh" "${TEMP_MODULE}/"
chmod +x "${TEMP_MODULE}/check_voltage.sh"

echo "[*] Step 4: Packaging flashable zip..."
VERSION=$(grep "^version=" "${MODULE_SRC}/module.prop" | cut -d= -f2)
ZIP_NAME="${OUT_DIR}/LH8nUnderVolt_${VERSION}.zip"
rm -f "${ZIP_NAME}"
(cd "${TEMP_MODULE}" && zip -r9 "${ZIP_NAME}" .)
rm -rf "${TEMP_MODULE}"

echo ""
echo "[+] Build complete!"
echo "    Flashable ZIP: ${ZIP_NAME}"
echo "    MD5: $(md5sum "${ZIP_NAME}" | awk '{print $1}')"
echo "================================================================="
