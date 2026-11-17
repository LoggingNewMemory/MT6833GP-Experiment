#!/system/bin/sh
# ==============================================================================
# TECNO LH8n Hardware Voltage & Frequency Monitor
# Target: MediaTek MT6833 / Dimensity 6080 (MT6359 PMIC)
# Author: Kana Wesley Yamada
# Usage: su -c /path/to/check_voltage.sh (or run directly in su shell)
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: Root privileges required. Please run with 'su'."
    exit 1
fi

fmt_mv() {
    uv="$1"
    if [ -z "$uv" ] || [ "$uv" -le 0 ] 2>/dev/null; then
        echo "0.00 mV (OFF)"
        return
    fi
    mv=$(( uv / 1000 ))
    dec=$(( (uv % 1000) / 10 ))
    printf "%4d.%02d mV (%d uV)\n" "$mv" "$dec" "$uv"
}

# --- 1-Pass Fast Regulator Discovery ---
reg_vgpu11=""
reg_vproc2=""
reg_vsram_proc1=""
reg_vsram_proc2=""
reg_vproc1=""
reg_vsram_md=""
reg_vsram_others=""
reg_vcore=""
reg_dvfsrc=""

for r in /sys/class/regulator/regulator.*; do
    if [ -f "$r/name" ]; then
        rname=$(cat "$r/name" 2>/dev/null)
        case "$rname" in
            vgpu11) reg_vgpu11="$r/microvolts" ;;
            vproc2) reg_vproc2="$r/microvolts" ;;
            vsram_proc1) reg_vsram_proc1="$r/microvolts" ;;
            vsram_proc2) reg_vsram_proc2="$r/microvolts" ;;
            vproc1) reg_vproc1="$r/microvolts" ;;
            vsram_md) reg_vsram_md="$r/microvolts" ;;
            vsram_others) reg_vsram_others="$r/microvolts" ;;
            vcore) reg_vcore="$r/microvolts" ;;
            dvfsrc-vcore) reg_dvfsrc="$r/microvolts" ;;
        esac
    fi
done

clear 2>/dev/null || true
echo "================================================================="
echo "       TECNO LH8n Hardware Voltage & Frequency Monitor           "
echo "================================================================="
echo "Timestamp: $(date)"
echo "Target:    MT6833 Dimensity 6080 | MT6359 PMIC"
echo "-----------------------------------------------------------------"

# Note on MT6833 / MT6359 PMIC Pin Mapping:
# In MT6833 Device Tree:
# - mt_cpufreq proc1-supply (Little CPU) -> buck_vgpu11 (regulator.9)
# - mt_cpufreq proc2-supply (Big CPU)    -> buck_vproc2 (regulator.15)
# - mt_cpufreq sram_proc1   (L Cache)    -> ldo_vsram_proc1 (regulator.48)
# - mt_cpufreq sram_proc2   (B Cache)    -> ldo_vsram_proc2 (regulator.23)
# - gpufreq    _vgpu-supply (GPU Core)   -> buck_vproc1 (regulator.16)
# - gpufreq    _vsram_gpu   (GPU SRAM)   -> ldo_vsram_md (regulator.44)
# - dvfsrc-vcore                         -> dvfsrc-vcore (regulator.3)

# --- 1. CPU Power Rails ---
echo ""
echo "[ CPU Logic & Cache Rails ]"
echo "-----------------------------------------------------------------"
cpu_little_uv=$(cat "$reg_vgpu11" 2>/dev/null || echo 0)
cpu_big_uv=$(cat "$reg_vproc2" 2>/dev/null || echo 0)
vsram1_uv=$(cat "$reg_vsram_proc1" 2>/dev/null || echo 0)
vsram2_uv=$(cat "$reg_vsram_proc2" 2>/dev/null || echo 0)

printf "  %-22s : %s\n" "Little CPU (buck_vgpu11)" "$(fmt_mv "$cpu_little_uv")"
printf "  %-22s : %s\n" "Big CPU    (buck_vproc2)" "$(fmt_mv "$cpu_big_uv")"
printf "  %-22s : %s\n" "L Cache    (vsram_proc1)" "$(fmt_mv "$vsram1_uv")"
printf "  %-22s : %s\n" "B Cache    (vsram_proc2)" "$(fmt_mv "$vsram2_uv")"

