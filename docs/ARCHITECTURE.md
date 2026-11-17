# MediaTek MT6833 (Dimensity 6080 / 810 / 700) DVFS Architecture & Hardware PMIC Internals

## 1. Overview
The MediaTek MT6833 platform (Dimensity 6080, Dimensity 810, Dimensity 700) features an octa-core CPU (2x Cortex-A76 @ 2.4 GHz + 6x Cortex-A55 @ 2.0 GHz) coupled with an ARM Mali-G57 MC2 GPU and an MT6359 Power Management IC (PMIC).

Dynamic Voltage and Frequency Scaling (DVFS) on MT6833 is governed by a distributed hardware/software pipeline:
1. **CPU DVFS Driver (`CPU_DVFS.ko`)**: Manages CPU operating performance points (OPP), PLL multipliers, and frequency scaling requests.
2. **GPU DVFS Driver (`mtk_gpufreq_mt6833.ko`)**: Interfaces with the Mali GPU kernel driver (`mali_kbase_mt6833.ko`) and regulates GPU core and SRAM rails.
3. **Energy Estimation Model (`mediatek_eem.ko`)**: Hardware adaptive voltage scaling engine that reads eFuse data via MCUPM coprocessor.
4. **Micro-Controller Unit Power Management (`MCUPM`)**: Secure on-chip firmware handling hardware power state transitions via Inter-Processor Interrupts (IPI).
5. **MT6359 PMIC Regulators**: Hardware buck converters and LDOs that supply physical voltages to the SoC rails.

---

## 2. Hardware PMIC Cross-Wiring Mystery (Device Tree Truth)
A critical discovery during reverse engineering MT6833 Device Tree (`/sys/firmware/devicetree/base/mt_cpufreq` and `/gpufreq`) revealed that MediaTek swapped regulator pin names in hardware schematics compared to typical Linux kernel conventions:

```
+---------------------+-------------------+---------------------+-------------------------+
| Logical Subsystem   | DT Supply Handle  | PMIC Hardware Rail  | Sysfs Node              |
+---------------------+-------------------+---------------------+-------------------------+
| CPU Little (A55)    | proc1-supply      | buck_vgpu11         | /sys/class/regulator/9  |
| CPU Big (A76)       | proc2-supply      | buck_vproc2         | /sys/class/regulator/15 |
| Little Cache SRAM   | sram_proc1-supply | ldo_vsram_proc1     | /sys/class/regulator/48 |
| Big Cache SRAM      | sram_proc2-supply | ldo_vsram_proc2     | /sys/class/regulator/23 |
| GPU Core (Mali)     | _vgpu-supply      | buck_vproc1         | /sys/class/regulator/16 |
| GPU SRAM            | _vsram_gpu-supply | ldo_vsram_md        | /sys/class/regulator/44 |
| SoC Core / Bus      | dvfsrc-vcore      | buck_vcore          | /sys/class/regulator/12 |
+---------------------+-------------------+---------------------+-------------------------+
```

### Why Standard Monitoring Scripts Fail
- Reading `vproc1` thinking it is CPU Little returns **400.00 mV** in idle because `vproc1` is actually the **GPU Core rail**, which enters sleep/power gating when 3D workload is absent.
- Reading `vgpu11` thinking it is GPU Core actually reads the **Little CPU Core** (~630–775 mV).

---

## 3. The `mediatek_eem.ko` Overwrite Vulnerability
In stock kernel operation:
1. `CPU_DVFS.ko` initializes and registers base nominal tables (`MT6833_B24GTbl`).
2. Shortly after boot, `mediatek_eem.ko` probes (`eem_probe` at `0x00101088`).
3. `eem_probe` communicates with MCUPM firmware via `mtk_ipi_send_compl` (IPI command `0xb`), fetches factory-burned eFuse calibration steps, and calculates an adaptive voltage curve.
4. `eem_probe` invokes `mt_cpufreq_update_legacy_volt()` for Cluster 0 (Little), Cluster 1 (Big), and Cluster 2 (CCI).
5. Inside `CPU_DVFS.ko`, `mt_cpufreq_update_legacy_volt()` loads `[x21, #0x38]` (the runtime OPP voltage table) and writes the eFuse values directly over the table in memory.

### Result on Unpatched Undervolts
Any undervolted table loaded by `CPU_DVFS.ko` was completely wiped out and replaced with stock eFuse voltages within 3 seconds of boot.

### The Solution: Zero-Overhead EEM Bypass
We patch `mt_cpufreq_update_legacy_volt` (`0x5408`) and `mt_cpufreq_update_volt` (`0x5204`) in `CPU_DVFS.ko` with:
```aarch64
paciasp      // d5 03 23 3f (ARM64 PAC/BTI landing pad)
mov w0, wzr  // 2a 1f 03 e0 (Return 0 / success)
autiasp      // d5 03 23 bf (Authenticate return address)
ret          // d6 5f 03 c0
```
This satisfies the caller without corrupting our custom undervolted OPP tables.
