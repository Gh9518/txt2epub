# Changelog

本文件记录各版本的功能与修复。日常使用请看 [README.md](README.md)。

## v2.1.4（2026-11-17，真机第二轮反馈）

依据用户上传的 `crash.log` 与各目录 `.txt2epub.log`，修复以下真机问题；全部经 Lua 5.3 / LuaJIT 双解释器回归（新增 `test/test_fixes_v214.lua` 9 项全通过）。

### 1. GBK 文本在无 iconv 设备上丢目录与正文（`05_edges/edge_gbk.txt`）
- 现象：真机 `has_title 预检结果：false` → 缩进模式回退整本单章，中文标题与正文全部丢失。
- 根因：旧版 GBK 解码依赖系统 `iconv` 命令；Kindle 等真机无 `iconv`，`_decode_tmp` 产出空文件后回退「原始 GBK 字节流」，标题正则无法匹配、正文为乱码。
- 修复：新增纯 Lua 模块 `gbk.lua`（GB2312→UTF-8 紧凑码表约 16 KB、流式内存有界、零外部依赖）。`converter.lua` 在 iconv 失败时回退 `gbk.decode_stream`：TXT 走 `_decode_tmp`、MD/HTML 走 `decode_via_iconv`。沙箱模拟无 iconv（PATH 置空）后 `edge_gbk.txt` 的「第一卷 / 第一章」等标题均正确识别，Lua 5.3 / LuaJIT 输出一致。

### 2. 内联标签 HTML 无目录（`05_edges/edge_html_inline.html`）
- 现象：标题只写在 `<span>` 内、无 `<hN>`/`<p>` 块级标签，转换只有 1 章、无目录。
- 修复：`build_epub_from_markup` 在解析结果完全没有 heading 时，复用 docx 的正文标题恢复逻辑，把「短段 + 命中章节标题规则」的段落提升为 heading。该样本现有 3 章目录，与其他格式标题识别一致。

### 3. TXT 缩进模式超长单行变成超长空目录（`05_edges/edge_no_title.txt`）
- 现象：真机走「按缩进切分」时，744 KB 单行纯正文被当成一个目录节点标题、正文传空表，产出单个超长空目录、正文全丢。
- 修复：indent 模式对超过 512 字节的行视为正文，按 UTF-8 边界拆段交给 emit 的 256 KB 分片逻辑，每片进目录。短行（正常缩进目录项）语义不变。该样本现有 4 个分片目录、正文完整。

### 4. EPUB 重复转换导致目录嵌套重复（通性问题）
- 现象：打开已转换的 `.epub` 再点转换，KOReader 已渲染的书名页/目录被当正文再包一层，点进正文出现两个目录标题。
- 修复：`convert()` 对 `.epub` 先弹确认框「重复转换会把原目录/书名页当正文再包一层…如非必要请取消」，误点可取消，确需重新打包才继续。`test_routing.lua` / `test_picker.lua` 已适配并新增确认提示断言。

### 5. DOCX / Markdown 大文件转换前防御性内存回收
- 依据 `crash.log` 时间线：`Killed` 发生在 KOReader「opening file」阶段、早于插件转换日志，主因是 KOReader 原生打开/渲染 Word 的 DOM 占用。插件侧无法释放已渲染 DOM，但在 DOCX/Markup 自解析入口转换前做两轮全量 `collectgarbage("collect")`，并（DOCX）记录 `collectgarbage("count")` 堆占用到 `.txt2epub.log`，便于区分原生 DOM 与插件逻辑。真机建议：大 DOCX 若崩溃，重启 KOReader 后用「选择文件」直接选 docx，避免先打开文档产生 DOM。

> 已知限制：`06_dom_fallback/dom_sample.rtf` 真机「目录不全」经 mock 验证重切分逻辑本身正确（5 章全识别），根因是 KOReader 对 RTF 的 DOM 渲染返回内容本身不全（可见正文仅 1038 字符且含乱码），属引擎能力限制，插件无法补回缺失的渲染内容；建议重要文档优先用 `.docx` 自解析路径。

## v2.1.3（2026-11-16）