if [ -f /proc/cpufreq/MT_CPU_DVFS_LL/cpufreq_oppidx ]; then
    ll_opp0=$(sed -n '3p' /proc/cpufreq/MT_CPU_DVFS_LL/cpufreq_oppidx 2>/dev/null | tr -d '\t ')
    l_opp0=$(sed -n '3p' /proc/cpufreq/MT_CPU_DVFS_L/cpufreq_oppidx 2>/dev/null | tr -d '\t ')
    echo "  Little OPP 0 (Max)     : $ll_opp0"
    echo "  Big OPP 0    (Max)     : $l_opp0"
fi

# --- 2. GPU Power Rails ---
echo ""
echo "[ GPU Power Rails (Mali-G57 MC2) ]"
echo "-----------------------------------------------------------------"
gpu_core_uv=$(cat "$reg_vproc1" 2>/dev/null || echo 0)
gpu_sram_uv=$(cat "$reg_vsram_md" 2>/dev/null || echo 0)
gpu_sram_alt_uv=$(cat "$reg_vsram_others" 2>/dev/null || echo 0)

printf "  %-22s : %s\n" "GPU Core   (buck_vproc1)" "$(fmt_mv "$gpu_core_uv")"
printf "  %-22s : %s\n" "GPU SRAM   (vsram_md)   " "$(fmt_mv "$gpu_sram_uv")"
printf "  %-22s : %s\n" "GPU SRAM2  (vsram_others)" "$(fmt_mv "$gpu_sram_alt_uv")"

if [ "$gpu_sram_alt_uv" -gt 0 ] && [ "$gpu_core_uv" -gt 0 ] 2>/dev/null; then
    delta=$(( gpu_sram_alt_uv - gpu_core_uv ))
    is_neg=0
    if [ "$delta" -lt 0 ]; then
        is_neg=1
        delta=$(( -delta ))
    fi
    delta_mv=$(( delta / 1000 ))
    delta_dec=$(( (delta % 1000) / 10 ))
    if [ "$is_neg" -eq 1 ]; then
        printf "  %-22s : -%d.%02d mV (Limit <= 200.00 mV)\n" "Delta (Vsram-Vgpu)" "$delta_mv" "$delta_dec"
    else
        printf "  %-22s :  %d.%02d mV (Limit <= 200.00 mV)\n" "Delta (Vsram-Vgpu)" "$delta_mv" "$delta_dec"
    fi
fi

# --- 3. SoC Core & DVFSRC Rails ---
echo ""
echo "[ SoC Core & DVFSRC Rails ]"
echo "-----------------------------------------------------------------"
vcore_uv=$(cat "$reg_vcore" 2>/dev/null || echo 0)
dvfsrc_uv=$(cat "$reg_dvfsrc" 2>/dev/null || echo 0)

printf "  %-22s : %s\n" "vcore      (buck_vcore) " "$(fmt_mv "$vcore_uv")"
printf "  %-22s : %s\n" "dvfsrc     (dvfsrc-vcore)" "$(fmt_mv "$dvfsrc_uv")"

# Read DVFSRC sysfs dump
dvfsrc_dump_path="/sys/devices/platform/10012000.dvfsrc/helio-dvfsrc/dvfsrc_dump"
if [ -f "$dvfsrc_dump_path" ]; then
    opp_val=$(grep "CURR_VCORE_OPP" "$dvfsrc_dump_path" 2>/dev/null | awk '{print $3}')
    sw_req=$(grep "SW_REQ 1~4" "$dvfsrc_dump_path" 2>/dev/null | awk '{print $4}' | tr -d ',')
    printf "  %-22s : Level %s (SW_REQ 3: %s)\n" "DVFSRC Vcore Level" "${opp_val:-N/A}" "${sw_req:-N/A}"
fi

