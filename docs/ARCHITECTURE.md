# MediaTek MT6833 (Dimensity 6080 / 810 / 700) DVFS Architecture & Hardware PMIC Internals

## 1. Overview
The MediaTek MT6833 platform (Dimensity 6080, Dimensity 810, Dimensity 700) features an octa-core CPU (2x Cortex-A76 @ 2.4 GHz + 6x Cortex-A55 @ 2.0 GHz) coupled with an ARM Mali-G57 MC2 GPU and an MT6359 Power Management IC (PMIC).

Dynamic Voltage and Frequency Scaling (DVFS) on MT6833 is governed by a distributed hardware/software pipeline:
1. **CPU DVFS Driver (`CPU_DVFS.ko`)**: Manages CPU operating performance points (OPP), PLL multipliers, and frequency scaling requests.
2. **GPU DVFS Driver (`mtk_gpufreq_mt6833.ko`)**: Interfaces with the Mali GPU kernel driver (`mali_kbase_mt6833.ko`) and regulates GPU core and SRAM rails.
3. **Energy Estimation Model (`mediatek_eem.ko`)**: Hardware adaptive voltage scaling engine that reads eFuse data via MCUPM coprocessor.
4. **Dynamic Voltage & Frequency Scaling Resource Collector (`mtk-dvfsrc.ko`, `mtk-dvfsrc-regulator.ko`, `mtk-dvfsrc-helper.ko`)**: Manages SoC digital core (Vcore) and memory controller (DDR) voltage arbitration.
5. **Micro-Controller Unit Power Management (`MCUPM`)**: Secure on-chip firmware handling hardware power state transitions via Inter-Processor Interrupts (IPI).
6. **System Power Manager (`SPM`)**: Hardware state machine controlling physical PMIC register writes over the PMIC wrapper (PWRAP) interface.
7. **MT6359 PMIC Regulators**: Hardware buck converters and LDOs that supply physical voltages to the SoC rails.

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

---

## 4. CPU Cache SRAM Power Architecture (vsram_proc1 & vsram_proc2)

### Dual-Rail Interconnect Design
Each CPU cluster on the MT6833 incorporates separate power domains for core logic vs. cache memory arrays:
1. **Little Cluster (6x Cortex-A55)**:
   * Logic Core: `buck_vgpu11` (regulator.9, high-efficiency switching buck converter).
   * L1/L2 Cache SRAM: `ldo_vsram_proc1` (regulator.48, low-noise LDO).
2. **Big Cluster (2x Cortex-A76)**:
   * Logic Core: `buck_vproc2` (regulator.15, high-current switching buck converter).
   * L2/L3 Cache SRAM: `ldo_vsram_proc2` (regulator.23, low-noise LDO).

### MCUPM Hardware Co-Regulation
The MCUPM coprocessor automatically correlates $V_{\text{sram}}$ with $V_{\text{proc}}$:
* As $V_{\text{proc}}$ scales dynamically between OPPs, $V_{\text{sram}}$ follows via the hardware transfer function $V_{\text{sram}} = \max(750.00\text{ mV},\; V_{\text{proc}} + 100.00\text{ mV})$.
* Under heavy 2.4 GHz load: $V_{\text{proc2}} = 812.50\text{ mV} \implies V_{\text{sram2}} = 912.50\text{ mV}$.
* When idle or downclocked to 200 MHz: $V_{\text{proc}} = 581.25\text{ mV}$, but $V_{\text{sram}}$ stays clamped at $750.00\text{ mV}$ to prevent 6T SRAM bitcell state degradation.

---

## 5. DVFSRC SPM & Dynamic Vcore Regulator Interconnect Architecture

### 5.1 The DVFSRC Pipeline
The Dynamic Voltage and Frequency Scaling Resource Collector (DVFSRC) manages the SoC digital core voltage rail (`dvfsrc-vcore`, regulator.3) and memory interconnect bandwidth. Unlike CPU and GPU frequencies which are managed by operating system CPUFreq/DevFreq frameworks, Vcore is governed by an on-chip hardware arbiter responding to high-speed hardware consumers:

1. **Display PWM & 120Hz Refresh Driver (`dispsys_config`)**: Requests peak Vcore (725.00 mV) to guarantee panel timing stability during 120Hz display refresh.
2. **UFS Storage Controller (`mtk-sd`)**: Votes for high bus bandwidth during burst storage I/O.
3. **Camera ISP QoS & Video Codec (`cam_qos`, `vdec`)**: Direct memory access pipelines requiring high bus throughput.
4. **System Power Manager (`SPM`)**: On-chip microcontroller executing autonomous power state transitions.

