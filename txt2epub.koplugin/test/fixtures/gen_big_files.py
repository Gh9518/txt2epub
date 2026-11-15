#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成大文件压力测试用的 Word 文档（可重复运行）。

用法：python3 test/fixtures/gen_big_files.py
产出（在 fixtures 目录，并复制到 /workspace/测试文件/ 供真机使用）：
  big_novel.docx        —— 真实 OOXML、DEFLATE 压缩、多级目录、数百章 + 一个超大章
  big_novel_STORED.docx —— 同上但不压缩（method 0），用于对照

设计目标：
  * 覆盖 v2.0.0 真机修复路径：.docx 自解析 + inflate.lua 解压大 DEFLATE 流；
  * document.xml 达数 MB，验证内存有界与 32KB 回溯窗口；
  * 含一个 >256KB 的单章，验证「超大章节自动切分」；
  * 多级标题（卷 Heading1 / 章 Heading1 / 节 Heading2），验证目录嵌套。

样式值直接用 Heading1 / Heading2 / Title：插件 docx.lua 的 paragraph_level
按 <w:pStyle w:val="..."> 字符串识别层级，不依赖 styles.xml，但本脚本仍生成
styles.xml / core.xml 等标准部件，确保 Word / WPS / KOReader 都能正常打开。
"""
import os
import shutil
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
# fixtures -> test -> txt2epub.koplugin -> workspace，再进「测试文件」目录
OUTDIR = os.path.abspath(os.path.join(HERE, "..", "..", "..", "测试文件"))

CN = ("天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳"
      "云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰菜重芥姜"
      "海咸河淡鳞潜羽翔龙师火帝鸟官人皇始制文字乃服衣裳推位让国有虞陶唐")


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def body_para(i):
    # 每段约 100~140 字，带编号与中英数字混排，保证内容有变化（避免压缩率失真）
    seg = CN[(i * 7) % len(CN):] + CN[: (i * 13) % 40]
    txt = ("%d　%s，风吹过山岗，带来远方的消息。English words %d and 数字 %d "
           "交织在 paragraphs & 段落之间，验证 <标签> 转义与 &amp; 实体是否正确。"
           % (i, seg[:60], i * 37 % 99991, i * 17 % 100000))
    return '<w:p><w:r><w:t xml:space="preserve">%s</w:t></w:r></w:p>' % esc(txt)


def heading(val, text):
    return ('<w:p><w:pPr><w:pStyle w:val="%s"/></w:pPr>'
            '<w:r><w:t>%s</w:t></w:r></w:p>' % (val, esc(text)))


def build_document_xml():
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
        '<w:body>',
    ]
    # 书名（Title 样式，作为书名不单独成章）
    parts.append(heading("Title", "大文件压力测试小说"))
    cn_num = "零一二三四五六七八九"

    def num(n):
        # 生成中文数字（简化：几十几百用数字+中文拼接即可，仅作标题文本）
        return str(n)

    para_id = 0
    for vol in range(1, 4):
        parts.append(heading("Heading1", "第%s卷　卷名之%d" % (cn_num[vol], vol)))
        for ch in range(1, 101):
            parts.append(heading("Heading1", "第%d章　章节标题%d" % ((vol - 1) * 100 + ch, ch)))
            # 每章 12 段正文
            for _ in range(12):
                para_id += 1
                parts.append(body_para(para_id))
            # 每 5 章插一个二级标题「节」
            if ch % 5 == 0:
                parts.append(heading("Heading2", "第%d节　细节展开" % ch))
                for _ in range(6):
                    para_id += 1
                    parts.append(body_para(para_id))

    # 超大章：单章 3000 段，远超 256KB，验证自动切分
    parts.append(heading("Heading1", "番外　超长章节（用于验证 256KB 自动切分）"))
    for _ in range(3000):
        para_id += 1
        parts.append(body_para(para_id))

    parts.append('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>')
    parts.append('</w:body></w:document>')
    return "".join(parts), para_id


CONTENT_TYPES = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                 '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                 '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                 '<Default Extension="xml" ContentType="application/xml"/>'
                 '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
                 '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
                 '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
                 '</Types>')

RELS = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>')

DOC_RELS = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
            '</Relationships>')

STYLES = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          + "".join('<w:style w:type="paragraph" w:styleId="%s"><w:name w:val="%s"/></w:style>'
                    % (s, s) for s in ("Title", "Heading1", "Heading2", "Heading3", "Normal"))
          + '</w:styles>')

CORE = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>大文件压力测试小说</dc:title></cp:coreProperties>')


def write_docx(path, document_xml, compress):
    method = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
    with zipfile.ZipFile(path, "w", method, compresslevel=6 if compress else None) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("_rels/.rels", RELS)
        z.writestr("word/document.xml", document_xml)
        z.writestr("word/_rels/document.xml.rels", DOC_RELS)
        z.writestr("word/styles.xml", STYLES)
        z.writestr("docProps/core.xml", CORE)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    xml, npara = build_document_xml()
    print("document.xml: %.2f MB, 正文段落 %d 个" % (len(xml.encode("utf-8")) / 1048576, npara))

    for name, compress in (("big_novel.docx", True), ("big_novel_STORED.docx", False)):
        p = os.path.join(HERE, name)
        write_docx(p, xml, compress)
        size = os.path.getsize(p)
        print("  %-22s %8.1f KB" % (name, size / 1024))
        shutil.copyfile(p, os.path.join(OUTDIR, name))

    # 指标文件，供测试脚本断言期望值
    with open(os.path.join(HERE, "big_files.meta"), "w") as f:
        f.write("paragraphs=%d\n" % npara)
        f.write("xml_bytes=%d\n" % len(xml.encode("utf-8")))
    print("输出目录:", OUTDIR)


if __name__ == "__main__":
    main()
