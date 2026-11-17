#!/usr/bin/env python3
"""
MediaTek MT6833 mtk_gpufreq_mt6833.ko Binary Patcher (v1.8 Profile)
Author: Kana Wesley Yamada (MT6833GP-Experiment)

Applies:
1. -50.00 mV aggressive undervolt across all 45 GPU operating points (Mali-G57 MC2).
2. Maintains strict compliance with the hardware constraint:
   Delta(Vsram - Vgpu) <= 200.00 mV.
"""

import sys
import os
import struct
import argparse

NUM_OPPS = 45          # 45 frequency steps (1068000 down to 390000 kHz)
STRIDE = 24            # 24 bytes per entry (6 x uint32)

def patch_file(input_path, output_path, delta_mv=50.0):
    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    magic = struct.pack("<I", 1068000)
    pos = data.find(magic)
    if pos == -1:
        raise ValueError("Could not locate g_default_gpu table signature (1068000)!")

    delta_10uv = int(round(delta_mv * 100))
    print(f"[*] Loaded {input_path} ({len(data)} bytes)")
    print(f"[*] Located g_default_gpu at file offset: 0x{pos:x}")
    print(f"[*] Applying GPU undervolt: -{delta_mv:.2f} mV across all {NUM_OPPS} OPPs")

    for i in range(NUM_OPPS):
        entry_offset = pos + (i * STRIDE)
        freq, vgpu, vsram, pdiv, pwr, rsv = struct.unpack("<6I", data[entry_offset : entry_offset + STRIDE])

        # Clamp floor to 550.00 mV to strictly respect MT6359 PMIC 200 mV max delta from 750 mV Vsram
        new_vgpu = max(55000, vgpu - delta_10uv)
        new_vsram = max(new_vgpu, 75000)

        delta = new_vsram - new_vgpu
        assert delta <= 20000, f"Delta constraint violated at OPP {i}: {delta}"
        assert new_vgpu >= 55000, f"Vgpu floor violated at OPP {i}: {new_vgpu}"
        assert new_vsram >= new_vgpu, f"Vsram < Vgpu at OPP {i}"

        data[entry_offset : entry_offset + STRIDE] = struct.pack("<6I", freq, new_vgpu, new_vsram, pdiv, pwr, rsv)

    with open(output_path, "wb") as f:
        f.write(data)

    print(f"[+] Output written to {output_path} ({len(data)} bytes)!")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Patch mtk_gpufreq_mt6833.ko for MT6833")
    parser.add_argument("-i", "--input", default="mtk_gpufreq_mt6833.ko", help="Input stock mtk_gpufreq_mt6833.ko")
    parser.add_argument("-o", "--output", default="mtk_gpufreq_mt6833_patched.ko", help="Output patched mtk_gpufreq_mt6833.ko")
    parser.add_argument("-d", "--delta-mv", type=float, default=50.0, help="Undervolt delta in mV (default: 50.0)")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"[-] Error: Input file not found: {args.input}")
        sys.exit(1)

    patch_file(args.input, args.output, args.delta_mv)
