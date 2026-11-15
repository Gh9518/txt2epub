#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 test_inflate.lua 用的 raw DEFLATE 样本集（可重复运行）。

用法：python3 test/fixtures/gen_inflate_cases.py
产出：test/fixtures/inflate_cases/<name>.deflate  +  <name>.plain

覆盖：真实 docx 的 word/document.xml 压缩条目、STORED / fixed / dynamic
Huffman、压缩级别 1/6/9、强重复（长距离回溯）、不可压缩随机数据、
全零长游程、1.84MB 大文件（跨 32KB 分块窗口）。
"""
import os
import random
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "inflate_cases")
os.makedirs(OUT, exist_ok=True)


def zip_compressed_entries(path):
    """手工解析 ZIP，取出每个条目的【压缩字节】（真实 ZIP 存的就是 raw deflate）。"""
    data = open(path, "rb").read()
    e = data.rfind(b"PK\x05\x06")
    total = struct.unpack_from("<H", data, e + 10)[0]
    cd = struct.unpack_from("<I", data, e + 16)[0]
    off, out = cd, {}
    for _ in range(total):
        assert data[off:off + 4] == b"PK\x01\x02"
        method = struct.unpack_from("<H", data, off + 10)[0]
        csize = struct.unpack_from("<I", data, off + 20)[0]
        usize = struct.unpack_from("<I", data, off + 24)[0]
        fnl = struct.unpack_from("<H", data, off + 28)[0]
        exl = struct.unpack_from("<H", data, off + 30)[0]
        cml = struct.unpack_from("<H", data, off + 32)[0]
        lo = struct.unpack_from("<I", data, off + 42)[0]
        name = data[off + 46:off + 46 + fnl].decode()
        lfnl = struct.unpack_from("<H", data, lo + 26)[0]
        lex = struct.unpack_from("<H", data, lo + 28)[0]
        ds = lo + 30 + lfnl + lex
        out[name] = (method, data[ds:ds + csize], usize)
        off += 46 + fnl + exl + cml
    return out


def raw_deflate(b, level=6, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(b) + c.flush()


def save(name, comp, plain):
    open(os.path.join(OUT, name + ".deflate"), "wb").write(comp)
    open(os.path.join(OUT, name + ".plain"), "wb").write(plain)
    print("%-18s %7d -> %7d B" % (name, len(comp), len(plain)))


# 1) 真实 docx（全部条目 method=8）里的 document.xml 压缩流
docx = os.path.join(HERE, "sample.docx")
if os.path.exists(docx):
    ents = zip_compressed_entries(docx)
    m, comp, usize = ents["word/document.xml"]
    save("doc_xml", comp, zlib.decompress(comp, -15))

# 2) 多种数据特征 / block 类型 / 压缩级别
random.seed(42)
chinese = ("第一章 风起\n这是第一段正文，包含中文与 English 123。\n" * 3000).encode()
mixed = b"".join(bytes([i % 256]) * ((i % 7) + 1) for i in range(5000))
big = ("第三章 大结局 这是一段用于验证 32KB 回溯窗口与分块冻结的长文本。" * 20000).encode()

cases = {
    "empty": b"",
    "short": b"hello world, KOReader txt2epub!",
    "ascii_repeat": b"AB" * 20000,
    "random_1k": bytes(random.randrange(256) for _ in range(1000)),
    "zeros": bytes(50000),
}
for name, plain in cases.items():
    save(name, raw_deflate(plain, 6), plain)

for name, plain in (("chinese", chinese), ("mixed", mixed)):
    for lvl in (1, 6, 9):
        save("%s_lv%d" % (name, lvl), raw_deflate(plain, lvl), plain)

# STORED block（level 0）与 fixed Huffman
save("stored_lv0", raw_deflate(cases["random_1k"], 0), cases["random_1k"])
fixed_plain = b"hello hello hello hello world"
save("fixed", raw_deflate(fixed_plain, 6, zlib.Z_FIXED), fixed_plain)

# 3) 大文件（触发 inflate.lua 的 freeze_old 分块）
save("big", raw_deflate(big, 6), big)

print("样本生成完毕 ->", OUT)
