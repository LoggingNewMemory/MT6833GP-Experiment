# Reverse Engineering MediaTek MT6833 DVFS & EEM Modules with Ghidra

This guide documents the reverse engineering process, function signatures, struct layouts, and opcode patch offsets for `CPU_DVFS.ko`, `mtk_gpufreq_mt6833.ko`, and `mediatek_eem.ko`.

---

## 1. `CPU_DVFS.ko` Reverse Engineering

### Binary Layout (ELF 64-bit LSB relocatable, ARM aarch64)
* Section `.text`: File Offset `0x00001000`, Size `0x0000a428`
* Section `.rodata`: File Offset `0x0000e4a0`, Size `0x00002038`

### Key Struct: `struct opp_desc`
Each entry in the nominal table is 16 bytes:
```c
struct opp_desc {
    uint16_t freq_mhz;   // Target clock frequency (e.g. 2000, 2400)
    uint16_t reserved;   // Zero padding
    uint32_t volt_step;  // Step: volt_mv = step * 6.25 + 400.0
    uint8_t  a;          // PLL post-divider factor A (VCO calculation)
    uint8_t  _pad[3];    // Padding
    uint32_t b;          // PLL post-divider factor B
};
```
* **PLL VCO Frequency Equation**:
  $$f_{\text{VCO}} = f_{\text{target}} \times a \times b$$
  For MT6833 PLL stability, $f_{\text{VCO}}$ must fall within $1500\text{ MHz} \le f_{\text{VCO}} \le 3500\text{ MHz}$.
  - For $200\text{ MHz}$: $a = 4, b = 2 \implies f_{\text{VCO}} = 200 \times 4 \times 2 = 1600\text{ MHz}$ (Stable).

### Table Offsets in `CPU_DVFS.ko`
* `MT6833_B24GTbl`: `0xd7f8` (768 bytes = 16 entries $\times$ 3 clusters)
* `MT6833_B20GTbl`: `0xd4f8` (768 bytes)
* `FY_6833Tbl`: `0xd1f8` (768 bytes)
* `opp_tbl_*` fallback tables: `0xc610`, `0xc690`, `0xc710`, `0xc790`, `0xc810`, `0xc890`, `0xc910`, `0xc990`, `0xca10`
* `opp_tbl_method_*`: `0xc4f0`–`0xc5f0`

### EEM Bypass Functions
When `mediatek_eem.ko` probes, it attempts to overwrite the tables via:
1. `mt_cpufreq_update_volt` (Function Address: `.text + 0x5204`, File Offset: `0x6204`)
2. `mt_cpufreq_update_legacy_volt` (Function Address: `.text + 0x5408`, File Offset: `0x6408`)

#### Patch Sequence (ARM64 Machine Code)
Replace the 16-byte function prologue:
```aarch64
paciasp      // \x3f\x23\x03\xd5
mov w0, wzr  // \xe0\x03\x1f\x2a
autiasp      // \xbf\x23\x03\xd5
ret          // \xc0\x03\x5f\xd6
```

---

## 2. `mtk_gpufreq_mt6833.ko` Reverse Engineering

### Table Structure: `g_default_gpu`
Located in `.rodata` at file offset `0xb4e8` (identified by header signature `1068000` / `0x00104cb0`):
Each entry is 24 bytes (`6 x uint32_t`):
```c
struct gpu_opp_entry {
    uint32_t freq_khz;   // e.g. 1068000 (1068 MHz)
    uint32_t vgpu_10uv;  // Core voltage in 10 uV units (80000 = 800.00 mV)
    uint32_t vsram_10uv; // SRAM voltage in 10 uV units (80000 = 800.00 mV)
    uint32_t posdiv;     // Post-divider configuration
    uint32_t vaging;     // Aging voltage offset
    uint32_t power;      // Power rating index
};
```
* 45 Total Operating Points (from 1068 MHz down to 390 MHz).
* Voltage values are stored in 10 uV units ($80000 \times 10\text{ uV} = 800000\text{ uV} = 800.00\text{ mV}$).
* **Hardware Limit**: $\Delta(V_{\text{sram}} - V_{\text{gpu}}) \le 200.00\text{ mV}$. Clamped at lower frequencies to prevent MT6359 over-differential shutdown.

---

## 3. `mediatek_eem.ko` Reverse Engineering

### Decompiled `eem_probe` Call Flow
In Ghidra decompiler (`eem_probe` at `0x00101088`):
```c
// Cluster 0: Little
bl mt_cpufreq_update_legacy_volt(0, &eem_table_cluster0);

// Cluster 1: Big
bl mt_cpufreq_update_legacy_volt(1, &eem_table_cluster1);

// Cluster 2: CCI
bl mt_cpufreq_update_legacy_volt(2, &eem_table_cluster2);
```

Because `mediatek_eem.ko` never directly calls `regulator_set_voltage()`, returning `0` from `mt_cpufreq_update_legacy_volt` completely disarms the overwrite mechanism without breaking Energy Aware Scheduling (EAS) or thermal monitoring.

---

## 4. CPU Cache SRAM Dynamic Tracking & MCUPM Architecture

### Regulator Transfer Functions in `CPU_DVFS.ko`
Disassembly in Ghidra identified two distinct voltage step converters:
1. **Core Logic Regulator Converter (`mt6359_vproc_transfer2volt` at `0x9c28`)**:
   ```c
   int mt6359_vproc_transfer2volt(uint32_t step) {
       return step * 625 + 40000; // Base: 400.00 mV (400000 uV)
   }
   ```
2. **Cache SRAM Regulator Converter (`mt6359_vsram_transfer2volt` at `0x9af4`)**:
   ```c
   int mt6359_vsram_transfer2volt(uint32_t step) {
       return step * 625 + 50000; // Base: 500.00 mV (500000 uV)
   }
   ```
3. **SRAM Actuation Routine (`set_cur_volt_sram_cpu` at `0x9a7c`)**:
   Invokes `regulator_set_voltage()` on `ldo_vsram_proc1` (Little cache) or `ldo_vsram_proc2` (Big cache).

### The MCUPM SYSRAM Channel (`0x11bc10`)
* In `cpuhvfs_pvt_tbl_create` (`0x8284`), the kernel populates `_recordRef` at physical SRAM address `0x11bc10` (inside MCUPM SYSRAM `0x11b000`).
* The kernel struct `opp_desc` only encodes a single 12-bit `volt_step` field for core logic.
* There is no independent SRAM voltage table in the kernel driver. The on-chip MCUPM firmware dynamically calculates both core and SRAM voltages from the single `volt_step` during OPP switches.
* Consequently, modifying `volt_step` in `CPU_DVFS.ko` scales down **both Core Logic and Cache SRAM** in lockstep.

### The Hardware Tracking Formula & Retention Floor
Telemetry readings under live frequency sweeping proved the exact formula enforced by MCUPM hardware:

$$V_{\text{sram}} = \max\left(750.00\text{ mV},\; V_{\text{proc}} + 100.00\text{ mV}\right)$$

* **Load Tracking**: High OPPs maintain $V_{\text{sram}} = V_{\text{proc}} + 100.00\text{ mV}$.
* **750.00 mV Silicon Clamp**: Prevents 6T SRAM bitcell retention failures ($V_{\text{min}}$) during low-frequency and idle operation.
