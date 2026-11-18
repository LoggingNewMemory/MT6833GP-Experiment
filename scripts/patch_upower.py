#!/usr/bin/env python3
"""
MediaTek MT6833 Upower.ko Binary Patcher (EAS Energy Model & PPM Calibrator)
Author: Kana Wesley Yamada (MT6833GP-Experiment)

Applies:
1. Calibrates static energy model tables (upower_tbl_l_*, upower_tbl_b_*, upower_tbl_cci_*,
   upower_tbl_cluster_l_*, upower_tbl_cluster_b_*) to match undervolted operating points:
   - Little OPPs: 581.25 mV (200 MHz floor) .. 950.00 mV (2000 MHz max)
   - Big OPPs: 581.25 mV (200 MHz floor) .. 1000.00 mV (2400 MHz max)
   - CCI OPPs: 581.25 mV (200 MHz floor) .. 950.00 mV (1600 MHz max)
2. Recalculates dynamic power entries using physical CMOS scaling:
   P_dyn_new = P_dyn_stock * (V_patched / V_stock)^2
3. Scales 200 MHz underclock floor capacity and power for optimal EAS task placement.
4. Stubs upower_update_volt_by_eem with a PAC/BTI-safe zero-return:
   Prevents mediatek_eem from overwriting calibrated energy model with stock eFuse values.
"""

import sys
import os
import struct
import argparse

LITTLE_PATCHED_VOLTS = [
    58125, # OPP 0 (200 MHz underclock floor)
    59375, # OPP 1 (500 MHz)
    62500, # OPP 2 (703 MHz)
    63750, # OPP 3 (756 MHz)
    66250, # OPP 4 (862 MHz)
    67500, # OPP 5 (968 MHz)
    69375, # OPP 6 (1048 MHz)
    71250, # OPP 7 (1128 MHz)
    75000, # OPP 8 (1287 MHz)
    77500, # OPP 9 (1393 MHz)
    80000, # OPP 10 (1500 MHz)
    84375, # OPP 11 (1645 MHz)
    87500, # OPP 12 (1750 MHz)
    89375, # OPP 13 (1812 MHz)
    92500, # OPP 14 (1916 MHz)
    95000, # OPP 15 (2000 MHz max)
]

BIG_PATCHED_VOLTS_B24G = [
    58125, # OPP 0 (200 MHz underclock floor)
    59375, # OPP 1 (500 MHz)
    65625, # OPP 2 (898 MHz)
    68125, # OPP 3 (985 MHz)
    68750, # OPP 4 (1042 MHz)
    70625, # OPP 5 (1129 MHz)
    75000, # OPP 6 (1274 MHz)
    78750, # OPP 7 (1418 MHz)
    81875, # OPP 8 (1534 MHz)
    85000, # OPP 9 (1650 MHz)
    88750, # OPP 10 (1837 MHz)
    91875, # OPP 11 (1993 MHz)
    94375, # OPP 12 (2118 MHz)
    96250, # OPP 13 (2203 MHz)
    98125, # OPP 14 (2306 MHz)
    100000,# OPP 15 (2400 MHz max)
]

BIG_PATCHED_VOLTS_B20G = [
    58125, # OPP 0 (200 MHz underclock floor)
    59375, # OPP 1 (500 MHz)
    65625, # OPP 2
    68125, # OPP 3
    68750, # OPP 4
    70625, # OPP 5
    75000, # OPP 6
    78750, # OPP 7
    81875, # OPP 8
    85000, # OPP 9
    88750, # OPP 10
    91875, # OPP 11
    91250, # OPP 12
    93125, # OPP 13
    94375, # OPP 14
    95000, # OPP 15 (2000 MHz max)
]

CCI_PATCHED_VOLTS = [
    58125, # OPP 0 (200 MHz underclock floor)
    60000, # OPP 1 (450 MHz)
    62500, # OPP 2 (525 MHz)
    63750, # OPP 3 (562 MHz)
    65000, # OPP 4 (600 MHz)
    67500, # OPP 5 (675 MHz)
    70625, # OPP 6 (768 MHz)
    72500, # OPP 7 (825 MHz)
    75000, # OPP 8 (900 MHz)
    77500, # OPP 9 (975 MHz)
    80000, # OPP 10 (1050 MHz)
    82500, # OPP 11 (1141 MHz)
    84375, # OPP 12 (1210 MHz)
    88750, # OPP 13 (1370 MHz)
    93125, # OPP 14 (1531 MHz)
    95000, # OPP 15 (1600 MHz max)
]

# paciasp; autiasp; ret (PAC & BTI clean instant return, 12 bytes - no relocation overlap)
STUB_BYTES = bytes.fromhex("3f2303d5bf2303d5c0035fd6")

