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

$$
f_{\text{VCO}} = f_{\text{target}} \times a \times b
$$

For MT6833 PLL stability, `f_VCO` must fall within `1500 MHz <= f_VCO <= 3500 MHz`.
- For 200 MHz: `a = 4, b = 2` -> `f_VCO = 200 x 4 x 2 = 1600 MHz` (Stable).

### Table Offsets in `CPU_DVFS.ko`
* `MT6833_B24GTbl`: `0xd7f8` (768 bytes = 16 entries x 3 clusters)
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
* Voltage values are stored in 10 uV units (80000 x 10 uV = 800,000 uV = 800.00 mV).
* **Hardware Limit**: `Delta(Vsram - Vgpu) <= 200.00 mV`. Clamped at lower frequencies to prevent MT6359 over-differential shutdown.

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

$$
V_{\text{sram}} = \max\left(750.00\text{ mV},\; V_{\text{proc}} + 100.00\text{ mV}\right)
$$

* **Load Tracking**: High OPPs maintain `Vsram = Vproc + 100.00 mV`.
* **750.00 mV Silicon Clamp**: Prevents 6T SRAM bitcell retention failures (`Vmin`) during low-frequency and idle operation.

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

We patch this single instruction to clamp the selector to a maximum of 2 using the bitwise formula `min(w, 2) = w & ~(w >> 1)`:
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

```c
result = Rn & ~(Rn >> 1)
```

For all 2-bit unsigned inputs:
* `Rn = 0` (`0b00`): `0 & ~0 = 0` (Level 0 / 550.00 mV)
* `Rn = 1` (`0b01`): `1 & ~0 = 1` (Level 1 / 600.00 mV)
* `Rn = 2` (`0b10`): `2 & ~1 = 2` (Level 2 / 650.00 mV)
* `Rn = 3` (`0b11`): `3 & ~1 = 2` (Level 3 clamped to Level 2 / 650.00 mV)

This achieves exact mathematical capping in a single 4-byte instruction without modifying branch predictors, condition flags, or requiring trampoline hooks.

---

## 6. `Upower.ko` Reverse Engineering (EAS Energy Model & PPM)

### 6.1 Binary Layout & Key Structs
* Architecture: ELF 64-bit LSB relocatable, ARM aarch64
* Section `.text`: File Offset `0x00001000`, Size `0x000014c8`
* Section `.data`: File Offset `0x00002548`, Size `0x00004238`

Each table entry inside `.data` consists of 48 bytes (`12 x uint32_t`):
```c
struct upower_opp_entry {
    uint32_t cap;           // Capacity index (e.g. 147 floor, 356 max Little, 1024 max Big)
    uint32_t reserved0;     // 0
    uint32_t volt_10uv;     // Voltage in 10 uV units (e.g. 100000 = 1000.00 mV)
    uint32_t dyn_power_uw;  // Dynamic power in microwatts (uW)
    uint32_t efficiency;    // Calculated power efficiency ((dyn + lkg) / cap)
    uint32_t lkg_power[6];  // Leakage power array across 6 temperature points
    uint32_t reserved1;     // 0
};
```

Following the 16 OPP entries (16 x 48 = 768 = 0x300 bytes), each table includes metadata tail fields (120 bytes = 0x78):
* `+0x300`: `col_num` (Cluster core count / columns, default: 4)
* `+0x304`: `row_num` (OPP count, default: 16)
* `+0x308`: `min_eff` (Minimum cluster efficiency across OPPs)
* `+0x30c`: `max_eff` (Maximum cluster efficiency across OPPs)
* `+0x374`: `turn_point` (Little cluster OPP threshold for task migration to Big cluster)

### 6.2 Table Symbol Addresses & File Offsets
The module contains static definitions for 3 hardware CPU bin revisions (`FY`, `B20G`, `B24G`):

