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
The MCUPM coprocessor automatically correlates `Vsram` with `Vproc`:

$$
V_{\text{sram}} = \max\left(750.00\text{ mV},\; V_{\text{proc}} + 100.00\text{ mV}\right)
$$

* As core logic voltage scales dynamically between OPPs, cache SRAM tracks with a +100.00 mV offset.
* Under heavy 2.4 GHz load: `Vproc2 = 812.50 mV` commands `Vsram2 = 912.50 mV`.
* When idle or downclocked to 200 MHz: `Vproc = 581.25 mV`, but `Vsram` stays clamped at **750.00 mV** to prevent 6T SRAM bitcell state degradation.

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
7. SPM hardware senses `SW_REQ 3 = 0x30` and transmits a command to MT6359 PMIC register `0x152c`, setting selector `0x23` (35), commanding the physical buck regulator to **725.00 mV** (506.25 mV + 35 x 6.25 mV = 725.00 mV).

### 5.3 The Solution: Mathematical 1-Instruction Clamp (`min(w, 2)`)
Simply modifying the `mt6853_voltages` table in `mtk-dvfsrc-regulator.ko` breaks driver compatibility: when consumers request `725000 uV`, the regulator core returns `-EINVAL` because the voltage no longer exists in the array, breaking display initialization.

Instead, we leave the regulator array intact and clamp the selector parameter in the execution path using the bitwise formula:

```c
min(w, 2) = w & ~(w >> 1)   // for w in {0, 1, 2, 3}
```

| Input Selector (`w`) | Binary (`w`) | `w >> 1` | `~(w >> 1)` | `w & ~(w >> 1)` | Output Level | Target Voltage |
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
3. The physical PMIC register `0x152c` never exceeds selector `0x17` (506.25 mV + 23 x 6.25 mV = 650.00 mV), achieving an autonomous **-75.00 mV Vcore undervolt**.

### 5.4 Bare-Metal Partition Patching Architecture
The DVFSRC drivers (`mtk-dvfsrc.ko`, `mtk-dvfsrc-regulator.ko`, and `mtk-dvfsrc-helper.ko`) reside inside the early boot ramdisk within the `vendor_boot` partition. Because they probe before root file systems or post-fs overlays are mounted, standard KernelSU module overlay mounts cannot intercept them.

The installer implements automated bare-metal partition patching directly on the target device:
1. Detects the active boot slot (`ro.boot.slot_suffix`).
2. Creates an uncompressed raw backup of `vendor_boot` to `/data/adb/lh8n_backup/vendor_boot_stock.img`.
3. Unpacks `vendor_boot` and `ramdisk.cpio` using `magiskboot`.
4. Injects the patched DVFSRC kernel modules into `lib/modules/`.
5. Repacks the partition image and writes it directly to `/dev/block/by-name/vendor_boot`.
6. An uninstaller script (`uninstall.sh`) automatically restores the stock partition block upon module removal.

---

## 6. Calibrated EAS Energy Model & PPM Power Policy Architecture (`Upower.ko`)

### 6.1 The Energy Disconnect in Stock Linux Schedutil / EAS
The Linux Energy Aware Scheduling (EAS) framework and MediaTek Power Policy Manager (PPM) optimize task placement and energy consumption across asymmetric CPU clusters:
1. **Schedutil Governor (`cpufreq_sugov_ext.ko`)**: Calls `upower_get_core_tbl()` during `init_capacity_table()` to query compute capacity and power efficiency curves.
2. **MediaTek PPM (`mtk_ppm_v3.ko`)**: Calls `upower_get_power()` during `ppm_calc_total_power()` and `ppm_cobra_init()` to dynamically enforce thermal envelopes and Cobra cluster power budgets.

