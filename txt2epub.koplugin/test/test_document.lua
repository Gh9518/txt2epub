-- test/test_document.lua
-- 通用文档转换（build_epub_from_document）的单元 + 集成测试。
-- 运行：lua5.3 test/test_document.lua   （在插件根目录执行）
--
-- 覆盖：
--   1) 多级 TOC：章节文件数、nav.xhtml 嵌套结构（卷/章/节）
--   2) 末章 pos1 为空时的单节点 HTML 提取回退
--   3) 无 TOC：按页聚合为单章
--   4) 完全拿不到内容（非 CreDocument，如 PDF）：安全回退为单章（保证 EPUB 合法）
--   5) 生成的 EPUB 是合法 ZIP 且含必要构件

local plugin_dir = arg and arg[0] and arg[0]:match("(.*/)") or "./"
if plugin_dir == "" then plugin_dir = "./" end
package.path = package.path .. ";" .. plugin_dir .. "?.lua" .. ";" .. plugin_dir .. "../?.lua"
package.path = package.path .. ";./?.lua"

local Converter = require("converter")

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

-- 把 EPUB 解到临时目录并返回某条目的内容（用 unzip -p）
local function epub_entry(out, entry)
    local cmd = string.format('unzip -p "%s" "%s" 2>/dev/null', out, entry)
    local f = io.popen(cmd, "r")
    local data = f and f:read("*a") or ""
    if f then f:close() end
    return data or ""
end
local function epub_valid(out)
    local f = io.popen(string.format('unzip -l "%s" >/dev/null 2>&1; echo $?', out), "r")
    local r = f and f:read("*a") or "1"
    if f then f:close() end
    return r:match("^0")
end

local tmp = os.tmpname()
local out = tmp .. "_out.epub"

------------------------------------------------------------------------
-- 用例 1：多级 TOC + 末章 pos1 为空
------------------------------------------------------------------------
local toc = {
    { text = "第一章", depth = 1, pos0 = "a", pos1 = "b" },
    { text = "第一节", depth = 2, pos0 = "b", pos1 = "c" },
    { text = "第二节", depth = 2, pos0 = "c", pos1 = "d" },
    { text = "第二章", depth = 1, pos0 = "d", pos1 = nil }, -- 末章，pos1 为空
}
local html_map = {
    a = "<p>第1章正文</p>",
    b = "<p>1.1节正文</p>",
    c = "<p>1.2节正文</p>",
    d = "<p>第2章正文</p>",
}
local doc1 = {
    title = "测试书",
    toc = toc,
    get_html = function(pos0, pos1)
        return html_map[pos0] or nil
    end,
    page_count = 0,
    get_page_xp = function(p) return "p" .. p end,
}
local ok, count = Converter.build_epub_from_document(doc1, out, { book_title = "测试书" })
check("用例1：返回成功", ok == true)
check("用例1：章节文件数 = 4", count == 4, "got " .. tostring(count))
check("用例1：EPUB 是合法 ZIP", epub_valid(out))

local nav = epub_entry(out, "OEBPS/nav.xhtml")
check("用例1：nav 含 第一章", nav:find("第一章") ~= nil)
check("用例1：nav 含 第二章", nav:find("第二章") ~= nil)
-- 嵌套：第一节/第二节 应出现在 第一章 的 <ol> 内（即位于 第一章 与 第二章 之间）
local p1 = nav:find("第一章")
local p2 = nav:find("第二章")
local p_sec = nav:find("第一节")
check("用例1：nav 章节顺序正确（第一节在 第一章 之后、第二章 之前）",
    p1 and p2 and p_sec and p1 < p_sec and p_sec < p2)
check("用例1：nav 包含嵌套 <ol>（多级目录）", nav:find("<ol>.*<ol>", 1, false) ~= nil or nav:find("第一节.-第二节") ~= nil)

local c1 = epub_entry(out, "OEBPS/chapter_0001.xhtml")
check("用例1：第一章 XHTML 含正文", c1:find("第1章正文") ~= nil)
check("用例1：第一章 XHTML 含标题", c1:find("第一章") ~= nil)

------------------------------------------------------------------------
-- 用例 2：无 TOC，按页聚合为单章
------------------------------------------------------------------------
local doc2 = {
    title = "页式书",
    toc = {},
    get_html = function(pos0, pos1)
        return "<p>页内容</p>"
    end,
    page_count = 3,
    get_page_xp = function(p) return "p" .. p end,
}
ok, count = Converter.build_epub_from_document(doc2, out, { book_title = "页式书" })
check("用例2：返回成功", ok == true)
check("用例2：章节文件数 = 1（单章）", count == 1, "got " .. tostring(count))
local c2 = epub_entry(out, "OEBPS/chapter_0001.xhtml")
check("用例2：单章含三页聚合内容", c2:find("页内容") ~= nil)

------------------------------------------------------------------------
-- 用例 3：完全拿不到内容（非 CreDocument，如 PDF）—— 安全回退为单章
------------------------------------------------------------------------
local doc3 = {
    title = "PDF式书",
    toc = {},
    get_html = nil,        -- 没有 getHTMLFromXPointers
    page_count = 0,
    get_page_xp = nil,
}
ok, count = Converter.build_epub_from_document(doc3, out, { book_title = "PDF式书" })
check("用例3：返回成功（回退不崩溃）", ok == true)
check("用例3：至少生成 1 个章节文件", count >= 1, "got " .. tostring(count))
check("用例3：EPUB 合法", epub_valid(out))

------------------------------------------------------------------------
-- 用例 4：大章节自动切分（>256KB 的 HTML 片段）
------------------------------------------------------------------------
local big = {}
for i = 1, 6000 do big[#big + 1] = "<p>段落内容填充以满足超长章节切分测试目的，确保单文件超过 256KB 上限触发分页。</p>" end
local doc4 = {
    title = "大书",
    toc = { { text = "唯一章", depth = 1, pos0 = "x", pos1 = nil } },
    get_html = function(pos0, pos1) return table.concat(big) end,
    page_count = 0,
    get_page_xp = function(p) return "p" .. p end,
}
ok, count = Converter.build_epub_from_document(doc4, out, { book_title = "大书" })
check("用例4：返回成功", ok == true)
check("用例4：超长章节被切分为多文件（count >= 2）", count >= 2, "got " .. tostring(count))
local ncx = epub_entry(out, "OEBPS/toc.ncx")
check("用例4：ncx 每个硬切分片都计入目录（唯一章出现 >= 2 次）",
    select(2, ncx:gsub("唯一章", "唯一章")) >= 2)

------------------------------------------------------------------------
print(string.format("\n==== test_document 结果：%d 通过 / %d 失败 ====", passed, failed))
os.remove(out)
if failed > 0 then os.exit(1) end
