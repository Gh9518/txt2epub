-- _meta.lua
-- KOReader 插件元数据（name 由插件目录名 txt2epub 决定，无需在此重复声明）
return {
    fullname = "TXT2EPUB",
    description = "把 TXT / Word(.docx) / Markdown(.md) / HTML(.html,.htm) 等文档一键转换为带多级章节目录、排版精修的 EPUB，保存在原文件同一目录。.txt/.docx/.md/.html/.htm 由插件直接解析源文件（不依赖 KOReader 解析器），.doc/RTF/FB2/EPUB 等由已打开文档内容兜底；即使 getToc() 为 0 条也会从正文识别标题重切分（兼容全角空格与中文标点），生成多级目录与标题排版；空结果另有体检提示。v2.1.0 重写 CRC-32 位运算并提前释放大缓冲，修复 Kindle 上大 .docx 转换被系统 Killed。借鉴 txtstyle 的排版预设与 toc_extractor 的多级目录思路，转换时一次性烘焙进 EPUB，不安装任何常驻阅读钩子。",
    min_koreader_version = "2021.01",
}