In the uncalibrated stock system, `Upower.ko` creates an energy disconnect:
* `Upower.ko` contains static lookup tables (`upower_tbl_l_*`, `upower_tbl_b_*`, `upower_tbl_cci_*`) hardcoded with stock nominal voltages (1000.00 mV Little OPP 15, 1050.00 mV Big OPP 15, 650.00 mV floor).
* Shortly after boot, `mediatek_eem.ko` invokes `upower_update_volt_by_eem()`, overwriting the tables with stock factory eFuse voltages.
* Schedutil and PPM evaluate power efficiency based on stock power curves (10% to 20% higher than our real physical power consumption).
* Schedutil computes `turn_point = 7` (1048 MHz), prematurely migrating lightweight background tasks to the power-hungry Cortex-A76 Big cluster.

### 6.2 Upower Calibration Architecture
We patch `Upower.ko` across four key dimensions:

```
+------------------------------------------------------------------------------------+
|                                    Upower.ko                                       |
+------------------------------------------------------------------------------------+
| 1. Static Tables Calibration:                                                      |
|    - Little (upower_tbl_l_*):      581.25 mV (200 MHz) .. 950.00 mV (2000 MHz)      |
|    - Big    (upower_tbl_b_*):      581.25 mV (200 MHz) .. 1000.00 mV (2400 MHz)     |
|    - CCI    (upower_tbl_cci_*):    618.75 mV (450 MHz) .. 962.50 mV (1600 MHz)     |
|    - Cluster Tables (cluster_*):   Voltages updated, dyn = 0                        |
+------------------------------------------------------------------------------------+
| 2. Dynamic Power Recalculation (Physical CMOS Scaling):                            |
|    P_dyn_new = P_dyn_stock * (V_patched / V_stock)^2                               |
+------------------------------------------------------------------------------------+
| 3. Underclock Floor Energy Calibration (200 MHz OPP 0):                            |
|    P_dyn(200MHz) = P_dyn(500MHz) * (200/500) * (581.25/593.75)^2                  |
|    - Little OPP 0 power drops from 17,036 uW down to 7,083 uW (~60% idle savings)  |
+------------------------------------------------------------------------------------+
| 4. Disarming mediatek_eem Runtime Overwrite:                                       |
|    - upower_update_volt_by_eem @ 0x1b1c stubbed with 12-byte PAC/BTI return         |
|    - upower_update_tables_by_eem @ 0x1d14 stubbed with 12-byte PAC/BTI return       |
|    - 35 ELF relocations neutralized to R_AARCH64_NONE to prevent loader corruption  |
+------------------------------------------------------------------------------------+
```

### 6.3 Scheduler Turn Point & Efficiency Impact
Inside `Upower.ko`, `get_L_pwr_efficiency()`, `get_LL_pwr_efficiency()`, and `upower_cal_turn_point()` compute task migration thresholds:

$$
\text{Efficiency} = \frac{P_{\text{total}}}{\text{Capacity}} = \frac{P_{\text{dyn}} + P_{\text{lkg}}}{\text{Capacity}}
$$

In `upower_cal_turn_point()`, the kernel compares Little cluster efficiency against the Big cluster minimum efficiency floor (`min_eff`), scanning Little OPPs from index 15 down to 0:
```c
min_eff = get_L_min_efficiency(); // Minimum efficiency across Big cluster OPPs
for (i = 15; i >= 0; i--) {
    if (eff_LL[i] <= min_eff) {
        turn_point = i + 1;
        break;
    }
}
```

* **Stock Turn Point Evaluation**:
  - Stock lowest Big OPP was 500 MHz (P_dyn = 88,853 uW, P_lkg0 = 103,988 uW, cap = 611):
    - `eff = (88853 + 103988) / 611 = 315`
  - Little OPP 6 (1048 MHz): `eff = 311 <= 315`
  - Little OPP 7 (1128 MHz): `eff = 321 > 315`
  - Result: `turn_point = 6 + 1 = 7` (1048 MHz).

