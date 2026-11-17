# Reverse Engineering MediaTek MT6833 DVFS & EEM Modules with Ghidra

This guide documents the reverse engineering process, function signatures, struct layouts, and opcode patch offsets for `CPU_DVFS.ko`, `mtk_gpufreq_mt6833.ko`, `mediatek_eem.ko`, `mtk-dvfsrc.ko`, `mtk-dvfsrc-regulator.ko`, and `mtk-dvfsrc-helper.ko`.

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

---

## 5. DVFSRC Reverse Engineering & The 1-Instruction Clamp

The Dynamic Voltage and Frequency Scaling Resource Collector (DVFSRC) subsystem consists of three kernel modules located inside the `vendor_boot` ramdisk:
* `mtk-dvfsrc-regulator.ko`: Implements the Linux regulator framework driver for `dvfsrc-vcore`.
* `mtk-dvfsrc.ko`: Core hardware communication driver interfacing with System Power Manager (SPM).
* `mtk-dvfsrc-helper.ko`: Manages memory frequency and interconnect OPP tables.

### 5.1 `mtk-dvfsrc-regulator.ko` Disassembly & Patch

#### Function: `dvfsrc_set_voltage_sel`
* Section: `.text`
* Relative Offset: `+0x27c`
* File Offset: `0x127c`

In Ghidra decompilation:
```c
int dvfsrc_set_voltage_sel(struct regulator_dev *rdev, unsigned int selector) {
    ...
    // Stock passes selector directly in w2:
    mtk_dvfsrc_send_request(dvfsrc, 2, selector);
    ...
}
```

At file offset `0x127c`, the stock instruction prepares argument 3 (`w2`) from `w21`:
```aarch64
// Stock:
mov w2, w21        // 2a 15 03 e2
```

We patch this single instruction to clamp the selector to a maximum of 2 using the bitwise formula $\min(w, 2) = w \ \& \ \sim(w \gg 1)$:
```aarch64
// Patched:
bic w2, w21, w21, lsr #1   // a2 06 75 0a (Little-Endian: 0a 75 06 a2)
```

### 5.2 `mtk-dvfsrc.ko` Disassembly & Patch

#### Function: `mt6873_set_vcore_level`
* Section: `.text`
* Relative Offset: `+0x3760`
* File Offset: `0x4760`

In Ghidra decompilation:
```c
int mt6873_set_vcore_level(struct mtk_dvfsrc *dvfsrc, unsigned int level) {
    ...
    // Hardware write: (level << 4) written to SW_REQ register 0x1000600c
    writel((level << 4), dvfsrc->regs + 0xc);
    ...
}
```

At file offset `0x4760`, the stock instruction moves argument `w1` into local variable register `w20`:
```aarch64
// Stock:
mov w20, w1        // 2a 01 03 f4
```

We patch this instruction to enforce the hardware clamp before computing the bitshift:
```aarch64
// Patched:
bic w20, w1, w1, lsr #1    // 34 04 61 0a (Little-Endian: 0a 61 04 34)
```

### 5.3 `mtk-dvfsrc-helper.ko` Table Clamping

#### Table: `dvfsrc_opp_mt6833_lp4`
* Section: `.data`
* File Offset: `0xeb90`
* Entry Size: 24 bytes

The table defines 25 interconnect operating points (OPP 0 through OPP 24). OPPs 0 through 7 are configured for Level 3 (725.00 mV):
```c
struct dvfsrc_opp {
    uint32_t ddr_khz;      // Memory clock (e.g. 4266000, 3200000)
    uint32_t vcore_level;  // Vcore level index (0, 1, 2, 3)
    uint32_t flags;
    ...
};
```

At file offset `0xeb90`, each entry has `vcore_level` at offset `+0x04`:
* Entries 0..7: Byte `0x03` at offsets `0xeb94, 0xebac, 0xebc4, 0xebdc, 0xebf4, 0xec0c, 0xec24, 0xec3c`.
* Patched: Each byte modified from `0x03` (Level 3 / 725 mV) to `0x02` (Level 2 / 650 mV).

### 5.4 Verification of Mathematical Equivalence
The 1-instruction clamp `bic Rd, Rn, Rn, lsr #1` computes:
$$\text{result} = R_n \ \& \ \sim(R_n \gg 1)$$

For all 2-bit unsigned inputs:
* $R_n = 0$ (`0b00`): $0 \ \& \ \sim(0) = 0$ (Level 0 / 550.00 mV)
* $R_n = 1$ (`0b01`): $1 \ \& \ \sim(0) = 1$ (Level 1 / 600.00 mV)
* $R_n = 2$ (`0b10`): $2 \ \& \ \sim(1) = 2$ (Level 2 / 650.00 mV)
* $R_n = 3$ (`0b11`): $3 \ \& \ \sim(1) = 2$ (Level 3 clamped to Level 2 / 650.00 mV)

This achieves exact mathematical capping in a single 4-byte instruction without modifying branch predictors, condition flags, or requiring trampoline hooks.
