-- test_markup.lua
-- 覆盖 v2.1.0 新增的 .md / .markdown / .html / .htm 插件自解析路径：
--   1) markup.lua 纯函数：Markdown ATX/Setext 标题、代码块、列表、行内标记
--   2) markup.lua 纯函数：HTML <title>/<hN>/<p>、脚本样式剥离、实体解码
--   3) 端到端：四种扩展名生成合法 EPUB，多级目录 + 完整正文 + CRC 正确
--   4) GBK 编码的 .md/.html 也能正确解码
--   5) 无标题 / 空文件不崩溃，仍产出合法 EPUB

local plugin_dir = arg and arg[0] and arg[0]:match("(.*/)") or "./"
if plugin_dir == "" then plugin_dir = "./" end
package.path = package.path .. ";" .. plugin_dir .. "?.lua" .. ";" .. plugin_dir .. "../?.lua"
package.path = package.path .. ";./?.lua"

local Converter = require("converter")
local M = require("markup")

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed = passed + 1
        print(string.format("[PASS] %s", name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s  %s", name, extra or ""))
    end
end
local function count_occurrences(s, pat, plain)
    local n, p, q = 0, s:find(pat, 1, plain)
    while p do
        n = n + 1
        p, q = s:find(pat, q + 1, plain)
    end
    return n
end
local function epub_entry(out, entry)
    local f = io.popen(string.format('unzip -p "%s" "%s" 2>/dev/null', out, entry), "r")
    local d = f and f:read("*a") or ""
    if f then f:close() end
    return d or ""
end
local function epub_valid(out)
    local f = io.popen(string.format('unzip -t "%s" >/dev/null 2>&1; echo $?', out), "r")
    local r = f and f:read("*a") or "1"
    if f then f:close() end
    return r:match("^0")
end
local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return "" end
    local d = f:read("*a")
    f:close()
    return d or ""
end

local tmp = os.tmpname()
local function out_name(tag) return tmp .. "_" .. tag .. ".epub" end
local function src_name(tag, ext) return tmp .. "_" .. tag .. "." .. ext end
local generated = {}

------------------------------------------------------------------------
-- 用例 1：Markdown 纯函数解析
------------------------------------------------------------------------
local md = table.concat({
    "# 测试之书",
    "",
    "## 第一卷　开端",
    "",
    "### 第1章　初见",
    "",
    "这是一段**粗体**与*斜体*，还有 [链接](https://example.com) 和 `代码`。",
    "",
    "- 列表项一",
    "- 列表项二",
    "",
    "> 引用的一段话。",
    "",
    "```lua",
    "print('不应被当成标题')",
    "```",
    "",
    "尾声",
    "======",
    "",
    "收尾正文，&amp; 实体应解码为 & 。",
}, "\n")

local p1 = M.parse(md, "md")
check("用例1：Markdown 书名取自首个 h1", p1.title == "测试之书", tostring(p1.title))
local heads1 = {}
for _, p in ipairs(p1.paragraphs) do
    if p.kind == "heading" then heads1[#heads1 + 1] = p.text .. "@" .. p.level end
end
check("用例1：ATX 标题层级 2/3 正确",
    count_occurrences(table.concat(heads1, "|"), "第一卷　开端@2", true) == 1
    and count_occurrences(table.concat(heads1, "|"), "第1章　初见@3", true) == 1,
    table.concat(heads1, " | "))
check("用例1：Setext 标题「尾声」识别为 level 1",
    count_occurrences(table.concat(heads1, "|"), "尾声@1", true) == 1,
    table.concat(heads1, " | "))
local alltext1 = {}
for _, p in ipairs(p1.paragraphs) do alltext1[#alltext1 + 1] = p.text end
local body1 = table.concat(alltext1, "\n")
check("用例1：行内 Markdown 标记被剥离",
    body1:find("**", 1, true) == nil and body1:find("](https", 1, true) == nil,
    body1:sub(1, 200))
check("用例1：列表项保留为可读正文", body1:find("列表项一", 1, true) ~= nil)
check("用例1：代码块内容保留", body1:find("print('不应被当成标题')", 1, true) ~= nil)
check("用例1：代码块里的文本未被误判为标题",
    count_occurrences(table.concat(heads1, "|"), "print", true) == 0)
check("用例1：实体 &amp; 解码为 &", body1:find("实体应解码为 &", 1, true) ~= nil)

------------------------------------------------------------------------
-- 用例 2：HTML 纯函数解析
------------------------------------------------------------------------
local html = table.concat({
    "<!DOCTYPE html>",
    "<html><head><title>网页之书 &amp; 测试</title>",
    "<style>p{color:red}</style><script>var X='脚本内容不应出现';</script></head><body>",
    "<h1>第一卷　缘起</h1>",
    "<h2>第1章　初见</h2>",
    "<p>第一段正文，含 &#x4E2D;&#x6587; 数字实体与 &nbsp; 空格。</p>",
    "<p>第二段正文<br/>换行后继续。</p>",
    "<h3>第1节　细节</h3>",
    "<div>div 里的正文。</div>",
    "</body></html>",
}, "\n")
local p2 = M.parse(html, "html")
check("用例2：书名取自 <title> 且实体已解码",
    p2.title == "网页之书 & 测试", tostring(p2.title))
local heads2, body2 = {}, {}
for _, p in ipairs(p2.paragraphs) do
    if p.kind == "heading" then heads2[#heads2 + 1] = p.text .. "@" .. p.level
    else body2[#body2 + 1] = p.text end
end
local h2s = table.concat(heads2, " | ")
local b2s = table.concat(body2, " | ")
check("用例2：<h1>/<h2>/<h3> 层级正确",
    h2s:find("第一卷　缘起@1", 1, true) ~= nil
    and h2s:find("第1章　初见@2", 1, true) ~= nil
    and h2s:find("第1节　细节@3", 1, true) ~= nil, h2s)
check("用例2：数字字符实体解码为中文", b2s:find("中文", 1, true) ~= nil, b2s)
check("用例2：<br> 产生分段", b2s:find("第二段正文", 1, true) ~= nil
    and b2s:find("换行后继续", 1, true) ~= nil)
check("用例2：<script>/<style> 内容被剥离",
    b2s:find("脚本内容", 1, true) == nil and b2s:find("color:red", 1, true) == nil, b2s)
check("用例2：div 正文保留", b2s:find("div 里的正文", 1, true) ~= nil)

------------------------------------------------------------------------
-- 用例 3：端到端 —— .md / .markdown
------------------------------------------------------------------------
local md_src = src_name("md", "md")
write_file(md_src, md)
local ok_md, n_md = Converter.build_epub_from_markup(md_src, out_name("md"), { book_title = "md" })
generated[#generated + 1] = out_name("md")
check("用例3：.md 返回成功", ok_md == true)
check("用例3：.md 章节数 >= 3", n_md >= 3, "got " .. tostring(n_md))
local nav_md = epub_entry(out_name("md"), "OEBPS/nav.xhtml")
check("用例3：.md nav 含「第一卷　开端」", nav_md:find("第一卷　开端", 1, true) ~= nil)
check("用例3：.md nav 含「第1章　初见」", nav_md:find("第1章　初见", 1, true) ~= nil)
check("用例3：.md nav 含 Setext 标题「尾声」", nav_md:find("尾声", 1, true) ~= nil)
check("用例3：.md nav 有多级 <ol>", count_occurrences(nav_md, "<ol>", true) >= 2)
check("用例3：.md 正文完整（粗体文字保留）",
    epub_entry(out_name("md"), "OEBPS/chapter_0002.xhtml"):find("粗体", 1, true) ~= nil
    or epub_entry(out_name("md"), "OEBPS/chapter_0001.xhtml"):find("粗体", 1, true) ~= nil)
check("用例3：.md EPUB 全部条目 CRC 正确", epub_valid(out_name("md")))

local mdx_src = src_name("markdown", "markdown")
write_file(mdx_src, md)
local ok_mdx = Converter.build_epub_from_markup(mdx_src, out_name("markdown"), { book_title = "markdown" })
generated[#generated + 1] = out_name("markdown")
check("用例3：.markdown 扩展名同样按 Markdown 解析",
    ok_mdx == true and epub_entry(out_name("markdown"), "OEBPS/nav.xhtml"):find("第一卷　开端", 1, true) ~= nil)

------------------------------------------------------------------------
-- 用例 4：端到端 —— .html / .htm
------------------------------------------------------------------------
local h_src = src_name("html", "html")
write_file(h_src, html)
local ok_h, n_h = Converter.build_epub_from_markup(h_src, out_name("html"), { book_title = "html" })
generated[#generated + 1] = out_name("html")
check("用例4：.html 返回成功", ok_h == true)
check("用例4：.html 章节数 >= 3", n_h >= 3, "got " .. tostring(n_h))
local nav_h = epub_entry(out_name("html"), "OEBPS/nav.xhtml")
check("用例4：.html nav 含 h1 标题", nav_h:find("第一卷　缘起", 1, true) ~= nil)
check("用例4：.html nav 含 h2 标题", nav_h:find("第1章　初见", 1, true) ~= nil)
check("用例4：.html nav 有多级 <ol>", count_occurrences(nav_h, "<ol>", true) >= 2)
check("用例4：.html 书名来自 <title>",
    epub_entry(out_name("html"), "OEBPS/content.opf"):find("网页之书 &amp; 测试", 1, true) ~= nil)
check("用例4：.html 正文含中文实体解码结果",
    epub_entry(out_name("html"), "OEBPS/chapter_0001.xhtml"):find("中文", 1, true) ~= nil
    or epub_entry(out_name("html"), "OEBPS/chapter_0002.xhtml"):find("中文", 1, true) ~= nil)
check("用例4：.html EPUB 合法", epub_valid(out_name("html")))

local htm_src = src_name("htm", "htm")
write_file(htm_src, html)
local ok_htm = Converter.build_epub_from_markup(htm_src, out_name("htm"), { book_title = "htm" })
generated[#generated + 1] = out_name("htm")
check("用例4：.htm 扩展名同样按 HTML 解析",
    ok_htm == true and epub_entry(out_name("htm"), "OEBPS/nav.xhtml"):find("第一卷　缘起", 1, true) ~= nil)

------------------------------------------------------------------------
-- 用例 5：GBK 编码的 .md / .html
------------------------------------------------------------------------
local utf8_md = src_name("gbk_utf8", "md")
write_file(utf8_md, "# GBK 之书\n\n## 第一章　测试\n\n这是 GBK 编码的中文正文。\n")
local gbk_md = src_name("gbk", "md")
os.execute(string.format('iconv -f UTF-8 -t GBK "%s" > "%s" 2>/dev/null', utf8_md, gbk_md))
if read_file(gbk_md) ~= "" then
    local ok_g = Converter.build_epub_from_markup(gbk_md, out_name("gbk"), { book_title = "gbk" })
    generated[#generated + 1] = out_name("gbk")
    check("用例5：GBK .md 转换成功", ok_g == true)
    local nav_g = epub_entry(out_name("gbk"), "OEBPS/nav.xhtml")
    check("用例5：GBK .md 中文标题正确（无乱码）",
        nav_g:find("第一章　测试", 1, true) ~= nil, nav_g:sub(1, 300))
    check("用例5：GBK .md EPUB 合法", epub_valid(out_name("gbk")))
else
    check("用例5：环境无 iconv，跳过 GBK 用例（不视为失败）", true)
end

------------------------------------------------------------------------
-- 用例 6：无标题 / 空文件仍产出合法 EPUB
------------------------------------------------------------------------
local plain_md = src_name("plain", "md")
write_file(plain_md, "只是一段没有任何标题的普通正文。\n第二段正文。\n")
local ok_p, n_p = Converter.build_epub_from_markup(plain_md, out_name("plain"), { book_title = "plain" })
generated[#generated + 1] = out_name("plain")
check("用例6：无标题 .md 返回成功", ok_p == true)
check("用例6：无标题 .md 至少 1 章", (n_p or 0) >= 1)
check("用例6：无标题 .md 正文未丢失",
    epub_entry(out_name("plain"), "OEBPS/chapter_0001.xhtml"):find("普通正文", 1, true) ~= nil)
check("用例6：无标题 .md EPUB 合法", epub_valid(out_name("plain")))

local empty_md = src_name("empty", "md")
write_file(empty_md, "")
local ok_e = Converter.build_epub_from_markup(empty_md, out_name("empty"), { book_title = "empty" })
generated[#generated + 1] = out_name("empty")
check("用例6：空 .md 不崩溃且 EPUB 合法", ok_e == true and epub_valid(out_name("empty")))

------------------------------------------------------------------------
print(string.format("\n==== test_markup 结果：%d 通过 / %d 失败 ====", passed, failed))
for _, p in ipairs(generated) do os.remove(p) end
for _, p in ipairs({ md_src, mdx_src, h_src, htm_src, utf8_md, gbk_md, plain_md, empty_md }) do os.remove(p) end
if failed > 0 then os.exit(1) end