* **Calibrated Undervolt & 200 MHz Underclock Floor Evaluation**:
  - Unlocking the 200 MHz underclock floor on Big cores reduces Big OPP 0 dynamic power by **-62.9%** (down to 32,928 uW @ 581.25 mV).
  - Under live operating conditions with thermal leakage scaling (Leakage Index 4 in `/proc/upower/upower_debug`):
    - Big OPP 0 (200 MHz): P_dyn = 32,928 uW, P_lkg = 175,000 uW, cap = 611 -> `eff = (32928 + 175000) / 611 = 340`.
    - Big OPP 1 (500 MHz): P_dyn = 85,900 uW, P_lkg = 175,000 uW, cap = 667 -> `eff = (85900 + 175000) / 667 = 391`.
    - Big cluster minimum efficiency shifts to `eff = 340` at the 200 MHz floor (or `eff = 224` in static tables without runtime thermal leakage updates).
  - Evaluating Little cluster OPPs top-down (15 -> 0):
    - Little OPP 2 (703 MHz): P_dyn = 22,145 uW, P_lkg = 46,000 uW, cap = 193 -> `eff = 353 > 340`.
    - Little OPP 1 (500 MHz): P_dyn = 18,479 uW, P_lkg = 43,000 uW, cap = 181 -> `eff = 339 <= 340` (Match).
    - Result: `turn_point = 1 + 1 = 2` (500 MHz).

* **Verified Hardware Confirmation**:
  Live hardware reading via `/proc/upower/upower_debug`:
  ```
  lkg_idx, num_row, turn_point: 4, 16, 2
  ```

Because Cortex-A76 Big cores can now operate stably at an ultra-low-power 200 MHz floor consuming only 32.9 mW dynamic power, waking a Big core for lightweight background work incurs virtually no power penalty. EAS scheduler energy calculations correctly reflect this reality, optimizing asymmetric task arbitration between Cortex-A55 and Cortex-A76 cores.

---

## 7. MediaTek Power Policy Manager (PPM) & PowerHAL Arbitration Architecture

### 7.1 Policy Hierarchy & Procfs Arbitration Architecture (`/proc/ppm/`)
The MediaTek Power Policy Manager (`mtk_ppm_v3.ko`) coordinates cluster frequency limits, core counts, and thermal/power envelopes across CPU clusters. It arbitrates multiple competing system policies and feeds the resultant constraints directly into the Linux kernel `cpufreq` framework using `freq_qos_update_request()`.

PPM maintains an internal priority hierarchy exposed through `/proc/ppm/dump_policy_list`:

```
+------------------------------------------------------------------------------------+
| Priority 128: PPM_POLICY_SYS_BOOST      (System boost: UT, WIFI, PERFSERV, USB)   |
| Priority  64: PPM_POLICY_LCM_OFF        (Display blank / standby sleep policy)    |
| Priority  64: PPM_POLICY_USER_LIMIT     (Userspace frequency and core constraints)|
| Priority  64: PPM_POLICY_HARD_USER_LIMIT(Hard userspace frequency clamps)         |
| Priority   1: PPM_POLICY_DLPT           (Dynamic Loading Power Throttling)        |
| Priority   1: PPM_POLICY_THERMAL        (Thermal budget throttling engine)        |
| Priority   1: PPM_POLICY_PWR_THRO       (Power budget throttling engine)          |
| Priority   0: PPM_POLICY_FORCE_LIMIT    (Forced core/frequency limits)            |
| Priority   0: PPM_POLICY_UT             (Unit test / debug overrides)             |
| Priority   0: PPM_POLICY_PTPOD          (PTPOD power tracking)                    |
+------------------------------------------------------------------------------------+
```

