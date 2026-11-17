#!/usr/bin/env python3
"""
patch_dvfsrc.py - Patch MediaTek MT6833 DVFSRC (SoC Interconnect / Vcore) Modules
Author: Kana Wesley Yamada & Antigravity

Targets:
  1. mtk-dvfsrc.ko:
     - dvfsrc_opp_mt6833_lp4 table: Remaps all Level 3 (725.00 mV) OPP entries to Level 2 (650.00 mV).
     - mt6873_set_vcore_level function: Replaces 'mov w20, w1' with 'bic w20, w1, w1, lsr #1',
       mathematically clamping requested Vcore level to <= 2 (650.00 mV cap).
  2. mtk-dvfsrc-regulator.ko:
     - dvfsrc_set_voltage_sel function: Replaces 'mov w2, w21' with 'bic w2, w21, w21, lsr #1',
       clamping regulator framework voltage selector requests (e.g., from 120Hz display) to <= 2.
  3. mtk-dvfsrc-helper.ko:
     - dvfsrc_opp_mt6833_lp4 table in .data: Remaps all Level 3 entries to Level 2 so sysfs
       and SMC opp initializations synchronize to 650.00 mV.
"""

import argparse
import os
import struct
import sys

def find_symbol_offset(elf_data, symbol_name):
    if elf_data[:4] != b'\x7fELF':
        raise ValueError("Not an ELF file")
    
    e_shoff = struct.unpack('<Q', elf_data[40:48])[0]
    e_shentsize = struct.unpack('<H', elf_data[58:60])[0]
    e_shnum = struct.unpack('<H', elf_data[60:62])[0]
    e_shstrndx = struct.unpack('<H', elf_data[62:64])[0]
    
    sections = []
    for i in range(e_shnum):
        sh_offset = e_shoff + i * e_shentsize
        sh_name, sh_type, sh_flags, sh_addr, sh_offset_file, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = \
            struct.unpack('<IIQQQQIIQQ', elf_data[sh_offset:sh_offset+64])
        sections.append({
            'name_idx': sh_name,
            'type': sh_type,
            'offset': sh_offset_file,
            'size': sh_size,
            'link': sh_link,
            'entsize': sh_entsize
        })
    
    shstrtab = elf_data[sections[e_shstrndx]['offset'] : sections[e_shstrndx]['offset'] + sections[e_shstrndx]['size']]
    for s in sections:
        name_end = shstrtab.find(b'\x00', s['name_idx'])
        s['name'] = shstrtab[s['name_idx']:name_end].decode('ascii', errors='ignore')
    
    symtab = next((s for s in sections if s['type'] == 2), None) # SHT_SYMTAB
    if not symtab:
        return None
    strtab = sections[symtab['link']]
    str_data = elf_data[strtab['offset'] : strtab['offset'] + strtab['size']]
    
    num_symbols = symtab['size'] // symtab['entsize']
    for i in range(num_symbols):
        sym_offset = symtab['offset'] + i * symtab['entsize']
        st_name, st_info, st_other, st_shndx, st_value, st_size = \
            struct.unpack('<IBBHQQ', elf_data[sym_offset:sym_offset+24])
        name_end = str_data.find(b'\x00', st_name)
        curr_name = str_data[st_name:name_end].decode('ascii', errors='ignore')
        if curr_name == symbol_name:
            target_section = sections[st_shndx]
            file_offset = target_section['offset'] + st_value
            return file_offset, st_size
            
    return None

def patch_mtk_dvfsrc(data, target_level=2):
    print("[*] Patching mtk-dvfsrc.ko...")
    # 1. OPP table
    res = find_symbol_offset(data, 'dvfsrc_opp_mt6833_lp4')
    if not res:
        offset, size = 0x8ef8, 200
        print(f"[!] dvfsrc_opp_mt6833_lp4 not found in symtab, using static offset 0x{offset:x}")
    else:
        offset, size = res
        print(f"[+] Located dvfsrc_opp_mt6833_lp4 at 0x{offset:x} (size {size} bytes)")
        
    num_entries = size // 8
    patched_opp = 0
    for i in range(num_entries):
        entry_offset = offset + i * 8
        vcore_opp, dram_opp = struct.unpack('<2I', data[entry_offset:entry_offset+8])
        if vcore_opp == 3:
            struct.pack_into('<2I', data, entry_offset, target_level, dram_opp)
            print(f"    - OPP entry {i:2d} (DDR step {dram_opp}): Level {vcore_opp} (725mV) -> {target_level} (650mV)")
            patched_opp += 1
    print(f"[+] Patched {patched_opp} OPP entries in mtk-dvfsrc.ko")
    
    # 2. mt6873_set_vcore_level function clamp
    res_func = find_symbol_offset(data, 'mt6873_set_vcore_level')
    if not res_func:
        func_offset = 0x473c
        print(f"[!] mt6873_set_vcore_level not found in symtab, using static offset 0x{func_offset:x}")
    else:
        func_offset, func_size = res_func
        print(f"[+] Located mt6873_set_vcore_level at 0x{func_offset:x}")
        
    inst_offset = func_offset + 0x24
    curr_inst = data[inst_offset:inst_offset+4]
    if curr_inst == bytes.fromhex('f403012a'): # mov w20, w1
        data[inst_offset:inst_offset+4] = bytes.fromhex('3404610a') # bic w20, w1, w1, lsr #1
        print(f"[+] Patched mt6873_set_vcore_level at 0x{inst_offset:x}: mov w20, w1 -> bic w20, w1, w1, lsr #1")
    elif curr_inst == bytes.fromhex('3404610a'):
        print(f"[+] mt6873_set_vcore_level at 0x{inst_offset:x} is already clamped.")
    else:
        raise ValueError(f"Unexpected instruction at 0x{inst_offset:x}: {curr_inst.hex()}")

