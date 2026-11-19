#!/system/bin/sh
MODDIR=${0%/*}

# Wait for boot completion
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

# Allow PowerHAL and vendor init scripts to finish their initial boosts
sleep 12

# Enforce minfreq down to 450000 (450 MHz) across all clusters, ensuring any late vendor inits are locked
for round in 1 2 3 4 5; do
    for node in \
        /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq \
        /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq \
        /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq \
        /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq; do
        if [ -f "$node" ]; then
            echo 450000 > "$node" 2>/dev/null
        fi
    done
    sleep 3
done

# Bind-mount patched powerhint.json if present
if [ -f "$MODDIR/vendor/etc/powerhint.json" ]; then
    mount -o bind "$MODDIR/vendor/etc/powerhint.json" /vendor/etc/powerhint.json 2>/dev/null
fi

# Configure MediaTek PPM Policy Arbitration
# Enable PPM_POLICY_LCM_OFF (idx 8) to lock CPU to 450 MHz idle floor during screen-off sleep
if [ -f /proc/ppm/policy_status ]; then
    echo "8 1" > /proc/ppm/policy_status 2>/dev/null
fi
if [ -f /proc/ppm/policy/lcmoff_min_freq ]; then
    echo 450000 > /proc/ppm/policy/lcmoff_min_freq 2>/dev/null
fi

# Configure MediaTek GED (Graphics Efficiency Driver) Micro-Tuning
# 1. Eliminate artificial 2D and buffer-queue boost spikes
if [ -d /sys/module/ged/parameters ]; then
    echo 0 > /sys/module/ged/parameters/enable_gpu_boost 2>/dev/null
    echo 0 > /sys/module/ged/parameters/ged_boost_enable 2>/dev/null
    echo 0 > /sys/module/ged/parameters/ged_smart_boost 2>/dev/null
    echo 25 > /sys/module/ged/parameters/gx_fb_dvfs_margin 2>/dev/null
fi

# Configure Uclamp System Group Decoupling & Background Utilization Floor
if [ -f /dev/cpuctl/system/uclamp.min ]; then
    echo 20.00 > /dev/cpuctl/system/uclamp.min 2>/dev/null
fi
if [ -f /dev/cpuctl/system/cpu.uclamp.min ]; then
    echo 20.00 > /dev/cpuctl/system/cpu.uclamp.min 2>/dev/null
fi
sysctl -w kernel.sched_util_clamp_min=0 2>/dev/null

# Configure MediaTek FPSGO (Frame Rate Stabilization & BHR Game Pacing)
if [ -d /sys/module/mtk_fpsgo/parameters ]; then
    echo 1 > /sys/module/mtk_fpsgo/parameters/bhr 2>/dev/null
    echo 1 > /sys/module/mtk_fpsgo/parameters/bhr_opp 2>/dev/null
    echo 1 > /sys/module/mtk_fpsgo/parameters/fstb_separate_runtime_enable 2>/dev/null
fi

# Configure MediaTek CCI Interconnect Mapping Policy
# Ensure idle 450 MHz engagement strictly when both clusters are at OPP 15
if [ -f /proc/cpufreq/cpufreq_cci_map_table ]; then
    for r in 11 12 13 14; do
        for c in 11 12 13 14 15; do
            echo "$r $c 14 0" > /proc/cpufreq/cpufreq_cci_map_table 2>/dev/null
        done
    done
    for c in 11 12 13 14; do
        echo "15 $c 14 0" > /proc/cpufreq/cpufreq_cci_map_table 2>/dev/null
    done
    echo "15 15 15 0" > /proc/cpufreq/cpufreq_cci_map_table 2>/dev/null
fi

# Configure SPM Hardware Vcore Sequencer Clamp & PMIC Direct Baseline
# Trigger patched mtk-dvfsrc-helper to clamp SPM_DVFS_CMD0 (0x10006710) to 0x152c0017 (650.00 mV)
if [ -f /sys/devices/platform/10012000.dvfsrc/10012000.dvfsrc:dvfsrc-helper/dvfsrc_dump ]; then
    cat /sys/devices/platform/10012000.dvfsrc/10012000.dvfsrc:dvfsrc-helper/dvfsrc_dump >/dev/null 2>&1
elif [ -f /sys/devices/platform/10012000.dvfsrc/helio-dvfsrc/dvfsrc_dump ]; then
    cat /sys/devices/platform/10012000.dvfsrc/helio-dvfsrc/dvfsrc_dump >/dev/null 2>&1
fi
# Direct MT6359 physical buck Vcore register clamp baseline defense (Reg 0x152c = 0x17 -> 650.00 mV)
if [ -f /sys/devices/platform/10026000.pwrap/10026000.pwrap:mt6359p/mt-pmic/pmic_access ]; then
    echo "0x152c 0x17" > /sys/devices/platform/10026000.pwrap/10026000.pwrap:mt6359p/mt-pmic/pmic_access 2>/dev/null
fi

# Log status
{
    echo "=== Triple Undervolt Module Status ==="
    date
    echo "--- System & Root Manager Info ---"
    uname -a
    echo "ROM build: $(getprop ro.build.flavor 2>/dev/null) $(getprop ro.build.description 2>/dev/null)"
    echo "SELinux: $(getenforce 2>/dev/null)"
    if [ -x /data/adb/ksu/bin/ksud ]; then
        echo "Root: KernelSU Next (/data/adb/ksu/bin/ksud)"
        /data/adb/ksu/bin/ksud -V 2>/dev/null
        echo "Preinit status:"
        /data/adb/ksu/bin/ksud module preinit status 2>/dev/null
    elif which magisk >/dev/null 2>&1; then
        echo "Root: Magisk ($(magisk -v 2>/dev/null))"
    elif which apd >/dev/null 2>&1; then
        echo "Root: APatch ($(apd -v 2>/dev/null))"
    else
        echo "Root: Unknown"
    fi
    echo "--- Module Mounts & Checksums ---"
    mount | grep -E '/vendor/lib/modules' 2>/dev/null
    md5sum /vendor/lib/modules/CPU_DVFS.ko /vendor/lib/modules/mtk_gpufreq_mt6833.ko /vendor/lib/modules/Upower.ko 2>/dev/null
    echo "--- Loaded Kernel Modules (lsmod) ---"
    lsmod | grep -E 'CPU_DVFS|mtk_gpufreq|dvfsrc|Upower' 2>/dev/null
    echo "--- Preinit Kernel Log ---"
    dmesg 2>/dev/null | grep -E 'lh8n_undervolt|CPU_DVFS|mtk_gpufreq|Upower' | tail -n 25
    echo "--- Upower EAS & PPM Energy Model ---"
    if [ -f /proc/upower/upower_debug ]; then
        cat /proc/upower/upower_debug 2>/dev/null | head -n 40
    else
        echo "Upower debug interface not present"
    fi
    echo "--- CPU Frequencies ---"
    echo "CPU0 available freqs:"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null
    echo "CPU6 available freqs:"
    cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_available_frequencies 2>/dev/null
    echo "CPU0 scaling_min_freq:"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null
    echo "CPU6 scaling_min_freq:"
    cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq 2>/dev/null
    echo "--- CPU OPP Tables ---"
    echo "CPU0 OPP table:"
    cat /proc/cpufreq/MT_CPU_DVFS_LL/cpufreq_oppidx 2>/dev/null
    echo "CPU6 OPP table:"
    cat /proc/cpufreq/MT_CPU_DVFS_L/cpufreq_oppidx 2>/dev/null
    echo "CCI OPP table:"
    cat /proc/cpufreq/MT_CPU_DVFS_CCI/cpufreq_oppidx 2>/dev/null
    echo "CCI mode:"
    cat /proc/cpufreq/cpufreq_cci_mode 2>/dev/null
    echo "--- GPU Status & OPP Table ---"
    echo "GPU gpufreq_status:"
    cat /proc/gpufreqv2/gpufreq_status 2>/dev/null
    echo "GPU working OPP table:"
    cat /proc/gpufreqv2/gpu_working_opp_table 2>/dev/null
    echo "GPU cur_freq:"
    cat /sys/devices/platform/13000000.mali/devfreq/13000000.mali/cur_freq 2>/dev/null
    echo "GPU Vgpu (vgpu11):"
    cat /sys/class/regulator/regulator.9/microvolts 2>/dev/null
    echo "GPU Vsram (vsram_others):"
    cat /sys/class/regulator/regulator.32/microvolts 2>/dev/null
    echo "--- DVFSRC & Vcore Status ---"
    echo "DVFSRC dump:"
    cat /sys/devices/platform/10012000.dvfsrc/10012000.dvfsrc:dvfsrc-helper/dvfsrc_dump 2>/dev/null || cat /sys/kernel/helio-dvfsrc/dvfsrc_dump 2>/dev/null
    echo "DVFSRC OPP table:"
    cat /sys/devices/platform/10012000.dvfsrc/10012000.dvfsrc:dvfsrc-helper/dvfsrc_opp_table 2>/dev/null || cat /sys/kernel/helio-dvfsrc/dvfsrc_opp_table 2>/dev/null
    echo "DVFSRC Vcore (regulator.3):"
    cat /sys/class/regulator/regulator.3/microvolts 2>/dev/null
    echo "PMIC buck_vcore (regulator.12):"
    cat /sys/class/regulator/regulator.12/microvolts 2>/dev/null
    echo "PMIC Reg 0x152c (PWRAP direct):"
    if [ -f /sys/devices/platform/10026000.pwrap/10026000.pwrap:mt6359p/mt-pmic/pmic_access ]; then
        echo 0x152c > /sys/devices/platform/10026000.pwrap/10026000.pwrap:mt6359p/mt-pmic/pmic_access 2>/dev/null
        cat /sys/devices/platform/10026000.pwrap/10026000.pwrap:mt6359p/mt-pmic/pmic_access 2>/dev/null
    fi
    echo "--- MediaTek PPM Policy Status & Arbitration ---"
    cat /proc/ppm/policy_status 2>/dev/null
    echo "PPM dump_policy_list:"
    cat /proc/ppm/dump_policy_list 2>/dev/null | head -n 15
    echo "PPM thermal power budget:"
    cat /proc/ppm/policy/thermal_cur_power 2>/dev/null
    echo "PPM lcmoff_min_freq:"
    cat /proc/ppm/policy/lcmoff_min_freq 2>/dev/null
    echo "--- GED Micro-Tuning Status ---"
    cat /sys/module/ged/parameters/enable_gpu_boost 2>/dev/null
    cat /sys/module/ged/parameters/ged_boost_enable 2>/dev/null
    cat /sys/module/ged/parameters/gx_fb_dvfs_margin 2>/dev/null
    echo "--- Uclamp Decoupling Status ---"
    cat /dev/cpuctl/system/uclamp.min 2>/dev/null || cat /dev/cpuctl/system/cpu.uclamp.min 2>/dev/null
    cat /proc/sys/kernel/sched_util_clamp_min 2>/dev/null
    echo "--- FPSGO BHR Status ---"
    cat /sys/module/mtk_fpsgo/parameters/bhr 2>/dev/null
    cat /sys/module/mtk_fpsgo/parameters/bhr_opp 2>/dev/null
} > /data/local/tmp/undervolt.log 2>&1
