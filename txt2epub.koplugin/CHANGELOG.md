# Changelog

各版本功能与修复的精简记录（保留关键技术结论）。日常使用请看 [README.md](README.md)。

## v2.1.8（2026-11-18）
- **修复 `big_novel.docx` 目录「卷」不折叠**：该文件的「第X卷」与「第X章」同为 `Heading1`、`第X节` 为 `Heading2`，旧逻辑只按样式定层级导致卷章平铺。
- **方案**：`build_epub_from_paragraphs` 入口新增 `refine_heading_levels`，**保守触发**——仅当文本层级种类多于样式层级种类时，按「卷/部/册/篇=0、章/回=1、节/集/幕=2」重分级。big_novel 触发（3卷/305章/60节三级折叠），long_chapter（H1/H2/H3）、markup `<hN>`、无章节字样的文档均不触发、零影响。
- 真机日志新增「目录层级精修」诊断行；新增 `test_fixes_v218.lua`（26 项双解释器通过）。
- **打包**：zip 解压即得 `txt2epub.koplugin/` 文件夹，可整目录拷入 `plugins/`。

## v2.1.7（2026-11-18）
- **根治 big_novel.docx / long_chapter.docx 的 `Killed`（OOM）崩溃**：真机新日志无 `ffi.load: z` 仍崩，推翻 v2.1.6 的 FFI 判断。真凶是旧 docx 流程「先全解压成 2.8MB 字符串→再解析成 7000+ 段落表」的**瞬时内存尖峰**（GC 前 ~18MB RSS），叠加 KOReader 已渲染 DOM 的 28–30MB 高基线堆触发内核 OOM。
- **方案**（功能零损失，段落逐段验证一致）：`inflate.lua` 新增 `raw_stream`（边解压边回调，保留 `raw` API）；`docx.lua` 新增增量解析器 `make_stream_parser`，解压即解析、凑成 `<w:p>` 立即 emit 丢弃源文本。瞬时堆 9.6→3.8MB、RSS 18→13.7MB、单次最大分配 2.8MB→32KB。
- 顺带消除同类瞬时大分配：`rtf.lua` 逐字节建表改整段切片（2.4MB RTF RSS 39.8→25.9MB）；TXT `emit` 先估算再分片，不再先拼整章大串。DOM 兜底路径因可能改变章节数/目录，遵循「不损失功能」未改。
- 新增 `test_fixes_v217.lua`（20 项双解释器通过）。

## v2.1.6（2026-11-17）
- **RTF 目录不全/乱码截断**：KOReader RTF 渲染器无法解析负数 `\u` 转义，DOM 只返回前 968 字符。新增 `rtf.lua` 自解析源文件（负数 `\u`+65536、`\ucN`、`\par`、`\b`、`\'XX`、过滤忽略组），坏码点降级 U+FFFD 占位符；`.rtf` 走独立流水线。真机验证目录完整、`garbled=0`。
- **移除 FFI 快路径 + 解压熔断**：当时判断 FFI zlib 是崩溃根因（后经 v2.1.7 推翻，FFI 非根因）。移除 FFI、回归纯 Lua 解压并加输出总量/迭代次数熔断——作为安全加固予以保留（坏流只报友好错误，绝不拖崩）。各转换入口转换前两轮全量 GC。

## v2.1.5（2026-11-17）
- **压缩 docx 转换必崩（OOM）**：旧纯 Lua inflate 逐字节处理 2.8MB XML 在 Kindle 上 CPU/内存爆炸。本轮引入 FFI zlib 快路径（后被 v2.1.6/v2.1.7 移除/推翻）+ 优化纯 Lua 回退；两条路径与系统 unzip 逐字节一致。
- **体积**：`gbk.lua` 码表改 base64 惰性解码，62KB→27KB。
- **标题标点清理**：`tidy_chapter_punct` 把「第X章/卷」与标题间标点换成单空格，成对括号与全角空格保留。
- **损坏 docx 友好提示**：新增 `_friendly_error`，弹简明中文提示，技术细节写日志。
- **DOM 兜底乱码清洗**：多次解码 HTML 实体、降重实体、`sanitize_garbled_text` 清除乱码字符区。
- testfiles 8 个有效 docx 补「测试文件规格」头与「正文结束·核对标记」，heading 数不变。新增 `test_fixes_v215.lua`（21 项）。

## v2.1.4（2026-11-17）
- **GBK 无 iconv 设备丢目录/正文**：新增纯 Lua `gbk.lua`（GB2312→UTF-8 码表，零外部依赖），iconv 失败时回退。
- **内联标签 HTML 无目录**：解析无 heading 时复用正文标题恢复逻辑。
- **TXT 超长单行空目录**：indent 模式对 >512 字节行按 UTF-8 边界拆段分片。
- **EPUB 重复转换防嵌套**：对 `.epub` 转换先弹确认框。
- **DOCX/Markdown 转换前防御性全量 GC**，并记录堆占用到日志。新增 `test_fixes_v214.lua`（9 项）。