全量代码自测（静态校验 + 20 套件双解释器回归 + 62 文件双解释器端到端 + EPUB XML 良构性 + 正文完整性）中发现并修复一个**静默正文丢失**缺陷。

### 修复：TXT 全文无标题时正文被静默丢弃
- 现象：`05_edges/edge_no_title.txt`（744 KB、整本一行、无任何标题与换行）转换后只产出 1 个 **358 字节空章**，744 KB 正文全部丢失；而既有验证只检查目录条数 / 单章大小 / zip 完整性，`nav=1` 即判通过，缺陷长期未被发现。
- 根因：`build_epub_streaming()` 标题模式把「第一个标题之前的正文」放在 `leading` 容器里，而 `flush_into(leading)` **只在遇到空行时触发**；循环结束后缺少收尾 flush，末尾没有空行时 `buffer` 中的残留行被丢弃，`leading.paras` 为空，最终只 emit 空章。
- 修复：循环结束后、`close_current()` 之前，若 `current` 为 nil 且 `leading` 存在，补一次 `flush_into(leading)`。有标题的路径由 `close_current()` 自行 flush，不受影响。
- 修复后：该样本生成 **4 个 XHTML 分片**（最大 197001 字节 / 192 KB），正文中文字符 **232000 与源文件完全守恒**，nav/ncx=1（仅首片进目录，属已记录观察项），Lua 5.3 / LuaJIT 一致。
- 新增回归 `test/test_notitle_flush.lua`（**18 项 × 双解释器**）：覆盖单行超长无标题、多行末尾无空行、末尾有空行护栏、有标题末尾无空行、空文件 / 纯空行、临时文件清理；用「中文字符守恒 + 特征短语」验证，**不依赖目录条数**，避免同类漏检再次发生。

### 自测与校验方法补强
- 静态：双编译器语法检查（25 个 Lua 文件）、4 个纯 Lua 模块导出 API 契约、跨模块调用-定义交叉核对（同时识别 `function X` 与 `X = function` 两种定义形式）、交付包 8 文件 SHA-256 一致性。
- 动态 EPUB：全部产出 EPUB 的 XHTML / OPF / NCX / XML 良构性、`container.xml` 与 `content.opf` 的 manifest / spine 引用完整性、nav 与 ncx 条目数一致、未入目录分片精确对账、按段落取中文骨架指纹验证正文无截断。
- 交叉核对时发现 `DocxReader._entry_reader` 是**可选测试注入钩子**（有 `if ... then` 存在性守卫），非运行时缺陷，已在校验脚本中显式列示而非静默放过。

## v2.1.2（2026-11-15）

真机日志（`crash.log` / `txt2epub.log`，用户第二轮反馈）暴露三个问题，全部修复并全格式回归。

### 1. 修复：同名不同格式输出互相覆盖
- 现象：`big_novel.txt / .docx / .html / .md` 全部输出成 `big_novel.epub`（日志 21:34/21:36/21:38/21:43），后转换的覆盖先转换的，还产生半成品 EPUB，触发 `CRE WARNING: zip file corrupted or invalid`。
- 修复：新增 `TXT2EPUB.output_name_with_ext(base, ext)`，输出名按源格式加小标记：`big_novel_txt.epub` / `big_novel_docx.epub` / `big_novel_html.epub` / `big_novel_md.epub` / `big_novel_doc.epub`。DOM 兜底路径同样加标记。已带标记则不重复追加，大小写归一。

### 2. 修复：超长章节拆分不够（各格式）
- 现象：真机 `.docx` 单章达 **279927 字节（273KB）**，超过 256KB 阈值；`Kindle indexer` 卡顿诱因。
- 根因：分片累加只用「原始段落文本字节」，未计 `build_chapter_xhtml` 每段 `<p>\n</p>\n` 包装与转义开销（约 9~40 字节/段）。180 段的章按原始字节切到 256KB，生成 XHTML 后被撑到 263KB+。
- 修复：三套 emit（streaming / paragraphs / DOM raw）统一按「段落实际输出开销」估算与累加（每段预留 64 字节）；docx/TXT/MD/HTML 各格式超长章样本均验证单章严格 <256KB（基线最大 244696 字节，239KB）。所有分片继续全部进目录。

