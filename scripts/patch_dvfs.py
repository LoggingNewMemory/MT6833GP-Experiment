#!/usr/bin/env python3
"""
MediaTek MT6833 CPU_DVFS.ko Binary Patcher (v2.6 Profile)
Author: Kana Wesley Yamada (MT6833GP-Experiment)

Applies:
1. 200 MHz underclock floor with stable PLL VCO parameters (a=4, b=2) across Little, Big, and CCI clusters.
2. Full -50.00 mV CPU, Cache SRAM, and CCI interconnect undervolt across all clusters.
3. Decoupled 16x16 CCI mapping matrices (CCI_FYTbl, CCI_B20GTbl, CCI_B24GTbl) ensuring 200 MHz floor engages strictly at full idle.
4. mediatek_eem bypass patch to prevent runtime eFuse table overwrite.
"""

import sys
import os
import struct
import argparse

def volt_10uv(step):
    return int((step * 6.25 + 400.0) * 100)

def pack_cluster_table(opps):
    buf = bytearray()
    for freq, volt_step, a, b in opps:
        entry = struct.pack('<HHI4sI', freq, 0, volt_step, bytes([a, 0, 0, 0]), b)
        buf.extend(entry)
    return buf

def pack_opp_tbl(opps):
    buf = bytearray()
    for freq, volt_step, _, _ in opps:
        buf.extend(struct.pack('<II', freq * 1000, volt_10uv(volt_step)))
    return buf

def pack_method_tbl(opps):
    buf = bytearray()
    for _, _, a, b in opps:
        buf.extend(bytes([a, b]))
    return buf

# Cluster 0: Little (LL)
# Min: 200 MHz, Max: 2000 MHz (Stock max)
# OPP 0..10: -50.00 mV (step - 8)
# OPP 11..13: -37.50 mV (step - 6)
# OPP 14: 500 MHz, step 31 (593.75 mV), a=4, b=1
# OPP 15: 200 MHz, step 29 (581.25 mV), a=4, b=2 (VCO = 200 * 4 * 2 = 1600 MHz)
little_opps = [
    (2000, 88, 1, 1), # OPP 0:  1000.00 -> 950.00 mV (-50.00 mV)
    (1916, 84, 1, 1), # OPP 1:   975.00 -> 925.00 mV (-50.00 mV)
    (1812, 79, 1, 1), # OPP 2:   943.75 -> 893.75 mV (-50.00 mV)
    (1750, 76, 1, 1), # OPP 3:   925.00 -> 875.00 mV (-50.00 mV)
    (1645, 71, 2, 1), # OPP 4:   893.75 -> 843.75 mV (-50.00 mV)
    (1500, 64, 2, 1), # OPP 5:   850.00 -> 800.00 mV (-50.00 mV)
    (1393, 60, 2, 1), # OPP 6:   825.00 -> 775.00 mV (-50.00 mV)
    (1287, 56, 2, 1), # OPP 7:   800.00 -> 750.00 mV (-50.00 mV)
    (1128, 50, 2, 1), # OPP 8:   762.50 -> 712.50 mV (-50.00 mV)
    (1048, 47, 2, 1), # OPP 9:   743.75 -> 693.75 mV (-50.00 mV)
    ( 968, 44, 2, 1), # OPP 10:  725.00 -> 675.00 mV (-50.00 mV)
    ( 862, 42, 2, 1), # OPP 11:  700.00 -> 662.50 mV (-37.50 mV)
    ( 756, 38, 4, 1), # OPP 12:  675.00 -> 637.50 mV (-37.50 mV)
    ( 703, 36, 4, 1), # OPP 13:  662.50 -> 625.00 mV (-37.50 mV)
    ( 500, 31, 4, 1), # OPP 14:  650.00 -> 593.75 mV (500 MHz, a=4, b=1)
    ( 200, 29, 4, 2), # OPP 15:  650.00 -> 581.25 mV (200 MHz, a=4, b=2, VCO=1600 MHz)
]