## v2.1.3（2026-11-16）
- **静默正文丢失**：TXT 全文无标题、末尾无空行时 `flush_into(leading)` 漏收尾，744KB 正文只剩空章。循环结束后补一次 flush。新增 `test_notitle_flush.lua`（18 项，中文字符守恒验证，不依赖目录条数）。
- 全量自测补强：双编译器语法检查、跨模块调用核对、EPUB XML 良构性、正文守恒指纹。

## v2.1.2（2026-11-15）
- **同名不同格式输出互相覆盖**：输出名加格式标记（`_txt`/`_docx`/`_html`/`_md`/`_doc`）。
- **超长章拆分不足**：emit 按段落实际输出开销（含 `<p>` 包装约 64 字节/段）估算累加，单章严格 <256KB。
- **TXT 目录不折叠**：`close_current()` 沿用 `current.level`（卷0/章1/节2），不再硬编码 0。
- **连续转换崩溃**：收尾双重 GC、断开协程/结果引用、`release_lines()` 无条件清缓存。新增 `test_v212.lua`（31 项）。

## v2.1.1（2026-11-15）
- **大 docx「目录不全（9 章）」+ OOM**：真机 Word 标题样式丢失、`heading=0`。新增 `Converter.recover_docx_headings()`：样式标题为 0 或文本候选 > 样式×2 时，从短段落 + `is_chapter_title` 恢复标题，层级用 `title_level`。`emit()` 改为按字节估算直接分片、每片进目录。从「9 章/nav 1 条」恢复为「367 章/nav 367 条三级目录」。新增日志「Word 标题体检」行、`test_docx_notoc.lua`（45 项）。
- **解码临时文件健壮性**：`_decode_tmp` 判空即删、回退原始字节流式读；`release_lines()` 清理临时文件污染。

## v2.1.0（2026-11-15）
- **`.doc` 无目录真因**：363 个标题用 U+3000 全角空格，后缀校验只认 ASCII 空白/标点全部漏判。新增 `normalize_title_ws()` / `is_title_separator()`，所有硬切分片都进目录。
- **`.docx` 被 Killed 真因**：`bxor` 逐位 32 次循环 + 幂运算，2.8MB 要跑上亿次级。改用 `bit.bxor`/`bit32.bxor`，否则 16×16 查表。2.8MB STORED docx：LuaJIT 2.02s→0.36s、Lua 5.3 14.82s→0.70s。
- **新增 Markdown/HTML 自解析**（`markup.lua`）；与 docx 统一走 `build_epub_from_paragraphs`。
- 发布包改为含顶层 `txt2epub.koplugin/`；插件文件增至 8 个。新增 `test_dom_unicode.lua`（42 项）、`test_markup.lua`（40 项）。

## v2.0.1（2026-11-15）
- **大 `.doc`「有正文、无目录」**：Word 标题样式经 CreDocument 渲染后只是 `<p>`、`getToc()` 为 0。新增 DOM 正文标题识别 + 重切分：`html_to_blocks()` 块拆分、复用 `title_level()`、`resplit_chapters_by_heading()`、`nest_toc()` 多级嵌套；`sanitize_document_html()` 全局剥离 html/body/style/script。仅当重切后章节更多才替换。新增 `test_dom_toc.lua`（41 项）。

## v2.0.0（2026-11-14）
- **统一入口**：用户只需打开文档→点转换。`.txt` 标题/缩进识别；`.docx` 自解析 OOXML；`.doc`/RTF/FB2/EPUB/HTML 走 DOM 兜底、空结果体检。
- 曾尝试让 docx 走 DOM 失败（getToc 1 条、末章只返单节点），回归自解析。
- 新增 `inflate.lua`：纯 Lua raw DEFLATE 解压器（canonical Huffman + LZ77，32KB 窗口，兼容 Lua 5.1/5.3/LuaJIT），不依赖设备 zlib/ffi。
- 大文件压测后修正 3 个隐患：`utf8.char` 在 LuaJIT 崩溃→纯 Lua 码点解码；DOM TOC 字段映射错误（`title/page/depth/xpointer`）；单段超长绕过 256KB 切分。畸形 docx 健壮性。新增 `test_docapi.lua`、`test_regress.lua`、`test_inflate.lua`。

## v1.0.1（2026-11-14）
- **「开始转换」按钮变灰**：按钮始终可点，源判定移入 `convert()`，源文件不可用时弹文件选择器。新增 `test_picker.lua`。

## v1.0.0（2026-11-05）
首个公开发布版本：TXT/Word(.docx)→EPUB 一键转换；卷/章/节多级目录（EPUB3 nav + EPUB2 ncx）；排版预设与本地字体；超长章切分；纯 Lua 流式实现、内存有界。
