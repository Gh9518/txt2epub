-- _meta.lua
-- KOReader 插件元数据（name 由插件目录名 txt2epub 决定，无需在此重复声明）
return {
    fullname = "TXT2EPUB",
    description = "把 TXT / Word(.docx) / Markdown(.md) / HTML(.html,.htm) 等文档一键转换为带多级章节目录、排版精修的 EPUB，保存在原文件同一目录。.txt/.docx/.md/.html/.htm 由插件直接解析源文件（不依赖 KOReader 解析器），.doc/RTF/FB2/EPUB 等由已打开文档内容兜底；即使 getToc() 为 0 条、或 Word 标题样式丢失，也会从正文识别标题重切分（兼容全角空格与中文标点），生成多级目录与标题排版；空结果另有体检提示。v2.1.0 重写 CRC-32 位运算并提前释放大缓冲；v2.1.1 修复真机大 .docx「目录不全 / 被 Killed」：Word 样式标题为 0 时从正文文本恢复章节标题，且分片写出不再拼整章大字符串、所有分片进目录。v2.1.2：① 输出文件名按源格式加标记（big_txt/docx/html/md.epub），同名不同格式不再互相覆盖；② 超长章按实际 XHTML 字节（计入 <p> 包装开销）拆分，各格式单章严格 <256KB；③ 修复 TXT 多级目录不折叠（卷/章/节 level 不再被压成 0），并在每次转换收尾彻底回收内存，缓解连续转换累积 OOM。v2.1.3：修复 TXT 全文无标题、末尾无空行时正文被静默丢弃（收尾 flush 缺失），并新增正文字符守恒回归测试。v2.1.4（真机反馈）：① 新增纯 Lua GB2312 解码兜底（gbk.lua），设备无 iconv 时 GBK 文本不再丢目录与正文；② 内联标签 HTML（标题只在 <span> 内）自动恢复多级目录；③ TXT 缩进模式超长单行按字节分片入目录，不再产出单个超长空目录；④ 打开已转换的 .epub 再点转换会先弹重复转换确认，避免目录嵌套重复；⑤ DOCX/Markdown 转换前主动全量回收并记录堆占用，缓解真机原生 DOM 叠加导致的 OOM。借鉴 txtstyle 的排版预设与 toc_extractor 的多级目录思路，转换时一次性烘焙进 EPUB，不安装任何常驻阅读钩子。",
    min_koreader_version = "2021.01",
}
