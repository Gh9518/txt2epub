-- _meta.lua
-- KOReader 插件元数据（name 由插件目录名 txt2epub 决定，无需在此重复声明）
return {
    fullname = "TXT2EPUB",
    description = "将 KOReader 中打开的 TXT 文件一键转换为带多级章节目录、排版精修的 EPUB 电子书，并保存在原文件同一目录。借鉴 txtstyle 的排版预设与 toc_extractor 的多级目录思路，在转换时一次性烘焙进 EPUB，不安装任何常驻阅读钩子。",
    min_koreader_version = "2021.01",
}