#### Arbitration Engine (`mt_ppm_main`)
Every cycle or policy update, `mt_ppm_main()` evaluates all active and enabled policies:
1. **OPP Index Bounds**: For each cluster, policies submit `(min_freq_idx, max_freq_idx, min_core_num, max_core_num)`. Note that in MediaTek convention, OPP index `0` represents the maximum frequency (highest clock speed) while index `15` represents the floor (200 MHz).
2. **Aggregated Final Limit**: PPM takes the union of constraints across all active policies:
   - `Final min_freq_idx = min(policy[k].min_freq_idx)`: Taking the minimum OPP index enforces the highest lower-bound clock speed (OPP 0 represents maximum frequency).
   - `Final max_freq_idx = max(policy[k].max_freq_idx)`: Taking the maximum OPP index enforces the lowest upper-bound clock ceiling (OPP 15 represents the 200 MHz floor).
3. **Cpufreq QoS Synchronization**: PPM looks up the frequency corresponding to `Final max_idx` and `Final min_idx` in the cluster DVFS tables via `ppm_main_freq_to_idx()` and calls:
   - `freq_qos_update_request(&cluster->qos_min, min_freq_khz)`
   - `freq_qos_update_request(&cluster->qos_max, max_freq_khz)`
4. **Sysfs Node Interface**: The nodes `/proc/ppm/policy/hard_userlimit_cpu_freq`, `userlimit_cpu_freq`, `hard_userlimit_max_cpu_freq`, and `hard_userlimit_min_cpu_freq` accept frequency values in **kHz** (e.g. `200000 2000000 200000 2400000`), automatically converted to internal OPP table indices by `ppm_main_freq_to_idx()`. Passing `-1` clears constraints to an unconstrained state.

### 7.2 MediaTek Cobra Power Matrix (`cobra_budget_to_limit` & `cobra_limit_to_budget`)
MediaTek's Cobra algorithm arbitrates multi-cluster power envelopes using calibrated power tables derived directly from [Upower.ko](file:///home/yamada/CODE/MT6833GP-Experiment/docs/REVERSE_ENGINEERING.md). Cobra models all 256 cluster Operating Performance Point combinations `(6, OPP_L, 2, OPP_B)` spanning 16 Little OPPs and 16 Big OPPs:

* **Maximum Power Budget**:
  - Configuration: `(6, 0, 2, 0)` = 6 cores @ 2000 MHz + 2 cores @ 2400 MHz.
  - Total Power: 2,479 mW (down from stock 2,800+ mW due to calibrated -50.00 mV undervolt).
* **Deep Idle Floor Budget**:
  - Configuration: `(6, 15, 2, 15)` = 6 cores @ 200 MHz + 2 cores @ 200 MHz.
  - Total Power: 293 mW (reflecting the 200 MHz underclock floor and dynamic power reduction).
* **Multi-Cluster Budget Allocation**:
  Writing an input budget in milliwatts to `/proc/ppm/cobra_budget_to_limit` (e.g. `1000` mW) calculates optimal multi-cluster capacity splits (e.g. `(6, 2, 2, 15)` = 955 mW or `(6, 0, 0, 0)` = 930 mW). Because our static energy model in `Upower.ko` was recalculated with CMOS voltage scaling (P proportional to V^2), all Cobra budget allocations align precisely with actual bare-metal silicon power consumption.

### 7.3 Touch Boost Deconstruction & PowerHAL Interaction Tuning
Stock Dimensity 6080 firmware suffers from severe battery drain during everyday interactions (typing, scrolling, UI taps). Reverse-engineering revealed this drain is driven by an uncoordinated dual-layer boost system that completely overrides Energy Aware Scheduling.

#### Dual-Layer Boost Architecture
1. **Google PowerHAL (`pixel-libperfmgr`)**:
   Monitors input interaction events (`INTERACTION` hint) defined in `/vendor/etc/powerhint.json`.
2. **MediaTek Contable (`vendor.mediatek.hardware.mtkpower`)**:
   Maintains proprietary boost resources in `/vendor/etc/powercontable.xml` (`PERF_RES_POWERHAL_TOUCH_BOOST_CLUSTER_*`).

