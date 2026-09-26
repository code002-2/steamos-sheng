#!/usr/bin/env python3
"""parse-gpt.py —— 从 GPT 镜像头部（前几 MB）解析出指定分区的字节偏移与长度

用法: parse-gpt.py <head.bin> [分区名关键字]
输出: 一行 `<偏移字节> <长度字节> <分区名>`；找不到则以非 0 退出。

为什么要它：Steam Frame 底包是 7.5 GB 的 GPT 整盘镜像 + 4 GB 的 bz2，直接解压两者
需要 11.6 GB 磁盘（runner 放不下）。改成「流式两遍」：第一遍只取前 4 MB 解析分区表，
第二遍 curl | bunzip2 | dd 精确切出 rootfs 分区 —— 全程只落盘 5 GB。
"""
import struct
import sys

SECTOR = 512


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: parse-gpt.py <head.bin> [分区名关键字]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    keyword = sys.argv[2] if len(sys.argv) > 2 else "rootfs"

    # 只读前 4 MiB：GPT 头在 LBA1、分区表在 LBA2（128 项 × 128 B = 16 KiB），全在文件开头。
    # 底包整盘镜像有 7.1 GB，绝不能整个读进内存。
    with open(path, "rb") as fh:
        data = fh.read(4194304)

    if len(data) < 2 * SECTOR or data[SECTOR:SECTOR + 8] != b"EFI PART":
        print(f"不是 GPT：LBA1 处没有 'EFI PART' 签名（读了 {len(data)} 字节）", file=sys.stderr)
        return 1

    hdr = data[SECTOR:SECTOR + SECTOR]
    entries_lba = struct.unpack_from("<Q", hdr, 72)[0]
    num_entries = struct.unpack_from("<I", hdr, 80)[0]
    entry_size = struct.unpack_from("<I", hdr, 84)[0]
    if entry_size < 128 or num_entries == 0:
        print(f"GPT 头异常：num_entries={num_entries} entry_size={entry_size}", file=sys.stderr)
        return 1

    base = entries_lba * SECTOR
    found = []
    for i in range(num_entries):
        off = base + i * entry_size
        if off + entry_size > len(data):
            break  # 头部读得不够长，剩下的条目不可见
        ent = data[off:off + entry_size]
        if ent[:16] == b"\x00" * 16:
            continue  # 空条目
        first_lba, last_lba = struct.unpack_from("<QQ", ent, 32)
        if last_lba < first_lba:
            continue
        name = ent[56:128].decode("utf-16-le", "replace").split("\x00")[0].strip()
        found.append((i, first_lba, last_lba, name))

    if not found:
        print("GPT 里没有任何有效分区条目（头部可能没读够）", file=sys.stderr)
        return 1

    print("解析到分区:", file=sys.stderr)
    for i, first, last, name in found:
        print(f"  [{i}] {name or '(无名)'} 起 LBA {first} 长度 {(last - first + 1) * SECTOR} 字节", file=sys.stderr)

    pick = None
    for i, first, last, name in found:
        if keyword and keyword.lower() in name.lower():
            pick = (i, first, last, name)
            break
    if pick is None and len(found) > 1:
        pick = found[1]  # 兜底：第 2 个分区（0-based index 1）
        print(f"警告: 没有名字含 '{keyword}' 的分区，退回第 2 个分区", file=sys.stderr)
    if pick is None:
        print(f"找不到分区（关键字 '{keyword}'）", file=sys.stderr)
        return 1

    _, first_lba, last_lba, name = pick
    offset = first_lba * SECTOR
    length = (last_lba - first_lba + 1) * SECTOR
    print(f"{offset} {length} {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
