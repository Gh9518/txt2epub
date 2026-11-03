# txt2epub —— KOReader 插件：TXT2EPUB（TXT 转 EPUB）

在 KOReader 中打开一个 `.txt` 文件后，通过菜单「**工具 › TXT2EPUB**」一键把当前 TXT 转换为**同名 `.epub`**，并保存在原文件同一目录。生成的 EPUB 带有可跳转的**多级章节目录**（同时兼容 EPUB3 `nav.xhtml` 与 EPUB2 `toc.ncx`，KOReader 的目录面板均可识别），并内置借鉴开源项目的排版精修。

> 本项目在转换层取长补短地借鉴了两个开源 KOReader 插件：
> - **[doudou-xsz/txtstyle.koplugin](https://github.com/doudou-xsz/txtstyle.koplugin)**：把"行高 / 段距 / 首行缩进 / 字距 / 两端对齐"等排版参数做成可一键套用的"快速风格"预设。本插件把这套参数模型在**转换时**一次性烘焙进 EPUB 的 `style.css`（而非安装常驻阅读钩子）。
> - **toc_extractor（开源 TXT 目录抽取）**：多级目录识别思路。本插件据此在转换时为"卷 / 章 / 节"自动分级，生成真正的多级嵌套目录。
> - 此前已落地的 [AnkioTomas/moon](https://github.com/AnkioTomas/moon) 稳健章节识别与段落回流合并，本版继续保留。

> **运行平台与生态**：[koreader/koreader](https://github.com/koreader/koreader)（开源阅读器本体）、[koreader/contrib](https://github.com/koreader/contrib)（官方社区插件集合）、[Awesome KOReader](https://github.com/ruiribeiro04/awesome-koreader)（社区插件与工具清单）。欢迎提交 Issue / PR 一起完善。

---

## English Overview

**txt2epub** is a KOReader plugin that converts the currently opened `.txt` file into a polished `.epub` with **one tap** (menu **Tools › TXT2EPUB**). The generated EPUB ships with a real multi-level table of contents (both EPUB3 `nav.xhtml` and EPUB2 `toc.ncx`, recognized by KOReader's TOC panel) and typography presets inspired by other open-source KOReader plugins.

### Why

- **Multi-level TOC** — auto-detects 卷/部/册/篇 → 章/回 → 节/集/幕 hierarchies instead of a flat list.
- **Typographic presets** (Compact / Standard / Relaxed / Custom) baked into the EPUB's `style.css` at conversion time — no resident runtime hooks, so zero ongoing memory cost inside KOReader.
- **Streaming, low-memory build** — writes the EPUB chapter-by-chapter and never pre-scans the whole book, so it won't be OOM-killed on memory-tight devices like Kindle.
- **Local font selection** — pick any font installed on the device, or type a name as a fallback.
- **Large-chapter splitting** — splits XHTML chapters larger than 256 KB.

### Install

1. Copy the `txt2epub.koplugin` folder into KOReader's `plugins/` directory (e.g. `koreader/plugins/` on Kindle/Kobo, `Android/data/org.koreader.ko_reader/files/plugins/` on Android).
2. Fully quit and restart KOReader.
3. Open any TXT file → **Tools › TXT2EPUB**.

### References & Thanks

This plugin stands on the shoulders of the KOReader open-source community:

- [koreader/koreader](https://github.com/koreader/koreader) — the open-source e-reader platform this plugin runs on.
- [koreader/contrib](https://github.com/koreader/contrib) — the official collection of community plugins.
- [Awesome KOReader](https://github.com/ruiribeiro04/awesome-koreader) — a curated community list of plugins & tools.
- [doudou-xsz/txtstyle.koplugin](https://github.com/doudou-xsz/txtstyle.koplugin) — typography "quick styles" model (line-height, paragraph spacing, first-line indent, letter-spacing, justification).
- [AnkioTomas/moon](https://github.com/AnkioTomas/moon) — robust chapter detection & paragraph reflow.
- *toc_extractor* — multi-level TOC extraction ideas.

Feedback and pull requests are welcome!

---

## 一、安装

1. 把整个 `txt2epub.koplugin` 目录复制到 KOReader 的插件目录：

   | 设备 | 路径 |
   | --- | --- |
   | Kindle / Kobo（内部存储） | `koreader/plugins/` |
   | Android | `Android/data/org.koreader.ko_reader/files/plugins/`（或 KOReader 设置里「存储」指向的目录下的 `plugins/`） |
   | 桌面版（Linux/macOS/Windows） | KOReader 安装目录下的 `plugins/` |

   复制后目录结构应为（运行插件只需前 4 个文件）：

   ```
   koreader/plugins/txt2epub.koplugin/
   ├── _meta.lua          # 插件元数据（fullname / description）
   ├── main.lua           # 插件入口与菜单注册
   ├── converter.lua      # 纯 Lua 核心：编码检测 / 章节切分 / EPUB 生成
   ├── README.md
   └── test/              # 以下为开发/测试用，可省略
       ├── test_convert.lua
       ├── test_menu.lua
       └── fixtures/      # KOReader 菜单源码（仅测试依赖）
   ```

2. 完全退出并重新启动 KOReader（插件在主程序启动时加载）。
3. 打开任意 TXT 文件，「工具」菜单下应出现「TXT2EPUB」。

> 说明：KOReader 在启动时扫描 `plugins/` 下所有 `*.koplugin` 目录并加载其中的 `_meta.lua` 与 `main.lua`。无需额外编译或依赖第三方 C 扩展。

---

## 二、使用步骤

1. 在 KOReader 中打开一本 TXT 小说。
2. 点击菜单「**工具 › TXT2EPUB › 开始转换**」。
   - 若当前不是 TXT 文件，会提示「请先打开 TXT 文件」。
   - 若输出文件已存在，会询问是否**覆盖**。
   - 转换前可先在「**排版预设…**」里选择「紧凑 / 标准 / 宽松大字」一键套用排版风格（借鉴 txtstyle.koplugin 的快速风格）。
3. 插件会按章节标题自动切分正文，生成带多级目录、排版精修的 EPUB。
4. **转换过程常驻进度提示（分阶段）**：先显示「正在识别章节…」做标题预检，再显示「正在写入…」+ `[=====-----]` ASCII 进度条 + 「已写入 N 章」实时计数（**不再预扫描总章数**，随写随报，避免大书在低内存设备上多读一遍被 OOM）。该提示**不会因误触或超时自动消失**，屏幕持续刷新，因此不会再出现"卡住 / 假死"的观感；转换**全部完成后自动关闭**，并弹出「✓ 转换完成：共 N 章」的提示（停留 5 秒），给出章节数量与输出路径。
5. 用 KOReader 打开生成的 `.epub` 即可通过目录面板跳转章节。

### 转换进度提示

- **分阶段反馈**（参考「月读」moon 排版优化）：预检标题时显示「**正在识别章节…**」，流式构建时显示「**正在写入…**」，让用户始终知道当前在干什么。
- **实时进度条 + 已写入章节数**：为避免大书在阅读器已打开时多读一遍被 OOM 强杀，**不再预扫描总章数**，改为构建时随写随报「已写入 N 章」；每 10 章刷新一次进度框（大书不会每章一闪）。
- **消除"假死"**：进度框为常驻 `InfoMessage`（`dismissable=false`、`timeout=nil`），转换期间屏幕始终有内容更新；底层仍是协程逐章 `yield`，主线程不被阻塞。
- **完成提示**：协程结束即关闭进度框并弹出「✓ 转换完成：共 N 章」（停留 5 秒，避免墨水屏上一闪而过）；若抛错则关闭进度框并弹出「转换失败：…」。

### 日志文件自动维护

转换诊断日志写在 **TXT 同目录的 `.txt2epub.log`**（崩溃时可凭此定位卡点）。为避免长期占用设备存储，采用**大小上限清理**：日志超过 **512 KB** 时，下次转换开始即清空重建。

> 注：旧版曾另有「每 3 次运行扫描同目录、删除 3 天前旧日志」的周期清理，用 `lfs.dir` 遍历整个书籍目录；在 Kindle 的慢速大目录（数百上千本书）上会卡住数秒到数十秒，表现为「点开始转换后卡在扫描目录」。现已**彻底移除目录遍历**，仅保留 O(1) 大小的单文件检查，绝不扫描目录、绝不因此卡顿。

### 排版优化（借鉴 moon.koplugin / txtstyle.koplugin / toc_extractor）

本插件在核心转换层取长补短地吸收了多个开源项目的优点：

- **稳健的章节标题识别**（来自 moon.koplugin）：中文数字校验（含 `零〇一二…十百千万两`）、英文 `Chapter/Section/Page` 序号、特例标题（序章/序言/前言/楔子/引子/尾声/后记/番外/终章/附录等）；并过滤"第一部门/部队"这类正文误判为"部"章节、以及"第二回的内容"这类正文行误判为标题。
- **段落回流合并**（来自 moon.koplugin）：把被软换行拆散的物理行，按"句末标点 / 空行 / 列表项 / 对话句首"重新聚合为逻辑段落，避免"一行一段"导致首行缩进与两端对齐失效。
- **排版风格预设**（来自 [txtstyle.koplugin](https://github.com/doudou-xsz/txtstyle.koplugin) 的"快速风格"）：把行高、段距、首行缩进、字号缩放、字距、两端对齐等参数做成可一键套用的三套预设，在**转换时**一次性烘焙进 EPUB 的 `style.css`：
  - **紧凑 Compact**：行距 130%、无段距、无首行缩进——同屏容纳更多文字。
  - **标准 Standard**（默认）：行距 155%、段距 0.3em、首行缩进 2 字宽——中文小说阅读舒适基准。
  - **宽松大字 Relaxed**：行距 185%、段距 0.6em、首行缩进 2 字宽、字号 115%——护眼大字版。
  - **自定义 Custom**：在「排版预设 › 自定义参数…」里逐项微调行高 / 段距 / 首行缩进 / 字号缩放 / 字距 / 两端对齐，每个参数用**预设选项列表**点选（而非虚拟键盘逐字输入，规避墨水屏输入与部分输入法插件的崩溃），**即时保存**。选中它后即成为默认排版——因为所选预设会持久化，所以"每次转换若不修改就默认用这个模式"。自定义参数也可一键恢复为标准值。
  - **正文字体预览选择**：「排版预设 › 正文字体…」会列出 **KOReader 本机已安装的全部字体**（通过 `require("fontlist"):getFontList()` 读取字体文件路径，再经 `fontinfo` 取家族名），点击即可套用；列表底部附「手动输入字体名…」作为兜底（旧版 KOReader 取不到字体列表时回退此入口）。
  - **内存说明**：txtstyle 原版是把 CSS 通过 `ApplyStyleSheet` **常驻钩子**实时注入阅读器，会持续占用运行时内存/CPU；本插件改为在转换时把排版烘焙进静态 `style.css`，转换代码仅在触发转换时加载，**不安装任何常驻钩子，因此对 KOReader 的常驻内存为零增量**。
- **多级目录**（来自 toc_extractor 的多级目录思路）：自动识别"卷 / 部 / 册 / 篇 → 章 / 回 → 节 / 集 / 幕"三级层级，在 `nav.xhtml` / `toc.ncx` 中生成真正的嵌套目录（而非平铺一长串），卷为顶层、章/回为一级、节/集/幕为二级。
- **超大章节切分**：单章 XHTML 超过 **256 KB** 时自动切分为多个文件（仅首分片入目录，续篇进正文流），避免单文件过大导致阅读器渲染卡顿/崩溃。
- **墨水屏友好排版**：`style.css` 增加 `word-break: break-word`、`orphans/widows: 2`、章节标题 `page-break-after: avoid` 等，提升中文电子书阅读体验。

### 支持的章节标题写法（默认规则）

- 中文：`第一章` / `第1章` / `第001章` / `第十二章` / `第一回` / `卷一 少年游` / `楔子` / `番外` / `后记` / `序章` / `引子` / `序言` / `前言` / `尾声` / `正文` / `附录` 等
- 英文：`Chapter 1` / `Chapter One`
- 自定义：见下方「设置」。

### 设置（可选）

「**工具 › TXT2EPUB › 排版预设…**」可一键套用「紧凑 / 标准 / 宽松大字 / 自定义」排版风格；「自定义参数…」逐项微调排版；「正文字体…」从本机字体列表中预览选择；「**设置章节标题正则…**」可填写一条 **Lua 模式**（pattern）覆盖默认识别规则，对话框内附「示例」按钮给出常用正则（如 `^%s*第[%d一-〇]+章`、英文 `^[Cc]hapter%s+%d+`、序号标题 `^【%d+】` 等）；「**恢复默认正则**」恢复内置规则；「**设置首行缩进…**」可改 CSS 首行缩进（默认 `2em`）；「**设置缩进步长（空格数）…**」用于缩进模式（见下），默认 `4`，即每行多 4 个空格降一个子层级。设置通过 KOReader 全局配置持久化。

### 无章节标题时：用空格缩进识别目录层级

若文件中**检测不到任何章节标题**（如没有"第一章"字样，而是用空格缩进表达目录层级），插件会弹窗提示可用「**空格缩进**」识别层级，并提供三个选择：

- **按缩进切分**（推荐）：把每行按前导空格数识别为目录层级——`0` 空格为顶层（第 1 级），`步长` 个空格为子层级（第 2 级），`2×步长` 个空格再下一层，依此类推。例如：

  ```
  第3章 剑客
      3.1 初入江湖        ← 比上层多 4 空格，是其子项
          3.1.1 少年离家  ← 再多 4 空格，是 3.1 的子项
      3.2 学艺
  第4章 风波
  ```

  转换后 EPUB 目录（nav.xhtml / toc.ncx）会呈现**真正的多级嵌套**，每个条目独立成页，且子层级标题字号略小以体现层级。

- **整本作一章**：整本 TXT 作为单个章节生成 EPUB（原回退逻辑，适合纯散文无目录结构的文本）。
- **取消**：放弃本次转换。

> 缩进步长可在「设置缩进步长（空格数）…」中自定义（如设为 `2` 表示每 2 个空格一级）。tab 字符按一个步长计。该模式把**每一行非空行**当作一个目录条目，因此最适合"目录/大纲式"的 TXT；若文件中混有大段散文正文，建议优先使用显式章节标题（或自定义正则）。

---

## 三、插件结构

| 文件 | 作用 |
| --- | --- |
| `_meta.lua` | 插件元数据（`fullname` / `description`；`name` 由插件目录名 `txt2epub` 决定，无需在此声明） |
| `main.lua` | 插件入口：注册菜单、文件校验、覆盖/回退确认、进度与完成提示、设置 |
| `converter.lua` | 核心模块（纯 Lua，无 UI 依赖）：编码检测、章节切分、EPUB 各文件生成、**纯 Lua ZIP 写入** |
| `test/test_convert.lua` | 测试用例（纯函数，可直接用 Lua 运行） |

`converter.lua` 不依赖 KOReader 运行环境，因此可被测试脚本直接 `require`，无需启动阅读器。

---

## 四、EPUB 内部结构

```
<书名>.epub
├── mimetype                  # 内容固定为 application/epub+zip，且为 ZIP 第一个条目、不压缩（Stored）
├── META-INF/
│   └── container.xml         # 指向 OEBPS/content.opf
└── OEBPS/
    ├── content.opf          # 元数据 / manifest / spine（EPUB3，同时引用 ncx）
    ├── nav.xhtml            # EPUB3 目录（epub:type="toc"）
    ├── toc.ncx              # EPUB2 兼容目录（KOReader 旧版读取）
    ├── style.css            # 排版预设驱动（行高/段距/首行缩进/字距/两端对齐等），墨水屏友好
    └── chapter_0001.xhtml … # 每章一个 XHTML，正文按空行分段包进 <p>
```

每个 XHTML 与 XML 均使用标准命名空间；中文标题与正文中的 `& < > " '` 已正确 HTML/XML 转义。

---

## 五、各设备上的打包限制与替代方案

### 纯 Lua ZIP 实现说明

本插件**不依赖任何第三方库或系统命令**，`converter.lua` 内置了一个最小可用的 ZIP 写入器（见 `ZipWriter`）：

- 采用 **Store（不压缩，method = 0）** 方式写出每个条目；
- 强制 `mimetype` 作为**第一个条目**且 `general purpose bit flag = 0`（EPUB 规范要求）；
- 自实现 CRC-32（多项式 `0xEDB88320`）与 ZIP 本地文件头 / 中央目录 / 结束记录，仅用 Lua 算术运算，**完全可运行**。

Store 方式生成的 EPUB 体积比 Deflate 略大，但**完全符合 EPUB 规范且兼容性最好**。如果希望更小体积，可在 `converter.lua` 的 `ZipWriter` 中改用 Deflate——但 KOReader 运行环境没有内置 zlib 流接口，需引入 Lua 的 Deflate 实现（如 `lua-deflatelua`，纯 Lua），这属于额外依赖，因此默认未启用。

### 各设备上的注意点

- **Kindle / Kobo（基于 Linux 的固件）**：ZIP/解压由 KOReader 内部处理，Store 方式生成的 EPUB 可正常打开。Kindle 原生阅读器不支持 EPUB，但 KOReader 自身完全支持。
- **Android / 桌面版**：无特殊限制，生成的 EPUB 也可被其它阅读器（如 Apple Books、Calibre）打开。
- **极老旧设备 / 内存极小**：超大 TXT（10MB+）采用**流式按行读取与逐章写出**，不会一次性把整本书拼进内存；但 EPUB 文件本身仍会占用与原书相当的存储空间，请确保设备有足够剩余空间。
- **系统 `zip` 命令兜底**：若未来需要改用系统 `zip` 命令（例如为了 Deflate 压缩），可在 `main.lua` 的 `_do_convert` 中把 `Converter.build_epub` 替换为调用 `os.execute('zip -X0 … mimetype && zip -r … OEBPS META-INF')`；本插件当前默认使用内置纯 Lua 方案，无需该命令。

---

## 六、EPUB 校验步骤

标准 EPUB 校验工具（如 [EPUBCheck](https://github.com/w3c/epubcheck)）可检查生成的文件。手工快速校验：

1. **ZIP 结构**：`unzip -l book.epub` 应看到 `mimetype` 为**第一个条目**；`unzip -v book.epub` 中 `mimetype` 的压缩方式应为 `Stored`。
2. **解压检查**：`unzip book.epub -d out/` 后确认 `META-INF/container.xml` 指向 `OEBPS/content.opf`，且 `content.opf` 的 `manifest`、`spine` 中的 `href` 均存在。
3. **结构与命名空间**：`nav.xhtml` 含 `<nav epub:type="toc">`；`content.opf` 的 `package` 声明 `version="3.0"`，并包含 `dc:identifier` / `dc:title` / `dc:language` 与 `dcterms:modified`。
4. **目录跳转**：用 KOReader 打开后，调出目录面板，应能逐项跳转。

> 本仓库的 `test/test_convert.lua` 已对「mimetype 首个且 Stored」「章节切分」「GBK 解码」「无标题回退」等做了断言，可用 `lua5.3 test/test_convert.lua` 运行。

---

## 七、运行测试

```bash
# 在插件根目录
lua5.3 test/test_convert.lua
# 或 lua5.1 / luajit
```

测试覆盖：

1. 含 3 个中文章节的 TXT → 校验章节数与目录层级（含英文 `Chapter One`）；
2. 无章节标题的 TXT → 校验「整本书作为一个章节」回退逻辑；
3. GBK 编码的中文 TXT → 校验编码自动识别与转换为 UTF-8；
4. 空格缩进目录 TXT → 校验按层级切分（含自定义步长），以及生成的 nav.xhtml / toc.ncx 为真正的多级嵌套结构。

---

## 八、已知限制

- 章节识别默认基于一组常见标题写法；非常规写法（如纯日期 `2024-01-01`、自定义符号）需通过「设置章节标题正则」补充 Lua 模式。
- 纯 Lua Store 方式不压缩，EPUB 体积偏大；如需压缩请见上文「替代方案」。
- 缩进模式把每一行非空行都当作一个目录条目，因此最适合"目录/大纲式"TXT；若文件混有大段散文正文，建议优先使用显式章节标题（或自定义正则）。多级嵌套目录（卷-章-节）在**缩进模式**下已原生支持，目录面板可逐层展开。

---

## 九、故障排查（菜单不显示 / 其它插件也消失）

**症状**：安装后「工具」菜单里看不到本插件，甚至**其它已安装插件也不显示**。

**根因**：KOReader 在构建阅读菜单时，会调用每个插件的 `addToMainMenu(menu_items)`，随后用 `MenuSorter:mergeAndSort("reader", menu_items, order)` 把所有菜单项合并排序（见 `readermenu.lua`）。该函数**没有 `pcall` 保护**——一旦某个插件往 `menu_items` 里写入了与 MenuSorter 预期不符的结构（例如**手动改写内置 `menu_items.tools.sub_item_table`**、或子项缺少 `sorting_hint`），合并排序时就会抛错，导致**整个阅读菜单构建失败**，于是所有插件的菜单项全部消失。

**本插件采用的标准写法**（与 KOReader 官方 `hello` / `toc_extractor` / `ComicMeta` 等一致）：

```lua
function TXT2EPUB:addToMainMenu(menu_items)
    menu_items.txt2epub = {
        text = _("TXT 转 EPUB"),
        sorting_hint = "tools",          -- 让框架自行归到“工具”菜单
        sub_item_table = { ... },        -- 子菜单项
    }
end
```

要点：

- **用 `sorting_hint` 让框架归类**，绝不手动去碰 `menu_items.tools` 等内置菜单的内部 `sub_item_table`。
- 每个顶层插件项都要有 `sorting_hint`（本插件用 `"tools"` 归到顶部「工具」菜单）。
- `sub_item_table` 内的子项不需要 `sorting_hint`（它们不是顶层分类项）。

仓库的 `test/test_menu.lua` 用**真实的 KOReader `menusorter.lua` 与 `reader_menu_order.lua`** 复现了整个菜单注册流程，可验证：本插件的 `addToMainMenu` 不会改写内置 `tools`、能被 `mergeAndSort` 正常合并、且「TXT 转 EPUB」与其它插件都能出现在工具菜单（`lua5.3 test/test_menu.lua`，10 项全通过）。

若仍不显示，请检查 KOReader 日志（`koreader.log`）：搜索 `failed to register widget` 或 `MenuSorter`，确认是否有其它插件的 `addToMainMenu` 抛错；并确认本插件目录名确为 `txt2epub.koplugin` 且放在正确的 `plugins/` 目录下。

---

## 十、故障排查（点「开始转换」后 KOReader 整体崩溃退出）

**症状**：插件安装正常、菜单也能看到，但点击「开始转换」后 KOReader **整个程序崩溃 / 闪退退出**，无法继续运行。

**根因**：转换发生在 `UIManager:nextTick` 回调里，而 `nextTick = scheduleIn(0, action)` 会在**下一次 UI 节拍里同步执行**该回调——它运行在 KOReader 主线程上。早期实现存在三层隐患：

1. **一次性把整本 TXT 读进内存**：把整个文件读成单一字符串再切分。10MB+ 大书单步内存峰值 + UI 线程长时间阻塞，易被设备 OOM 或看门狗杀掉。
2. **转换回调无兜底保护**：`nextTick` 回调里任何一行出错都会 panic 进程，无法「只提示错误、不退出」。
3. **确认框字段格式错误**：`ConfirmBox.other_buttons` 必须是一个「数组的数组」，写成单层表会让按钮渲染/回调抛错并 panic。

本版本已修复上述三点（流式读取 / 整段 `pcall` / 修正 `other_buttons` / 移除 `^%s*正文` 误判）。但**仅这些仍可能崩溃**，核心原因在于：

4. **转换全程同步阻塞主线程**。即便不再一次性读全文件（改为流式读取、逐章写 ZIP），「生成全部章节 XHTML + 计算 CRC32 + 写 ZIP」仍是一段**连续、不释放主线程的同步重活**。在墨水屏（CPU 很慢的 e-ink）或 Android（KOReader 作为前台 App）上，主线程一旦被长时间占用，系统会判定应用「无响应」：Android 触发 **ANR 并杀掉进程**，或设备看门狗直接终止 KOReader。**这不是 Lua 错误，`pcall` 兜不住**——所以即便加了 `pcall`，点转换依然会整体退出。

5. **`util.fileExists` 在部分 KOReader 版本中不存在（本次日志确认的真实根因）**。早期代码在 `convert()` 里调用 `util.fileExists(out_path)` 判断输出是否已存在。但某些 KOReader 构建（尤其较旧或裁剪版）的 `ffi/util` 并未导出该函数，调用即抛 `attempt to call field 'fileExists' (a nil value)`，且发生在点击「开始转换」的最外层、`_safe` 兜底之前的逻辑路径上，直接 panic 崩溃整个 KOReader。崩溃日志 `crash.log` 与插件诊断日志 `.txt2epub.log` 均精确指向该行。

6. **整本书被一次性堆进内存 → Kindle OOM 整机重启（本次崩溃的最终根因）**。即便绕过了 `fileExists`、也加了协程逐章 yield，转换在真机上仍「跑一会儿就重启」。`.txt2epub.log` 显示新一轮 `has_title=true` 之后日志戛然而止、无任何 Lua 错误；Kindle 原生崩溃转储末尾是内核 `Killed`（`poll: Interrupted system call` 之后），**无 Lua 报错栈**——这明确指向**被系统 OOM killer 硬杀**，而非 Lua 错误。真机此前更早的日志里还出现过 `fork failed: Cannot allocate memory`，说明该 Kindle 内存本就吃紧。

   真正的元凶有两点：
   - **编码误判**：旧代码用 `is_valid_utf8(前 64KB)` 判断文件是否 UTF-8，而前 64KB 常常**正好切在中文多字节字符中途**，于是合法 UTF-8 文件被误判为「非 UTF-8」。
   - **随之进入整本载入分支**：被误判后，代码走 `fh:read("*a")` 把**整本书读进内存**，再整段解码成又一个大字符串 `full`，并由 `string_lines(full)` **在整段转换期间全程攥着**——于是几 MB 的中文小说（无论本来是 UTF-8 还是真·GBK）都会在内存里常驻一份「整本解码副本」。本就捉襟见肘的 Kindle 内存再叠加这份常驻量，触发 **OOM → 内核直接杀掉 KOReader 并重启整机**。日志之所以停在中途、没有错误，正是因为进程在「整本读入 / 解码」阶段就被系统硬杀，根本来不及走 Lua 的 `_safe`/`_log`。

**本插件的最终修复**（已随本版本发布）：

- **流式按行读取（UTF-8 全程有界）**：`Converter.lines(path)` 对带/无 BOM 的 UTF-8 走 64KB 分块流式读取（`stream_lines`），绝不把整本书拼成单一字符串。
- **编码判定容忍末尾截断**：新增 `is_valid_utf8_prefix()`——若前 64KB 末尾恰好切在中文多字节中途，只要它仍是「合法 UTF-8 的前缀」就判定为 UTF-8，避免大量 UTF-8 文件被误判进整本载入的 GBK 分支。
- **非 UTF-8（GBK / UTF-16）改为「解码到临时文件 + 流式读回」**：UTF-16 / GBK 等不再用 `fh:read("*a")` 整本读入、也不再在内存里整段驻留。新路径用 `iconv` 把文件解码到**源文件同目录**的临时文件（落盘、不占 Lua 堆），再用 `stream_lines` 以 64KB 分块流式读回，转换结束即删除临时文件。`iconv` 不可用时回退为「按原始字节流式切行」（可能乱码但**内存有界、绝不崩溃**）。
- **整段转换在协程中执行，逐章 `yield` 回 UI 线程**：`_run` / `_run_indent` 用 `coroutine` 驱动；`Converter.build_epub_streaming` **每写完一个章节文件就 `yield` 一次**，主线程永不被长时间占用，消除看门狗 / ANR 风险。错误由 `coroutine.resume` 捕获，只弹「转换失败：…」提示。
- **真·流式构建，内存只保留「一章」量级**：`_do_convert` / `_do_convert_indent` 改用 `build_epub_streaming(line_iter, ...)`，**逐章生成 XHTML → 立即写入 ZIP → 随即释放该章正文**（`paras = nil`），仅保留轻量目录元数据（标题 + 内部路径 + 层级）。
- **周期性全量 GC**：每 25 章一次 `collectgarbage("collect")`，主动把内存还给系统（墨水屏 / 低内存设备关键）。
- **不再依赖 `util.fileExists`**：改用模块内 `file_exists(path)`（仅 `io.open`），规避 `fileExists` 为 nil 导致的 panic。

   实测（luajit）：7MB UTF-8 大书、2000 章，峰值内存 **≈1.3MB**；GBK 文件 200 章，峰值内存 **≈1.5MB**——内存随章节数**不再增长**，稳定在「一章 + 64KB 缓冲」量级，Kindle OOM 重启问题得到根治。

**如何验证修复**：仓库 `test/` 提供三套测试（插件根目录运行）：

```bash
lua5.3 test/test_convert.lua          # 单元测试：27 项（ZIP 结构/章节切分/GBK/回退）
luajit  test/test_runtime.lua         # 运行时测试：21 项（模拟点击转换，验证协程逐章 yield 不 panic + 进度框/完成提示必被创建）
luajit  test/test_edge.lua            # 边界测试：15 项（UTF-8 BOM / GBK / 9MB 单行 / 中文路径 / 空文件）
luajit  test/test_stream.lua          # 流式构建测试：23 项（含「前64KB切在多字节中途的UTF-8」OOM回归用例）
```

`test_runtime.lua` 用最小 KOReader 运行时桩**复现「点击开始转换 → 协程逐章 yield → 完成」的完整路径**：它把 `UIManager:nextTick` 改为入队，再用 `drain_next_ticks()` 模拟真实 UI 主循环逐个执行。其中 **「大书(120章) 分多次 UI tick 完成」** 这一项专门统计 `nextTick` 被入队次数——120 章的书会被切分成**多次 UI 节拍**完成（而非一次阻塞调用），直接证明主线程已被分片、不会再触发看门狗/ANR。只要测试不 panic 且断言全过，即可确认真机上点转换不会再导致 KOReader 崩溃退出。

若仍出现异常，请查看 `koreader.log` 中紧邻崩溃前的 `转换失败：` 提示文本——它已包含真实 Lua 错误栈，可按该信息定位具体文件或设置问题。

## 十一、故障排查（点「排版预设…」后 KOReader 崩溃退出）

**症状**：插件安装正常、菜单也能看到，但进入「工具 › TXT2EPUB › 排版预设…」子菜单时，KOReader **整个程序崩溃 / 闪退退出**。崩溃日志 `crash.log` 指向 `main.lua` 的 `sub_item_table_func`（即 `gen_style_menu`）：

```
./luajit: plugins/txt2epub.koplugin/main.lua:168: attempt to call local '_' (a number value)
stack traceback:
	plugins/txt2epub.koplugin/main.lua:168: in function 'sub_item_table_func'
	frontend/ui/widget/touchmenu.lua:892: in function 'onMenuSelect'
```

**根因**：文件顶部 `local _ = require("gettext")` 把 `_` 定义为翻译函数。而在 `gen_style_menu` 里曾错误地写了 `for _, key in ipairs(...)`——**循环变量 `_` 遮蔽了外层的 gettext 函数**，在循环体内 `_` 变成数字 `1/2/3`，于是 `_（STYLE_LABELS[key]）` 变成「把数字当函数调用」，触发 `attempt to call local '_' (a number value)` 并 panic 崩溃进程。

> 这是 Lua 的经典坑：`_` 在 Lua 里**只是一个普通变量名**，并非「占位不变量」。任何 `for _, x` / `local _ = ...` 都会覆盖它。本插件仅在 `main.lua` 用到 gettext 的 `_`，`converter.lua` 与测试文件没有定义它，因此那些文件里的 `for _, x` 是安全的。

**本插件已修复**：把该处循环变量从 `_` 改名为 `_i`（`for _i, key in ipairs(...)`），循环体内 `_()` 重新指向翻译函数。`test/test_menu.lua` 已新增**回归测试**：真正调用 `gen_style_menu()`，断言其返回 4 个菜单项且每个 `text` 都是字符串（若 `_` 被遮蔽则 `text` 会变成把 `_` 当函数的异常结果，测试即失败）。

**日常开发规避规则**：在 `main.lua` 中，**禁止用 `_` 作循环 / 局部变量名**；凡需要丢弃的循环变量，请改用 `_i`、`_k`、`_idx` 等。若确实需要 `_()` 翻译，确保它不在任何把 `_` 重绑定的作用域内被调用。

```bash
lua5.3 test/test_menu.lua   # 含上述回归测试，全部 PASS 即说明排版预设菜单不再崩溃
```

## 十二、故障排查（点「开始转换」后 KOReader 崩溃退出，日志停在 `has_title 预检结果：true` 且进程被 `Killed`）

**症状**：进入「开始转换」后，诊断日志 `.txt2epub.log` 仅记录到 `== 开始转换流程` 与 `has_title 预检结果：true` 即中断，KOReader 进程被系统 `Killed`（OOM 强杀，无 Lua 报错栈）。这类崩溃有多处典型根因，均已修复：

1. **GBK / UTF-16 文件被反复解码**：早期实现里 `has_title` / `count_chapters` / `build_epub_streaming` 各自都会对同一个文件跑一次 `iconv` 子进程做解码，在内存吃紧的 Kindle 上反复 `fork` 子进程极易触发 OOM。
   **修复**：`converter.lua` 新增**解码一次缓存**——按原文件路径缓存「已解码的临时文件」，整个转换流程只解码一次；转换结束由 `Converter.release_lines(path)` 自动清理临时文件（UTF-8 文件为 no-op）。

2. **协程内直接弹 UI**：早前 `on_progress` 回调在协程内部调用 `UIManager:show(InfoMessage)` 刷新进度，在部分 KOReader 主循环时序下会从协程里触碰 UI 而 panic。
   **修复**：协程内只记录 `self._progress_i`（已写入章节数），进度刷新全部移到主线程的 `step`（`nextTick` 回调）里统一执行，协程内**绝不触碰 UIManager**。

3. **`on_yield` 误用 `coroutine.running()` 做守卫（跨版本兼容性坑）**：流式构建每写完一章调用 `on_yield` 让出主线程，早期写法为 `if coroutine.running() then coroutine.yield() end`。该写法依赖「主线程下 `coroutine.running()` 返回 `nil`」的语义——**这在 Lua 5.1 / LuaJIT 2.1（KOReader 真机）成立，但在 Lua 5.2+（含测试用的 Lua 5.3）不成立**：Lua 5.3 即使在主线程也会返回「主线程对象」而非 `nil`，于是守卫失效、直接调用 `coroutine.yield()`，抛出 `attempt to yield from outside a coroutine`。
   **修复**：不再依赖 `coroutine.running()` 的版本相关语义，改为**显式标志位**——由 `_async_run` 的 `work_fn` 在进入 `_do_convert` 前置位 `self._in_async = true`、退出后置 `false`；`on_yield` 仅当 `self._in_async` 为真时才 `coroutine.yield()`。该方案在 Lua 5.3（CI 测试）与 LuaJIT 2.1（真机）下行为完全一致，且不涉及「跨 pcall yield」的兼容性顾虑。

4. **同一大文件被同步遍历 3 遍**（本次日志确认的持续复现根因）：流程为 `has_title`（读到首个标题即返回）→ `count_chapters`（**完整读一遍**统计章节数）→ `build_epub_streaming`（**再完整读一遍**写 EPUB）。当用户正在阅读器里打开同一本大书（本书打开耗时约 11 秒、体量很大）时，后两遍完整遍历的磁盘 IO 与 GC 压力叠加在「阅读器已持有整本书」的内存上，Kindle 内存吃紧即被 OOM killer 硬杀。
   **修复**：**移除 `count_chapters` 预扫描这一整遍遍历**——`_run` / `_run_indent` 不再预统计章节数，进度条改为显示「已写入 N 章」（构建时随写随累加），全程只保留 `build_epub_streaming` 这一遍流式读取；构建期间把 `collectgarbage("collect")` 从每 25 章收紧到**每 5 章**一次，并在构建结束整体回收一次，及时把内存还给系统。

**验证**：`test/test_runtime.lua` 用最小运行桩完整复现「点击开始转换 → 协程逐章 yield → 完成」路径并捕获任何 panic；流式内存峰值仅约 **630 KB / 6MB 文件 / 500 章**，确认转换路径内存有界、不再 OOM。全部 5 个测试套件在 **Lua 5.3 与 LuaJIT 2.1 两种解释器下均通过**。

```bash
lua    test/test_runtime.lua   # 21 项通过（Lua 5.3）
luajit test/test_runtime.lua   # 21 项通过（LuaJIT 2.1，KOReader 真机同款）
```

## 十三、故障排查（转换成功但页面全程无提示、卡住，转换完毕也无提示）

**症状**：转换本身能成功（诊断日志 `.txt2epub.log` 显示「EPUB 生成成功，共 N 章」），但**转换过程中屏幕无任何进度提示、看似卡住**，转换结束也**没有完成提示**——用户无法判断是否还在转换、何时结束。

**根因**：进度刷新函数 `_set_progress` 首行写死了 `if not self._progress then return end`，而 `_open_progress` 在调用它之前**先把 `self._progress` 置为 `nil`**（准备重建），于是首次调用 `_set_progress` 时命中该守卫**直接 return**，进度框**从始至终从未被创建**。后续协程 `step` 里的刷新调用同样因 `self._progress == nil` 而全部短路——转换在后台正常进行，但屏幕上从头到尾没有任何反馈。

**修复**：
1. **移除「首帧短路」守卫**：`_set_progress` 改为「仅当进度框**已存在**时才做节流判断」，首次调用**必定创建**进度框；`UIManager:close` 前先判空，杜绝 nil 调用。
2. **分阶段文案（参考「月读」moon 排版优化）**：预检标题时显示「**正在识别章节…**」；流式构建时显示「**正在写入…**」+ 进度条 + 「已写入 N 章」。
3. **完成提示明确且停留足够久**：转换完成弹出「✓ 转换完成：共 N 章」（`timeout=5`），避免墨水屏上一闪而过。
4. **失败兜底**：`_safe` 捕获异常后先 `_close_progress()` 关闭可能残留的常驻进度框，避免挡住「转换失败」提示。

**验证**：`test_runtime.lua` 新增两项回归断言——「转换过程创建了常驻进度框（`dismissable=false`、`timeout=nil`）」与「转换结束弹出了完成提示（`timeout≥5`）」，在 Lua 5.3 与 LuaJIT 2.1 下均通过；旧代码（首帧短路版）会在这两项上直接失败。

## 十四、故障排查（卡在扫描目录 / 样式预设无法选择字体、无法修改样式参数）

**症状**：①点「开始转换」或打开「正文字体…」时卡住（表现为「卡在扫描目录」）；②「排版预设」里字体列表为空、无法选择字体；③「自定义参数…」里改参数无效或输入即崩溃。

**三处根因与修复**：

1. **「卡在扫描目录」= 日志维护遍历整个书籍目录**：旧版 `_maintain_log` 每 3 次运行会调用 `_cleanup_old_logs`，用 `lfs.dir` 遍历 TXT 同目录、逐项 `lfs.attributes` 查修改时间。在 Kindle 的慢速大目录（数百上千本书）上会卡住数秒到数十秒。**修复**：彻底移除目录遍历，仅保留 O(1) 的「日志超 512 KB 清空重建」单文件检查。

2. **「无法选择字体 / 无法修改样式参数」= Lua 5.1 闭包共享陷阱**：`gen_style_menu` / `gen_font_menu` / `gen_custom_menu` 里 `for _i, x in ipairs(...)` 的循环变量 `x` 是**共享 upvalue**，循环结束后所有 `callback`/`checked_func` 里的 `x` 都指向**最后一个值**——于是「选紧凑却存成 custom」「选字体 A 却存成字体 Z」「选行高 120 却存成 200」。**修复**：每个循环体内用 `local this_x = x` 拷贝后再进闭包。

3. **「修改样式参数崩溃」= 数值参数用 InputDialog 逐字输入**：InputDialog 会弹出虚拟键盘，在部分输入法插件（如 pinyin_enhancement，crash.log 中 `inputtext.lua` 的 `added_charlist nil` 崩溃即源于此）下会崩溃，且墨水屏逐字输入体验差。**修复**：行高/段距/首行缩进/字号缩放/字距一律改为**预设选项列表**点选，点击即选即保存，不再依赖键盘输入；「默认（衬线体）」也改为**始终可选**，不依赖字体扫描结果。

**验证**：`test_menu.lua` 新增 11 项闭包捕获回归断言——「预设#N 回调保存第 N 个 key」「字体#N 回调保存第 N 个名字」「行高选项#N 保存第 N 个值」，在 Lua 5.3 与 LuaJIT 2.1 下均通过；旧代码（未拷贝循环变量）会在这批断言上全部失败。

## 十五、故障排查（转换完成提示后卡在「正在识别章节」/ 自定义参数点不动）

**症状**：①转换成功、也弹出了「✓ 转换完成（已保存到…）」提示，但提示消失后屏幕**卡在「正在识别章节…」**，无法点击其它页面；②「排版预设 › 自定义参数…」里点行高/段距等数值项**毫无反应**（点不开可选值列表）。

**根因**：

1. **「卡在正在识别章节」= 常驻进度框残留**：`_check_title_and_run` 先打开「正在识别章节」（`scan`）阶段的进度框，它被设为 `dismissable=false`、`timeout=nil` 的**常驻框**。检测到标题后进入构建阶段时，旧 `_open_progress` 只是把 `self._progress` 指针换成新框，**并没有 `UIManager:close` 旧的 scan 框**——于是 scan 框残留在屏幕栈底；转换完成提示（`timeout=5`）消失后，这个残留的常驻框重新露出、又无法点击关闭，界面就「卡死」了。**修复**：`_open_progress` 现在**先 `_close_progress()` 关闭任何残留旧框**，再创建新框，杜绝常驻框叠加残留。

2. **「自定义参数点不动」= 用了错误的下拉组件**：旧版「自定义参数…」用 `require("ui/widget/menu")` 的 `Menu`（分页列表）打开独立菜单，但 KOReader 的 `Menu:onMenuSelect` **只识别 `sub_item_table`（静态表），不识别 `sub_item_table_func`**（惰性子菜单只在 `TouchMenu` 里被调用展开）。而自定义参数的数值项全部用 `sub_item_table_func` 生成可选值，于是在 `Menu` 里点了直接落入「叶子分支」、无回调、菜单关闭——表现为「点不动」。**修复**：「自定义参数…」改回 **`sub_item_table_func` 惰性子菜单**（在主菜单 TouchMenu 里正常展开），数值项的可选值列表与勾选标记也随之正常。

3. **勾选/显示不刷新**：`gen_font_menu` / `gen_custom_menu` 里 `checked_func` 与参数显示曾**缓存**了旧值（`current` / `cur_val`），改动后菜单刷新时勾选与「当前值」仍停在旧值，用户误以为「没选上」。**修复**：字体勾选、参数勾选与参数显示一律改为**实时读取**（`text_func` + 动态 `checked_func`），改动后立即更新。

4. **字体列表兜底**：`get_font_list` 在 `fontinfo` 解析为空时，改用 `fontlist.fontnames`（家族名表）兜底，并追加诊断日志；避免个别设备上字体列表恒为空。

**验证**：`test_runtime.lua` 新增回归断言「『正在识别章节』框已被关闭、不残留」（有标题场景下 `scan` 框必须在进入 build 阶段时被 `close`），旧代码（`_open_progress` 不先关旧框）会在此项直接失败；`test_menu.lua` 同步断言「自定义参数…」为 `sub_item_table_func` 入口。全部测试在 Lua 5.3 与 LuaJIT 2.1 下通过。
