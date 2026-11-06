#!/usr/bin/env python3
"""把 Mach-O 的 cpusubtype 改成 arm64e（2）。
用法: python3 macho_to_arm64e.py <file> [<file> ...]
说明: 只改 header 里的 subtype，不重算 ad-hoc 签名（越狱环境通常不校验）。
"""
import struct, sys

CPU_TYPE_ARM64 = 0x0100000C
SUBTYPE_ARM64E = 2
MH_MAGIC_64 = 0xFEEDFACF

def patch(path):
    data = bytearray(open(path, "rb").read())
    magic, cputype, subtype = struct.unpack_from("<III", data, 0)
    if magic == 0xCAFEBABE:      # fat
        print("fat 文件，跳过:", path); return False
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        print("不是 arm64 Mach-O:", path, hex(magic), hex(cputype)); return False
    if subtype == SUBTYPE_ARM64E:
        print("已是 arm64e:", path); return True
    struct.pack_into("<I", data, 8, SUBTYPE_ARM64E)
    open(path, "wb").write(data)
    print(f"已改 arm64e: {path}  (subtype {subtype} -> {SUBTYPE_ARM64E})")
    return True

if __name__ == "__main__":
    for p in sys.argv[1:]:
        patch(p)