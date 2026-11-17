#!/usr/bin/env python3
"""
MediaTek MT6833 mtk_gpufreq_mt6833.ko Binary Patcher
Author: Kana Wesley Yamada (MT6833GP-Experiment)

Applies:
1. -37.50 mV undervolt across all 45 GPU operating points (Mali-G57 MC2).
2. Maintains strict compliance with the hardware constraint:
   Delta(Vsram - Vgpu) <= 200.00 mV.
"""

import sys
import os
import struct
import argparse

TABLE_OFFSET = 0x1928  # Offset of g_default_gpu in .rodata
NUM_OPPS = 45          # 45 frequency steps (1068000 down to 390000 kHz)
DELTA_UV = 3750        # -37.50 mV in 10 uV units (-37500 uV)

def patch_file(input_path, output_path):
    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    print(f"[*] Loaded {input_path} ({len(data)} bytes)")

    patched_count = 0
    for i in range(NUM_OPPS):
        entry_offset = TABLE_OFFSET + (i * 24)
        freq, vgpu, vsram = struct.unpack("<QQQ", data[entry_offset : entry_offset + 24])

        new_vgpu = max(55000, vgpu - DELTA_UV)
        new_vsram = max(75000, vsram - DELTA_UV)

        # Enforce hardware constraint: Vsram - Vgpu <= 200 mV (20000 in 10uV)
        if (new_vsram - new_vgpu) > 20000:
            new_vsram = new_vgpu + 20000

        data[entry_offset : entry_offset + 24] = struct.pack("<QQQ", freq, new_vgpu, new_vsram)
        patched_count += 1

    print(f" [+] Successfully patched {patched_count} GPU OPP entries at 0x{TABLE_OFFSET:x}")

    with open(output_path, "wb") as f:
        f.write(data)

    print(f"[+] Output written to {output_path} ({len(data)} bytes)!")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Patch mtk_gpufreq_mt6833.ko for MT6833")
    parser.add_argument("-i", "--input", default="mtk_gpufreq_mt6833.ko", help="Input stock mtk_gpufreq_mt6833.ko")
    parser.add_argument("-o", "--output", default="mtk_gpufreq_mt6833_patched.ko", help="Output patched mtk_gpufreq_mt6833.ko")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"[-] Error: Input file not found: {args.input}")
        sys.exit(1)

    patch_file(args.input, args.output)