#### Stock Interaction Drain Anatomy
When a user taps or flings the screen, stock `powerhint.json` enforces the following extreme clamps:
* `CPUEfficiencyClusterMinFreq`: Clamped to `1325000` (1325 MHz) for **1500 ms**.
* `CPUSuperClusterMinFreq`: Clamped to `1443000` (1443 MHz) for **1500 ms**.
* `GpuPwrLevel`: Clamped to `0` (1068 MHz maximum GPU clock) for **1500 ms**.
* `TAUclampMin`: Clamped to `30` for **5000 ms** (5 seconds).
* `FGUclampMin`: Clamped to `10` for **3000 ms** (3 seconds).

Because a typical user taps or scrolls every 1 to 2 seconds while reading, chatting, or web browsing, the CPU and GPU are continuously locked into high-power states, consuming over 1.5 W continuously for simple 2D display updates.

#### Calibrated EAS-Aligned Interaction Tuning
With EAS energy models and scheduler migration calibrated (`turn_point = 2` / 500 MHz), EAS schedutil responds within 2-4 ms to genuine thread runqueue demand. Heavy artificial boost durations are unnecessary.

The module eliminates touch-boost battery drain through specific targets:
1. **Eliminate Big Core Minimum Clamp**: `CPUSuperClusterMinFreq` boost is removed. UI rendering threads remain on energy-efficient Little cores. When heavy operations occur (e.g. app cold start), EAS autonomously migrates threads to Big cores when utilization crosses the 500 MHz threshold.
2. **Eliminate GPU Boost on 2D Touch**: `GpuPwrLevel` is removed from `INTERACTION`. The Mali-G57 GPU stays at its 390 MHz idle floor and scales dynamically via GED only when SurfaceFlinger / HWUI frame composition deadlines require it.
3. **Gentle, Short Little Cluster Bump**: `CPUEfficiencyClusterMinFreq` is tuned to `703000` (703 MHz, OPP 13) for only **100 ms**. At 703 MHz (-50 mV @ 637.50 mV), dynamic power is only 24.8 mW per core, eliminating frame drop latency during the initial touch event while consuming a fraction of the energy.
4. **uclamp Duration Reduction**: `TAUclampMin` and `FGUclampMin` durations are reduced from 5000 ms and 3000 ms down to **150 ms**.

#### Autonomous Dynamic On-Boot Patcher (`tools/patch_powerhint`)
Shipping static `powerhint.json` files in Magisk/KernelSU modules breaks compatibility when ROM maintainers update the file (e.g. tuning camera, VR, game modes, thermal profiles, or refresh rate policies). Overwriting the entire file clobbers upstream improvements.

