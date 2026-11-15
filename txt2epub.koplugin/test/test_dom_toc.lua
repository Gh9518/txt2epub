-- test/test_dom_toc.lua
-- DOM 兜底格式（.doc/.rtf/.fb2…）「getToc() 返回 0 条」时的目录修复回归测试。
--
-- 真机日志（2026-11-15 11:22:32，big_novel.doc）：
--   「DOM 提取体检：可见正文 2204261 字符，TOC 条目 0，章节 15」
-- 根因：KOReader 把 Word 标题样式渲染成普通 <p>，getToc() 为空，
--       全书被聚合成 1 个大章再按 256KB 硬切，nav/ncx 只剩 1 条目录、
--       正文里的「第一卷 / 第X章 / 第X节」也没有任何标题排版。
--
-- 覆盖：
--   1) 真机规模复现：无 TOC + 卷/章/节 + 每页 <html>/<body> 包裹 → 多级目录
--   2) 章节标题以 <h1 class="chapter-title lv-N"> 排版，且不在正文重复
--   3) 按页聚合残留的 <html>/<head>/<body> 被清理，正文完整不丢
--   4) 单章 XHTML 不超过 300KB
--   5) 已有完整 TOC 的场景不被重切分破坏
--   6) 正文无任何标题时按字节硬切，但所有分片都进目录（不再只剩 1 条）
--   7) <hN> 标签层级 + 数字字符实体（&#x...;）标题
--   8) 纯文本 + 换行（无块标签）的兜底切分
--   9) stats.detected_titles / stats.resplit 诊断字段

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

local function epub_entry(out, entry)
    local f = io.popen(string.format('unzip -p "%s" "%s" 2>/dev/null', out, entry), "r")
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
local function count_occurrences(s, pat, plain)
    local n = 0
    local p, q = s:find(pat, 1, plain)
    while p do
        n = n + 1
        p, q = s:find(pat, q + 1, plain)
    end
    return n
end
-- 返回 (最大章节文件字节数, 章节文件数)；按 unzip -l 逐行解析，避免模式不匹配时
-- 静默返回 0 造成「假通过」。
local function epub_max_chapter_size(out)
    local f = io.popen(string.format('unzip -l "%s" 2>/dev/null', out), "r")
    local listing = f and f:read("*a") or ""
    if f then f:close() end
    local max, n_chapters = 0, 0
    for line in listing:gmatch("[^\r\n]+") do
        if line:find("OEBPS/chapter_", 1, true) and line:find(".xhtml", 1, true) then
            local n = tonumber(line:match("^%s*(%d+)"))
            if n then
                n_chapters = n_chapters + 1
                if n > max then max = n end
            end
        end
    end
    return max, n_chapters
end

local tmp = os.tmpname()
local out = tmp .. "_out.epub"