### 3. 修复：TXT 目录不折叠 + 连续转换崩溃
- 目录不折叠：`build_epub_streaming` 标题模式 `close_current()` 把章节 level 硬编码为 0，丢弃创建时算好的卷(0)/章(1)/节(2)层级，nav/ncx 全平铺。改为沿用 `current.level`，多级目录正确嵌套折叠（单测验证 nav 多个 `<ol>`、节级标题入目录）。
- 连续转换崩溃：日志中连续转换 8 个大文件后 `Killed`（内核 OOM，无 Lua 堆栈）。`_async_run` 在成功/失败收尾都做双重 `collectgarbage("collect")` 并断开协程/结果引用；`docx.lua` 解压释放后双重回收；`Converter.release_lines()` 无条件清除解码缓存条目（含原生 UTF-8 的 `false` 值，避免连续转换累积）。

### 验证
- 新增 `test_v212.lua`（31 项，覆盖输出名契约、各格式超长章拆分、TXT 目录折叠、连续转换内存），Lua 5.3 / LuaJIT 双解释器全通过。
- 全量回归约 19 套件 × 双解释器 0 失败；连续 8 次真实大文件（STORED.docx/html/txt/md/DEFLATE.docx）压力测试全部成功，插件侧堆稳定不无限增长。
- 说明：真机 OOM 主因是 KOReader 打开 docx 的 DOM 缓存渲染（日志中每次 opening 6~8 秒）叠加 Kindle 有限内存；插件侧已将自身内存与分片体积压到最低并稳定，无法消除 KOReader 原生 DOM 的占用。

## v2.1.1（2026-11-15）
### 修复：大 `.docx` 转换「目录不全（共 9 章）」与「OOM 被 Killed」

真机日志（`crash.log` / `txt2epub.log`，`big_novel_STORED.docx`）：
- `16:52:33 开始由 Word 生成 EPUB` 后无成功行，`crash.log` 第 204 行只有 `Killed`（内核 OOM killer，无 Lua 堆栈），KOReader 直接退出。
- `17:17:12 EPUB 生成成功（Word），共 9 章` —— 但目录严重不全。
- 对照同一次会话 `17:03:21` 转换 `big_novel.doc` 成功 **370 章**（正文标题 364、重切分是），说明 `.doc`/DOM 路径正常，问题只在 `.docx` 自解析路径。

**根因**（沙箱精确复现）：设备上那份 `.docx` 的 Word 标题样式（`w:pStyle` / `outlineLvl`）丢失或未被识别，`DocxReader` 得到 `heading=0`。把测试文件去掉 `<w:pStyle>` 后，双解释器均复现「**9 章、nav 仅 1 条**」，与真机一致。旧流水线两个缺陷同时爆发：
1. `build_epub_from_paragraphs()` 的 `emit()` 先 `table.concat` 出**整章 2.2 MB 大字符串**，叠加 KOReader 已打开的 docx DOM（crash.log 里 `rendering took 6.5 s`），在 Kindle 低内存上触发 OOM `Killed`；
2. 6960 个正文段全聚成 1 个大章，按 256 KB 硬切成 9 片，且 `toc=(part==1)` 只让首片进目录 → `nav.xhtml` / `toc.ncx` 仅 1 条 →「共 9 章、目录不全」。
而 `.doc` 走 DOM 路径早有「从正文文本重切标题」兜底（`resplit_chapters_by_heading`），故正常 —— 这个能力此前没补到 docx 自解析路径。

