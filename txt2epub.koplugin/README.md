# txt2epub —— KOReader 插件：TXT / Word / Markdown / HTML 一键转 EPUB

在 KOReader 中打开一个文档，通过「**工具 › TXT2EPUB**」一键把它转换成一个**带格式标记的 `.epub`**（如 `big_novel_txt.epub` / `big_novel_docx.epub`，保存在原文件同一目录；**v2.1.2 起按源格式加标记，同名不同格式不再互相覆盖**）。插件内部自动选最可靠的方式：`.txt` 走标题/缩进识别；`.docx` 直接解析 OOXML；`.html` / `.htm` / `.md` 由 `markup.lua` 直接解析源文件；`.rtf` 由 `rtf.lua` 直接解析源文件（**v2.1.6 起**，正确解码负数 `\u` 转义，绕开 KOReader DOM 的乱码/截断）；`.doc` / FB2 / EPUB 等由 KOReader 已打开的文档内容兜底。生成的 EPUB 带有可跳转的**多级章节目录**（EPUB3 `nav.xhtml` + EPUB2 `toc.ncx`）与内置排版精修。

> 借鉴的开源项目与具体代码，见文末「致谢与开源借鉴」。命名建议见「七、更名方案」。

---

## English Overview

**txt2epub** is a KOReader plugin that converts a document into a polished `.epub` with **one tap** (menu **Tools › TXT2EPUB**). It picks the most reliable path automatically: `.txt` uses title/indent detection; `.docx` is parsed **directly from OOXML**; `.html`/`.htm`/`.md` are parsed by the plugin's own `markup.lua`; `.rtf` is parsed by the plugin's own `rtf.lua` (**v2.1.6+**, correctly decoding negative `\u` escapes instead of relying on KOReader's DOM); `.doc`/FB2/EPUB fall back to the document KOReader already opened. The result ships with a real multi-level TOC (both EPUB3 `nav.xhtml` and EPUB2 `toc.ncx`) and typography presets inspired by other open-source KOReader plugins.

### Highlights
- **One-tap, many formats** — `.txt`, `.docx`, `.html`, `.htm`, `.md` are parsed by the plugin itself (no dependency on KOReader's parser); other reader-supported formats use KOReader's parsed document as a fallback, with an empty-result guard instead of silently producing an empty book.
- **TOC rebuilt from body (v2.0.1+)** — when KOReader returns **no TOC** for `.doc`/RTF/FB2 (Word heading styles become plain `<p>`), the plugin detects chapter headings in the extracted body and rebuilds a nested TOC + styled `<h1>` headings. **v2.1.0** also handles U+3000 full-width spaces (`第1章　标题`) and Chinese punctuation, and falls back to a plain-text rebuild when the DOM has no block tags at all.
- **Fast, low-memory build (v2.1.0)** — CRC-32 now uses the LuaJIT `bit` library (table-based fallback elsewhere); a 2.8 MB `.docx` converts in ~0.4 s instead of minutes, and ZIP/EPUB buffers are released eagerly.
- **Robust `.docx` TOC (v2.1.1)** — if a `.docx` loses its Word heading styles (`w:pStyle`), the plugin recovers chapter headings from the body text (short lines matching `第X章 / 第X节 …`), so a 2.2 MB book still gets its full multi-level TOC instead of 9 flat slices. Chapters are streamed to disk in ≤256 KB pieces without ever building one giant XHTML string, and **every piece is listed in the TOC**. This fixes both the `Killed` (OOM) crash and the "共 9 章 / no TOC" issue on Kindle; `.txt2epub.log` gains a "Word 标题体检" line to confirm.
- **Multi-level TOC** — auto-detects 卷/部/册/篇 → 章/回 → 节/集/幕 instead of a flat list.
- **Typography presets** (Compact / Standard / Relaxed / Custom) baked into `style.css` at conversion time — no resident hooks, zero runtime memory cost.
- **Local font selection** — pick any installed font (name shown in your UI language) or type a name.
- **Large-chapter splitting** — splits XHTML chapters larger than 256 KB, with the `<p>` wrapper overhead counted so actual output stays strictly under the limit; every split part gets its own TOC entry.
- **Format-tagged output names (v2.1.2)** — same base name in different formats gets a small tag (`_txt` / `_docx` / `_html` / `_md` / `_doc`), so converting `big_novel.txt`, `big_novel.docx`, `big_novel.html`, `big_novel.md` no longer overwrites one `big_novel.epub`.
- **Folded TXT TOC (v2.1.2)** — the 卷/章/节 level detected for TXT headings is preserved in `nav.xhtml` / `toc.ncx` (no longer flattened to one level). Conversion cleanup now does full GC on every completion to avoid OOM after a long run of large files.
- **No-title body integrity (v2.1.3)** — fixed silent data loss: a TXT with no headings and no trailing blank line produced an empty chapter with all body text dropped. A final flush now preserves the text, covered by a Chinese-character-conservation regression test.
- **GBK without iconv (v2.1.4)** — a pure-Lua GB2312 decoder (`gbk.lua`) kicks in when the device has no `iconv`, so GBK text keeps its headings and body instead of becoming an empty/garbled book.
- **Inline-tag HTML headings (v2.1.4)** — HTML whose headings live only inside `<span>` (no `<hN>`) now recovers a multi-level TOC from short chapter-like lines.
- **Long single-line TXT (v2.1.4)** — indent mode splits an over-long heading-free line into byte-sized parts, each listed in the TOC, instead of one giant empty TOC entry.
- **EPUB re-convert guard (v2.1.4)** — converting an already-converted `.epub` asks for confirmation first, avoiding a nested duplicate TOC on a mis-tap.
- **Stable raw-DEFLATE (v2.1.6)** — compressed `.docx` is inflated by an optimized, bounded pure-Lua decoder with hard output/iteration guards. v2.1.5 briefly used libz via ffi for speed, but on real Kindle devices KOReader's own zlib declarations collided with the plugin's cdef (32-bit ABI), causing `ffi.load: z → Killed` OOM; v2.1.6 removed that path and returned to the device-proven pure-Lua decoder, so a corrupt/odd stream now yields a friendly error instead of crashing the reader.
- **Direct RTF parsing (v2.1.6)** — `.rtf` is now parsed from the source file by `rtf.lua` (negative `\u` escapes, `\par`, `\b` headings) instead of KOReader's DOM, which garbled and truncated chapters containing negative `\u` codes; full TOC and body are preserved.
- **Smaller footprint (v2.1.5)** — the GB2312 table is base64-encoded and lazily decoded, shrinking `gbk.lua` from 62 KB to 27 KB and the plugin package accordingly.
- **Cleaner TOC titles (v2.1.5)** — punctuation between a chapter marker and its title (`第1章：开端`, `第六卷 - 狂暴`) becomes a single space; brackets and full-width spaces are preserved.

### Install
1. Unzip the release archive — it contains a single top-level folder `txt2epub.koplugin/`.
2. Copy that whole folder into KOReader's `plugins/` directory (e.g. `koreader/plugins/`, or `Android/data/org.koreader.ko_reader/files/plugins/` on Android).
3. Fully quit and restart KOReader.
4. Open any supported document → **Tools › TXT2EPUB › 开始转换**.

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
| `.docx` | 插件自解析 OOXML | Word 标题样式（Heading1/2/3… 与 Title）；**v2.1.1：样式为 0 时自动从正文文本恢复章节标题** |
| `.md` / `.markdown` | 插件自解析 `markup.lua` | `#` ~ `######`、Setext 标题 |
| `.html` / `.htm` | 插件自解析 `markup.lua` | `<title>` 作书名、`<h1>`~`<h6>` 作多级标题 |
| `.rtf` | 插件自解析 `rtf.lua`（v2.1.6 起，不经 KOReader DOM） | `\b` 粗体段 + 章节规则；正确解码负数 `\u` 转义，目录/正文完整 |
| `.doc` / FB2 / EPUB | KOReader 已打开文档的 DOM 兜底 | 优先用 `getToc()`；为 0 时从正文识别标题重切分 |

**转换进度**：先显示「正在识别章节…」，再显示「正在写入… + 进度条 + 已写入 N 章」；全程常驻进度框，完成即自动关闭。诊断日志写在**源文件同目录**的隐藏文件 `.txt2epub.log`（需在文件管理器开启「显示隐藏文件」；每次转换追加写入，超 512 KB 自动清空重建）。日志含「TOC 条目 / 正文标题数 / 重切分方式 / DOM HTML 样本（前 160 字节）」，便于定位真机差异。

### 设置（可选）
- **排版预设**：紧凑 / 标准 / 宽松大字 / 自定义；「自定义参数…」逐项微调行高·段距·首行缩进·字号缩放·字距·两端对齐；「正文字体…」从本机字体列表预览选择（中文字体显示中文名+样式，英文显示英文名）。
- **章节标题正则**：可填一条 Lua 模式覆盖默认识别规则，附「示例」按钮；「恢复默认正则」复位。
- 默认支持的标题写法：`第一章` / `第1章` / `第一回` / `卷一 少年游` / `楔子` / `番外` / `后记` / `序章` / `Chapter 1` 等；**v2.1.0 起兼容全角空格与中文全角标点**（`第1章　标题`、`第1章：标题`、`第1章（上）`）。
- **无标题时按空格缩进识别层级**：若文档无显式章节标题，可弹窗选择「按缩进切分」「整本作一章」或「取消」。

---

## 三、功能特性

- **多级目录**：卷/部/册/篇 → 章/回 → 节/集/幕 三级嵌套，生成真正的 EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx`。
- **排版预设**：紧凑（行距130%）/ 标准（默认，行距155%＋段距0.3em＋首行缩进2字）/ 宽松大字（行距185%＋字号115%）/ 自定义，转换时烘焙进 `style.css`，不装常驻钩子。
- **本地字体**：列出本机全部已安装字体，菜单按界面语言显示中文名/英文名及样式（粗体·斜体）。
- **Word 文档**：`.docx` 由纯 Lua 直接解析 OOXML，STORED 与 DEFLATE 均支持，不依赖设备 zlib；标题样式 → 多级目录 + 完整正文。**v2.1.1 起**：若设备上的 `.docx` 丢失了 Word 标题样式（例如经 KOReader/WPS 打开另存后），插件会从正文短段落自动恢复「第X章 / 第X节」等章节标题，仍生成完整多级目录，不再退化成几个硬切片；超大章节按 ≤256 KB 分片流式写出、全部分片进目录，避免低内存设备 OOM。旧版 `.doc` 走 DOM 兜底，即使 `getToc()` 返回 0 条也会从正文识别标题重切分。
- **Markdown / HTML**：`.md` / `.html` / `.htm` 由插件直接读磁盘解析，不依赖 KOReader 是否支持该格式；支持 ATX/Setext 标题、`<h1>`~`<h6>`、代码块、列表、引用、行内标记与 XML 实体，UTF-8 与 GBK 编码均可。
- **超大章节切分**：单章 XHTML 超过 256 KB 自动切分；**v2.1.2 起按「段落实际输出字节（含 `<p>` 包装开销）」估算**，单章严格 <256 KB（旧版按原始文本字节切，曾被包装撑到 273 KB）。TXT / DOCX / Markdown / HTML / DOM 兜底各格式均已用超长章样本验证；**每个分片都有目录条目**，不会再出现「整本书只有 1 条目录」。
- **输出文件名（v2.1.2）**：按源格式加小标记，例如 `big_novel.txt → big_novel_txt.epub`、`big_novel.docx → big_novel_docx.epub`、`big_novel.html → big_novel_html.epub`、`big_novel.md → big_novel_md.epub`。同名不同格式各自独立，不再互相覆盖（覆盖还会产生半成品 EPUB，触发 `CRE zip corrupted` 警告）。已带标记的文件名不会重复追加。
- **TXT 目录折叠（v2.1.2）**：修复 TXT 标题模式把卷/章/节层级压平成 0 级的问题，多级目录在 `nav.xhtml` / `toc.ncx` 中正确嵌套折叠。
- **无标题正文完整性（v2.1.3）**：修复 TXT 全文无标题、末尾无空行时正文被静默丢弃（只产出空章）的缺陷；循环结束补收尾 flush，正文按 256 KB 分片完整保留，并有「中文字符守恒」回归测试兜底。
- **低内存**：CRC-32 走 LuaJIT `bit`（其余环境查表回退），ZIP 写完即释放，逐段消费段落序列；Kindle 等低内存设备上不再因分钟级纯 Lua 运算被系统 `Killed`。
- **墨水屏友好**：`word-break`、`orphans/widows: 2`、`page-break-after: avoid` 等。
- **稳健识别（借鉴 moon）**：中文数字校验 + 特例标题 + 误判过滤 + 段落回流合并。
- **纯 Lua 实现**：内置最小 ZIP 写入器（Store 方式，符合 EPUB 规范），不依赖任何第三方库；流式按行读写，内存有界。

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
- 缩进模式把每行非空行都当作目录条目，最适合「目录/大纲式」TXT；混有大段散文时建议用显式章节标题或自定义正则。
- `.doc` / FB2 / EPUB 走 **KOReader 已打开文档的 DOM 兜底**：`getToc()` 常为 0 条，插件会从正文识别「第一卷 / 第X章 / 第X节」重切分（v2.1.0 已兼容全角空格与中文标点），并有第二层「纯文本重建」兜底；若正文里确实没有任何可识别标题，则退化为按 256 KB 切分，但**每个分片都会列入目录**，仍可逐段跳转。若提取到的正文过少，插件会删除半成品并提示「另存为 .docx」。
- `.rtf`（**v2.1.6 起**）改走**插件自解析源文件**（`rtf.lua`），不再依赖 DOM：KOReader 的 RTF 渲染器无法解析负数 `\u` 转义（如「第二章 远行」），会乱码并截断正文；自解析可拿到完整目录与正文，单个坏码点降级为占位符（提示「已跳过 N 处无法识别的字符」）。
- DOM 兜底格式的**渲染 HTML 由 KOReader 引擎生成**，沙箱内用贴近真机的 mock 验证适配层与重切分逻辑，无法完整复现引擎输出，请以设备实测为准。日志里的「DOM HTML 样本」可用于核对实际结构。
- `.html`/`.htm`/`.md` 由插件自解析，但只保留文本与标题层级：图片、复杂表格、CSS 布局不会还原（行内粗体/斜体/链接会转成纯文本）。
- 非 UTF-8 的 `.md`/`.html` 依赖系统 `iconv` 做 GBK→UTF-8 解码；设备无 `iconv` 时按原始字节处理，可能乱码但不崩溃。

---

## 六、故障排查与更新日志

详细的崩溃修复与版本变更见 **[CHANGELOG.md](CHANGELOG.md)**。常见问题速查：

- **菜单不显示**（甚至其它插件也消失）：确认目录名为 `txt2epub.koplugin` 且位于 `plugins/`。若所有插件菜单都消失，通常是某插件的 `addToMainMenu` 抛错导致 `MenuSorter` 合并失败——本插件用标准 `sorting_hint = "tools"` 写法，不会触碰内置菜单结构。
- **转换后是空书 / 只有标题没有正文（v2.1.3 已修复）**：旧版对「全文无标题 + 末尾无空行」的 TXT（例如整本一行的纯正文）会丢掉全部正文，只生成 1 个空章。v2.1.3 起正文完整保留并自动分片。若仍遇到空书，请提供 `.txt2epub.log` 与源文件结构（行数 / 是否含标题）。
- **不同格式同名文件互相覆盖 / 提示已有同名 EPUB（v2.1.2 已解决）**：输出名现在带格式标记（`_txt`/`_docx`/`_html`/`_md`/`_doc`），如 `big_novel_txt.epub` 与 `big_novel_docx.epub` 并存。若仍看到旧的无标记 `big_novel.epub`，那是 v2.1.1 及更早版本生成的遗留文件，可删除。
- **TXT 目录不折叠 / 全平铺（v2.1.2 已修复）**：旧版 TXT 标题模式把卷/章/节层级压成 0 级，目录一长串不折叠。v2.1.2 保留已识别的层级，目录按卷→章→节嵌套；若你的 TXT 没有「第一卷/第X章/第X节」这类标题，可在「章节标题正则」补充后再转换。
- **连续转换多个大文件后崩溃 / 被 Killed**：v2.1.2 在每次转换收尾都做双重内存回收并断开协程/解码缓存引用，避免多次转换累积；真机若仍 OOM，主因多为 KOReader 打开 docx 的原生 DOM 渲染占用（日志中每次 opening 数秒）。**v2.1.4 起**转换前还会主动全量回收并把堆占用写入 `.txt2epub.log`。**v2.1.6 关键修复**：v2.1.5 曾为加速压缩版 docx 而引入 ffi/libz 快路径，但真机 `crash.log` 显示 `ffi.load: z` 后立即 `Killed`——KOReader 自身已声明 zlib 符号，与插件 cdef 在 32 位 ABI 下冲突导致无限内存增长。v2.1.6 **移除 FFI 快路径**，回归经真机验证的纯 Lua 解压并加输出/迭代熔断（坏流只报友好错误，绝不 OOM）。若仍崩溃，多为 KOReader 打开 docx 的原生 DOM 占用：建议重启 KOReader 后用菜单「选择文件」直接选 docx（不先打开文档，避开 DOM 渲染），并提供 `.txt2epub.log` + `crash.log`。
- **打开已转换的 .epub 再点转换，正文出现两个目录（v2.1.4 已处理）**：`.epub` 本身多为转换产物，重复转换会把原书名页/目录当正文再包一层。v2.1.4 起会对 `.epub` 先弹确认提示，误点选「取消」即可；确需重新打包再点「继续转换」。
- **GBK 中文文本转换无目录 / 内容乱码（v2.1.4 已修复）**：设备无 `iconv` 时旧版会丢目录与正文。v2.1.4 内置纯 Lua GB2312 解码兜底，无需 `iconv` 即可正确识别中文标题与正文。
- **标题只写在 `<span>` 里的 HTML 无目录（v2.1.4 已修复）**：这类无 `<hN>` 的内联标签 HTML 现在会从短标题行恢复多级目录。
- **损坏的 .docx 提示看不懂（v2.1.5 已改进）**：文件损坏或图片错误时不再弹出整段 Lua 栈轨迹，而是显示简明中文提示（如「此文件不是有效的 .docx，无法转换，请重新导出/另存后再试」）；详细技术信息仍记录在 `.txt2epub.log`。
- **RTF 目录不全、正文有乱码（v2.1.6 已解决）**：旧版走 KOReader DOM，其 RTF 渲染器无法解析负数 `\u` 转义（「第二章 远行」等），会在此乱码并截断，只返回部分正文——插件无法补回 DOM 未返回的内容。v2.1.6 起 `.rtf` 改由插件直接解析源文件（`rtf.lua`），正确解码 `\u`（含负数）、`\par`、`\b` 标题，完整目录与正文均能保留，个别坏码点降级为占位符并提示「已跳过 N 处无法识别的字符」。FB2 仍走 DOM 兜底（多次解码实体 + 乱码清洗）。
- **`.docx` 目录不全 / 只有几章（v2.1.1 重点修复）**：看 `.txt2epub.log` 新增的「**Word 标题体检**」行。若「样式标题 0、兜底重切 是」，说明设备上的 `.docx` 丢了 Word 标题样式，插件已自动从正文文本恢复章节标题（`第X章 / 第X节` 等短段落），目录应完整；若「文本候选标题」仍为 0，说明正文写法不在默认识别范围内，可在「设置章节标题正则」补充 Lua 模式。v2.1.1 起每个 256 KB 分片都会列入目录，即使完全无标题也不会只剩 1 条。
- **无目录 / 只有 1 条目录（`.doc` 等 DOM 格式）**：查看 `.txt2epub.log` 的「正文标题数 / 重切分」。若为 0，说明正文没有可识别标题或 HTML 结构与预期不同，可补充「章节标题正则」；v2.1.0 起即使为 0 也会把分片逐条列入目录。
- **点转换后崩溃/重启**：低内存或 UI 阻塞所致。v2.1.0 已把 CRC-32 从逐位纯 Lua 换成 `bit` 库/查表实现（大文档从分钟级降到秒级），并提前释放 ZIP 原始缓冲；**v2.1.1 更进一步**：超大章节按段流式写盘、不再拼整章大字符串，且 Word 样式丢失时先恢复标题以免生成 2.2 MB 巨型单章，消除大 `.docx` 的 OOM `Killed`。若仍发生，请提供 `.txt2epub.log` 与 `crash.log`。
- **排查日志**：优先发**源文件同目录的隐藏文件 `.txt2epub.log`**（含时间戳、源类型、逐章进度、体检字段、完整 Lua 错误栈）；`crash.log` / `koreader.log`（KOReader 安装目录下）用于区分插件问题与原生固件/内存问题。

---

## 七、更名方案（便于发布）

插件已从「TXT → EPUB」扩展为 **TXT / Word / Markdown / HTML / 阅读器文档 → EPUB**，原名 `txt2epub` 已明显低估能力，不利于社区检索与收录。**推荐主方案**：

| 项目 | 现名 | 建议改为 |
| --- | --- | --- |
| 插件目录 / 包名 | `txt2epub.koplugin` | **`doc2epub.koplugin`** |
| GitHub 仓库 | `Gh9518/txt2epub` | `Gh9518/doc2epub`（用 GitHub rename，旧链接自动重定向） |
| 菜单显示名 | `TXT2EPUB` | `Doc2EPUB`（中文界面可写「文档转 EPUB」） |
| `_meta.lua` | `fullname = "TXT2EPUB"` | `fullname = "Doc2EPUB — 文档转 EPUB"` |
| Release / 附件 | `v2.1.1` + `txt2epub.koplugin.zip` | `v3.0.0` + `doc2epub.koplugin.zip` |
| 一句话简介 | 「TXT 排版助手」 | 「把 TXT/Word/Markdown/HTML 等文档转成带多级目录的 EPUB」 |

**备选名**：`any2epub.koplugin`（强调多格式）、`text2epub.koplugin`（比 txt 宽但仍偏文本）、`epubforge.koplugin`（品牌感强、可注册性好，但不直观）。

**改名需同步的清单**：插件目录名、`_meta.lua` 的 `fullname`、`main.lua` 的 `name` / `menu_items` key、7 个 `G_reader_settings` 键（`txt2epub_pattern` / `_indent` / `_indent_step` / `_style` / `_custom_style` / `_font`，建议加一次性迁移读取旧键）、README/CHANGELOG/测试说明里的路径与文件名、`.gitignore`、`Awesome KOReader` PR #45 的条目、Release 附件名与安装说明。诊断日志 `.txt2epub.log` 可保留原名，避免用户已积累的排查记录断开。

**本轮决策**：按需求保持 `txt2epub.koplugin/` 目录名与现有仓库不变（发布包解压即得到该目录，安装路径零变化），**只提供方案、不强制执行改名**，避免破坏已安装用户、旧下载链接与已提交的社区收录条目。建议在下一个主版本 v3.0.0 一次性切换，并在 Release 说明里写清「旧目录请删除、设置会自动迁移」。

---

本插件运行于 **[KOReader](https://github.com/koreader/koreader)** 之上。欢迎 Star ⭐ 与 PR；收录建议提交至 [koreader/contrib](https://github.com/koreader/contrib) 或 [Awesome KOReader](https://github.com/jannick-holm/awesome-koreader)。