def clear_function_relocations(data, func_val, func_size):
    e_shoff = struct.unpack("<Q", data[40:48])[0]
    e_shentsize = struct.unpack("<H", data[58:60])[0]
    e_shnum = struct.unpack("<H", data[60:62])[0]

    cleared = 0
    for i in range(e_shnum):
        s_off = e_shoff + i * e_shentsize
        sh_type = struct.unpack("<I", data[s_off+4:s_off+8])[0]
        if sh_type == 4: # SHT_RELA
            sh_offset = struct.unpack("<Q", data[s_off+24:s_off+32])[0]
            sh_size = struct.unpack("<Q", data[s_off+32:s_off+40])[0]
            sh_entsize = struct.unpack("<Q", data[s_off+56:s_off+64])[0]
            num_relas = sh_size // sh_entsize
            for r in range(num_relas):
                r_entry = sh_offset + r * sh_entsize
                r_offset = struct.unpack("<Q", data[r_entry:r_entry+8])[0]
                if func_val <= r_offset < (func_val + func_size):
                    data[r_entry+8:r_entry+16] = b"\x00" * 8 # r_info = 0 (R_AARCH64_NONE)
                    cleared += 1
    return cleared

def parse_elf_symbols(data):
    e_shoff = struct.unpack("<Q", data[40:48])[0]
    e_shentsize = struct.unpack("<H", data[58:60])[0]
    e_shnum = struct.unpack("<H", data[60:62])[0]
    e_shstrndx = struct.unpack("<H", data[62:64])[0]

    sections = []
    for i in range(e_shnum):
        sh_offset = e_shoff + i * e_shentsize
        sh_name, sh_type, sh_flags, sh_addr, sh_offset_val, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = \
            struct.unpack("<IIQQQQIIQQ", data[sh_offset:sh_offset + 64])
        sections.append({
            "name_idx": sh_name, "type": sh_type, "flags": sh_flags, "addr": sh_addr,
            "offset": sh_offset_val, "size": sh_size, "link": sh_link, "info": sh_info,
            "entsize": sh_entsize
        })

    shstrtab = data[sections[e_shstrndx]["offset"] : sections[e_shstrndx]["offset"] + sections[e_shstrndx]["size"]]
    for s in sections:
        name_end = shstrtab.find(b"\x00", s["name_idx"])
        s["name"] = shstrtab[s["name_idx"]:name_end].decode("ascii", errors="ignore")

    symtab = next((s for s in sections if s["type"] == 2), None)
    if not symtab:
        return {}
    strtab = sections[symtab["link"]]
    str_data = data[strtab["offset"] : strtab["offset"] + strtab["size"]]

    num_syms = symtab["size"] // symtab["entsize"]
    symbols = {}
    for i in range(num_syms):
        sym_offset = symtab["offset"] + i * symtab["entsize"]
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack("<IBBHQQ", data[sym_offset:sym_offset + 24])
        name_end = str_data.find(b"\x00", st_name)
        sym_name = str_data[st_name:name_end].decode("ascii", errors="ignore")
        if st_shndx < len(sections):
            sec = sections[st_shndx]
            file_offset = sec["offset"] + st_value
        else:
            file_offset = None
        symbols[sym_name] = {"value": st_value, "size": st_size, "shndx": st_shndx, "file_offset": file_offset}
    return symbols

def patch_table(data, offset, patched_volts, is_cluster=False, is_floor_scaled=True, floor_ratio=(200, 500)):
    for i in range(16):
        entry_off = offset + i * 48
        entry = data[entry_off : entry_off + 48]
        vals = list(struct.unpack("<IIIIIIIIIIII", entry))
        cap, _, volt_old, dyn_old, eff = vals[0], vals[1], vals[2], vals[3], vals[4]
        lkg = vals[5:11]

        volt_new = patched_volts[i]
        vals[2] = volt_new

        if is_cluster:
            vals[3] = 0
        elif i == 0 and is_floor_scaled:
            # Underclock floor: scale dynamic power from OPP 1 (e.g. 500 MHz CPU or 450 MHz CCI)
            # P_dyn = P_dyn(ref) * (f_floor / f_ref) * (V_floor / V_ref)^2
            f_floor, f_ref = floor_ratio
            entry_1 = data[offset + 48 : offset + 96]
            vals_1 = struct.unpack("<IIIIIIIIIIII", entry_1)
            v_ref_old = vals_1[2]
            v_ref_new = patched_volts[1]
            dyn_ref_new = int(vals_1[3] * ((v_ref_new / v_ref_old) ** 2))
            dyn_new = int(dyn_ref_new * (f_floor / f_ref) * ((volt_new / v_ref_new) ** 2))
            vals[3] = dyn_new
        else:
            dyn_new = int(dyn_old * ((volt_new / volt_old) ** 2))
            vals[3] = dyn_new

        data[entry_off : entry_off + 48] = struct.pack("<IIIIIIIIIIII", *vals)