**修复**（`converter.lua` / `main.lua`）：
- 新增 `Converter.recover_docx_headings()`：仅当 Word 样式标题缺失或严重不足（为 0，或文本候选 > 样式标题 ×2）时，把正文中「短段落（≤80 字节，真机正文段 373 字节 / 标题段约 20 字节）+ 命中 `is_chapter_title`」的段落提升为 `heading`，层级用 `title_level`（与 `.txt`/DOM 路径完全一致）。标准 Word 样式文档完全不改动（护栏测试确认）。
- `emit()` 改为**先按累计字节估算、超限直接按段分片逐片写盘**，绝不先拼整章大字符串；**每个分片都进目录**（旧实现只让首片进）。这同时消除 OOM 峰值与「硬切 9 片只有 1 条目录」。
- `build_epub_from_docx()` 通过 `hooks.on_diag` / 第三个返回值回传标题体检统计；`main.lua` 在 `.txt2epub.log` 新增一行「Word 标题体检：样式标题 N，正文段 N，文本候选标题 N，兜底重切 是/否（提升 N，模式 …）」，真机可直接判断是否生效。

**验证**：
- 真机场景复现（去样式 `big_novel_STORED.docx`）：从「**9 章 / nav 1 条**」变为「**367 章 / nav 367 条 / 三级嵌套目录**」，与标准样式版章节数完全一致；峰值内存 LuaJIT 21 MB / Lua 5.3 28 MB，耗时 0.36–0.70 s。
- 纯正文零标题大 docx（OOM 兜底）：10 个分片**全部进目录**、单章 XHTML < 300 KB、不 panic。
- 新增 `test_docx_notoc.lua`（45 项，覆盖纯函数 8 组 + 端到端无样式/标准样式/纯正文大书 + 标准样式护栏）。全套 **533 项 × Lua 5.3 / LuaJIT 双解释器通过、0 失败**（18 套件）。过程中修正测试样本 `c/4` 在 Lua 5.3 产生浮点 `1.0` 导致 `第1.0节` 漏识别的问题（双解释器验证抓到，非插件 bug）。

**收尾加固（全类型测试阶段发现）**：
- `verify_all_types.lua` 处理 GBK 样本时经 `Converter.lines()` 会在源文件同目录生成 `.txt2epub_decode.tmp`，但验证脚本漏调 `release_lines()`，导致临时文件污染样本目录、有被误打包风险。现每个文件处理完（成功/失败路径）都用 `pcall(release_lines)` 清理；真机 `main.lua` 本就在 pcall 后无条件清理，插件逻辑无误。
- `Converter._decode_tmp()` 原只判断解码临时文件「能否打开」，未判「是否为空」。设备无 `iconv` / 解码失败时 shell 重定向仍会创建空文件，被当作结果返回会导致**空书 + 空临时文件残留**。现改为判空即删除并返回 `false`，回退为按原始字节流式读（内存有界、不崩溃、不空书），与「无 iconv 时按原始字节处理」承诺一致。`test_edge.lua` 新增 3 项边界用例覆盖空/正常输出，双解释器通过。

## v2.1.0（2026-11-15）
### 修复：`.doc` 仍无目录、`.docx` 大文件崩溃；新增 Markdown / HTML 支持

真机日志（`big_novel.doc`）：`可见正文 2204261 字符，TOC 条目 0，正文标题 0，重切分 否，章节 15`；随后转换 `big_novel_STORED.docx` 时 `crash.log` 只留 `Killed`，KOReader 被系统杀死、无 EPUB 产出。

- **`.doc` 无目录的真因**：`big_novel.doc` 的 363 个标题全部用 **U+3000 全角空格**（`第1章　章节标题1`），`chapterTitle()` 的后缀校验只认 `^%s` / `^%p`（ASCII 空白/标点），导致**全部漏判 → 正文标题 0 → 不重切**；再加上硬切的 15 个分片只有第 1 片进 `nav/ncx`，最终只剩 1 条目录。
  - 新增 `normalize_title_ws()`（全角空格 / NBSP / U+2000 系列 / 零宽空格）与 `is_title_separator()`（中文全角标点 `：` `（` 等），`.txt` 与 DOM 路径同时受益。
  - 新增第二层「纯文本重建」兜底：DOM 无块级标签时把 HTML 转纯文本行再识别标题，退化成 `<p>` 但保证有目录；`html_to_blocks()` 增加 `<br>` 切点。
  - **所有硬切分片都进目录**（不再只有第 1 片）；正文确实无标题时也能逐段跳转。
  - 日志新增「重切分方式」「DOM HTML 样本（前 160 字节）」，`stats` 增加 `resplit_mode` / `html_sample`。
