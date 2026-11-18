# txt2epub —— KOReader 插件：TXT / Word / Markdown / HTML 一键转 EPUB

在 KOReader 中打开一个文档，通过「**工具 › TXT2EPUB**」一键把它转换成一个**带格式标记的 `.epub`**（如 `big_novel_txt.epub` / `big_novel_docx.epub`，保存在原文件同一目录；**v2.1.2 起按源格式加标记，同名不同格式不再互相覆盖**）。插件内部自动选最可靠的方式：`.txt` 走标题/缩进识别；`.docx` 直接解析 OOXML；`.html` / `.htm` / `.md` 由 `markup.lua` 直接解析源文件；`.rtf` 由 `rtf.lua` 直接解析源文件（**v2.1.6 起**，正确解码负数 `\u` 转义，绕开 KOReader DOM 的乱码/截断）；`.doc` / FB2 / EPUB 等由 KOReader 已打开的文档内容兜底。生成的 EPUB 带有可跳转的**多级章节目录**（EPUB3 `nav.xhtml` + EPUB2 `toc.ncx`）与内置排版精修。

> 借鉴的开源项目与具体代码，见文末「致谢与开源借鉴」。命名建议见「七、更名方案」。详细版本变更见 [CHANGELOG.md](CHANGELOG.md)。

---

## English Overview

