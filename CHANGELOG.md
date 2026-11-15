# Changelog

本文件记录各版本的功能与修复。日常使用请看 [README.md](README.md)。

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