- **`.docx` 被 `Killed` 的真因**：`crc32()` 每字节调用 3 次 `bxor()`，而旧 `bxor` 是**逐位 32 次循环 + `2^i` 幂运算**；2.8 MB 内容要跑上亿次级运算，在 Kindle ARM 上耗时分钟级并持续占用内存，被内核 OOM killer 杀死（无 Lua 堆栈）。
  - `bxor` 改为优先 `bit.bxor`（LuaJIT 真机）/ `bit32.bxor`，否则用 16×16 半字节查表（8 次循环、无幂运算）；`crc32` 热路径精简。实测 2.8 MB STORED docx：LuaJIT **2.02 s → 0.36 s**、Lua 5.3 **14.82 s → 0.70 s**，EPUB 全部条目 CRC 仍正确。
  - `DocxReader` 解析完立刻释放 ZIP 原始字节与 `document.xml`；`build_epub_from_paragraphs()` 逐段消费并置空、`collectgarbage("step")`，降低内存峰值。
- **新增 `.md` / `.markdown` / `.html` / `.htm` 插件自解析**（`markup.lua`）：Markdown ATX/Setext 标题、代码块、列表、行内标记；HTML `<title>` 作书名、`<h1>`~`<h6>` 作多级标题，剥离 script/style、解码实体；UTF-8 与 GBK 均可。不依赖 KOReader 能否打开该格式。`.docx` 与新格式统一走 `build_epub_from_paragraphs()` 流水线。
- **发布包改为含顶层目录** `txt2epub.koplugin/`：解压即得插件目录，直接拷入 `plugins/` 即可，无需手动建目录。插件文件由 7 个增至 **8 个**（新增 `markup.lua`）。
- **测试样本**：新增 `big_novel.txt`（2.2 MB，3 卷/300 章/60 节、标题含全角空格），并附 `big_novel.md` / `big_novel.html`；生成脚本 `test/fixtures/gen_txt_big.py`。
- **更名方案**：README 新增「七、更名方案」，主推 `doc2epub.koplugin`（仓库 `doc2epub`、菜单 `Doc2EPUB`），列出全部需同步项；本轮按需求保持现名与安装路径不变。
- **验证**：新增 `test_dom_unicode.lua`（42 项，完整复现真机 363 标题全角空格场景）、`test_markup.lua`（40 项）；真机日志场景从「正文标题 0 / 章节 15」变为「**正文标题 363 / 章节 363 / 363 条目录**，耗时 0.7 s」。全套 **488 项 × Lua 5.3 / LuaJIT 双解释器通过、0 失败**（17 套件）。

## v2.0.1（2026-11-15）
### 修复：大文件 `.doc` 转换「有正文、无目录、目录没排版」

真机日志（`big_novel.doc`）：`DOM 提取体检：可见正文 2204261 字符，TOC 条目 0，章节 15` → `EPUB 生成成功（通用文档），共 15 章`。

- **根因**：旧版 `.doc`（OLE2）经 KOReader CreDocument 渲染后，Word 的「标题 1/2/3」样式只是普通 `<p>`，DOM 里没有 `<h1>`~`<h6>`，`getToc()` 返回 **0 条**。旧实现因此把全书按页聚合成 1 个 2.2 MB 大章，再由 `emit()` 按 256 KB 硬切成 15 个「big_novel（2）…（15）」续篇——`nav.xhtml` / `toc.ncx` 只剩 **1 条无意义目录**（书名，续篇不计入），正文里的「第一卷 / 第X章 / 第X节」也全是普通 `<p>`，既无居中加粗标题、也无层级。
- **修复**（`converter.lua` 新增「DOM 正文标题识别 + 重切分」）：
  - `html_to_blocks()` 按 `</p>` / `</div>` / `</hN>` 等块边界单次线性拆块并给出纯文本；无块标签时按行兜底。数字字符实体用零依赖的码点→UTF-8 解码（LuaJIT 无 `utf8.char`，超范围码点安全降级 U+FFFD）。
  - 复用 `.txt` 路径同一套 `chapterTitle()` / `title_level()` 识别标题（中文数字、卷/章/节多级、楔子/番外等特例），并兼容 DOM 自带 `<hN>` 层级。
  - `resplit_chapters_by_heading()`：识别到 ≥ 2 个标题、且重切后章节数明显更多时，按标题重切——标题以 `<h1 class="chapter-title lv-N">` 居中排版且不再在正文重复，首个标题之前的正文并入第一章，正文 HTML 无损拼接保留。
  - `nest_toc()` 依 level 生成真正的多级嵌套 `nav.xhtml` / `toc.ncx`（卷 → 章 → 节）。
  - `sanitize_document_html()` 改为**全局**剥离 `<html>/<body>/<head>/<style>/<script>`：按页聚合时每页都自带一份包裹，残留会让首章 XHTML 出现嵌套 `<body>`；`<style>` 文本还会与本页第一个标题落在同一文本块，导致卷标题漏识别。
  - 仅当「重切后章节数 > 现有章节数」才替换，**已有完整 TOC 的文档不受影响**；正文确实无标题时保持原按 256 KB 切分行为。
