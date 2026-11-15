-- test/test_big_files.lua
-- 大文件压力测试：验证 v2.0.0 真机修复路径在「数 MB 文档」下的正确性与健壮性。
-- 运行：lua5.3 test/test_big_files.lua   （在插件根目录执行）
--
-- 覆盖：
--   1) 大 DEFLATE .docx：inflate.lua 解压 2.69MB document.xml（含 32KB 回溯窗口）、
--      6960 段落解析、多级目录、超大章 256KB 自动切分；
--   2) 大 STORED .docx 对照：结果必须与 DEFLATE 版逐项一致；
--   3) 大 .doc（OLE2）：插件走「通用 DOM 兜底」，沙箱无 KOReader 引擎，
--      故用【模拟 doc_api 灌入等价大内容】测试该路径真实代码
--      （build_epub_from_document）的大章节切分 / 空书体检 / 内存有界。
--   4) 全程监控内存与耗时，防止 OOM 退化。

local plugin_dir = arg and arg[0] and arg[0]:match("(.*/)") or "./"
if plugin_dir == "" then plugin_dir = "./" end
package.path = package.path .. ";" .. plugin_dir .. "?.lua" .. ";" .. plugin_dir .. "../?.lua"
package.path = package.path .. ";./?.lua"

local Converter = require("converter")
local DocxReader = require("docx")

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then passed = passed + 1; print("[PASS] " .. name)
    else failed = failed + 1; print("[FAIL] " .. name .. "  " .. (extra or "")) end
end
local function fixture(n) return plugin_dir .. "fixtures/" .. n end
local function mem_mb() return collectgarbage("count") / 1024 end

-- 读取 meta 里的期望值
local function read_meta()
    local f = io.open(fixture("big_files.meta"), "r")
    if not f then return {} end
    local t = {}
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(%d+)$")
        if k then t[k] = tonumber(v) end
    end
    f:close()
    return t
end

local meta = read_meta()
print(string.format("== 大文件指标：document.xml %d 字节，正文段落 %d ==",
    meta.xml_bytes or 0, meta.paragraphs or 0))