# Cluster 1: Big (L)
# Min: 200 MHz, Max: 2400 MHz (Stock max)
# OPP 0..11: -50.00 mV (step - 8)
# OPP 12..13: -37.50 mV (step - 6)
# OPP 14: 500 MHz, step 31 (593.75 mV), a=4, b=1 (VCO = 500 * 4 = 2000 MHz)
# OPP 15: 200 MHz, step 29 (581.25 mV), a=4, b=2 (VCO = 200 * 4 * 2 = 1600 MHz)
big_opps = [
    (2400,  96, 1, 1), # OPP 0: 1050.00 -> 1000.00 mV (-50.00 mV)
    (2306,  93, 1, 1), # OPP 1: 1031.25 ->  981.25 mV (-50.00 mV)
    (2203,  90, 1, 1), # OPP 2: 1012.50 ->  962.50 mV (-50.00 mV)
    (2118,  87, 1, 1), # OPP 3:  993.75 ->  943.75 mV (-50.00 mV)
    (1993,  83, 1, 1), # OPP 4:  968.75 ->  918.75 mV (-50.00 mV)
    (1837,  78, 1, 1), # OPP 5:  937.50 ->  887.50 mV (-50.00 mV)
    (1650,  72, 2, 1), # OPP 6:  900.00 ->  850.00 mV (-50.00 mV)
    (1534,  67, 2, 1), # OPP 7:  868.75 ->  818.75 mV (-50.00 mV)
    (1418,  62, 2, 1), # OPP 8:  837.50 ->  787.50 mV (-50.00 mV)
    (1274,  56, 2, 1), # OPP 9:  800.00 ->  750.00 mV (-50.00 mV)
    (1129,  49, 2, 1), # OPP 10: 756.25 ->  706.25 mV (-50.00 mV)
    (1042,  46, 2, 1), # OPP 11: 737.50 ->  687.50 mV (-50.00 mV)
    ( 985,  45, 2, 1), # OPP 12: 718.75 ->  681.25 mV (-37.50 mV)
    ( 898,  41, 2, 1), # OPP 13: 693.75 ->  656.25 mV (-37.50 mV)
    ( 500,  31, 4, 1), # OPP 14: 681.25 ->  593.75 mV (500 MHz, a=4, b=1, VCO=2000 MHz)
    ( 200,  29, 4, 2), # OPP 15: 650.00 ->  581.25 mV (200 MHz, a=4, b=2, VCO=1600 MHz)
]

# Cluster 2: CCI (Cache Coherent Interconnect)
# Min: 200 MHz (Underclock floor), Max: 1600 MHz (Stock max)
# OPP 0..13: -50.00 mV (step - 8)
# OPP 14: 450 MHz, step 32 (600.00 mV), a=4, b=1 (VCO = 1800 MHz)
# OPP 15: 200 MHz, step 29 (581.25 mV), a=4, b=2 (VCO = 200 * 4 * 2 = 1600 MHz)
cci_opps = [
    (1600, 88, 1, 1), # OPP 0:  1000.00 -> 950.00 mV (-50.00 mV)
    (1531, 85, 2, 1), # OPP 1:   981.25 -> 931.25 mV (-50.00 mV)
    (1370, 78, 2, 1), # OPP 2:   937.50 -> 887.50 mV (-50.00 mV)
    (1210, 71, 2, 1), # OPP 3:   893.75 -> 843.75 mV (-50.00 mV)
    (1141, 68, 2, 1), # OPP 4:   875.00 -> 825.00 mV (-50.00 mV)
    (1050, 64, 2, 1), # OPP 5:   850.00 -> 800.00 mV (-50.00 mV)
    ( 975, 60, 2, 1), # OPP 6:   825.00 -> 775.00 mV (-50.00 mV)
    ( 900, 56, 2, 1), # OPP 7:   800.00 -> 750.00 mV (-50.00 mV)
    ( 825, 52, 2, 1), # OPP 8:   775.00 -> 725.00 mV (-50.00 mV)
    ( 768, 49, 4, 1), # OPP 9:   756.25 -> 706.25 mV (-50.00 mV)
    ( 675, 44, 4, 1), # OPP 10:  725.00 -> 675.00 mV (-50.00 mV)
    ( 600, 40, 4, 1), # OPP 11:  700.00 -> 650.00 mV (-50.00 mV)
    ( 562, 38, 4, 1), # OPP 12:  687.50 -> 637.50 mV (-50.00 mV)
    ( 525, 36, 4, 1), # OPP 13:  675.00 -> 625.00 mV (-50.00 mV)
    ( 450, 32, 4, 1), # OPP 14:  650.00 -> 600.00 mV (450 MHz, a=4, b=1, VCO=1800 MHz)
    ( 200, 29, 4, 2), # OPP 15:  650.00 -> 581.25 mV (200 MHz, a=4, b=2, VCO=1600 MHz)
]

def patch_cci_map(data, offset):
    """
    Decouple 16x16 CCI mapping table (Normal mode + Perf mode).
    In stock, rows 11..15 and cols 11..15 map down to OPP 15.
    With OPP 15 underclocked to 200 MHz and OPP 14 at 450 MHz,
    we ensure OPP 15 engages strictly when BOTH Little and Big clusters are at OPP 15 (idle floor).
    All other low-frequency combinations clamp to OPP 14 (450 MHz).
    """
    for mode_idx in range(2):
        base = offset + mode_idx * 256
        for r in range(16):
            for c in range(16):
                idx = base + r * 16 + c
                if data[idx] == 15 and not (r == 15 and c == 15):
                    data[idx] = 14