- **诊断**：`.txt2epub.log` 体检行新增「正文标题 N / 重切分 是·否」，`stats` 增加 `detected_titles` / `resplit`，真机可直接判断识别是否生效。
- **测试**：新增 **`test_dom_toc.lua`（41 项）** 复现真机规模（3 页、300 章、6 节、每页文档包裹），验证多级目录 / 标题排版 / 无重复标题 / 单章 < 300 KB / 正文不丢；`test_docapi.lua` 追加**适配层 → converter 端到端**用例（48 项）。**全套 406 项 × Lua 5.3 / LuaJIT 双解释器通过、0 失败**（15 套件）。

## v2.0.0（2026-11-14）
### 重大变更：统一入口，无需区分格式 / 无需另存为
用户侧只需「打开文档 → 点开始转换」。插件内部按**能否可靠自解析**自动选路，对格式无感：

- **`.txt`**：插件自解析，标题正则 / 空格缩进识别（中文网文最佳）。
- **`.docx`**：插件**直接解析 OOXML**（`build_epub_from_docx`）——Word 标题样式 → 多级目录 + 完整正文，纯 Lua 读 ZIP、不依赖 KOReader，结果最完整、最稳定。
- **`.doc` / `.rtf` / `.fb2` / `.epub` / `.html`**：插件无专用解析器，改由 **KOReader 已打开文档的 DOM 兜底**（`build_epub_from_document`），旧版 `.doc` 等无需再另存为 `.docx`。所有 KOReader 专属调用（getProps / getToc / getHTMLFromXPointer(s) / getPageXPointer）均用 `pcall` 守护并抽象为 `doc_api` 接口，任一缺失都不会 panic。
- **空结果体检**（`is_empty_document_result`）：DOM 提取到的正文可见字符过少时，删除半成品并明确提示"请另存为 .docx"，绝不静默交出空壳 EPUB。