def patch_upower(input_path, output_path):
    with open(input_path, "rb") as f:
        data = bytearray(f.read())

    print(f"[*] Loaded {input_path} ({len(data)} bytes)")
    syms = parse_elf_symbols(data)
    if not syms:
        raise ValueError("Could not parse ELF symbols from input module!")

    # 1. Patch static tables
    tables = [
        # (Table name, Volt list, is_cluster, is_floor_scaled, floor_ratio)
        ("upower_tbl_l_FY", LITTLE_PATCHED_VOLTS, False, True, (200, 500)),
        ("upower_tbl_l_B20G", LITTLE_PATCHED_VOLTS, False, True, (200, 500)),
        ("upower_tbl_l_B24G", LITTLE_PATCHED_VOLTS, False, True, (200, 500)),
        ("upower_tbl_cluster_l_FY", LITTLE_PATCHED_VOLTS, True, True, (200, 500)),
        ("upower_tbl_cluster_l_B20G", LITTLE_PATCHED_VOLTS, True, True, (200, 500)),
        ("upower_tbl_cluster_l_B24G", LITTLE_PATCHED_VOLTS, True, True, (200, 500)),

        ("upower_tbl_b_FY", BIG_PATCHED_VOLTS_B24G, False, True, (200, 500)),
        ("upower_tbl_b_B20G", BIG_PATCHED_VOLTS_B20G, False, True, (200, 500)),
        ("upower_tbl_b_B24G", BIG_PATCHED_VOLTS_B24G, False, True, (200, 500)),
        ("upower_tbl_cluster_b_FY", BIG_PATCHED_VOLTS_B24G, True, True, (200, 500)),
        ("upower_tbl_cluster_b_B20G", BIG_PATCHED_VOLTS_B20G, True, True, (200, 500)),
        ("upower_tbl_cluster_b_B24G", BIG_PATCHED_VOLTS_B24G, True, True, (200, 500)),

        ("upower_tbl_cci_FY", CCI_PATCHED_VOLTS, False, True, (200, 450)),
        ("upower_tbl_cci_B20G", CCI_PATCHED_VOLTS, False, True, (200, 450)),
        ("upower_tbl_cci_B24G", CCI_PATCHED_VOLTS, False, True, (200, 450)),
    ]

    for tbl_name, volts, is_cluster, is_floor, floor_rat in tables:
        if tbl_name not in syms or syms[tbl_name]["file_offset"] is None:
            raise KeyError(f"Missing required table symbol: {tbl_name}")
        fo = syms[tbl_name]["file_offset"]
        print(f"[*] Patching {tbl_name} at file offset 0x{fo:04x}...")
        patch_table(data, fo, volts, is_cluster=is_cluster, is_floor_scaled=is_floor, floor_ratio=floor_rat)

    # 2. Stub and disarm EEM functions
    for stub_sym in ["upower_update_volt_by_eem", "upower_update_tables_by_eem"]:
        if stub_sym in syms and syms[stub_sym]["file_offset"] is not None:
            stub_off = syms[stub_sym]["file_offset"]
            stub_val = syms[stub_sym]["value"]
            stub_size = syms[stub_sym]["size"]
            print(f"[*] Disarming {stub_sym} at file offset 0x{stub_off:04x} with PAC/BTI clean-return stub...")
            orig_prefix = data[stub_off : stub_off + len(STUB_BYTES)]
            assert orig_prefix[:4] == bytes.fromhex("3f2303d5"), f"Expected paciasp at {stub_sym} start!"
            data[stub_off : stub_off + len(STUB_BYTES)] = STUB_BYTES
            n_cleared = clear_function_relocations(data, stub_val, stub_size)
            print(f"[*] Cleared {n_cleared} relocations in {stub_sym} to R_AARCH64_NONE")

    with open(output_path, "wb") as f:
        f.write(data)

    print(f"[+] Output written to {output_path} ({len(data)} bytes)!")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Patch Upower.ko for MT6833 EAS & PPM calibration")
    parser.add_argument("-i", "--input", default="Upower.ko", help="Input stock Upower.ko")
    parser.add_argument("-o", "--output", default="Upower_patched.ko", help="Output patched Upower.ko")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"[-] Error: Input file not found: {args.input}")
        sys.exit(1)

    patch_upower(args.input, args.output)