def patch_file(input_path, output_path):
    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    print(f"[*] Loaded {input_path} ({len(data)} bytes)")

    # 1. Patch MT6833_B24GTbl (0xd7f8)
    b24g_offset = 0xd7f8
    data[b24g_offset : b24g_offset + 256] = pack_cluster_table(little_opps)
    data[b24g_offset + 256 : b24g_offset + 512] = pack_cluster_table(big_opps)
    data[b24g_offset + 512 : b24g_offset + 768] = pack_cluster_table(cci_opps)
    print(f" [+] Patched MT6833_B24GTbl at 0x{b24g_offset:x}")

    # 2. Patch MT6833_B20GTbl (0xd4f8)
    b20g_offset = 0xd4f8
    data[b20g_offset : b20g_offset + 256] = pack_cluster_table(little_opps)
    data[b20g_offset + 512 : b20g_offset + 768] = pack_cluster_table(cci_opps)
    for i in range(16):
        off = b20g_offset + 256 + i * 16
        f, z, s, a_raw, b = struct.unpack('<HHI4sI', data[off : off + 16])
        a = a_raw[0]
        if i == 15:
            f, s, a, b = 200, 30, 4, 2
        elif i == 14:
            f, s, a, b = 500, 32, 4, 1
        elif i >= 12:
            s = max(30, s - 5)
        else:
            s = max(30, s - 7)
        data[off : off + 16] = struct.pack('<HHI4sI', f, z, s, bytes([a, 0, 0, 0]), b)
    print(f" [+] Patched MT6833_B20GTbl at 0x{b20g_offset:x}")

    # 3. Patch FY_6833Tbl (0xd1f8)
    fy_offset = 0xd1f8
    data[fy_offset : fy_offset + 256] = pack_cluster_table(little_opps)
    data[fy_offset + 256 : fy_offset + 512] = pack_cluster_table(big_opps)
    data[fy_offset + 512 : fy_offset + 768] = pack_cluster_table(cci_opps)
    print(f" [+] Patched FY_6833Tbl at 0x{fy_offset:x}")

    # 4. Patch fallback opp_tbl_*
    for off in [0xc610, 0xc690, 0xc710]:
        data[off : off + 128] = pack_opp_tbl(little_opps)
    for off in [0xc790, 0xc810, 0xc890]:
        data[off : off + 128] = pack_opp_tbl(big_opps)
    for off in [0xc910, 0xc990, 0xca10]:
        data[off : off + 128] = pack_opp_tbl(cci_opps)
    print(" [+] Patched opp_tbl_* fallback tables")

    # 5. Patch method tables
    for off in [0xc4f0, 0xc510, 0xc530]:
        data[off : off + 32] = pack_method_tbl(little_opps)
    for off in [0xc550, 0xc570, 0xc590]:
        data[off : off + 32] = pack_method_tbl(big_opps)
    for off in [0xc5b0, 0xc5d0, 0xc5f0]:
        data[off : off + 32] = pack_method_tbl(cci_opps)
    print(" [+] Patched opp_tbl_method_* tables")

    # 5.5 Patch 16x16 CCI mapping matrices (CCI_FYTbl, CCI_B20GTbl, CCI_B24GTbl)
    patch_cci_map(data, 0xcbf8) # CCI_FYTbl
    patch_cci_map(data, 0xcdf8) # CCI_B20GTbl
    patch_cci_map(data, 0xcff8) # CCI_B24GTbl
    print(" [+] Patched CCI_FYTbl, CCI_B20GTbl, and CCI_B24GTbl (idle-only 200 MHz engagement)")

    # 6. Patch mediatek_eem overwrite bypass
    eem_bypass_stub = bytes([
        0x3f, 0x23, 0x03, 0xd5,  # paciasp
        0xe0, 0x03, 0x1f, 0x2a,  # mov w0, wzr
        0xbf, 0x23, 0x03, 0xd5,  # autiasp
        0xc0, 0x03, 0x5f, 0xd6,  # ret
    ])
    off_update_volt = 0x1000 + 0x5204          # 0x6204
    off_update_legacy_volt = 0x1000 + 0x5408   # 0x6408

    data[off_update_volt : off_update_volt + 16] = eem_bypass_stub
    data[off_update_legacy_volt : off_update_legacy_volt + 16] = eem_bypass_stub
    print(" [+] Patched mt_cpufreq_update_volt and mt_cpufreq_update_legacy_volt (EEM bypass)")

    with open(output_path, "wb") as f:
        f.write(data)

    print(f"[+] Output written to {output_path} ({len(data)} bytes)!")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Patch CPU_DVFS.ko for MT6833")
    parser.add_argument("-i", "--input", default="CPU_DVFS.ko", help="Input stock CPU_DVFS.ko")
    parser.add_argument("-o", "--output", default="CPU_DVFS_patched.ko", help="Output patched CPU_DVFS.ko")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"[-] Error: Input file not found: {args.input}")
        sys.exit(1)

    patch_file(args.input, args.output)