```
+----------------------------+-------------+---------------+------------+
| Symbol Name                | Section VMA | File Offset   | Size       |
+----------------------------+-------------+---------------+------------+
| upower_tbl_l_FY            | .data+0x01a8| 0x000026f0    | 888 bytes  |
| upower_tbl_b_FY            | .data+0x0520| 0x00002a68    | 888 bytes  |
| upower_tbl_cluster_l_FY    | .data+0x0898| 0x00002de0    | 888 bytes  |
| upower_tbl_cluster_b_FY    | .data+0x0c10| 0x00003158    | 888 bytes  |
| upower_tbl_cci_FY          | .data+0x0f88| 0x000034d0    | 888 bytes  |
+----------------------------+-------------+---------------+------------+
| upower_tbl_l_B20G          | .data+0x1300| 0x00003848    | 888 bytes  |
| upower_tbl_b_B20G          | .data+0x1678| 0x00003bc0    | 888 bytes  |
| upower_tbl_cluster_l_B20G  | .data+0x19f0| 0x00003f38    | 888 bytes  |
| upower_tbl_cluster_b_B20G  | .data+0x1d68| 0x000042b0    | 888 bytes  |
| upower_tbl_cci_B20G        | .data+0x20e0| 0x00004628    | 888 bytes  |
+----------------------------+-------------+---------------+------------+
| upower_tbl_l_B24G          | .data+0x2458| 0x000049a0    | 888 bytes  |
| upower_tbl_b_B24G          | .data+0x27d0| 0x00004d18    | 888 bytes  |
| upower_tbl_cluster_l_B24G  | .data+0x2b48| 0x00005090    | 888 bytes  |
| upower_tbl_cluster_b_B24G  | .data+0x2ec0| 0x00005408    | 888 bytes  |
| upower_tbl_cci_B24G        | .data+0x3238| 0x00005780    | 888 bytes  |
+----------------------------+-------------+---------------+------------+
```

### 6.3 Disassembly of Key Energy Model Functions

#### 1. Dynamic Power Calculation (`upower_update_dyn_pwr` at `.text + 0x022c`, File Offset: `0x122c`)
```aarch64
0x248: add  x13, x11, x10         // Table entry pointer
0x24c: ldp  w13, w14, [x13, #0x8] // w13 = ref_volt, w14 = ref_dyn
0x250: add  x12, x12, x10         // Runtime table pointer
0x254: ldr  w15, [x12, #0x8]      // w15 = curr_volt
0x258: add  x10, x10, #0x30       // Entry stride (48 bytes)
0x25c: mul  x13, x13, x13         // x13 = ref_volt^2
0x264: mul  x14, x15, x14         // x14 = ref_dyn * curr_volt
0x268: mul  x14, x14, x15         // x14 = ref_dyn * curr_volt^2
0x26c: udiv x13, x14, x13         // x13 = (ref_dyn * curr_volt^2) / ref_volt^2
0x270: str  w13, [x12, #0xc]      // Store updated dyn_power
```
This confirms physical dynamic power scaling:

$$
P_{\text{dyn}} = P_{\text{dyn, ref}} \times \frac{V_{\text{curr}}^2}{V_{\text{ref}}^2}
$$

#### 2. Efficiency Calculation & Turn Point (`upower_update_tables_by_eem` at `.text + 0x0d14`, File Offset: `0x1d14`)
```aarch64
0xd44: ldr  w14, [x9, #0x14]      // w14 = lkg_power
0xd48: ldr  w15, [x9, #0xc]       // w15 = dyn_power
0xd4c: ldr  x16, [x9]             // x16 = cap
0xd54: add  w14, w15, w14         // total_power = dyn + lkg
0xd58: udiv x14, x14, x16         // eff = total_power / cap
0xd70: str  w14, [x9, #0x10]      // Store eff
0xdd8: bl   upower_cal_turn_point // Recalculate scheduler migration turn point
```

#### 3. Scheduler Turn Point Algorithm (`upower_cal_turn_point` at `.text + 0x07f8`, File Offset: `0x17f8`)
`upower_cal_turn_point()` determines the capacity crossover threshold where tasks transition between Little and Big clusters:
```aarch64
0x7f8: paciasp
0x800: ldr   x8, [x8]              // x8 = p_upower_tbl_infos
0x804: ldr   w9, [x8, #0x684]      // w9 = min_eff of Big cluster (stored at Bank L + 0x30c)
0x808: ldr   w10, [x8, #0x2e0]     // Little OPP 15 eff
0x80c: cmp   w10, w9
0x810: b.ls  0x8d4                 // Match OPP 15 (turn_point = 16)
...
0x8b0: ldr   w10, [x8, #0x40]      // Little OPP 1 eff
0x8b4: cmp   w10, w9
0x8b8: b.ls  0x944                 // Match OPP 1 (turn_point = 2)
0x8bc: ldr   w10, [x8, #0x10]      // Little OPP 0 eff
0x8c0: cmp   w10, w9
0x8c4: b.ls  0x94c                 // Match OPP 0 (turn_point = 1)
...
0x950: add   w9, w0, #0x1          // turn_point = matched_index + 1
0x954: str   w9, [x8, #0x6ec]      // Store in Big cluster table (+0x374)
0x958: str   w9, [x8, #0x374]      // Store in Little cluster table (+0x374)
0x95c: autiasp
0x960: ret
```
The routine scans Little cluster OPPs top-down (15 -> 0), selecting the first OPP whose efficiency satisfies:

