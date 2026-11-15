# txt2epub —— KOReader 插件：TXT / Word 等一键转 EPUB

在 KOReader 中打开一个文档，通过「**工具 › TXT2EPUB**」一键把它转换成**同名的 `.epub`**，保存在原文件同一目录。**无需区分格式、无需另存为**——插件内部自动选最可靠的方式：`.txt` 走标题/缩进识别；`.docx` 由插件**直接解析 OOXML**（Word 标题样式 → 多级目录 + 完整正文，最完整）；`.doc`/RTF/FB2/EPUB/HTML 等由 KOReader 已打开的文档内容兜底转换。生成的 EPUB 带有可跳转的**多级章节目录**（同时兼容 EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx`），并内置借鉴开源项目的排版精修。

> 借鉴的开源项目与具体代码，见文末「致谢与开源借鉴」。

---

## English Overview

**txt2epub** is a KOReader plugin that converts the currently opened document into a polished `.epub` with **one tap** (menu **Tools › TXT2EPUB**). **No format juggling, no "save as"** — the plugin picks the most reliable path automatically: `.txt` uses title/indent detection; `.docx` is parsed **directly from OOXML** by the plugin (Word heading styles → multi-level TOC + full text, the most complete result); `.doc`/RTF/FB2/EPUB/HTML fall back to the document KOReader already opened. The result ships with a real multi-level TOC (both EPUB3 `nav.xhtml` and EPUB2 `toc.ncx`, recognized by KOReader) and typography presets inspired by other open-source KOReader plugins.

### Highlights
- **One-tap, any format (v2.0.0)** — `.txt` and `.docx` are parsed by the plugin itself (reliable, full TOC + text); other reader-supported formats (`.doc`/RTF/FB2/EPUB/HTML) use KOReader's parsed document as a fallback, with an empty-result guard instead of silently producing an empty book.
- **Multi-level TOC** — auto-detects 卷/部/册/篇 → 章/回 → 节/集/幕 instead of a flat list.
- **Typography presets** (Compact / Standard / Relaxed / Custom) baked into `style.css` at conversion time — no resident hooks, zero runtime memory cost.
- **Streaming, low-memory build** — writes the EPUB chapter-by-chapter and never pre-scans the whole book, so it won't be OOM-killed on memory-tight devices like Kindle.
- **Local font selection** — pick any installed font (name shown in your UI language) or type a name as fallback.
- **Large-chapter splitting** — splits XHTML chapters larger than 256 KB.

### Install
1. Copy `txt2epub.koplugin/` into KOReader's `plugins/` directory (e.g. `koreader/plugins/`, or `Android/data/org.koreader.ko_reader/files/plugins/` on Android).
2. Fully quit and restart KOReader.
3. Open any supported document (`.txt`, Word `.doc`/`.docx`, RTF, FB2, EPUB, HTML) → **Tools › TXT2EPUB**.

---

## 一、安装

把整个 `txt2epub.koplugin` 目录复制到 KOReader 的插件目录，再**完全退出并重启** KOReader：

| 设备 | 路径 |
| --- | --- |
| Kindle / Kobo | `koreader/plugins/` |
| Android | `Android/data/org.koreader.ko_reader/files/plugins/` |
| 桌面版 | KOReader 安装目录下的 `plugins/` |

插件目录需包含**全部文件**（勿遗漏）：`_meta.lua`、`main.lua`、`converter.lua`、`docx.lua`（Word 解析）、`inflate.lua`（raw DEFLATE 解压）、`README.md`、`CHANGELOG.md`。其中 `docx.lua` / `inflate.lua` 为 `.docx` 转换必需，缺失会报「无法加载 docx/inflate 模块」。重启后打开任意文档，「工具」菜单下应出现「TXT2EPUB」。

---

## 二、使用

1. 在 KOReader 打开任意受支持的文档（`.txt` / Word `.doc`·`.docx` / RTF / FB2 / EPUB / HTML）。
2. 点「**工具 › TXT2EPUB › 开始转换**」（按钮始终可点；无法判定源文件时会弹文件选择器让你点选；输出已存在会询问是否覆盖）。
3. 可在「**排版预设…**」里先选「紧凑 / 标准 / 宽松大字」一键套用排版风格。
4. 插件按章节标题自动切分正文，生成带多级目录与排版精修的 EPUB，转换完成后弹「✓ 转换完成：共 N 章」。
5. 用 KOReader 打开生成的 `.epub` 即可通过目录面板跳转。

**转换进度**：先显示「正在识别章节…」做标题预检，再显示「正在写入…+进度条+已写入 N 章」；全程常驻进度框，完成即自动关闭并弹出完成提示。诊断日志写在**源文件同目录**的隐藏文件 `.txt2epub.log`（日志为隐藏文件，需在文件管理器开启「显示隐藏文件」；每次转换追加写入，超 512 KB 自动清空重建）。

### 设置（可选）
- **排版预设**：紧凑 / 标准 / 宽松大字 / 自定义；「自定义参数…」逐项微调行高·段距·首行缩进·字号缩放·字距·两端对齐（选项列表点选，即时保存）；「正文字体…」从本机字体列表预览选择（中文字体显示中文名+样式，英文显示英文名）。
- **章节标题正则**：可填一条 Lua 模式覆盖默认识别规则，附「示例」按钮；「恢复默认正则」复位。
- 默认支持的标题写法：`第一章` / `第1章` / `第一回` / `卷一 少年游` / `楔子` / `番外` / `后记` / `序章` / `Chapter 1` 等。
- **无标题时按空格缩进识别层级**：若文档无显式章节标题，可弹窗选择「按缩进切分」（每行前导空格数决定层级，步长可在设置里改）、「整本作一章」或「取消」。

---

## 三、功能特性

- **多级目录**：卷/部/册/篇 → 章/回 → 节/集/幕 三级嵌套，生成真正的 EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx`。
- **排版预设**：紧凑（行距130%）/ 标准（默认，行距155%＋段距0.3em＋首行缩进2字）/ 宽松大字（行距185%＋字号115%）/ 自定义，转换时烘焙进 `style.css`，不装常驻钩子。
- **本地字体**：列出本机全部已安装字体，菜单按界面语言显示中文名/英文名及样式（粗体·斜体）。
- **Word 文档**：直接打开 `.docx` 亦可一键转换（菜单同为「工具 › TXT2EPUB」）。章节层级取自 Word 的标题样式（Heading1/2/3… 与 Title），自动生成多级目录、完整正文；插件用纯 Lua 直接解析 OOXML，STORED 与压缩（DEFLATE）docx 均支持，不依赖设备 zlib。旧版 `.doc` 等其它格式由 KOReader 已打开的文档内容兜底转换。
- **超大章节切分**：单章 XHTML 超过 256 KB 自动切分。
- **墨水屏友好**：`word-break`、`orphans/widows: 2`、`page-break-after: avoid` 等。
- **稳健识别（借鉴 moon）**：中文数字校验 + 特例标题 + 误判过滤 + 段落回流合并。
- **纯 Lua 实现**：内置最小 ZIP 写入器（Store 方式，符合 EPUB 规范），不依赖任何第三方库或系统命令；流式按行读写，内存有界。

