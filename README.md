# txt2epub —— KOReader 插件：TXT 一键转 EPUB

在 KOReader 中打开一个 `.txt` 文件，通过「**工具 › TXT2EPUB**」一键把它转换成**同名的 `.epub`**，保存在原文件同一目录。生成的 EPUB 带有可跳转的**多级章节目录**（同时兼容 EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx`），并内置借鉴开源项目的排版精修。

> 借鉴的开源项目与具体代码，见文末「致谢与开源借鉴」。

---

## English Overview

**txt2epub** is a KOReader plugin that converts the currently opened `.txt` into a polished `.epub` with **one tap** (menu **Tools › TXT2EPUB**). The result ships with a real multi-level TOC (both EPUB3 `nav.xhtml` and EPUB2 `toc.ncx`, recognized by KOReader) and typography presets inspired by other open-source KOReader plugins.

### Highlights
- **Multi-level TOC** — auto-detects 卷/部/册/篇 → 章/回 → 节/集/幕 instead of a flat list.
- **Typography presets** (Compact / Standard / Relaxed / Custom) baked into `style.css` at conversion time — no resident hooks, zero runtime memory cost.
- **Streaming, low-memory build** — writes the EPUB chapter-by-chapter and never pre-scans the whole book, so it won't be OOM-killed on memory-tight devices like Kindle.
- **Local font selection** — pick any installed font (name shown in your UI language) or type a name as fallback.
- **Large-chapter splitting** — splits XHTML chapters larger than 256 KB.

### Install
1. Copy `txt2epub.koplugin/` into KOReader's `plugins/` directory (e.g. `koreader/plugins/`, or `Android/data/org.koreader.ko_reader/files/plugins/` on Android).
2. Fully quit and restart KOReader.
3. Open any TXT file → **Tools › TXT2EPUB**.

---

## 一、安装

把整个 `txt2epub.koplugin` 目录复制到 KOReader 的插件目录，再**完全退出并重启** KOReader：

| 设备 | 路径 |
| --- | --- |
| Kindle / Kobo | `koreader/plugins/` |
| Android | `Android/data/org.koreader.ko_reader/files/plugins/` |
| 桌面版 | KOReader 安装目录下的 `plugins/` |

插件目录只需 4 个文件：`_meta.lua`、`main.lua`、`converter.lua`、`README.md`。重启后打开任意 TXT，「工具」菜单下应出现「TXT2EPUB」。

---

## 二、使用

1. 在 KOReader 打开一本 TXT 小说。
2. 点「**工具 › TXT2EPUB › 开始转换**」（非 TXT 会提示先打开 TXT；输出已存在会询问是否覆盖）。
3. 可在「**排版预设…**」里先选「紧凑 / 标准 / 宽松大字」一键套用排版风格。
4. 插件按章节标题自动切分正文，生成带多级目录与排版精修的 EPUB，转换完成后弹「✓ 转换完成：共 N 章」。
5. 用 KOReader 打开生成的 `.epub` 即可通过目录面板跳转。

**转换进度**：先显示「正在识别章节…」做标题预检，再显示「正在写入…+进度条+已写入 N 章」；全程常驻进度框，完成即自动关闭并弹出完成提示。诊断日志写在 TXT 同目录的 `.txt2epub.log`。

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

---

## 六、故障排查与更新日志

详细的崩溃修复与版本变更见 **[CHANGELOG.md](CHANGELOG.md)**。常见问题速查：

- **菜单不显示**（甚至其它插件也消失）：确认目录名为 `txt2epub.koplugin` 且位于 `plugins/`。若所有插件菜单都消失，通常是某插件的 `addToMainMenu` 抛错导致 `MenuSorter` 合并失败——本插件用标准 `sorting_hint = "tools"` 写法，不会触碰内置菜单结构。
- **点转换后崩溃/重启**：多为低内存或 UI 阻塞所致，已通过流式写盘、协程逐章 yield、移除目录遍历等彻底修复（详见 CHANGELOG）。
- **仍异常**：查看 `koreader.log` 中紧邻崩溃前的 `转换失败：` 提示，已含真实 Lua 错误栈。

---

本插件运行于 **[KOReader](https://github.com/koreader/koreader)** 之上。欢迎 Star ⭐ 与 PR；收录建议提交至 [koreader/contrib](https://github.com/koreader/contrib) 或 [Awesome KOReader](https://github.com/jannick-holm/awesome-koreader)。