### 真机验证与修正（相对初始实现）
- 曾尝试让 **Word(.docx) 也走通用 DOM 流程**：在 Kindle 上转换 `sample_stored.docx`，结果 EPUB 仅有标题 + 「测试小说书名」一行，无目录、无正文（crash.log 显示转换"成功"、无报错）。
- **根因 1**：CreDocument 打开 Word 文档时 `getToc()` 只有 1 条（文档标题；Word 的「标题样式」≠ 文档目录），且末章 `getHTMLFromXPointer(pos0)` 只返回**单个节点**的 HTML（恰好是 Title 段），正文全部丢失。
- **修正 1**：`.docx` 回到自解析（本地端到端验证 5 章 + 嵌套目录 + 完整正文）；DOM 流程仅保留给插件无法自解析的格式，并加空书体检。
- **真机报错 2**：转换压缩版 `.docx`（真实 Word 保存的 DEFLATE 文件）弹出 `converter.lua: 读取 Word 文档失败：解压失败：./ffi/zlib.lua:29: assertion failed!`。此前只有不压缩的 STORED 样本能过（沙箱测试曾因无 `ffi/zlib` 直接跳过，从未验证压缩路径）。
- **根因 2**：.docx 是 ZIP，条目存的是 **raw DEFLATE**（RFC1951，无 zlib 头、无 adler32 尾）；而 KOReader `ffi/zlib.zlib_uncompress()` 内部是 zlib `uncompress()`，**只认 zlib 格式**，喂 raw 流会返回 `Z_DATA_ERROR` 并触发 `assert(res == 0)` 失败。其 `zlib_h` 也未声明 `inflateInit2_`/`inflate` 等 raw-inflate 接口，无从借用。
- **修正 2**：新增 **`inflate.lua`** —— 纯 Lua 实现的 raw DEFLATE 解压器（canonical Huffman + LZ77，算术代替位运算，兼容 Lua 5.1/5.3/LuaJIT；32 KB 回溯窗口 + 分块冻结，内存有界不 OOM），彻底不依赖设备 zlib / ffi / 外部进程。`docx.lua` 的 deflate 条目改由它解压，STORED 与 DEFLATE 统一走同一条 EPUB 打包链路。
- 测试：`test_routing.lua`（25 项）锁定「.docx 走自解析、不走 DOM」与空书体检；`test_picker.lua`（20 项）匹配选择器扩列；新增 **`test_inflate.lua`（30 项）** 用真实 docx 压缩条目 + STORED/fixed/dynamic/多压缩级别/1.84 MB 大文件逐字节比对；`test_docx.lua`（29 项）取消 DEFLATE 跳过、改为沙箱内完整端到端验证。

### 大文件压测后的代码审查修正（发布前）
大文件测试全绿后，进一步对照 KOReader 真机源码审查，修掉 3 个「测试全绿、真机/大文件却会翻车」的隐患：
- **数字字符实体崩溃**：`docx.lua` 用 Lua 5.3 才有的 `utf8.char` 解 `&#20013;` / `&#x4E2D;`，而 KOReader 真机是 **LuaJIT（无全局 utf8 库）** → 含此类实体的 Word 文档转换直接抛错；超范围码点在 Lua 5.3 上也会抛 `value out of range`。改为纯 Lua 码点→UTF-8，并对非法/超范围码点安全降级为 U+FFFD。
- **DOM 兜底格式真机全废**：`_build_doc_api` 误按 `text/pos0/pos1` 读 KOReader 的 TOC，而真实字段是 **`title/page/depth/xpointer`**（见 `readertoc.lua`）→ `pos0` 恒为 nil、所有条目被跳过 → `.doc`/RTF/FB2/EPUB/HTML 全部落进空书提示，一个都转不出来。此前测试全用模拟 `doc_api` 手工灌 `pos0`，**从未覆盖真机适配层**。修正字段映射 + 无 xpointer 时用页码经 `getPageXPointer` 换算 + 补齐文档末尾 xpointer（末章不再退化为「单节点 HTML」）；`build_epub_from_document` 右端边界改为「下一个有 pos0 的条目」，避免中间无效条目导致整章延伸到文档末尾。
- **单段超长绕过 256 KB 切分**：Word「一整章不分段」时 `emit` 要求 `#paras > 1` 才切分，会产出 576 KB 单章 XHTML（Kindle indexer 卡顿/重启诱因）；DOM 路径无 `</p>` 边界时 `split_html_at_p` 同样失效。新增 UTF-8 安全的超长文本拆分 + DOM 二次硬切，单章 XHTML 稳定 < 300 KB，正文完整保留。
- **畸形 / 截断 docx 健壮性**：`le16`/`le32` 越界返回 nil、ZIP 各字段做边界检查、`DocxReader.read` 加 `pcall` 兜底，损坏文件统一返回明确错误而非抛出 Lua 算术异常。
- 新增 **`test_docapi.lua`（34 项）** 用贴近真机的 mock 文档对象验证「适配层 → converter → EPUB」全链路；**`test_regress.lua`（30 项）** 自包含生成样本，双解释器锁定实体解码 / 单段超长 / 无边界切分 / 畸形文件；收紧 `test_big_files.lua` 的 `pcall` 断言（同时校验 build 的 `ok` 返回值，消除假通过）。**全套 315 项 × Lua 5.3 / LuaJIT 双解释器通过**。