**txt2epub** is a KOReader plugin that converts a document into a polished `.epub` with **one tap** (menu **Tools › TXT2EPUB**). It parses `.txt`, `.docx`, `.html`/`.htm`/`.md` and `.rtf` itself (no dependency on KOReader's parser), and falls back to KOReader's rendered document for `.doc`/FB2/EPUB, with an empty-result guard. The result ships with a real multi-level TOC (EPUB3 `nav.xhtml` + EPUB2 `toc.ncx`) and typography presets.

### Highlights
- **Self-parsing, many formats** — TXT (title/indent), DOCX (raw OOXML + pure-Lua DEFLATE), Markdown/HTML (`markup.lua`) and RTF (`rtf.lua`, incl. negative `\u` escapes) are parsed from source; other formats use the rendered document as fallback.
- **Robust TOC** — rebuilds nested 卷/章/节 headings from body text when the source has no TOC or loses Word heading styles; preserves heading levels (no flat TOC); re-levels 卷/章 by text semantics only when styles are ambiguous (v2.1.8).
- **Low memory, streaming** — CRC-32 uses the LuaJIT `bit` library (table fallback elsewhere); compressed DOCX is inflated **and parsed in one streaming pass** (`inflate.raw_stream` → incremental `<w:p>` parser), largest single allocation 2.8 MB → 32 KB (v2.1.7). This fixes the `Killed` (OOM) crash on Kindle.
- **Format-tagged output** — same base name in different formats no longer overwrites one `.epub` (`_txt`/`_docx`/`_html`/`_md`/`_doc`, v2.1.2).
- **Large-chapter splitting** — XHTML chapters >256 KB are split with `<p>` wrapper overhead counted; every split part gets a TOC entry.
- **Body integrity & encoding** — no silent data loss for heading-free TXT (v2.1.3); pure-Lua GB2312 decoder when the device lacks `iconv` (v2.1.4); cleaned TOC punctuation and smaller footprint (v2.1.5).
- **Typography presets** baked into `style.css` at conversion time (no resident hooks) and **local font selection**.

### Install
1. Unzip the release archive — it contains a single top-level folder `txt2epub.koplugin/`.
2. Copy that whole folder into KOReader's `plugins/` directory.
3. Fully quit and restart KOReader → open a document → **Tools › TXT2EPUB › 开始转换**.

---

## 一、安装

发布包解压后**直接得到一个 `txt2epub.koplugin/` 目录**，把它整个复制到 KOReader 的插件目录，再**完全退出并重启** KOReader：

| 设备 | 路径 |
| --- | --- |
| Kindle / Kobo | `koreader/plugins/` |
| Android | `Android/data/org.koreader.ko_reader/files/plugins/` |
| 桌面版 | KOReader 安装目录下的 `plugins/` |

插件目录需包含**全部 8 个文件**（勿遗漏）：`_meta.lua`、`main.lua`、`converter.lua`、`docx.lua`（Word 解析）、`inflate.lua`（raw DEFLATE 解压）、`markup.lua`（Markdown/HTML 解析）、`README.md`、`CHANGELOG.md`。其中 `docx.lua` / `inflate.lua` 为 `.docx` 必需，`markup.lua` 为 `.md`/`.html`/`.htm` 必需；缺失会明确报「无法加载 xxx 模块」，不会静默失败。重启后打开任意文档，「工具」菜单下应出现「TXT2EPUB」。

---

## 二、使用

1. 在 KOReader 打开任意受支持的文档，或从菜单里的文件选择器直接选文件。
2. 点「**工具 › TXT2EPUB › 开始转换**」（按钮始终可点；无法判定源文件时会弹文件选择器；输出已存在会询问是否覆盖）。
3. 可在「**排版预设…**」里先选「紧凑 / 标准 / 宽松大字」一键套用排版风格。
4. 插件按章节标题自动切分正文，生成带多级目录与排版精修的 EPUB，完成后弹「✓ 转换完成：共 N 章」。
5. 用 KOReader 打开生成的 `.epub` 即可通过目录面板跳转。

| 扩展名 | 转换方式 | 目录来源 |
| --- | --- | --- |
| `.txt` | 插件自解析（流式按行） | 章节标题正则 / 空格缩进 |
| `.docx` | 插件自解析 OOXML | Word 标题样式（Heading1/2/3… 与 Title）；样式为 0 时自动从正文文本恢复章节标题（v2.1.1） |
| `.md` / `.markdown` | 插件自解析 `markup.lua` | `#` ~ `######`、Setext 标题 |
| `.html` / `.htm` | 插件自解析 `markup.lua` | `<title>` 作书名、`<h1>`~`<h6>` 作多级标题 |
| `.rtf` | 插件自解析 `rtf.lua`（v2.1.6 起，不经 KOReader DOM） | `\b` 粗体段 + 章节规则；正确解码负数 `\u` 转义，目录/正文完整 |
| `.doc` / FB2 / EPUB | KOReader 已打开文档的 DOM 兜底 | 优先用 `getToc()`；为 0 时从正文识别标题重切分 |

**转换进度**：先显示「正在识别章节…」，再显示「正在写入… + 进度条 + 已写入 N 章」；全程常驻进度框，完成即自动关闭。诊断日志写在**源文件同目录**的隐藏文件 `.txt2epub.log`（需在文件管理器开启「显示隐藏文件」；每次转换追加写入，超 512 KB 自动清空重建）。日志含「TOC 条目 / 正文标题数 / 重切分方式 / DOM HTML 样本（前 160 字节）/ Word 标题体检 / 目录层级精修」，便于定位真机差异。

### 设置（可选）
- **排版预设**：紧凑 / 标准 / 宽松大字 / 自定义；「自定义参数…」逐项微调行高·段距·首行缩进·字号缩放·字距·两端对齐；「正文字体…」从本机字体列表预览选择（中文字体显示中文名+样式，英文显示英文名）。
- **章节标题正则**：可填一条 Lua 模式覆盖默认识别规则，附「示例」按钮；「恢复默认正则」复位。
- 默认支持的标题写法：`第一章` / `第1章` / `第一回` / `卷一 少年游` / `楔子` / `番外` / `后记` / `序章` / `Chapter 1` 等；**v2.1.0 起兼容全角空格与中文全角标点**（`第1章　标题`、`第1章：标题`、`第1章（上）`）。
- **无标题时按空格缩进识别层级**：若文档无显式章节标题，可弹窗选择「按缩进切分」「整本作一章」或「取消」。

---

## 三、功能特性

- **多级目录**：卷/部/册/篇 → 章/回 → 节/集/幕 三级嵌套，生成真正的 EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx`；TXT 与 Word 的卷/章/节层级正确折叠；Word 卷章样式相同时按文本语义保守重分级（v2.1.8）。
- **稳健章节识别**（借鉴 moon）：中文数字校验 + 特例标题（序章/楔子/番外等）+ 误判过滤 + 段落回流合并；DOM 无 `getToc()` 时从正文重建目录与标题样式。
- **排版预设**：紧凑（行距130%）/ 标准（默认，行距155%＋段距0.3em＋首行缩进2字）/ 宽松大字（行距185%＋字号115%）/ 自定义，转换时烘焙进 `style.css`，不装常驻钩子；墨水屏友好（`word-break`、`orphans/widows`、`page-break-after: avoid`）。
- **本地字体**：列出本机全部已安装字体，菜单按界面语言显示中文名/英文名及样式（粗体·斜体）。
- **Word 文档**：`.docx` 纯 Lua 直接解析 OOXML，STORED 与 DEFLATE 均支持，不依赖设备 zlib；流式「解压即解析」（v2.1.7）消除 OOM 崩溃；超大章节按 ≤256 KB 分片流式写出、全部分片进目录；样式丢失时自动从正文恢复章节标题（v2.1.1）。旧版 `.doc` 走 DOM 兜底。
- **Markdown / HTML / RTF**：由插件直接读磁盘解析，不依赖 KOReader 是否支持；ATX/Setext 标题、`<h1>`~`<h6>`、代码块、列表、引用、行内标记与 XML 实体；RTF 正确解码负数 `\u`，UTF-8 与 GBK 编码均可。
- **超大章节切分**：单章 XHTML 超过 256 KB 自动切分，按「段落实际输出字节（含 `<p>` 包装开销）」估算，单章严格 <256 KB；每个分片都有目录条目。
- **输出文件名（v2.1.2）**：按源格式加小标记（如 `big_novel.txt → big_novel_txt.epub`），同名不同格式各自独立，不再互相覆盖。
- **低内存 / 纯 Lua**：CRC-32 走 LuaJIT `bit`（其余环境查表回退），ZIP 写完即释放，逐段消费；内置最小 ZIP 写入器（Store 方式，符合 EPUB 规范），不依赖任何第三方库，流式按行读写、内存有界。

---

## 四、致谢与开源借鉴（Attribution）

本插件在转换层取长补短地借鉴了以下开源项目的**代码与方案**，在此郑重致谢：

### 1. [AnkioTomas/moon](https://github.com/AnkioTomas/moon)
借鉴其**稳健章节识别**与**段落回流合并**：中文数字校验（含 `零〇一二…十百千万两`）、英文 `Chapter/Section` 序号、特例标题并过滤正文误判；把软换行拆散的物理行按句末标点/空行/列表/对话句首重新聚合成逻辑段落。本插件在转换阶段复用其判定逻辑，而非阅读时挂常驻钩子。

### 2. [doudou-xsz/txtstyle.koplugin](https://github.com/doudou-xsz/txtstyle.koplugin)
借鉴其**排版"快速风格"参数模型**与**字体枚举**：把行高/段距/首行缩进/字号缩放/字距/两端对齐做成可一键套用的预设，转换时烘焙进 `style.css`；通过 `require("fontlist"):getFontList()` 读取本机字体。差异：txtstyle 以常驻钩子实时注入 CSS，本插件改在转换时烘焙静态样式，对 KOReader 常驻内存零增量。

### 3. [michael-galaxy/toc_extractor.koplugin](https://github.com/michael-galaxy/toc_extractor.koplugin)
借鉴其**多级目录识别**思路：自动识别卷/部/册/篇 → 章/回 → 节/集/幕 三级层级，生成真正的嵌套目录。

---

## 五、已知限制

- 非常规章节写法（如纯日期、自定义符号）需通过「设置章节标题正则」补充 Lua 模式。
- 纯 Lua Store 方式不压缩，EPUB 体积偏大（兼容性最好）。
- 缩进模式把每行非空行都当作目录条目，最适合「目录/大纲式」TXT；混有大段散文时建议用显式章节标题或自定义正则。
- `.doc` / FB2 / EPUB 走 **KOReader 已打开文档的 DOM 兜底**：`getToc()` 常为 0 条，插件会从正文识别标题重切分并有「纯文本重建」兜底；正文确实无可识别标题时退化为按 256 KB 切分，但每个分片都列入目录；正文过少则删除半成品并提示「另存为 .docx」。
- `.rtf`（v2.1.6 起）改走插件自解析（`rtf.lua`）：KOReader 的 RTF 渲染器无法解析负数 `\u` 转义，会乱码并截断正文；自解析可拿到完整目录与正文，单个坏码点降级为占位符并提示。
- DOM 兜底格式的渲染 HTML 由 KOReader 引擎生成，沙箱无法完整复现，请以设备实测为准；日志里的「DOM HTML 样本」可用于核对。
- `.html`/`.htm`/`.md` 自解析只保留文本与标题层级：图片、复杂表格、CSS 布局不会还原（行内粗体/斜体/链接转纯文本）。
- 非 UTF-8 的 `.md`/`.html` 依赖系统 `iconv` 做 GBK→UTF-8；设备无 `iconv` 时按原始字节处理，可能乱码但不崩溃。

---

## 六、故障排查与更新日志

详细的崩溃修复与版本变更见 **[CHANGELOG.md](CHANGELOG.md)**。常见问题速查（括号内为修复版本）：

| 现象 | 处理 |
| --- | --- |
| 菜单不显示 / 其它插件也消失 | 确认目录名为 `txt2epub.koplugin` 且在 `plugins/`。本插件用标准 `sorting_hint = "tools"`，不会破坏内置菜单。 |
| 空书 / 只有标题没正文（v2.1.3） | 全文无标题 + 末尾无空行的 TXT 曾丢正文，现已完整保留并分片。仍遇到请提供 `.txt2epub.log` 与源文件结构。 |
| 同名不同格式互相覆盖（v2.1.2） | 输出名已带 `_txt`/`_docx`/`_html`/`_md`/`_doc` 标记；旧的无标记 `.epub` 是遗留文件，可删。 |
| TXT 目录不折叠（v2.1.2） | 已保留卷→章→节层级；无此类标题时可在「章节标题正则」补充。 |
| Word 目录「卷」不折叠（v2.1.8） | 卷章同为 Heading1 时按文本语义保守重分级（日志「目录层级精修」）；已正确分级的不受影响，重新转换即可。 |
| 转 docx 后被 Killed（v2.1.7 根治） | 真凶是旧流程 2.8MB 全文 + 7000+ 段落表的瞬时内存尖峰叠加 DOM 高基线堆；现改为流式「解压即解析」，单次分配 2.8MB→32KB。若仍崩，重启 KOReader 后用菜单「选择文件」直接选 docx（避开原生 DOM 渲染），并附日志。 |
| 打开已转换的 .epub 再转，出现两个目录（v2.1.4） | 会先弹确认框，误点选「取消」即可。 |
| GBK 中文无目录/乱码（v2.1.4）、内联 `<span>` HTML 无目录（v2.1.4） | 已内置纯 Lua GBK 解码与短标题行恢复多级目录。 |
| 损坏 .docx 弹整段 Lua 栈（v2.1.5） | 改为简明中文提示，细节写日志。 |
| RTF 目录不全/乱码（v2.1.6） | 改为插件自解析源文件（含负数 `\u`），目录/正文完整；FB2 仍走 DOM（多次解码实体 + 乱码清洗）。 |
| docx 目录不全/只有几章（v2.1.1） | 看日志「Word 标题体检」行：样式 0 会自动从正文恢复标题；仍为 0 则补「章节标题正则」。每个 256 KB 分片都进目录。 |
| 无目录 / 只有 1 条（.doc 等 DOM 格式） | 看日志「正文标题数 / 重切分」；v2.1.0 起即使为 0 也逐条列入目录。 |
| 点转换后崩溃/重启 | v2.1.0 起 CRC-32 换 `bit`/查表，v2.1.1 起超大章流式写盘、样式丢失先恢复标题；仍发生请附两份日志。 |

**排查日志**：优先提供源文件同目录的隐藏文件 `.txt2epub.log`（时间戳、源类型、逐章进度、体检字段、完整错误栈）；`crash.log` / `koreader.log`（KOReader 安装目录）用于区分插件问题与原生固件/内存问题。

---

## 七、更名方案（便于发布）

插件已从「TXT → EPUB」扩展为 **TXT / Word / Markdown / HTML / 阅读器文档 → EPUB**，原名 `txt2epub` 已低估能力。**推荐主方案**：

| 项目 | 现名 | 建议改为 |
| --- | --- | --- |
| 插件目录 / 包名 | `txt2epub.koplugin` | **`doc2epub.koplugin`** |
| GitHub 仓库 | `Gh9518/txt2epub` | `Gh9518/doc2epub`（用 GitHub rename，旧链接自动重定向） |
| 菜单显示名 | `TXT2EPUB` | `Doc2EPUB`（中文界面可写「文档转 EPUB」） |
| `_meta.lua` | `fullname = "TXT2EPUB"` | `fullname = "Doc2EPUB — 文档转 EPUB"` |
| Release / 附件 | `v2.1.8` + `txt2epub.koplugin.zip` | `v3.0.0` + `doc2epub.koplugin.zip` |
| 一句话简介 | 「TXT 排版助手」 | 「把 TXT/Word/Markdown/HTML 等文档转成带多级目录的 EPUB」 |

**备选名**：`any2epub.koplugin`（强调多格式）、`text2epub.koplugin`、`epubforge.koplugin`（品牌感强但不直观）。

**改名需同步的清单**：插件目录名、`_meta.lua` 的 `fullname`、`main.lua` 的 `name` / `menu_items` key、7 个 `G_reader_settings` 键（建议加一次性迁移读取旧键）、README/CHANGELOG/测试说明里的路径与文件名、`.gitignore`、`Awesome KOReader` PR #45 的条目、Release 附件名与安装说明。诊断日志 `.txt2epub.log` 可保留原名，避免用户排查记录断开。

**本轮决策**：按需求保持 `txt2epub.koplugin/` 目录名与现有仓库不变（发布包解压即得到该目录，安装路径零变化），**只提供方案、不强制执行改名**，避免破坏已安装用户、旧链接与已提交的社区收录条目。建议在下一个主版本 v3.0.0 一次性切换，并在 Release 说明里写清「旧目录请删除、设置会自动迁移」。

---

本插件运行于 **[KOReader](https://github.com/koreader/koreader)** 之上。欢迎 Star ⭐ 与 PR；收录建议提交至 [koreader/contrib](https://github.com/koreader/contrib) 或 [Awesome KOReader](https://github.com/jannick-holm/awesome-koreader)。