def patch_mtk_dvfsrc_regulator(data):
    print("[*] Patching mtk-dvfsrc-regulator.ko...")
    res = find_symbol_offset(data, 'dvfsrc_set_voltage_sel')
    if not res:
        func_offset = 0x1240
        print(f"[!] dvfsrc_set_voltage_sel not found in symtab, using static offset 0x{func_offset:x}")
    else:
        func_offset, func_size = res
        print(f"[+] Located dvfsrc_set_voltage_sel at 0x{func_offset:x}")
        
    inst_offset = func_offset + 0x3c
    curr_inst = data[inst_offset:inst_offset+4]
    if curr_inst == bytes.fromhex('e203152a'): # mov w2, w21
        data[inst_offset:inst_offset+4] = bytes.fromhex('a206750a') # bic w2, w21, w21, lsr #1
        print(f"[+] Patched dvfsrc_set_voltage_sel at 0x{inst_offset:x}: mov w2, w21 -> bic w2, w21, w21, lsr #1")
    elif curr_inst == bytes.fromhex('a206750a'):
        print(f"[+] dvfsrc_set_voltage_sel at 0x{inst_offset:x} is already clamped.")
    else:
        raise ValueError(f"Unexpected instruction at 0x{inst_offset:x}: {curr_inst.hex()}")

def patch_mtk_dvfsrc_helper(data, target_level=2):
    print("[*] Patching mtk-dvfsrc-helper.ko...")
    res = find_symbol_offset(data, 'dvfsrc_opp_mt6833_lp4')
    if not res:
        offset, size = 0xeb90, 400
        print(f"[!] dvfsrc_opp_mt6833_lp4 not found in symtab, using static offset 0x{offset:x}")
    else:
        offset, size = res
        print(f"[+] Located helper dvfsrc_opp_mt6833_lp4 at 0x{offset:x} (size {size} bytes)")
        
    num_entries = size // 16
    patched_count = 0
    for i in range(num_entries):
        entry_offset = offset + i * 16
        vcore_opp, dram_opp, uV, khz = struct.unpack('<4I', data[entry_offset:entry_offset+16])
        if vcore_opp == 3:
            struct.pack_into('<4I', data, entry_offset, target_level, dram_opp, uV, khz)
            print(f"    - Helper OPP entry {i:2d} (DDR step {dram_opp}): Level {vcore_opp} -> {target_level}")
            patched_count += 1
    print(f"[+] Patched {patched_count} OPP entries in mtk-dvfsrc-helper.ko")

def main():
    parser = argparse.ArgumentParser(description="MediaTek MT6833 DVFSRC Vcore Patcher")
    parser.add_argument("-i", "--input", required=True, help="Input kernel module (.ko)")
    parser.add_argument("-o", "--output", required=True, help="Output patched kernel module (.ko)")
    parser.add_argument("-t", "--type", choices=['dvfsrc', 'regulator', 'helper', 'auto'], default='auto',
                        help="Module type to patch (auto detects by filename)")
    args = parser.parse_args()
    
    if not os.path.isfile(args.input):
        print(f"[-] Error: Input file {args.input} does not exist.")
        sys.exit(1)
        
    with open(args.input, 'rb') as f:
        data = bytearray(f.read())
        
    mod_type = args.type
    if mod_type == 'auto':
        base = os.path.basename(args.input)
        if 'regulator' in base:
            mod_type = 'regulator'
        elif 'helper' in base:
            mod_type = 'helper'
        elif 'dvfsrc' in base:
            mod_type = 'dvfsrc'
        else:
            print("[-] Error: Unable to determine module type from filename.")
            sys.exit(1)
            
    if mod_type == 'dvfsrc':
        patch_mtk_dvfsrc(data)
    elif mod_type == 'regulator':
        patch_mtk_dvfsrc_regulator(data)
    elif mod_type == 'helper':
        patch_mtk_dvfsrc_helper(data)
        
    with open(args.output, 'wb') as f:
        f.write(data)
    print(f"[+] Output written to {args.output}")

if __name__ == "__main__":
    main()