------------------------------------------------------------------------
-- 1) 大 DEFLATE .docx：DocxReader 读取
------------------------------------------------------------------------
print("\n---- [1] 大 DEFLATE docx 读取 ----")
collectgarbage("collect")
local m0 = mem_mb()
local t0 = os.clock()
local doc, derr = DocxReader.read(fixture("big_novel.docx"))
local read_dt = os.clock() - t0
local read_mem = mem_mb() - m0
check("读取大 DEFLATE docx 成功", doc ~= nil, tostring(derr))
check("解压未触发 zlib（走 inflate.lua）", DocxReader._inflate ~= false)
if doc then
    check("书名 = 大文件压力测试小说", doc.title == "大文件压力测试小说", tostring(doc.title))
    -- 6960 正文段 + 标题段（1 Title + 3 卷 + 300 章 + 60 节 + 1 番外 = 365 标题）
    local nheads = 0
    for _, p in ipairs(doc.paragraphs) do if p.kind == "heading" then nheads = nheads + 1 end end
    print(string.format("    段落总数 %d，其中标题 %d，正文 %d", #doc.paragraphs, nheads, #doc.paragraphs - nheads))
    check("段落总数 > 7000", #doc.paragraphs > 7000, tostring(#doc.paragraphs))
    check("含多级标题（Heading2 层级 2）", (function()
        for _, p in ipairs(doc.paragraphs) do if p.kind == "heading" and p.level == 2 then return true end end
        return false
    end)())
    check("正文含省略的特殊字符已解码（& < >）", (function()
        for _, p in ipairs(doc.paragraphs) do
            if p.kind == "body" and p.text:find("&") and p.text:find("<标签>") then return true end
        end
        return false
    end)())
    check("超大章存在（番外）", (function()
        for _, p in ipairs(doc.paragraphs) do
            if p.kind == "heading" and p.text:find("超长章节") then return true end
        end
        return false
    end)())
end
print(string.format("    读取耗时 %.2fs，内存增量 %.2f MB", read_dt, read_mem))
check("读取耗时 < 30s", read_dt < 30, string.format("%.2fs", read_dt))
check("读取内存增量 < 120 MB（内存有界）", read_mem < 120, string.format("%.2f MB", read_mem))

------------------------------------------------------------------------
-- 2) 大 DEFLATE .docx：端到端生成 EPUB
------------------------------------------------------------------------
print("\n---- [2] 大 DEFLATE docx 端到端生成 EPUB ----")
local out = "/tmp/test_big_novel.epub"
os.remove(out)
collectgarbage("collect")
local m1 = mem_mb()
local t1 = os.clock()
local bok, build_ok, cnt = pcall(Converter.build_epub_from_docx, fixture("big_novel.docx"), out, {
    indent = "2em", style = "standard", book_title = "大文件压力测试小说",
})
local build_dt = os.clock() - t1
local build_mem = mem_mb() - m1
-- pcall 第 1 个返回值只代表「没抛异常」，第 2 个才是 build_epub_from_docx 的 ok，
-- 两者都要查，否则函数返回 false,err（非抛错）时测试会假通过。
check("端到端生成 EPUB 成功", bok and build_ok == true, tostring(cnt))
print(string.format("    章节文件数 %s，耗时 %.2fs，内存增量 %.2f MB", tostring(cnt), build_dt, build_mem))
check("生成耗时 < 60s", build_dt < 60, string.format("%.2fs", build_dt))
check("生成内存增量 < 150 MB（内存有界）", build_mem < 150, string.format("%.2f MB", build_mem))

if bok then
    local epub_sz = (function() local f=io.open(out,"rb"); if not f then return 0 end; local s=f:seek("end"); f:close(); return s end)()
    print(string.format("    输出 EPUB 大小 %.2f MB", epub_sz / 1048576))
    check("输出 EPUB 非空（> 1MB）", epub_sz > 1048576, tostring(epub_sz))

    local tmp = "/tmp/test_big_epub_unzip"
    os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
    os.execute("cd " .. tmp .. " && unzip -o -q " .. out .. " >/dev/null 2>&1")

    -- nav.xhtml：多级目录 + 大量条目
    local nav = io.open(tmp .. "/OEBPS/nav.xhtml", "r")
    if nav then
        local s = nav:read("*a"); nav:close()
        local _, links = s:gsub('href="chapter_', "")
        print(string.format("    nav 目录链接数 %d", links))
        check("nav 含 300+ 章节链接", links >= 300, tostring(links))
        check("nav 含嵌套 <ol>（多级目录）", s:find("<ol>.-<ol>", 1, false) ~= nil or
            s:find("<ol", 1, true) ~= nil and s:find("</ol>.-</ol>", 1, false) ~= nil)
        check("nav 含「第1章」与「番外」", s:find("第1章") ~= nil and s:find("番外") ~= nil)
    else
        check("nav.xhtml 存在", false)
    end

    -- 超大章切分：番外章 >256KB 应被切成多个分片文件
    local p = io.popen("ls " .. tmp .. "/OEBPS/chapter_*.xhtml 2>/dev/null | wc -l")
    local nfiles = tonumber(p:read("*a"):match("%d+") or "0"); p:close()
    print(string.format("    章节 XHTML 文件数 %d", nfiles))
    check("章节文件数 > 350（含超大章切分的续篇）", nfiles > 350, tostring(nfiles))

    -- 抽查正文：chapter_0001 是「第一卷」纯标题章（卷标题后紧跟章标题，无正文，符合预期），
    -- 故改为校验 chapter_0002（首个正文章）确有完整 <p> 正文；并统计含正文的章节文件数。
    local ch = io.open(tmp .. "/OEBPS/chapter_0002.xhtml", "r")
    local body_ok = false
    if ch then
        local s = ch:read("*a"); ch:close()
        body_ok = s:find("<p>") ~= nil and #s > 500
    end
    check("首个正文章含完整 <p> 段落（非空书）", body_ok)
    local pb = io.popen("grep -l '<p>' " .. tmp .. "/OEBPS/chapter_*.xhtml 2>/dev/null | wc -l")
    local n_with_body = tonumber(pb:read("*a"):match("%d+") or "0"); pb:close()
    print(string.format("    含正文的章节文件数 %d / %d", n_with_body, nfiles))
    check("绝大多数章节含正文（> 350 个）", n_with_body > 350, tostring(n_with_body))

    -- 校验所有 chapter 分片都不超过 ~256KB（切分生效）
    local p2 = io.popen("ls -l " .. tmp .. "/OEBPS/chapter_*.xhtml 2>/dev/null | awk '{print $5}' | sort -rn | head -1")
    local maxsz = tonumber(p2:read("*a"):match("%d+") or "0"); p2:close()
    print(string.format("    最大章节文件 %d 字节", maxsz))
    check("单章 XHTML 未超 300KB（切分生效）", maxsz < 300 * 1024, tostring(maxsz))
end

------------------------------------------------------------------------
-- 3) 大 STORED .docx 对照：与 DEFLATE 版逐段一致
------------------------------------------------------------------------
print("\n---- [3] 大 STORED docx 对照 ----")
local doc2, derr2 = DocxReader.read(fixture("big_novel_STORED.docx"))
check("读取大 STORED docx 成功", doc2 ~= nil, tostring(derr2))
if doc and doc2 then
    check("STORED 与 DEFLATE 段落数一致", #doc.paragraphs == #doc2.paragraphs,
        tostring(#doc.paragraphs) .. " vs " .. tostring(#doc2.paragraphs))
    local same = true
    local n = math.min(#doc.paragraphs, #doc2.paragraphs)
    for i = 1, n do
        local a, b = doc.paragraphs[i], doc2.paragraphs[i]
        if a.kind ~= b.kind or a.level ~= b.level or a.text ~= b.text then same = false; break end
    end
    check("STORED 与 DEFLATE 逐段完全一致（7000+ 段）", same)
    local out2 = "/tmp/test_big_novel_stored.epub"
    os.remove(out2)
    local sok, sbuild_ok, scnt = pcall(Converter.build_epub_from_docx, fixture("big_novel_STORED.docx"), out2,
        { indent = "2em", style = "standard", book_title = "大文件压力测试小说" })
    check("STORED 端到端生成 EPUB", sok and sbuild_ok == true, tostring(scnt))
    if sok then
        check("STORED 与 DEFLATE 章节数一致", scnt == cnt, tostring(scnt) .. " vs " .. tostring(cnt))
    end
end

------------------------------------------------------------------------
-- 4) 大 .doc 走「通用 DOM 兜底」：用模拟 doc_api 测该路径真实代码
--    说明：真正 .doc 是 OLE2 二进制，插件不解析它，而是读取 KOReader
--    已打开文档的 getToc()/getHTMLFromXPointers()；沙箱无 KOReader 引擎，
--    无法端到端。此处灌入等价「大文档」验证 build_epub_from_document 的
--    大章节切分、空书体检、内存有界。
------------------------------------------------------------------------
print("\n---- [4] 大 .doc 路径（DOM 兜底）：模拟 doc_api 灌入大内容 ----")
-- 真实接口（见 main.lua:_build_doc_api）：
--   doc_api.toc = { {text, depth, pos0, pos1}, ... }
--   doc_api.get_html(pos0, pos1) -> 该区间的渲染 HTML 字符串
-- 用 pos0 = "xp_<章号>" 编码章号；get_html 依章号返回内容。
local big_html_parts = {}
for i = 1, 4000 do
    big_html_parts[i] = "<p>" .. i .. "　" .. string.rep("正文内容ABC123", 12) .. "</p>"
end
local big_html = table.concat(big_html_parts)
local small_html = "<p>该章正文段落，含有可见文字内容。</p>"
local fake_toc = {}
for i = 1, 300 do
    fake_toc[i] = { text = "第" .. i .. "章 章节标题", depth = 1,
                    pos0 = "xp_" .. i, pos1 = (i == 300) and "xp_end" or nil }
end
local doc_api = {
    title = "大文件DOM测试",
    toc = fake_toc,
    get_html = function(pos0, pos1)
        local idx = tonumber(tostring(pos0):match("xp_(%d+)"))
        if idx == 300 then return big_html end           -- 超大章，触发 256KB 切分
        return small_html
    end,
}
local out3 = "/tmp/test_big_doc_dom.epub"
os.remove(out3)
collectgarbage("collect")
local m3 = mem_mb()
local t3 = os.clock()
-- 注意 pcall 的返回布局：status, build_ok, #toc_meta, stats
-- 故 dres 实为 build_ok（布尔）、dcnt 为章节数、dstats 为统计表。
local dok, dres, dcnt, dstats = pcall(Converter.build_epub_from_document, doc_api, out3,
    { book_title = "大文件DOM测试" })
local ddt = os.clock() - t3
local dmem = mem_mb() - m3
check("DOM 兜底大内容生成 EPUB 不 panic", dok and dres == true, tostring(dres))
print(string.format("    章节文件数 %s，耗时 %.2fs，内存增量 %.2f MB", tostring(dcnt), ddt, dmem))
check("DOM 兜底耗时 < 30s", ddt < 30, string.format("%.2fs", ddt))
check("DOM 兜底内存增量 < 120 MB", dmem < 120, string.format("%.2f MB", dmem))
if dok and dstats then
    print(string.format("    stats: 章节 %d, 目录 %d, 可见字符 %d, empty=%s",
        dstats.chapter_count or -1, dstats.toc_entries or -1, dstats.visible_chars or -1,
        tostring(dstats.empty)))
    check("大内容不被误判为空书（empty=false）", dstats.empty == false, tostring(dstats.empty))
    check("可见字符数 > 100000", (dstats.visible_chars or 0) > 100000, tostring(dstats.visible_chars))
    check("超大章被切成多个分片（章节文件数 > 300）", (dcnt or 0) > 300, tostring(dcnt))
    -- 校验分片不超限
    local tmp3 = "/tmp/test_big_doc_dom_unzip"
    os.execute("rm -rf " .. tmp3 .. " && mkdir -p " .. tmp3)
    os.execute("cd " .. tmp3 .. " && unzip -o -q " .. out3 .. " >/dev/null 2>&1")
    local p3 = io.popen("ls -l " .. tmp3 .. "/OEBPS/chapter_*.xhtml 2>/dev/null | awk '{print $5}' | sort -rn | head -1")
    local dmax = tonumber(p3:read("*a"):match("%d+") or "0"); p3:close()
    print(string.format("    DOM 路径最大章节文件 %d 字节", dmax))
    check("DOM 路径单章未超 300KB（切分生效）", dmax < 300 * 1024, tostring(dmax))
end

-- 空书体检：极小内容应被标记 empty
local empty_api = {
    toc = { { text = "标题", depth = 1, pos0 = "xp_1" } },
    get_html = function() return "" end,
}
os.remove("/tmp/test_empty_dom.epub")
local eok, _, _, estats = pcall(Converter.build_epub_from_document, empty_api,
    "/tmp/test_empty_dom.epub", { book_title = "空" })
check("空书体检能识别空内容（empty=true）", eok and estats and estats.empty == true,
    estats and tostring(estats.empty) or tostring(estats))

------------------------------------------------------------------------
print(string.format("\n=== 大文件测试：%d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