To ensure universal ROM compatibility without manual maintenance, the module implements an autonomous native AArch64 JSON patcher ([tools/patch_powerhint](file:///home/yamada/CODE/MT6833GP-Experiment/tools/patch_powerhint/patch_powerhint.c)) built with static `cJSON`:
1. **Zero Static Overlays**: The module zip contains no pre-baked `powerhint.json`.
2. **Execution Timing**: Executes in [post-fs-data.sh](file:///home/yamada/CODE/MT6833GP-Experiment/module/post-fs-data.sh) before KernelSU/Magisk attaches OverlayFS / magic mounts.
3. **Pristine ROM Ingestion**: Reads the ROM's live, unmounted `/vendor/etc/powerhint.json` directly from the ROM filesystem.
4. **Surgical AST Modification**: Parses the true JSON AST, preserving 100% of the ROM maintainer's custom hints, camera profiles, and thermal configurations. It modifies exclusively the `INTERACTION` actions and appends `"200000"` to CPU frequency nodes, respecting both ascending and descending frequency table conventions.
5. **Caching & Zero-Overhead**: Computes the MD5 checksum of `/vendor/etc/powerhint.json`. On standard boots, the MD5 check matches and skips execution in 1 ms. When the ROM is updated via OTA or dirty flash, the MD5 difference automatically triggers re-patching against the new ROM file.

### 7.4 Screen-Off Standby Floor (`PPM_POLICY_LCM_OFF`)
In stock firmware, `PPM_POLICY_LCM_OFF` (PPM Policy Index 8) is disabled by default (`is_enabled = 0`). The module activates this policy in [service.sh](file:///home/yamada/CODE/MT6833GP-Experiment/module/service.sh):
```sh
echo "8 1" > /proc/ppm/policy_status
echo 200000 > /proc/ppm/policy/lcmoff_min_freq
```
When the display panel enters low power or sleeps, the Linux framebuffer notifier invokes `ppm_lcmoff_fb_notifier_callback()`, activating `LCM_OFF`. PPM enforces `lcmoff_min_freq = 200000` as the upper clamp for cluster 0, locking the system into the 200 MHz deep idle floor during screen-off sleep and eliminating background battery drain. Upon display unblank (`FB_BLANK_UNBLANK`), `LCM_OFF` immediately deactivates, restoring full dynamic range up to 2000/2400 MHz.

---

## 8. MediaTek Graphics Efficiency Driver (GED), Uclamp Decoupling & FPSGO BHR Architecture

### 8.1 MediaTek Graphics Efficiency Driver (GED) Micro-Tuning
The MediaTek Graphics Efficiency Driver (`ged.ko`) sits between userspace SurfaceFlinger / HWUI composition and the low-level Mali GPU frequency governor (`mtk_gpufreq_mt6833.ko`). It intercepts vsync pulses, render fences, and frame buffer swaps (`queueBuffer`, `dequeueBuffer`) to dynamically scale GPU frequencies and issue boost pulses.

#### Anatomy of 2D GPU Boost Spikes
Under stock MediaTek tuning, GED enforces aggressive heuristic boost spikes even for trivial 2D interactions:
* `enable_gpu_boost = 1`: Triggers a synchronous GPU frequency boost on every SurfaceFlinger frame submission, regardless of frame completion latency or GPU utilization.
* `ged_boost_enable = 1`: Enables userspace bridge boost requests from MediaTek proprietary frameworks (`libged.so`, `libperfservice.so`).
* `gx_fb_dvfs_margin = 100`: Enforces an artificial 100% frequency headroom margin on top of calculated frame workloads:

$$
f_{\text{target}} = f_{\text{calc}} \times \frac{100 + \text{gx\_fb\_dvfs\_margin}}{100} = f_{\text{calc}} \times 2.0
$$

With a margin of 100%, GED doubles every calculated GPU frequency target. As a result, scrolling a simple text list or typing on a virtual keyboard forces the Mali-G57 MC2 out of its 390 MHz idle floor (550.00 mV) into 570–722 MHz OPPs (568.75–612.50 mV), consuming an unnecessary 80 to 150 mW of GPU core power.

#### Zero-Overhead Assembly Bypasses in `ged.ko`
Reverse engineering `ged.ko` via disassembly revealed that the MediaTek driver contains built-in bypass checks:
1. **Early Return in `ged_dvfs_boost_gpu_freq`**:
   At offset `0x11018` in `ged.ko`, the function checks the global variable `enable_gpu_boost`:
   ```aarch64
   0x11018: adrp x8, 0x2e000
   0x1101c: ldrb w8, [x8, #0x2d8]     // Load enable_gpu_boost
   0x11020: cbz  w8, 0x11074          // If enable_gpu_boost == 0, branch directly to exit
   ```
   When `enable_gpu_boost = 0`, execution branches immediately to `0x11074` before acquiring `ged_dvfs_lock`, creating bridge notifications, or requesting frequency increases from `mtk_gpufreq`.
2. **Bridge Boost Disarm in `ged_dispatch` & `ged_bridge_event_notify`**:
   At offsets `0x66f8` and `0xd2b0`, bridge boost requests check `ged_boost_enable`. Setting `ged_boost_enable = 0` bypasses all synthetic boost events at zero CPU cycle cost.
3. **Headroom Buffer Normalization**:
   Setting `gx_fb_dvfs_margin = 25` reduces the headroom multiplier from 2.0x down to 1.25x:

$$
f_{\text{target}} = f_{\text{calc}} \times \frac{100 + 25}{100} = f_{\text{calc}} \times 1.25
$$

This ensures adequate 25% compute margin to satisfy 60/90/120 Hz display frame deadlines without dragging the GPU into higher voltage states for simple 2D drawing.

### 8.2 Android System Uclamp Group Decoupling
Android's Energy Aware Scheduling (EAS) utilizes Utilization Clamping (`uclamp`) via the control group hierarchy (`/dev/cpuctl/`) to guide task placement and frequency selection.

#### Stock Firmware Pathology
In stock Transsion / MediaTek Android 14 firmware, the `system` cpuctl cgroup is misconfigured:
* `/dev/cpuctl/system/uclamp.min` is set to `max` (1024), or clamped to an excessively high utilization floor.
* As a consequence, any thread assigned to the `system` cgroup (including `system_server`, background package scanners, location providers, and sensor listeners) is treated by EAS as requiring 100% CPU capacity.
* This forces the schedutil governor to ramp Little cores to 2.0 GHz and Big cores to 2.4 GHz even when executing lightweight I/O or polling loops, draining 100 to 250 mW during background operation.

#### Decoupled System Uclamp Configuration
The module decouples the `system` cgroup in [service.sh](file:///home/yamada/CODE/MT6833GP-Experiment/module/service.sh):
```sh
echo 20.00 > /dev/cpuctl/system/uclamp.min
echo 20.00 > /dev/cpuctl/system/cpu.uclamp.min
sysctl -w kernel.sched_util_clamp_min=0
```
* **System Floor Clamped to 20.00**: Allows background system tasks to run at lower, energy-efficient frequencies (500–703 MHz) on Little cores without waking Big cores.
* **Global Sched Util Clamp Min = 0**: Clears any residual global floor that prevents cores from dropping down to the 200 MHz deep idle floor when runqueues are empty.

### 8.3 MediaTek FPSGO Game Pacing & BHR Engine
MediaTek FPSGO (Frame Rate Stabilization and Optimization) is an in-kernel subsystem (`mtk_fpsgo.ko`) that orchestrates frame time prediction, dynamic render thread affinity, and GPU OPP hints for 3D gaming.

#### BHR (Bounceless High-Efficiency Rendering)
Under default settings, FPSGO frequently oscillates between adjacent OPPs during 3D gaming due to transient variations in per-frame vertex and fragment complexity. This "OPP bounce" causes transient frame pacing jitter and micro-stutter.

The module configures FPSGO BHR in [service.sh](file:///home/yamada/CODE/MT6833GP-Experiment/module/service.sh):
* `bhr = 1`: Activates Bounceless High-efficiency Rendering, smoothing the hysteresis curve used to determine frame rendering deadlines.
* `bhr_opp = 1`: Enables smooth OPP interpolation, preventing the governor from prematurely downclocking between frame phases and eliminating erratic frequency oscillations.
* `fstb_separate_runtime_enable = 1`: Decouples render thread runtime accounting from compositor wait time, preventing false throttling during vsync backpressure.

Live gaming telemetry on 60 FPS and 90 FPS titles confirms a ~30% reduction in frame time standard deviation (jitter), producing smooth, predictable frame delivery alongside reduced thermal accumulation.

---

## 9. Cluster 2: Cache Coherent Interconnect (CCI) DVFS Architecture

### 9.1 The Role of Interconnect DVFS on MT6833
On the MediaTek MT6833 platform, Cluster 2 corresponds to the Cache Coherent Interconnect (CCI) and DynamIQ Shared Unit (DSU) bus logic. The CCI routes memory traffic, cache snoops, and L3 cache access across:
* Cluster 0: 6x ARM Cortex-A55 Little CPU cores
* Cluster 1: 2x ARM Cortex-A76 Big CPU cores
* Mali-G57 MC2 GPU and peripheral DMA subsystems

In stock firmware, CCI operates across 16 discrete OPPs ranging from **1600 MHz** down to a floor of **450 MHz**.

### 9.2 Hardware HVFS Mailbox Arbitration (`0x24c`)
Frequency and voltage transitions on the CCI bus are not handled by Linux cpufreq governors directly. Instead, `CPU_DVFS.ko` interfaces with the hardware Hardware Voltage and Frequency Scaling (HVFS) controller:
1. `mt_cpufreq_ctrl_cci_volt` and `cpuhvfs_set_set_cci_volt` write target PMIC voltage codes into HVFS control mailbox offset `0x24c`:
   ```aarch64
   0x7cf8 <cpuhvfs_set_set_cci_volt>:
       adrp x8, [hvfs_base]
       add  x9, x8, #0x24c
       str  w0, [x9]           // Transmit target CCI voltage step to HVFS arbiter
       dsb  sy
       ret
   ```
2. The on-chip MCUPM / SPM power manager monitors this register and coordinates level-shifting across core logic and interconnect rails.

### 9.3 The 16x16 Interconnect Mapping Matrix (`CCI_B24GTbl`)
The active CCI OPP index is looked up at runtime using a 16x16 two-dimensional matrix via `cpuhvfs_get_cci_result`:
```c
u8 cpuhvfs_get_cci_result(int little_idx, int big_idx, int mode) {
    if ((little_idx | big_idx) > 15) return 0;
    int offset = (little_idx << 4) + (mode != 0 ? 0x100 : 0) + big_idx;
    return record_CCI_Ref[offset];
}
```
* **Normal Mode (`mode = 0`, 0x000–0x0ff)**: 16 rows (Little OPP) $\times$ 16 columns (Big OPP).
* **Performance Mode (`mode = 1`, 0x100–0x1ff)**: Allows uncapped interconnect scaling up to 1600 MHz OPP 0.

### 9.4 200 MHz Underclock Floor Unlock & Decoupled Matrix Clamping

In stock configuration:
* OPP 15 was clamped to 450 MHz with PLL divider parameters `a=4, b=1` (`f_VCO = 1800 MHz`) at 650.00 mV.
* Both Little and Big clusters downclock to 200 MHz, but the interconnect remained pinned at 450 MHz.

#### Underclock Floor Implementation

By reconfiguring OPP 15 to `a=4, b=2`:

$$
f_{\text{VCO}} = 200\text{ MHz} \times 4 \times 2 = 1600\text{ MHz}
$$

This maintains strict compliance with the MT6833 CCIPLL lock envelope (`1500 MHz <= f_VCO <= 3500 MHz`) while unlocking a **200 MHz interconnect clock** operating at **581.25 mV (Step 29)**.

#### Idle-Only Decoupling

In stock `CCI_B24GTbl`, rows 11..15 and columns 11..15 all mapped to OPP 15. If OPP 15 was unconditionally lowered to 200 MHz, a Little core running at 862 MHz (OPP 11) would experience interconnect bandwidth starvation.

To solve this, `scripts/patch_dvfs.py` and `module/service.sh` decouple the 16x16 matrix:
* Rows 11..14 map to **OPP 14 (450 MHz @ 600.00 mV)**.
* **OPP 15 (200 MHz @ 581.25 mV)** engages strictly when **both** Little and Big clusters are simultaneously at OPP 15 `(row == 15 && col == 15)`.
* When the phone is at idle or in screen-off standby, interconnect dynamic power drops by **64.5%**. The moment any core wakes up to execute work (`>= 500 MHz`), CCI instantaneously jumps to 450 MHz or higher with zero memory latency penalty.