# Read MT6359 PMIC register 0x152c (VCORE buck target)
pwrap_node="/sys/devices/platform/10026000.pwrap/10026000.pwrap:mt6359p/mt-pmic/pmic_access"
if [ -f "$pwrap_node" ]; then
    echo 0x152c > "$pwrap_node" 2>/dev/null
    reg_val_hex=$(cat "$pwrap_node" 2>/dev/null | tr -d '\r\n ')
    if [ -n "$reg_val_hex" ]; then
        reg_val_dec=$(( reg_val_hex ))
        # Formula: 506.25 mV + Selector * 6.25 mV
        # In uV: 506250 + dec * 6250
        reg_uv=$(( 506250 + reg_val_dec * 6250 ))
        printf "  %-22s : %s (Selector %d -> %s)\n" "PMIC Reg 0x152c" "$reg_val_hex" "$reg_val_dec" "$(fmt_mv "$reg_uv")"
    fi
fi

# --- 4. Live CPU Frequencies ---
echo ""
echo "[ Live CPU Frequencies & Clocks ]"
echo "-----------------------------------------------------------------"
c0_cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
c0_min=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo 0)
c0_hw=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo 0)

c6_cur=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
c6_min=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 2>/dev/null || echo 0)
c6_hw=$(cat /sys/devices/system/cpu/cpu6/cpufreq/cpuinfo_min_freq 2>/dev/null || echo 0)

printf "  CPU0 (Little A55) : Cur: %4d MHz | Gov Min: %4d MHz | HW Min: %4d MHz\n" \
    "$(( c0_cur / 1000 ))" "$(( c0_min / 1000 ))" "$(( c0_hw / 1000 ))"
printf "  CPU6 (Big A76)    : Cur: %4d MHz | Gov Min: %4d MHz | HW Min: %4d MHz\n" \
    "$(( c6_cur / 1000 ))" "$(( c6_min / 1000 ))" "$(( c6_hw / 1000 ))"

# --- 5. Live GPU Status ---
echo ""
echo "[ Live GPU State ]"
echo "-----------------------------------------------------------------"
gpu_cur_raw=$(cat /sys/devices/platform/13000000.mali/devfreq/13000000.mali/cur_freq 2>/dev/null || echo 0)
gpu_cur_mhz=$(( gpu_cur_raw / 1000000 ))
if [ "$gpu_cur_mhz" -eq 0 ]; then
    gpu_cur_mhz=$(( gpu_cur_raw / 1000 ))
fi

if [ -f /proc/gpufreqv2/gpufreq_status ]; then
    opp_line=$(grep "\[GPU-OPP\]" /proc/gpufreqv2/gpufreq_status 2>/dev/null | head -n 1)
    echo "  Status : $opp_line"
fi
printf "  Clock  : %d MHz\n" "$gpu_cur_mhz"

# --- 6. Active Undervolt Module Health ---
echo ""
echo "[ Module & Thermal Health ]"
echo "-----------------------------------------------------------------"
dvfs_md5=$(md5sum /vendor/lib/modules/CPU_DVFS.ko 2>/dev/null | awk '{print $1}')
gpu_md5=$(md5sum /vendor/lib/modules/mtk_gpufreq_mt6833.ko 2>/dev/null | awk '{print $1}')
upower_md5=$(md5sum /vendor/lib/modules/Upower.ko 2>/dev/null | awk '{print $1}')

echo "  CPU_DVFS.ko MD5 : ${dvfs_md5:-Not Loaded}"
echo "  GPU_DVFS.ko MD5 : ${gpu_md5:-Not Loaded}"
echo "  Upower.ko MD5   : ${upower_md5:-Not Loaded}"

soc_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
batt_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)
printf "  SoC Temp        : %d.%d C\n" "$(( soc_temp / 1000 ))" "$(( (soc_temp % 1000) / 100 ))"
printf "  Battery Temp    : %d.%d C\n" "$(( batt_temp / 10 ))" "$(( batt_temp % 10 ))"

# --- 7. Upower EAS & PPM Energy Model ---
echo ""
echo "[ Upower EAS & PPM Energy Model ]"
echo "-----------------------------------------------------------------"
if [ -f /proc/upower/upower_debug ]; then
    tp_val=$(grep "turn_point" /proc/upower/upower_debug 2>/dev/null | head -n 1 | awk '{print $NF}')
    echo "  Little Turn Point: ${tp_val:-N/A} (OPP migration threshold)"
    echo "  Live Power Curves: Active (/proc/upower/upower_debug)"
else
    echo "  Upower Procfs    : Not active or Upower not loaded"
fi

echo "================================================================="