------------------------------------------------------------------------
-- 用例 1：真机规模复现（无 TOC，卷/章/节，带每页文档包裹）
------------------------------------------------------------------------
-- 按 3 页分别返回内容（真实 KOReader 按页聚合不会重复整本书）。
-- 每页都自带一份 <html>/<head>/<body> 包裹，用来验证全局清理。
local function build_big_pages()
    local pages = { {}, {}, {} }
    local function add(page, s)
        local t = pages[page]
        t[#t + 1] = s
    end
    local function wrap(page)
        add(page, '<html><head><style>p{color:#000}</style></head><body>')
    end
    wrap(1)
    add(1, '<p>big_novel</p>')
    add(1, '<p>第一卷 少年时</p>')
    for c = 1, 300 do
        local page = (c <= 100) and 1 or (c <= 200) and 2 or 3
        if c == 101 or c == 201 then wrap(page) end
        add(page, string.format('<p>第%d章 剑起青云</p>', c))
        for k = 1, 8 do
            add(page, string.format(
                '<p>这是第%d章的第%d段正文，用于填充以模拟大文件转换，确保章节切分与目录生成在真实规模下仍然正确无误。</p>', c, k))
        end
        if c % 50 == 0 then
            add(page, string.format('<p>第%d节 小结</p>', c / 50))
            add(page, '<p>本节为层级目录测试内容。</p>')
        end
    end
    add(3, '<h2>人物介绍</h2>')
    add(3, '<p>这是最后一页的正文，用于验证正文完整性不丢失。</p>')
    add(3, '</body></html>')
    for i = 1, 3 do pages[i] = table.concat(pages[i], "\n") end
    return pages
end

local big_pages = build_big_pages()
local doc1 = {
    title = "big_novel",
    toc = {},                       -- ★ 真机日志：TOC 条目 0
    get_html = function(pos0)
        local n = tonumber((pos0 or ""):match("%d+")) or 1
        return big_pages[n] or ""
    end,
    page_count = 3,
    get_page_xp = function(p) return "p" .. p end,
}
local ok, count, stats = Converter.build_epub_from_document(doc1, out, { book_title = "big_novel" })
check("用例1：返回成功", ok == true)
check("用例1：EPUB 是合法 ZIP", epub_valid(out))
check("用例1：stats.resplit = true", stats and stats.resplit == true,
    "got " .. tostring(stats and stats.resplit))
check("用例1：识别到 >= 300 个正文标题", stats and (stats.detected_titles or 0) >= 300,
    "got " .. tostring(stats and stats.detected_titles))
check("用例1：章节数 >= 300（不再是 15 个硬切片）", count >= 300, "got " .. tostring(count))

local nav = epub_entry(out, "OEBPS/nav.xhtml")
local ncx = epub_entry(out, "OEBPS/toc.ncx")
check("用例1：nav 含卷标题「第一卷 少年时」", nav:find("第一卷 少年时", 1, true) ~= nil)
check("用例1：nav 含首章「第1章 剑起青云」", nav:find("第1章 剑起青云", 1, true) ~= nil)
check("用例1：nav 含末章「第300章 剑起青云」", nav:find("第300章 剑起青云", 1, true) ~= nil)
check("用例1：nav 含节标题「第1节 小结」", nav:find("第1节 小结", 1, true) ~= nil)
check("用例1：nav 含 <h2> 标题「人物介绍」", nav:find("人物介绍", 1, true) ~= nil)
check("用例1：nav 有多级嵌套 <ol>（>= 2 层）", count_occurrences(nav, "<ol>", true) >= 2,
    "got " .. count_occurrences(nav, "<ol>", true))
check("用例1：ncx 有多个 navPoint（>= 300）", count_occurrences(ncx, "<navPoint", true) >= 300,
    "got " .. count_occurrences(ncx, "<navPoint", true))
check("用例1：目录里不再是单条书名「big_novel」",
    count_occurrences(nav, ">big_novel<", true) == 0)

local c1 = epub_entry(out, "OEBPS/chapter_0001.xhtml")
check("用例1：首章标题以 h1.chapter-title 排版",
    c1:find('<h1 class="chapter-title', 1, true) ~= nil and c1:find("第一卷 少年时", 1, true) ~= nil,
    "\n--- chapter_0001.xhtml ---\n" .. c1:sub(1, 700))
check("用例1：首章正文保留前置内容 big_novel", c1:find("big_novel", 1, true) ~= nil)
-- XHTML 模板自身各有 1 个 <html>/<head>/<body>；按页聚合残留的额外包裹必须被清掉
check("用例1：文档级包裹已清理（各自恰好 1 个）",
    count_occurrences(c1, "<html", true) == 1
    and count_occurrences(c1, "<head", true) == 1
    and count_occurrences(c1, "<body", true) == 1,
    string.format("html=%d head=%d body=%d", count_occurrences(c1, "<html", true),
        count_occurrences(c1, "<head", true), count_occurrences(c1, "<body", true)))
check("用例1：标题不在正文里以 <p> 重复",
    c1:find("<p>第一卷 少年时</p>", 1, true) == nil)
local max_size, n_files = epub_max_chapter_size(out)
check("用例1：章节文件数与返回值一致", n_files == count,
    string.format("files=%d count=%d", n_files, count))
check("用例1：所有章节 XHTML < 300KB", max_size > 0 and max_size < 300 * 1024,
    "max=" .. max_size)

-- 末章正文完整性（最后一个章节文件里应含收尾段落）
local last_name = string.format("OEBPS/chapter_%04d.xhtml", count)
local clast = epub_entry(out, last_name)
check("用例1：收尾正文未丢失", clast:find("这是最后一页的正文", 1, true) ~= nil,
    "entry=" .. last_name)

------------------------------------------------------------------------
-- 用例 2：已有完整 TOC 时不被重切分破坏
------------------------------------------------------------------------
local toc2 = {
    { text = "自定义卷一", depth = 1, pos0 = "a", pos1 = "b" },
    { text = "自定义章一", depth = 2, pos0 = "b", pos1 = "c" },
    { text = "自定义章二", depth = 2, pos0 = "c", pos1 = "d" },
    { text = "自定义卷二", depth = 1, pos0 = "d", pos1 = "e" },
}
local html2 = { a = "<p>卷一正文</p>", b = "<p>章一正文</p>",
                c = "<p>章二正文</p>", d = "<p>卷二正文</p>" }
local doc2 = {
    title = "有目录的书", toc = toc2,
    get_html = function(pos0) return html2[pos0] or "" end,
    page_count = 0, get_page_xp = function(p) return "p" .. p end,
}
ok, count, stats = Converter.build_epub_from_document(doc2, out, { book_title = "有目录的书" })
check("用例2：返回成功", ok == true)
check("用例2：章节数仍为 4", count == 4, "got " .. tostring(count))
check("用例2：stats.resplit = false", stats and stats.resplit == false)
local nav2 = epub_entry(out, "OEBPS/nav.xhtml")
check("用例2：原 TOC 标题完整保留", nav2:find("自定义卷一", 1, true) ~= nil
    and nav2:find("自定义卷二", 1, true) ~= nil)

------------------------------------------------------------------------
-- 用例 3：正文无任何章节标题 → 保持原行为（按字节硬切，目录仅书名 1 条）
------------------------------------------------------------------------
local plain = {}
for i = 1, 6000 do
    plain[#plain + 1] = "<p>段落内容填充以满足超长章节切分测试目的，确保单文件超过 256KB 上限触发分页，且不应被误判为章节标题。</p>"
end
local doc3 = {
    title = "无标题大书", toc = {},
    get_html = function() return table.concat(plain) end,
    page_count = 1, get_page_xp = function(p) return "p" .. p end,
}
ok, count, stats = Converter.build_epub_from_document(doc3, out, { book_title = "无标题大书" })
check("用例3：返回成功", ok == true)
check("用例3：超长章节被硬切为多文件", count >= 2, "got " .. tostring(count))
check("用例3：stats.resplit = false", stats and stats.resplit == false)
check("用例3：识别到 0 个标题", stats and stats.detected_titles == 0,
    "got " .. tostring(stats and stats.detected_titles))
local ncx3 = epub_entry(out, "OEBPS/toc.ncx")
check("用例3：无标题时每个硬切分片都进目录（navPoint >= 2）",
    count_occurrences(ncx3, "<navPoint", true) >= 2,
    "got " .. count_occurrences(ncx3, "<navPoint", true))
local max3 = epub_max_chapter_size(out)
check("用例3：所有章节 XHTML < 300KB", max3 > 0 and max3 < 300 * 1024,
    "max=" .. max3)

------------------------------------------------------------------------
-- 用例 4：数字字符实体标题 + <hN> 层级
------------------------------------------------------------------------
local html4 = table.concat({
    "<p>&#x7B2C;&#x4E00;&#x7AE0; 开端</p>",   -- 第一章 开端
    "<p>正文甲</p>",
    "<h2>人物介绍</h2>",                        -- 非正则标题，靠 <hN>
    "<p>正文乙</p>",
    "<p>第二章 落幕</p>",
    "<p>正文丙</p>",
}, "\n")
local doc4 = {
    title = "实体书", toc = {},
    get_html = function() return html4 end,
    page_count = 1, get_page_xp = function(p) return "p" .. p end,
}
ok, count, stats = Converter.build_epub_from_document(doc4, out, { book_title = "实体书" })
check("用例4：返回成功", ok == true)
check("用例4：重切为 3 章", count == 3, "got " .. tostring(count))
check("用例4：识别到 3 个标题", stats and stats.detected_titles == 3,
    "got " .. tostring(stats and stats.detected_titles))
local nav4 = epub_entry(out, "OEBPS/nav.xhtml")
check("用例4：数字实体标题被正确解码进目录", nav4:find("第一章 开端", 1, true) ~= nil)
check("用例4：<hN> 标题进目录", nav4:find("人物介绍", 1, true) ~= nil)
check("用例4：末章标题进目录", nav4:find("第二章 落幕", 1, true) ~= nil)
local c4 = epub_entry(out, "OEBPS/chapter_0001.xhtml")
check("用例4：第一章含正文甲", c4:find("正文甲", 1, true) ~= nil)

------------------------------------------------------------------------
-- 用例 5：纯文本 + 换行（无块标签）兜底切分
------------------------------------------------------------------------
local html5 = table.concat({
    "第一卷 少年时",
    "这是卷首说明文字。",
    "第一章 开端",
    "这是第一章正文。",
    "第二章 落幕",
    "这是第二章正文。",
}, "\n")
local doc5 = {
    title = "纯文本", toc = {},
    get_html = function() return html5 end,
    page_count = 1, get_page_xp = function(p) return "p" .. p end,
}
ok, count, stats = Converter.build_epub_from_document(doc5, out, { book_title = "纯文本" })
check("用例5：返回成功", ok == true)
check("用例5：重切为 3 章", count == 3, "got " .. tostring(count))
local nav5 = epub_entry(out, "OEBPS/nav.xhtml")
check("用例5：三个标题均在目录中", nav5:find("第一卷 少年时", 1, true) ~= nil
    and nav5:find("第一章 开端", 1, true) ~= nil
    and nav5:find("第二章 落幕", 1, true) ~= nil)
local c5 = epub_entry(out, "OEBPS/chapter_0001.xhtml")
check("用例5：卷首说明并入第一章", c5:find("这是卷首说明文字", 1, true) ~= nil)

------------------------------------------------------------------------
print(string.format("\n==== test_dom_toc 结果：%d 通过 / %d 失败 ====", passed, failed))
os.remove(out)
if failed > 0 then os.exit(1) end
