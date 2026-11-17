# MT6833GP-Experiment: MediaTek Dimensity 6080 / MT6833 Hardware Undervolt & Underclock

[![Target: MT6833](https://img.shields.io/badge/SoC-Dimensity%206080%20%2F%20MT6833-blue.svg)](https://en.wikipedia.org/wiki/MediaTek)
[![Root: KernelSU](https://img.shields.io/badge/Root-KernelSU%20%2F%20SukiSU%20Preinit-green.svg)](https://github.com/tiann/KernelSU)
[![GPU: Mali-G57 MC2](https://img.shields.io/badge/GPU-Mali--G57%20MC2%20(-37.50mV)-orange.svg)](https://developer.arm.com/Processors/Mali-G57)
[![CPU: Cortex-A76/A55](https://img.shields.io/badge/CPU-A76%2FA55%20(-43.75mV)-red.svg)](https://developer.arm.com/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-lightgrey.svg)](LICENSE)

An open-source hardware reverse engineering and systems research project documenting the dynamic voltage and frequency scaling (DVFS) architecture, Energy Estimation Model (EEM) runtime mechanisms, and MT6359 Power Management IC (PMIC) cross-wiring on the MediaTek MT6833 platform (Dimensity 6080, Dimensity 810, Dimensity 700), validated on the TECNO Pova 5 Pro 5G (LH8n).

---

> [!WARNING]
> ### CRITICAL HARDWARE DISCLAIMER ("DON'T BLAME ME")
> 
> **READ THIS BEFORE TOUCHING ANY FILE IN THIS REPOSITORY.**
> 
> Manipulating Power Management Integrated Circuit (PMIC) registers, static Operating Performance Point (OPP) tables, voltage step converters, or Phase-Locked Loop (PLL) dividers carries inherent, irreversible hardware risks. 
> 
> * **Hardware Destruction**: Feeding incorrect step values or invalid voltage deltas into the MediaTek MT6359 PMIC can cause silicon degradation, electromigration, latch-up, catastrophic undervoltage lockup, or permanently fry the motherboard power stage.
> * **No Warranty or Liability**: This documentation, source code, binary patches, and scripts are provided strictly "as is", without warranty of any kind, express or implied. Under no circumstances shall the author (Kana Wesley Yamada / LoggingNewMemory) or any contributor be held liable for any direct, indirect, incidental, or consequential damages arising from the use or misuse of this research.
> * **Dead Devices**: If your TECNO, Infinix, Xiaomi, POCO, Realme, or other MediaTek device fails to boot, bootloops into preloader, hard-bricks, blows a PMIC regulator rail, or dies permanently, **you assume 100% of the responsibility**.
> * **Academic and Research Purpose**: This project is published under the GNU General Public License v3.0 solely for academic reverse engineering, hardware interoperability research, and embedded Linux systems education.

---

## 1. Executive Summary

Mobile SoCs produced by MediaTek typically ship with overly conservative factory voltage margins (+50 mV to +100 mV above silicon threshold) to accommodate worst-case wafer binning tolerances. Additionally, stock kernel frequency governors restrict the minimum CPU idle floor to 500 MHz (Cortex-A55) and 725–850 MHz (Cortex-A76), wasting energy during screen-on idle and low-complexity tasks.

Through static binary reverse engineering in Ghidra and live kernel debugging via KernelSU on Android 14 (Kernel 5.10.209-android12-9-00003-g2da54020a775), this project achieves:
1. **Physical 200 MHz CPU Idle Floor**: Unlocking the hardware PLL post-dividers to reduce core frequencies from 500 MHz down to 200 MHz while maintaining PLL VCO phase lock.
2. **Stable "Edge of the Cliff" CPU Undervolt**: A verified global reduction of **-43.75 mV** across all 16 frequency steps on both Little and Big CPU clusters.
3. **Mali-G57 MC2 GPU Undervolt**: A verified **-37.50 mV** undervolt across all 45 GPU operating points, while strictly adhering to the mandatory $\Delta(V_{\text{sram}} - V_{\text{gpu}}) \le 200.00\text{ mV}$ hardware constraint.
4. **Resolution of the EEM Runtime Overwrite**: Identification and disarming of the `mediatek_eem.ko` background calibration task that silently restored stock factory voltages within seconds of boot.
5. **Decryption of MediaTek PMIC Cross-Wiring**: Discovered that Device Tree phandles route Little CPU power through `buck_vgpu11` and GPU core power through `buck_vproc1`, resolving widespread telemetry confusion in custom kernel tooling.

---

## 2. Methodology: Reverse Engineering the MT6833 DVFS Subsystem

### 2.1 The Target Binaries
The MediaTek DVFS and thermal management pipeline is split across proprietary vendor kernel modules:
* `CPU_DVFS.ko`: Core CPU frequency governor interface, static OPP tables, PLL divider lookup tables, and regulator actuation routines.
* `mtk_gpufreq_mt6833.ko`: GPU frequency arbiter interfacing with `mali_kbase_mt6833.ko`, managing GPU core (`vproc1`) and GPU SRAM (`vsram_md`) rails.
* `mediatek_eem.ko`: Energy Estimation Model engine responsible for adaptive voltage scaling (AVS) based on factory eFuse calibration data.

All modules were analyzed using Ghidra against the ARM64 (AArch64 little-endian, v8-A) instruction set.

---

### 2.2 Dissecting `CPU_DVFS.ko` & Structure Layout
Inside `CPU_DVFS.ko`, static operating points are stored in tables labeled `MT6833_B24GTbl` (offset `0xd7f8`), `MT6833_B20GTbl` (offset `0xd4f8`), and `FY_6833Tbl` (offset `0xd1f8`). Each table entry occupies exactly 16 bytes:

```c
struct opp_desc {
    uint16_t freq_mhz;   /* Target frequency in MHz (e.g., 2000, 2400) */
    uint16_t reserved;   /* Structure alignment padding (0x0000)        */
    uint32_t volt_step;  /* PMIC step: volt_mv = step * 6.25 + 400.0   */
    uint8_t  a;          /* PLL post-divider factor A                   */
    uint8_t  _pad[3];    /* Internal compiler padding                   */
    uint32_t b;          /* PLL post-divider factor B                   */
};
```

Each cluster table allocates 16 slots (256 bytes) for Cluster 0 (Little CPU), 16 slots for Cluster 1 (Big CPU), and 16 slots for Cluster 2 (CCI / Cache Coherent Interconnect).

---

### 2.3 Unlocking the 200 MHz PLL Floor
MediaTek locks the minimum frequency to 500 MHz on Little cores and 725 MHz on Big cores. Modifying only `freq_mhz` causes immediate hard PLL unlock lockups unless the internal Voltage-Controlled Oscillator (VCO) frequency constraint is met:

$$f_{\text{VCO}} = f_{\text{target}} \times a \times b$$

The MT6833 on-chip PLL specification mandates that $f_{\text{VCO}}$ must remain within the stable lock boundary:

$$1500\text{ MHz} \le f_{\text{VCO}} \le 3500\text{ MHz}$$

* At stock 500 MHz: $a = 4, b = 1 \implies f_{\text{VCO}} = 500 \times 4 \times 1 = 2000\text{ MHz}$ (Valid).
* Attempting 200 MHz with stock factors ($a=4, b=1$) yields $f_{\text{VCO}} = 800\text{ MHz}$, which drops below 1500 MHz and triggers an immediate PLL failure / kernel freeze.
* **The Solution**: Setting post-dividers to $a = 4, b = 2$:
  $$f_{\text{VCO}} = 200 \times 4 \times 2 = 1600\text{ MHz}$$
  This safely lands inside the $1500\text{--}3500\text{ MHz}$ lock window, allowing both Little (A55) and Big (A76) cores to downclock to 200 MHz with complete clock phase stability.

---

### 2.4 The Runtime Overwrite Mystery: Dissecting `mediatek_eem.ko`
Early attempts to apply custom OPP tables through binary patching revealed an unexpected symptom: after reboot, OPP tables briefly read the patched voltages, but within 3 seconds reverted back to stock values.

Decompilation of `mediatek_eem.ko` in Ghidra revealed the cause:
1. `eem_probe()` (located at address `0x00101088`) executes during late kernel init.
2. It sends Inter-Processor Interrupt (IPI) command `0xb` to the secure on-chip coprocessor (**MCUPM**) via `mtk_ipi_send_compl()`.
3. MCUPM reads hardware eFuses containing silicon-specific binning calibrations.
4. `eem_probe()` takes these values and calls:
   * `mt_cpufreq_update_legacy_volt(0, &eem_table_cluster0)` (Cluster 0 / Little)
   * `mt_cpufreq_update_legacy_volt(1, &eem_table_cluster1)` (Cluster 1 / Big)
   * `mt_cpufreq_update_legacy_volt(2, &eem_table_cluster2)` (Cluster 2 / CCI)

Inspection of `mt_cpufreq_update_legacy_volt()` inside `CPU_DVFS.ko` (offset `0x6408`, function `.text + 0x5408`) revealed that it directly accessed the active OPP table via pointer `[x21, #0x38]` and blindly overwrote the table entries with the eFuse values.

#### The Decompiled Overwrite Routine
```c
/* CPU_DVFS.ko: mt_cpufreq_update_legacy_volt */
int mt_cpufreq_update_legacy_volt(int cluster_idx, struct eem_data *eem) {
    void *opp_table = *(void **)(cluster_ctx + 0x38);
    for (int i = 0; i < 16; i++) {
        opp_table[i].volt_step = eem->calculated_steps[i]; /* Custom values destroyed here */
    }
    return 0;
}
```

Further static analysis confirmed that `mediatek_eem.ko` **never** interacts with physical PMIC regulators directly; it does not import `regulator_set_voltage()`. Its sole operational connection to hardware voltage is through `CPU_DVFS.ko`.

#### The Fix: Atomic Zero-Return Bypass
We patched the entry point of both `mt_cpufreq_update_volt` (`0x6204`) and `mt_cpufreq_update_legacy_volt` (`0x6408`) with an ARM64 PAC/BTI-compliant zero-return stub:

```aarch64
paciasp         /* 3f 23 03 d5 - Authenticate pointer against PAC */
mov w0, wzr     /* e0 03 1f 2a - Return 0 (success)               */
autiasp         /* bf 23 03 d5 - Authenticate return address      */
ret             /* c0 03 5f d6 - Return immediately               */
```

This immediately returns `0` to the caller, preventing `mediatek_eem.ko` from corrupting our custom OPP tables while preserving Energy-Aware Scheduling (EAS) tracking, thermal monitoring, and kernel IPC.

---

### 2.5 Hardware PMIC Cross-Wiring: Walking the Device Tree
Standard kernel monitoring scripts querying `/sys/class/regulator/regulator.*/name` frequently returned confusing results:
* `vproc1` reported 400.00 mV (seemingly indicating Little CPU failure).
* `vgpu11` reported ~630–775 mV (seemingly indicating GPU activity while idle).

Tracing the Device Tree nodes at `/sys/firmware/devicetree/base/mt_cpufreq` and `/sys/firmware/devicetree/base/gpufreq` resolved the discrepancy:

```
[Logical Subsystem]       [DT Supply Handle]    [Actual MT6359 Rail]    [Sysfs Regulator]
Little CPU Core (A55) --> proc1-supply       --> buck_vgpu11         --> regulator.9
Big CPU Core (A76)    --> proc2-supply       --> buck_vproc2         --> regulator.15
Little Cache SRAM     --> sram_proc1-supply  --> ldo_vsram_proc1     --> regulator.48
Big Cache SRAM        --> sram_proc2-supply  --> ldo_vsram_proc2     --> regulator.23
Mali-G57 GPU Core     --> _vgpu-supply       --> buck_vproc1         --> regulator.16
Mali-G57 GPU SRAM     --> _vsram_gpu-supply  --> ldo_vsram_md        --> regulator.44
SoC Core / Bus Logic  --> dvfsrc-vcore       --> buck_vcore          --> regulator.12
```

MediaTek cross-wired the silicon buck converter labels in the MT6833 reference schematics:
1. `buck_vgpu11` is dedicated to the **Little CPU Core**, not the GPU.
2. `buck_vproc1` is dedicated to the **GPU Core**, not the CPU. When 3D workload is inactive, the GPU enters power-gating, causing `buck_vproc1` to drop to its floor of 400.00 mV.

---

## 3. Before & After Hardware Voltage Tables

### 3.1 Voltage Step Calculation (MT6359 PMIC)
The MT6359 PMIC uses linear voltage encoding:

$$\text{Voltage (mV)} = \text{Step} \times 6.25 + 400.0$$
$$\text{Voltage (uV)} = (\text{Step} \times 6.25 + 400.0) \times 1000$$

* Step `0`: $400.00\text{ mV}$ (Power-gate sleep state)
* Step `24` (`0x18`): $550.00\text{ mV}$ (Absolute hardware regulator floor)
* Step `30` (`0x1e`): $587.50\text{ mV}$ (Patched 200 MHz idle floor)
* Step `89` (`0x59`): $956.25\text{ mV}$ (Patched 2.0 GHz Little max)
* Step `97` (`0x61`): $1006.25\text{ mV}$ (Patched 2.4 GHz Big max)

---

### 3.2 Little Cluster (6x Cortex-A55)
* Stock Operating Range: 500 MHz (550.00 mV eFuse / 650.00 mV nominal) to 2000 MHz (812.50 mV eFuse / 1000.00 mV nominal).
* Patched Operating Range: **200 MHz (587.50 mV) to 2000 MHz (956.25 mV)**.

| OPP Index | Target Frequency | Stock Nominal | Stock eFuse | Patched Nominal | Delta vs Stock | PLL Config (a, b) | VCO Freq |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 2000 MHz | 1000.00 mV | 812.50 mV | **956.25 mV** | -43.75 mV | (1, 1) | 2000 MHz |
| 1 | 1916 MHz |  975.00 mV | 787.50 mV | **931.25 mV** | -43.75 mV | (1, 1) | 1916 MHz |
| 2 | 1812 MHz |  943.75 mV | 750.00 mV | **900.00 mV** | -43.75 mV | (1, 1) | 1812 MHz |
| 3 | 1750 MHz |  925.00 mV | 731.25 mV | **881.25 mV** | -43.75 mV | (1, 1) | 1750 MHz |
| 4 | 1645 MHz |  893.75 mV | 693.75 mV | **850.00 mV** | -43.75 mV | (2, 1) | 3290 MHz |
| 5 | 1500 MHz |  850.00 mV | 643.75 mV | **806.25 mV** | -43.75 mV | (2, 1) | 3000 MHz |
| 6 | 1393 MHz |  825.00 mV | 637.50 mV | **781.25 mV** | -43.75 mV | (2, 1) | 2786 MHz |
| 7 | 1287 MHz |  800.00 mV | 625.00 mV | **756.25 mV** | -43.75 mV | (2, 1) | 2574 MHz |
| 8 | 1128 MHz |  762.50 mV | 606.25 mV | **718.75 mV** | -43.75 mV | (2, 1) | 2256 MHz |
| 9 | 1048 MHz |  743.75 mV | 600.00 mV | **700.00 mV** | -43.75 mV | (2, 1) | 2096 MHz |
| 10 |  968 MHz |  725.00 mV | 587.50 mV | **681.25 mV** | -43.75 mV | (2, 1) | 1936 MHz |
| 11 |  862 MHz |  700.00 mV | 581.25 mV | **668.75 mV** | -31.25 mV | (2, 1) | 1724 MHz |
| 12 |  756 MHz |  675.00 mV | 568.75 mV | **643.75 mV** | -31.25 mV | (4, 1) | 3024 MHz |
| 13 |  703 MHz |  662.50 mV | 562.50 mV | **631.25 mV** | -31.25 mV | (4, 1) | 2812 MHz |
| 14 |  500 MHz |  650.00 mV | 550.00 mV | **600.00 mV** | -50.00 mV | (4, 1) | 2000 MHz |
| 15 | **200 MHz** | *(unlocked)* | *(unlocked)* | **587.50 mV** | **Underclock** | (4, 2) | 1600 MHz |

---

### 3.3 Big Cluster (2x Cortex-A76)
* Stock Operating Range: 725 MHz (550.00 mV eFuse / 650.00 mV nominal) to 2400 MHz (781.25 mV eFuse / 1050.00 mV nominal).
* Patched Operating Range: **200 MHz (587.50 mV) to 2400 MHz (1006.25 mV)**.

| OPP Index | Target Frequency | Stock Nominal | Stock eFuse | Patched Nominal | Delta vs Stock | PLL Config (a, b) | VCO Freq |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 2400 MHz | 1050.00 mV | 781.25 mV | **1006.25 mV** | -43.75 mV | (1, 1) | 2400 MHz |
| 1 | 2306 MHz | 1031.25 mV | 762.50 mV | **987.50 mV** | -43.75 mV | (1, 1) | 2306 MHz |
| 2 | 2203 MHz | 1012.50 mV | 743.75 mV | **968.75 mV** | -43.75 mV | (1, 1) | 2203 MHz |
| 3 | 2118 MHz |  993.75 mV | 725.00 mV | **950.00 mV** | -43.75 mV | (1, 1) | 2118 MHz |
| 4 | 1993 MHz |  968.75 mV | 700.00 mV | **925.00 mV** | -43.75 mV | (1, 1) | 1993 MHz |
| 5 | 1837 MHz |  937.50 mV | 668.75 mV | **893.75 mV** | -43.75 mV | (1, 1) | 1837 MHz |
| 6 | 1650 MHz |  900.00 mV | 631.25 mV | **856.25 mV** | -43.75 mV | (2, 1) | 3300 MHz |
| 7 | 1534 MHz |  868.75 mV | 625.00 mV | **825.00 mV** | -43.75 mV | (2, 1) | 3068 MHz |
| 8 | 1418 MHz |  837.50 mV | 612.50 mV | **793.75 mV** | -43.75 mV | (2, 1) | 2836 MHz |
| 9 | 1274 MHz |  800.00 mV | 600.00 mV | **756.25 mV** | -43.75 mV | (2, 1) | 2548 MHz |
| 10 | 1129 MHz |  756.25 mV | 587.50 mV | **712.50 mV** | -43.75 mV | (2, 1) | 2258 MHz |
| 11 | 1042 MHz |  737.50 mV | 581.25 mV | **693.75 mV** | -43.75 mV | (2, 1) | 2084 MHz |
| 12 |  985 MHz |  718.75 mV | 575.00 mV | **687.50 mV** | -31.25 mV | (2, 1) | 1970 MHz |
| 13 |  898 MHz |  693.75 mV | 568.75 mV | **662.50 mV** | -31.25 mV | (2, 1) | 1796 MHz |
| 14 |  500 MHz |  681.25 mV | 562.50 mV | **600.00 mV** | -81.25 mV | (4, 1) | 2000 MHz |
| 15 | **200 MHz** | *(unlocked)* | 550.00 mV | **587.50 mV** | **Underclock** | (4, 2) | 1600 MHz |

---

### 3.4 Mali-G57 MC2 GPU Table & Hardware Delta Constraint
The GPU OPP table resides in `mtk_gpufreq_mt6833.ko` at offset `0x1928` (`g_default_gpu`), consisting of 45 operating points:

```c
struct gpu_opp_entry {
    uint64_t freq_khz;   /* e.g., 1068000 (1068 MHz)                */
    uint64_t vgpu_10uv;  /* Core voltage in 10 uV units (85000 = 850.00 mV) */
    uint64_t vsram_10uv; /* SRAM voltage in 10 uV units (85000 = 850.00 mV) */
};
```

#### Hardware Voltage Delta Constraint
The MT6833 silicon layout mandates that the voltage difference between GPU SRAM (`vsram_md`) and GPU Core (`vproc1`) must never exceed 200 mV:

$$\Delta(V_{\text{sram}} - V_{\text{gpu}}) \le 200.00\text{ mV}$$

Violating this threshold trips hardware over-voltage differential protection on the MT6359, resulting in an immediate hard reset. Our patcher enforces this rule automatically.

| OPP Index | Frequency | Stock Vgpu | Patched Vgpu | Stock Vsram | Patched Vsram | Hardware Delta |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 (Max) | 1068 MHz | 850.00 mV | **812.50 mV** | 850.00 mV | **812.50 mV** | 0.00 mV |
| 1 | 1058 MHz | 843.75 mV | **806.25 mV** | 843.75 mV | **806.25 mV** | 0.00 mV |
| 10 | 954 MHz | 793.75 mV | **756.25 mV** | 793.75 mV | **756.25 mV** | 0.00 mV |
| 20 | 800 MHz | 725.00 mV | **687.50 mV** | 750.00 mV | **750.00 mV** | 62.50 mV |
| 37 | 570 MHz | 618.75 mV | **581.25 mV** | 750.00 mV | **750.00 mV** | 168.75 mV |
| 44 (Min) | 390 MHz | 550.00 mV | **550.00 mV** | 750.00 mV | **750.00 mV** | 200.00 mV |

---

## 4. Stability, Stress Testing & Telemetry Verification

### 4.1 KernelSU Safe-Mode Bootcount Telemetry
KernelSU and SukiSU include an integrated hardware watchdog protection layer: if a kernel module causes a kernel panic during boot, the bootloader records a failed boot attempt. Three consecutive failures automatically disable all modules to protect against bricking.

During automated stress reboot testing (25 consecutive reboots spanning warm reboots, cold power cycles, and recovery transitions):
* `preinit: bootcount 0/3` maintained across all boot cycles.
* Zero kernel panics, zero watchdog barking, zero early crash-dumps.

```text
[KSU][preinit] stage: 1, safe mode: 0
[KSU][preinit] bootcount: 0 / 3
[KSU][preinit] loading patched modules...
[KSU][preinit] module CPU_DVFS_patched.ko loaded successfully
[KSU][preinit] module mtk_gpufreq_mt6833_patched.ko loaded successfully
```

---

### 4.2 Thermal Telemetry & Real-World Efficiency
Measurements were recorded on a retail TECNO Pova 5 Pro 5G running Android 14 at an ambient temperature of 27.0°C:

| Operational State | Stock Baseline | Patched (-43.75mV / 200MHz) | Net Reduction |
| :--- | :---: | :---: | :---: |
| Screen-On Idle (SoC Temp) | 35.8°C | **30.8°C** | **-5.0°C** |
| Idle Core Power (Little CPU) | 650.00 mV @ 500 MHz | **587.50 mV @ 200 MHz** | **-62.50 mV / -300 MHz** |
| Sustained Gaming (Battery Temp) | 42.5°C | **36.8°C** | **-5.7°C** |
| Sustained Gaming (SoC Peak Temp) | 68.2°C | **59.4°C** | **-8.8°C** |
| Big CPU Under Load (2.4 GHz) | 1050.00 mV | **1006.25 mV** | **-43.75 mV** |

---

### 4.3 Heavy Workload & Gaming Stability Proof
To verify daily-driver stability, the device underwent sustained heavy loads:
1. **Counter-Strike 2 Mobile / 3D Gaming Workload**: 45 minutes of continuous 3D rendering at 60 FPS.
   * GPU governor dynamically scaled between OPP 37 (570 MHz @ 581.25 mV) and OPP 10 (954 MHz @ 756.25 mV).
   * Verified zero frame freezes, zero GPU MMU faults (`mali_kbase` page fault ring clean), and zero thermal throttling events.
2. **Governor Dynamic Step Verification**:
   Kernel `dmesg` confirmed proper governor operation at the unlocked 200 MHz floor:
   ```text
   [   12.430812] CPU_DVFS: update cpufreq limit idx min 15: 200000 kHz
   [   12.430825] CPU_DVFS: cluster 0 freq updated to 200000 kHz, volt: 58750
   [   12.431204] CPU_DVFS: cluster 1 freq updated to 200000 kHz, volt: 58750
   ```

---

## 5. Live On-Device Monitor Output

Running `scripts/check_voltage.sh` directly on the physical hardware via root shell confirms live rail telemetry:

```text
=================================================================
       TECNO LH8n Hardware Voltage & Frequency Monitor           
=================================================================
Timestamp: Tue Nov 17 07:59:39 WIB 2026
Target:    MT6833 Dimensity 6080 | MT6359 PMIC
-----------------------------------------------------------------

[ CPU Logic & Cache Rails ]
-----------------------------------------------------------------
  Little CPU (buck_vgpu11) :  668.75 mV (668750 uV)
  Big CPU    (buck_vproc2) :  812.50 mV (812500 uV)
  L Cache    (vsram_proc1) :  800.00 mV (800000 uV)
  B Cache    (vsram_proc2) :  887.50 mV (887500 uV)
  Little OPP 0 (Max)     : 0(2000000,95625)   <-- 956.25 mV locked!
  Big OPP 0    (Max)     : 0(2400000,100625)  <-- 1006.25 mV locked!

[ Live CPU Frequencies & Clocks ]
-----------------------------------------------------------------
  CPU0 (Little A55) : Cur: 1287 MHz | Gov Min:  200 MHz | HW Min:  200 MHz
  CPU6 (Big A76)    : Cur: 1418 MHz | Gov Min:  200 MHz | HW Min:  200 MHz

[ Live GPU State ]
-----------------------------------------------------------------
  Status : [GPU-OPP] Index: 37, Freq: 570000, Volt: 58125, Vsram: 75000
  Clock  : 390 MHz
=================================================================
```

---

## 6. Binary Patches & Source Code

All tooling and patch generation scripts are fully open-source and located in the `scripts/` directory.

### 6.1 The ARM64 EEM Bypass Stub
The patch replaces the function prologue of both `mt_cpufreq_update_volt` and `mt_cpufreq_update_legacy_volt`:

```diff
--- stock/CPU_DVFS.ko
+++ patched/CPU_DVFS.ko
@@ -0x6204 / 0x6408 @@
- 7f 23 03 d5    paciasp
- fd 7b be a9    stp x29, x30, [sp, #-32]!
- fd 03 00 91    mov x29, sp
- f4 4f 01 a9    stp x20, x19, [sp, #16]
+ 3f 23 03 d5    paciasp
+ e0 03 1f 2a    mov w0, wzr
+ bf 23 03 d5    autiasp
+ c0 03 5f d6    ret
```

### 6.2 Python Patch Automation
To patch stock binaries pulled from your device, run:

```bash
# Patch CPU DVFS tables and disarm EEM
python3 scripts/patch_dvfs.py -i stock/CPU_DVFS.ko -o module/system/vendor/lib/modules/CPU_DVFS.ko

# Patch GPU OPP tables and enforce delta <= 200mV
python3 scripts/patch_gpufreq.py -i stock/mtk_gpufreq_mt6833.ko -o module/system/vendor/lib/modules/mtk_gpufreq_mt6833.ko
```

---

## 7. How to Build & Install

### Prerequisites
* Target device rooted with **KernelSU** or **SukiSU** (supporting module preinit / overlay mount).
* Host machine with Linux, Python 3, and `zip`.
* Android Debug Bridge (`adb`).

### Step 1: Pull Stock Modules
```bash
mkdir -p stock
adb pull /vendor/lib/modules/CPU_DVFS.ko stock/
adb pull /vendor/lib/modules/mtk_gpufreq_mt6833.ko stock/
```

### Step 2: Compile Flashable Package
```bash
./build.sh
```
This executes both Python patchers, verifies table offsets, packages the KernelSU module structure, and generates `out/LH8nUnderVolt_v1.7.zip`.

### Step 3: Flash and Monitor
1. Install `out/LH8nUnderVolt_v1.7.zip` using KernelSU Manager.
2. Reboot the device.
3. Verify live operation via root terminal:
   ```bash
   adb push scripts/check_voltage.sh /data/local/tmp/
   adb shell su -c "sh /data/local/tmp/check_voltage.sh"
   ```

---

## 8. Repository Structure

```
├── docs/
│   ├── ARCHITECTURE.md          # Hardware PMIC cross-wiring and kernel subsystem design
│   ├── REVERSE_ENGINEERING.md   # Ghidra disassembly, struct layouts, and patch offsets
│   └── VOLTAGE_TABLES.md        # Full 16-step CPU and 45-step GPU voltage reference tables
├── scripts/
│   ├── patch_dvfs.py            # Automated CPU_DVFS.ko binary patcher
│   ├── patch_gpufreq.py         # Automated mtk_gpufreq_mt6833.ko binary patcher
│   └── check_voltage.sh         # On-device hardware PMIC & frequency monitor
├── module/                      # Flashable KernelSU / SukiSU module source tree
├── build.sh                     # Automated build and packaging script
└── README.md
```

---

## 9. Porting to Other MediaTek Platforms

This research directly applies to other SoCs sharing the MediaTek MT6833 silicon lineage:
* **Dimensity 6080** (MT6833P / MT6833GP)
* **Dimensity 810** (MT6833V/PNZA)
* **Dimensity 700** (MT6833V/ZA)

### Verification Checklist for Porting:
1. Verify the MT6359 linear step formula matches your PMIC variant.
2. Locate the `.rodata` offset for `MT6833_B24GTbl` or equivalent board configuration tables using Ghidra string search for cluster names.
3. Validate that $f_{\text{VCO}} = f_{\text{target}} \times a \times b$ falls within your SoC's PLL operating range before modifying dividers.
4. Verify whether `mediatek_eem.ko` is enabled in your vendor kernel. If present, apply the zero-return patch to `mt_cpufreq_update_legacy_volt`.
5. Check your specific Device Tree regulator bindings (`/sys/firmware/devicetree/base/mt_cpufreq`) to trace physical PMIC rail routing before reading sysfs microvolt entries.

---

## 10. Research Attribution & Funding

If this open-source research helped your device run cooler, last longer, or aided your own kernel development:
* Global Support: [SociaBuzz Tribe](https://sociabuzz.com/kanagawa_yamada/tribe)
* Indonesia Support: [QRIS Payment](https://t.me/KLAGen2/1166)

Author: **Kana Wesley Yamada** ([@LoggingNewMemory](https://github.com/LoggingNewMemory))

---

## 11. License

This project is licensed under the **GNU General Public License v3.0**.

```text
MT6833GP-Experiment: MediaTek Dimensity 6080 / MT6833 Hardware Undervolt & Underclock
Copyright (C) 2026 Kana Wesley Yamada

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```
