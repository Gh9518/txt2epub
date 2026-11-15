-- _meta.lua
-- KOReader 插件元数据（name 由插件目录名 txt2epub 决定，无需在此重复声明）
return {
    fullname = "TXT2EPUB",
    description = "将 KOReader 中打开的文档一键转换为带多级章节目录、排版精修的 EPUB，并保存在原文件同一目录。v2.0.0 起无需区分格式、无需另存为：TXT 走标题/缩进识别；.docx 由插件直接解析 OOXML（Word 标题样式→多级目录+完整正文，结果最完整）；.doc/RTF/FB2/EPUB/HTML 等由 KOReader 已打开的文档内容兜底，并对空结果做体检提示。借鉴 txtstyle 的排版预设与 toc_extractor 的多级目录思路，在转换时一次性烘焙进 EPUB，不安装任何常驻阅读钩子。",
    min_koreader_version = "2021.01",
}
