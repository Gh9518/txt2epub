-- test_dom_unicode.lua
-- 复现真机日志（2026-11-15 13:04:24，big_novel.doc）：
--   「DOM 提取体检：可见正文 2204261 字符，TOC 条目 0，正文标题 0，重切分 否，章节 15」
--
-- 根因：big_novel.doc 的 363 个标题全部使用 U+3000 全角空格
--   （「第1章　章节标题1」「第一卷　卷名之1」「第5节　细节展开」），
--   而 chapterTitle 的后缀校验只认 ASCII 空白/标点（^%s / ^%p），
--   导致所有标题被判为正文 → 识别 0 个 → 不重切 → 全书按 256KB 硬切，
--   且旧实现只让第 1 个分片进 nav/ncx，最终目录只剩 1 条、标题无排版。
--
-- 覆盖：
--   1) 真机规模（3 卷 / 300 章 / 60 节，全角空格，TOC=0）→ 多级目录 + h1 排版
--   2) stats 诊断字段（detected_titles / resplit / resplit_mode / html_sample）
--   3) 中文全角标点后缀（：（））也能识别，正文「第二回的内容」不误判
--   4) 第二层兜底：无块级标签、用 <span> 包裹的单行 HTML → 纯文本重建目录
--   5) <br> 分段的 HTML 也能切块识别
--   6) EPUB 合法（unzip -t 全条目 CRC 正确）与单章 < 300KB

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
    local f = io.popen(string.format('unzip -t "%s" >/dev/null 2>&1; echo $?', out), "r")
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
local function epub_max_chapter_size(out)
    local f = io.popen(string.format('unzip -l "%s" 2>/dev/null', out), "r")
    local listing = f and f:read("*a") or ""
    if f then f:close() end
    local max, n = 0, 0
    for line in listing:gmatch("[^\r\n]+") do
        if line:find("OEBPS/chapter_", 1, true) and line:find(".xhtml", 1, true) then
            local sz = tonumber(line:match("^%s*(%d+)"))
            if sz then
                n = n + 1
                if sz > max then max = sz end
            end
        end
    end
    return max, n
end

local tmp = os.tmpname()
local out = tmp .. "_unicode.epub"