$$
\text{eff}(\text{Little}) \le \text{eff}(\text{Big, min})
$$

#### 4. EEM Overwrite Disarm & The ELF Relocation Collision Hazard

##### The Initial Bug & Kernel Panic Post-Mortem
In the initial v2.2 build, `upower_update_volt_by_eem` was stubbed with a standard 16-byte ARM64 PAC/BTI zero-return sequence:
```aarch64
0x0b1c: paciasp      // 3f 23 03 d5 (ARM64 Pointer Authentication & BTI landing pad)
0x0b20: mov w0, wzr  // e0 03 1f 2a (Return 0 / success)
0x0b24: autiasp      // bf 23 03 d5 (Authenticate return address)
0x0b28: ret          // c0 03 5f d6 (Clean return)
```

Upon flashing and rebooting, the device dropped into Fastboot mode due to an immediate kernel panic during early module initialization:
```
[    8.683908][T400390] ------------[ cut here ]------------
[    8.684946][T400390] kernel BUG at arch/arm64/kernel/traps.c:410!
[    8.685718][T400390] Internal error: Oops - BUG: 0 [#1] PREEMPT SMP
...
[    8.931631][T400390]  do_undefinstr+0xa4/0xa8
[    8.932191][T400390]  el1_undef+0x30/0x50
[    8.932703][T400390]  el1_sync_handler+0x58/0x8c
[    8.933287][T400390]  el1_sync+0x8c/0x140
[    8.933810][T400390]  upower_update_volt_by_eem+0xc/0x1f8 [Upower]
[    8.940693][T400390]  init_module+0x788/0x890 [mediatek_eem]
```

##### Root Cause Analysis
Disassembly and ELF relocation inspection revealed that relocatable kernel modules (`.ko`) contain active relocation records in `.rela.text.upower_update_dyn_pwr`:
```
0000000000000b28  000000c200000113 R_AARCH64_ADR_PREL_PG_HI21 00000000000035c8 upower_recognize_by_eem + 0
0000000000000b2c  000000c200000116 R_AARCH64_LDST8_ABS_LO12_NC 00000000000035c8 upower_recognize_by_eem + 0
```
- Offset `0x0b28` corresponded exactly to `upower_update_volt_by_eem + 0xc` (the `ret` instruction in the 16-byte stub).
- When the Linux kernel module loader invoked `apply_relocate_add()`, it processed relocation record `0x0b28`, calculating the relative page offset to `upower_recognize_by_eem` and **overwriting the `ret` opcode with an `adrp x8, ...` instruction**.
- As a result, when `mediatek_eem.ko` called `upower_update_volt_by_eem`, execution fell through the clobbered `ret` into partially modified instructions without a valid stack frame or epilogue, immediately triggering an undefined instruction exception (`do_undefinstr`).

##### The Permanent Resolution
1. **Compact 12-Byte Epilogue Termination**:
   Because `upower_update_volt_by_eem` is a void function (as confirmed by the stock `b.hi 0xd08` check which branches directly to `autiasp; ret`), the `mov w0, wzr` instruction is unnecessary. The function stub is compacted to 12 bytes:
   ```aarch64
   0x0b1c: paciasp  // 3f 23 03 d5 (BTI / PAC sign)
   0x0b20: autiasp  // bf 23 03 d5 (BTI / PAC authenticate)
   0x0b24: ret      // c0 03 5f d6 (Return cleanly before offset 0x0b28)
   ```
   This ensures the `ret` instruction executes at `0x0b24`, strictly before the `0x0b28` relocation boundary.

2. **ELF Relocation Disarming (`R_AARCH64_NONE`)**:
   In addition to compacting the stub, [`patch_upower.py`](file:///home/yamada/CODE/MT6833GP-Experiment/scripts/patch_upower.py) programmatically parses all `SHT_RELA` relocation sections in the ELF binary and converts every relocation targeting the interior of the disarmed functions to `R_AARCH64_NONE` (relocation type 0):
   - `upower_update_volt_by_eem` (`0x0b1c` - `0x0d14`): 29 relocations cleared
   - `upower_update_tables_by_eem` (`0x0d14` - `0x0dec`): 6 relocations cleared
   - Total relocations neutralized: 35

3. **Storage Sync**:
   `customize.sh` was augmented with explicit kernel page cache flushes (`sync; sync; sync`) immediately after bare-metal partition writes to prevent dirty block writeback truncation during automated reboots.