## v1.0.1（2026-11-14）
### 修复
- **「开始转换」按钮变灰、点不了（尤其 DOCX）**：旧实现用 `enabled_func` 把「当前文档不是 .txt/.docx」的菜单项静默置灰且无提示；而 KOReader 打开 DOCX 后 `document.file` 在某些版本下并非原始 `.docx` 路径（内部转换），导致判断失效、按钮置灰。
  改为：**按钮始终可点**；真正的源判定移到 `convert()` 内；当打开的并非可用源文件（epub/pdf，或 DOCX 路径被改写）时，**弹出文件选择器让用户直接点选磁盘上的 `.txt`/`.docx`**，彻底绕开对 `document.file` 扩展名的不可靠依赖。新增 `test_picker.lua`（19 项）覆盖该逻辑。

## v1.0.0（2026-11-05）
首个公开发布版本。

### 功能
- TXT → EPUB 一键转换（菜单「工具 › TXT2EPUB」），输出同名 `.epub` 至原目录。
- **Word(.docx) → EPUB 转换**：章节层级取自 Word 标题样式（Title / Heading1–9、含中/日/法/德文样式名与 outlineLvl），自动生成多级目录；纯 Lua 解析 OOXML（ZIP 容器 + 纯 Lua raw DEFLATE 解压），不依赖第三方库。旧版 `.doc` 暂不支持。
- 多级章节目录：卷/部/册/篇 → 章/回 → 节/集/幕，生成 EPUB3 `nav.xhtml` + EPUB2 `toc.ncx`。
- 排版预设：紧凑 / 标准 / 宽松大字 / 自定义，转换时烘焙进 `style.css`，无常驻钩子。
- 本地字体选择：列出本机全部字体，菜单按界面语言显示中文名/英文名及样式（粗体·斜体）；存储值仍为系统可识别的英文族名。
- 超大章节切分（>256 KB）、无标题时按空格缩进识别层级、自定义章节标题正则。
- 纯 Lua 实现（内置 ZIP 写入器），不依赖第三方库；流式按行读写，内存有界。

### 稳定性修复（迭代过程）
- **Kindle OOM 重启 / ANR 闪退**：改为流式逐章写盘 + 协程 `yield` 回 UI 线程，主线程永不被长时间阻塞；编码判定容忍 64KB 末尾截断误判；GBK/UTF-16 改为解码到临时文件再流式读回；周期性 `collectgarbage`。峰值内存稳定在一章量级（约 1.3 MB / 7MB 大书）。
- **卡在扫描目录**：移除 `count_chapters` 预扫描整遍遍历与 `lfs` 目录遍历（旧版每 3 次运行扫整个书籍目录），仅保留 O(1) 的单文件日志检查。
- **预设/字体/参数"选不中"**：修复 Lua 5.1 闭包共享陷阱（循环变量拷贝 `local this_x = x`）。
- **数值参数输入崩溃**：行高/段距等改选项列表点选，规避虚拟键盘在部分输入法插件下崩溃。
- **「正在识别章节」卡死**：`_open_progress` 先关闭残留旧常驻框再建新框。
- **自定义参数点不动**：改回 `sub_item_table_func` 惰性子菜单（独立 `Menu` 不识别该字段）。
- **勾选/显示不刷新**：字体与参数勾选改为实时读取。
- **「排版预设」菜单崩溃**：修复 `for _` 循环变量遮蔽 gettext `_` 函数（`attempt to call local '_' (a number value)`）。
- **日志维护/字体列表兜底**：日志超 512 KB 清空重建；`fontinfo` 为空时回退 `fontlist.fontnames`。

### 致谢
借鉴 [AnkioTomas/moon](https://github.com/AnkioTomas/moon)（章节识别+段落回流）、[doudou-xsz/txtstyle.koplugin](https://github.com/doudou-xsz/txtstyle.koplugin)（快速风格参数+字体枚举）、[michael-galaxy/toc_extractor.koplugin](https://github.com/michael-galaxy/toc_extractor.koplugin)（多级目录思路）。
