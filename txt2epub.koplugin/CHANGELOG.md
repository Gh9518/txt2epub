# Changelog

本文件记录各版本的功能与修复。日常使用请看 [README.md](README.md)。

## v1.0.0（2026-11-05）
首个公开发布版本。

### 功能
- TXT → EPUB 一键转换（菜单「工具 › TXT2EPUB」），输出同名 `.epub` 至原目录。
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
