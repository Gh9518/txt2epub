#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成大文件 TXT（及配套 .md/.html）压力测试样本。

用法：python3 test/fixtures/gen_txt_big.py
产出（写到 /workspace/测试文件/）：
  big_novel.txt   —— UTF-8 纯文本，3 卷 / 300 章 / 60 节，约 2MB+
  big_novel.md    —— 同内容的 Markdown（# ~ #### 多级标题）
  big_novel.html  —— 同内容的 HTML（<h1>~<h4> + <p>）

设计要点：
  * 标题一律使用 U+3000 全角空格（「第1章　章节标题1」），与真机
    big_novel.doc 完全一致，用于覆盖 v2.1.0 修复的「全角空格导致
    chapterTitle 全部漏判」缺陷。
  * 卷 -> 章 -> 节三级，验证 EPUB nav.xhtml / toc.ncx 的多级嵌套。
  * 正文含中文、英文、数字与 XML 特殊字符（& < >），验证转义。
"""
import html
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.abspath(os.path.join(HERE, "..", "..", "..", "测试文件"))

CN = ("天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳"
      "云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰菜重芥姜"
      "海咸河淡鳞潜羽翔龙师火帝鸟官人皇始制文字乃服衣裳推位让国有虞陶唐")
CN_NUM = "零一二三四五六七八九"
FULL_SPACE = "\u3000"  # U+3000 全角空格（真机日志里的关键字符）


def body_line(vol, ch, k):
    seg = CN[(vol * 31 + ch * 7 + k * 13) % len(CN):]
    seg = (seg + CN)[:70]
    return ("%d　%s，风吹过山岗，带来远方的消息。English words %d and 数字 %d "
            "交织在段落之间，验证 <标签> 转义与 & 符号是否正确无误。"
            % (ch, seg, (vol * 99991 + ch * 37 + k) % 99991,
               (vol * 17 + ch * 131 + k * 7) % 100000))


def build_sections():
    """返回 [(level, title, [正文行...]), ...]，level: 1=书名 2=卷 3=章 4=节"""
    out = [(1, "大文件压力测试小说", [])]
    for vol in range(1, 4):
        out.append((2, "第%s卷%s卷名之%d" % (CN_NUM[vol], FULL_SPACE, vol), []))
        for ch in range(1, 101):
            no = (vol - 1) * 100 + ch
            lines = []
            for k in range(1, 21):
                lines.append(body_line(vol, ch, k))
            out.append((3, "第%d章%s章节标题%d" % (no, FULL_SPACE, ch), lines))
            if ch % 5 == 0:
                out.append((4, "第%d节%s细节展开" % (ch, FULL_SPACE),
                            ["本节为层级目录测试正文，记录第%d章的小结与补充。" % ch,
                             "继续补充一段正文，确保章节不为空。"]))
    return out


def render_txt(sections):
    parts = []
    for level, title, lines in sections:
        parts.append(title)
        parts.append("")
        for ln in lines:
            parts.append(ln)
            parts.append("")
    return "\n".join(parts)


def render_md(sections):
    parts = []
    for level, title, lines in sections:
        parts.append("#" * level + " " + title)
        parts.append("")
        for ln in lines:
            parts.append(ln)
            parts.append("")
    return "\n".join(parts)


def render_html(sections):
    parts = ["<!DOCTYPE html>", "<html><head><meta charset=\"UTF-8\"/>",
             "<title>大文件压力测试小说</title></head><body>"]
    for level, title, lines in sections:
        parts.append("<h%d>%s</h%d>" % (level, html.escape(title), level))
        for ln in lines:
            parts.append("<p>%s</p>" % html.escape(ln))
    parts.append("</body></html>")
    return "\n".join(parts)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    sections = build_sections()
    n_heads = len(sections)
    n_bodies = sum(len(x[2]) for x in sections)
    print("标题 %d 个，正文段 %d 个" % (n_heads, n_bodies))
    for name, renderer in (("big_novel.txt", render_txt),
                           ("big_novel.md", render_md),
                           ("big_novel.html", render_html)):
        text = renderer(sections)
        data = text.encode("utf-8")
        path = os.path.join(OUTDIR, name)
        with open(path, "wb") as f:
            f.write(data)
        print("  %-20s %8.1f KB  %d 字节" % (name, len(data) / 1024, len(data)))
    print("输出目录:", OUTDIR)


if __name__ == "__main__":
    main()