---

## 四、致谢与开源借鉴（Attribution）

本插件在转换层取长补短地借鉴了以下开源项目的**代码与方案**，在此郑重致谢：

### 1. [AnkioTomas/moon](https://github.com/AnkioTomas/moon)
借鉴其**稳健章节识别**与**段落回流合并**：中文数字校验（含 `零〇一二…十百千万两`）、英文 `Chapter/Section` 序号、特例标题（序章/序言/楔子/尾声/番外等）并过滤正文误判；把软换行拆散的物理行按句末标点/空行/列表/对话句首重新聚合成逻辑段落。本插件在转换阶段复用其判定逻辑，而非阅读时挂常驻钩子。

### 2. [doudou-xsz/txtstyle.koplugin](https://github.com/doudou-xsz/txtstyle.koplugin)
借鉴其**排版"快速风格"参数模型**与**字体枚举**：把行高/段距/首行缩进/字号缩放/字距/两端对齐做成可一键套用的预设，转换时烘焙进 `style.css`；通过 `require("fontlist"):getFontList()` 读取本机字体。差异：txtstyle 以常驻钩子实时注入 CSS，本插件改在转换时烘焙静态样式，对 KOReader 常驻内存零增量。

### 3. [michael-galaxy/toc_extractor.koplugin](https://github.com/michael-galaxy/toc_extractor.koplugin)
借鉴其**多级目录识别**思路：自动识别卷/部/册/篇 → 章/回 → 节/集/幕 三级层级，生成真正的嵌套目录。

---

## 五、已知限制

- 非常规章节写法（如纯日期、自定义符号）需通过「设置章节标题正则」补充 Lua 模式。
- 纯 Lua Store 方式不压缩，EPUB 体积偏大（兼容性最好）。
- 缩进模式把每行非空行都当作目录条目，最适合"目录/大纲式"TXT；混有大段散文时建议用显式章节标题或自定义正则。
- `.doc` / RTF / FB2 / EPUB / HTML 走 **KOReader 已打开文档的 DOM 兜底**，目录层级与正文完整度取决于 KOReader 自身对该格式的解析；若提取到的正文过少，插件会删除半成品并提示「另存为 .docx」——`.docx` 由插件直接解析 OOXML，结果最完整、最稳定。旧版 `.doc`（OLE2 二进制）无法达到 `.docx` 的完整度。
- 旧版 `.doc` 等 DOM 兜底格式无法在沙箱真机端到端验证（需 KOReader 引擎），请以设备实测为准。

---

## 六、故障排查与更新日志

详细的崩溃修复与版本变更见 **[CHANGELOG.md](CHANGELOG.md)**。常见问题速查：

- **菜单不显示**（甚至其它插件也消失）：确认目录名为 `txt2epub.koplugin` 且位于 `plugins/`。若所有插件菜单都消失，通常是某插件的 `addToMainMenu` 抛错导致 `MenuSorter` 合并失败——本插件用标准 `sorting_hint = "tools"` 写法，不会触碰内置菜单结构。
- **点转换后崩溃/重启**：多为低内存或 UI 阻塞所致，已通过流式写盘、协程逐章 yield、超大章切分（含单段超长拆分）、移除目录遍历等彻底修复（详见 CHANGELOG）。
- **排查日志**：优先发**源文件同目录的隐藏文件 `.txt2epub.log`**（含时间戳、源类型、逐章进度、含完整 Lua 错误栈的失败信息）；转换失败时屏幕弹窗里的 `转换失败：…` 也带错误栈，可直接截图。`crash.log` / `koreader.log`（KOReader 安装目录下）用于区分插件问题与原生固件/内存问题。

---

本插件运行于 **[KOReader](https://github.com/koreader/koreader)** 之上。欢迎 Star ⭐ 与 PR；收录建议提交至 [koreader/contrib](https://github.com/koreader/contrib) 或 [Awesome KOReader](https://github.com/jannick-holm/awesome-koreader)。