### 5.2 Stock Voltage Table & The 725.00 mV Dynamic Override
Inside `mtk-dvfsrc-regulator.ko`, available Vcore operating points are declared in `mt6853_voltages`:
```c
static const unsigned int mt6853_voltages[] = {
    550000, /* Index 0: Level 0 (Idle / Deep Sleep)     */
    600000, /* Index 1: Level 1 (Low Power Bus)          */
    650000, /* Index 2: Level 2 (Nominal Performance)    */
    725000, /* Index 3: Level 3 (Peak / 120Hz Display)   */
};
```

Whenever a 120Hz display mode is active:
1. `dispsys_config` invokes `regulator_set_voltage(rdev, 725000, 725000)`.
2. The Linux regulator core matches `725000` against `mt6853_voltages`, finding `selector = 3`.
3. The core invokes `dvfsrc_set_voltage_sel(rdev, selector=3)`.
4. `dvfsrc_set_voltage_sel()` invokes `mtk_dvfsrc_send_request(dvfsrc, cmd=2, selector=3)`.
5. Inside `mtk-dvfsrc.ko`, command 2 triggers `mt6873_set_vcore_level(dvfsrc, level=3)`.
6. `mt6873_set_vcore_level()` calculates `(level << 4)` and writes `0x30` into hardware register `SW_REQ 3` (`0x1000600c`).
7. SPM hardware senses `SW_REQ 3 = 0x30` and transmits a command to MT6359 PMIC register `0x152c`, setting selector `0x23` (35), commanding the physical buck regulator to **725.00 mV** ($506.25\text{ mV} + 35 \times 6.25\text{ mV} = 725.00\text{ mV}$).

### 5.3 The Solution: Mathematical 1-Instruction Clamp (`min(w, 2)`)
Simply modifying the `mt6853_voltages` table in `mtk-dvfsrc-regulator.ko` breaks driver compatibility: when consumers request `725000 uV`, the regulator core returns `-EINVAL` because the voltage no longer exists in the array, breaking display initialization.

Instead, we leave the regulator array intact and clamp the selector parameter in the execution path using the mathematical property:
$$\min(w, 2) = w \ \& \ \sim(w \gg 1) \quad \text{for } w \in \{0, 1, 2, 3\}$$

| Input Selector ($w$) | Binary ($w$) | $w \gg 1$ | $\sim(w \gg 1)$ | $w \ \& \ \sim(w \gg 1)$ | Output Level | Target Voltage |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | `00` | `0` | `1` | `00 & 01 = 00` | 0 | 550.00 mV |
| 1 | `01` | `0` | `1` | `01 & 01 = 01` | 1 | 600.00 mV |
| 2 | `10` | `1` | `0` | `10 & 00 = 00`? | *See BIC logic below* | 650.00 mV |

In ARM64 Bit Clear (`BIC Rd, Rn, Rn, LSR #1`):
* `w=0` (`0b00`): `0b00 & ~(0b00 >> 1) = 0`
* `w=1` (`0b01`): `0b01 & ~(0b01 >> 1) = 1`
* `w=2` (`0b10`): `0b10 & ~(0b10 >> 1) = 2`
* `w=3` (`0b11`): `0b11 & ~(0b11 >> 1) = 2` (Clamped from Level 3 down to Level 2)

This guarantees that:
1. Consumer drivers (such as 120Hz display) continue requesting 725,000 uV successfully without error.
2. The DVFSRC driver silently and atomically clamps the hardware actuation to Level 2 (650.00 mV).
3. The physical PMIC register `0x152c` never exceeds selector `0x17` ($506.25 + 23 \times 6.25 = 650.00\text{ mV}$), achieving an autonomous **-75.00 mV Vcore undervolt**.

### 5.4 Bare-Metal Partition Patching Architecture
The DVFSRC drivers (`mtk-dvfsrc.ko`, `mtk-dvfsrc-regulator.ko`, and `mtk-dvfsrc-helper.ko`) reside inside the early boot ramdisk within the `vendor_boot` partition. Because they probe before root file systems or post-fs overlays are mounted, standard KernelSU module overlay mounts cannot intercept them.

The installer implements automated bare-metal partition patching directly on the target device:
1. Detects the active boot slot (`ro.boot.slot_suffix`).
2. Creates an uncompressed raw backup of `vendor_boot` to `/data/adb/lh8n_backup/vendor_boot_stock.img`.
3. Unpacks `vendor_boot` and `ramdisk.cpio` using `magiskboot`.
4. Injects the patched DVFSRC kernel modules into `lib/modules/`.
5. Repacks the partition image and writes it directly to `/dev/block/by-name/vendor_boot`.
6. An uninstaller script (`uninstall.sh`) automatically restores the stock partition block upon module removal.