------------------------------------------------------------------------
-- 用例 1：真机规模复现（全角空格标题，TOC 条目 0）
------------------------------------------------------------------------
local CN = { "零", "一", "二", "三" }
local function build_real_html()
    local p = {}
    p[#p + 1] = '<html><head><style>p{color:#000}</style></head><body>'
    p[#p + 1] = '<p>big_novel</p>'
    for vol = 1, 3 do
        p[#p + 1] = '<p>第' .. CN[vol + 1] .. '卷　卷名之' .. vol .. '</p>'
        for ch = 1, 100 do
            local no = (vol - 1) * 100 + ch
            p[#p + 1] = '<p>第' .. no .. '章　章节标题' .. ch .. '</p>'
            for k = 1, 3 do
                p[#p + 1] = string.format(
                    '<p>这是第%d章的第%d段正文，用于复现真机大文件转换，验证全角空格标题识别与多级目录生成是否正确。</p>',
                    no, k)
            end
            if ch % 5 == 0 then
                p[#p + 1] = '<p>第' .. ch .. '节　细节展开</p>'
                p[#p + 1] = '<p>本节为层级目录测试正文。</p>'
            end
        end
    end
    p[#p + 1] = '</body></html>'
    return table.concat(p, "\n")
end

local big_html = build_real_html()
local doc1 = {
    title = "big_novel",
    toc = {},                       -- ★ 真机日志：TOC 条目 0
    get_html = function() return big_html end,
    page_count = 1,
    get_page_xp = function(p) return "p" .. p end,
}
local t0 = os.clock()
local ok, count, stats = Converter.build_epub_from_document(doc1, out, { book_title = "big_novel" })
local elapsed = os.clock() - t0

check("用例1：返回成功", ok == true)
check("用例1：识别到 >= 300 个正文标题（真机旧版为 0）",
    stats and (stats.detected_titles or 0) >= 300,
    "got " .. tostring(stats and stats.detected_titles))
check("用例1：发生重切分", stats and stats.resplit == true)
check("用例1：重切模式为「标题重切」",
    stats and stats.resplit_mode == "标题重切", tostring(stats and stats.resplit_mode))
check("用例1：诊断字段含 DOM HTML 样本",
    stats and type(stats.html_sample) == "string" and stats.html_sample:find("<p", 1, true) ~= nil)
check("用例1：章节数 >= 300（不再是 15 个硬切片）", count >= 300, "got " .. tostring(count))
check("用例1：转换在 10 秒内完成（CRC32 已优化）", elapsed < 10,
    string.format("elapsed=%.2fs", elapsed))

local nav = epub_entry(out, "OEBPS/nav.xhtml")
local ncx = epub_entry(out, "OEBPS/toc.ncx")
check("用例1：nav 含卷标题「第一卷　卷名之1」", nav:find("第一卷　卷名之1", 1, true) ~= nil)
check("用例1：nav 含首章「第1章　章节标题1」", nav:find("第1章　章节标题1", 1, true) ~= nil)
check("用例1：nav 含末章「第300章　章节标题100」", nav:find("第300章　章节标题100", 1, true) ~= nil)
check("用例1：nav 含节标题「第5节　细节展开」", nav:find("第5节　细节展开", 1, true) ~= nil)
check("用例1：nav 有多级嵌套 <ol>（>= 2 层）", count_occurrences(nav, "<ol>", true) >= 2,
    "got " .. count_occurrences(nav, "<ol>", true))
check("用例1：ncx 有 >= 300 个 navPoint", count_occurrences(ncx, "<navPoint", true) >= 300,
    "got " .. count_occurrences(ncx, "<navPoint", true))
check("用例1：目录里不再只剩单条书名", count_occurrences(nav, ">big_novel<", true) == 0)

local c1 = epub_entry(out, "OEBPS/chapter_0001.xhtml")
check("用例1：首章标题以 h1.chapter-title 排版",
    c1:find('<h1 class="chapter-title', 1, true) ~= nil
    and c1:find("第一卷　卷名之1", 1, true) ~= nil)
check("用例1：标题未在正文里以 <p> 重复",
    c1:find("<p>第一卷　卷名之1</p>", 1, true) == nil)
local max1, nchap1 = epub_max_chapter_size(out)
check("用例1：章节文件数 >= 300", nchap1 >= 300, "got " .. nchap1)
check("用例1：所有章节 XHTML < 300KB", max1 > 0 and max1 < 300 * 1024, "max=" .. max1)
check("用例1：EPUB 全部条目 CRC 正确", epub_valid(out))
check("用例1：stats.visible_chars 反映完整正文",
    stats and (stats.visible_chars or 0) > 100000,
    "got " .. tostring(stats and stats.visible_chars))

------------------------------------------------------------------------
-- 用例 2：中文全角标点后缀 + 正文不误判
------------------------------------------------------------------------
local punct_cases = {
    { "第1章：章节标题", true },
    { "第1章（上）", true },
    { "第一卷　卷名", true },
    { "番外　超长章节", true },
    { "第1章 章节标题", true },
    { "Chapter 1 Test", true },
}
for _, c in ipairs(punct_cases) do
    check("用例2：识别「" .. c[1] .. "」", Converter.is_chapter_title(c[1]) == c[2])
end
local not_titles = {
    "第二回的内容", "第一部门的工作", "这是第一章里提到的事",
    "第3章节选段落", "普通的正文一行",
}
for _, s in ipairs(not_titles) do
    check("用例2：不误判「" .. s .. "」", not Converter.is_chapter_title(s))
end

------------------------------------------------------------------------
-- 用例 3：第二层兜底 —— 无块级标签、<span> 包裹的单行 HTML
------------------------------------------------------------------------
local out3 = tmp .. "_span.epub"
local span_html = table.concat({
    "<div>",
    "<span>第一章　开端</span>", "<span>正文第一段，讲述故事的开始。</span>",
    "<span>第二章　发展</span>", "<span>正文第二段，情节逐渐推进。</span>",
    "<span>第三章　结局</span>", "<span>正文第三段，故事到此结束。</span>",
    "</div>",
}, "")
local doc3 = {
    title = "span_doc",
    toc = {},
    get_html = function() return span_html end,
    page_count = 1,
    get_page_xp = function(p) return "p" .. p end,
}
local ok3, count3, stats3 = Converter.build_epub_from_document(doc3, out3, { book_title = "span_doc" })
check("用例3：返回成功", ok3 == true)
check("用例3：识别到 >= 3 个标题", stats3 and (stats3.detected_titles or 0) >= 3,
    "got " .. tostring(stats3 and stats3.detected_titles))
check("用例3：触发「纯文本重建」兜底",
    stats3 and stats3.resplit_mode == "纯文本重建",
    tostring(stats3 and stats3.resplit_mode))
local nav3 = epub_entry(out3, "OEBPS/nav.xhtml")
check("用例3：nav 含「第一章　开端」", nav3:find("第一章　开端", 1, true) ~= nil)
check("用例3：nav 含「第三章　结局」", nav3:find("第三章　结局", 1, true) ~= nil)
check("用例3：正文未丢失（含正文第一段）",
    epub_entry(out3, "OEBPS/chapter_0001.xhtml"):find("正文第一段", 1, true) ~= nil)
check("用例3：EPUB 合法", epub_valid(out3))

------------------------------------------------------------------------
-- 用例 4：<br> 分段也能切块识别
------------------------------------------------------------------------
local out4 = tmp .. "_br.epub"
local br_html = table.concat({
    "第一章　开端<br/>", "正文第一段。<br/>",
    "第二章　发展<br/>", "正文第二段。<br/>",
    "第三章　结局<br/>", "正文第三段。<br/>",
}, "")
local doc4 = {
    title = "br_doc",
    toc = {},
    get_html = function() return br_html end,
    page_count = 1,
    get_page_xp = function(p) return "p" .. p end,
}
local ok4, count4, stats4 = Converter.build_epub_from_document(doc4, out4, { book_title = "br_doc" })
check("用例4：返回成功", ok4 == true)
check("用例4：<br> 分段下识别到 >= 3 个标题",
    stats4 and (stats4.detected_titles or 0) >= 3,
    "got " .. tostring(stats4 and stats4.detected_titles))
check("用例4：章节数 >= 3", count4 >= 3, "got " .. tostring(count4))
check("用例4：EPUB 合法", epub_valid(out4))

------------------------------------------------------------------------
print(string.format("\n==== test_dom_unicode 结果：%d 通过 / %d 失败 ====", passed, failed))
for _, p in ipairs({ out, out3, out4 }) do os.remove(p) end
if failed > 0 then os.exit(1) end
