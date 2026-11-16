-- test_docx_notoc.lua
-- 真机日志（2026-11-15 17:17:12 / 16:52:33，big_novel_STORED.docx）回归锁定：
--   「EPUB 生成成功（Word），共 9 章」但目录不全；更早一次 16:52 转换后
--   crash.log 只有 Killed（内核 OOM killer），KOReader 直接退出。
--
-- 根因：设备上那份 .docx 的 Word 标题样式（w:pStyle / outlineLvl）丢失或
-- 未被识别，DocxReader 得到 heading=0。旧流水线的两个缺陷同时爆发：
--   (a) build_epub_from_paragraphs 的 emit 先 table.concat 出整章 2.2MB
--       大字符串，叠加 KOReader 已打开的 docx DOM -> OOM Killed；
--   (b) 6960 个正文段全聚成 1 个大章，按 256KB 硬切成 9 片，且
--       toc=(part==1) 只让首片进目录 -> nav/ncx 仅 1 条，目录严重不全。
--
-- 修复：
--   1) emit 改为「先按累计字节估算、超限直接分片逐片写盘」，绝不拼整串；
--      每个分片都进目录。
--   2) 新增 recover_docx_headings：Word 样式标题缺失时，从正文「短段 +
--      命中 chapterTitle 规则」恢复章节标题（复用 .txt/DOM 路径规则），
--      生成完整多级目录。标准 Word 样式文档不受影响。
--
-- 全部样本自包含生成（纯 Lua 写 STORED docx），Lua 5.3 / LuaJIT 均可跑。
-- 用法：lua5.3 test/test_docx_notoc.lua  /  luajit test/test_docx_notoc.lua

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path

local DocxReader = require("docx")
local Converter = require("converter")

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print(string.format("[PASS] %s", name))
    else fails = fails + 1; print(string.format("[FAIL] %s  %s", name, extra or "")) end
end

----------------------------------------------------------------------
-- 纯 Lua 生成 STORED 版 .docx（DocxReader 不校验 CRC）
----------------------------------------------------------------------
local function le16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function make_stored_docx(path, xml)
    local name = "word/document.xml"
    local data = xml
    local lfh = string.char(0x50, 0x4b, 0x03, 0x04)
        .. le16(20) .. le16(0) .. le16(0)
        .. le16(0) .. le16(0)
        .. le32(0) .. le32(#data) .. le32(#data)
        .. le16(#name) .. le16(0) .. name .. data
    local cd = string.char(0x50, 0x4b, 0x01, 0x02)
        .. le16(20) .. le16(20) .. le16(0) .. le16(0)
        .. le16(0) .. le16(0)
        .. le32(0) .. le32(#data) .. le32(#data)
        .. le16(#name) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
        .. le32(0) .. le32(0) .. name
    local eocd = string.char(0x50, 0x4b, 0x05, 0x06)
        .. le16(0) .. le16(0) .. le16(1) .. le16(1)
        .. le32(#cd) .. le32(#lfh) .. le16(0)
    local f = assert(io.open(path, "wb")); f:write(lfh, cd, eocd); f:close()
end

local function esc(s)  -- 样本仅含中文/数字/空格/全角空格，保守转义几个实体
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
-- style: nil=无样式(纯正文段) / "Title" / "Heading1" / "Heading2" / "Heading3"
local function para(text, style)
    local pr = style and ('<w:pPr><w:pStyle w:val="' .. style .. '"/></w:pPr>') or ""
    return '<w:p>' .. pr .. '<w:r><w:t>' .. esc(text) .. '</w:t></w:r></w:p>'
end
local function build_xml(paras)
    return '<?xml version="1.0" encoding="UTF-8"?>'
        .. '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
        .. table.concat(paras) .. '</w:body></w:document>'
end

-- 构造「同一本书」的两种写法：无样式版（标题只是普通短段落）与标准样式版
local BODY_MARK = "这是本章的正文段落，用于验证转换后正文完整无损，讲述故事里发生的大小事件与人物对话。"
local function book_paras(with_style, n_chapters)
    local P = {}
    P[#P + 1] = para("压力测试小说", with_style and "Title" or nil)  -- 书名段
    for v = 1, 1 do
        P[#P + 1] = para("第一卷　少年时", with_style and "Heading1" or nil)
        for c = 1, (n_chapters or 12) do
            P[#P + 1] = para("第" .. c .. "章　剑起青云", with_style and "Heading2" or nil)
            for k = 1, 3 do
                P[#P + 1] = para(BODY_MARK .. c .. "-" .. k .. " " .. string.rep("填充内容。", 6))
            end
            if c % 4 == 0 then
                -- 用整数字符串：Lua 5.3 的 / 产生浮点，"第1.0节" 会被
                -- isNumberToken 判为非法编号而漏识别（LuaJIT 打印为 1）。
                P[#P + 1] = para(string.format("第%d节　小结", math.floor(c / 4)),
                                 with_style and "Heading3" or nil)
                P[#P + 1] = para(BODY_MARK .. " 节正文")
            end
        end
    end
    return P
end

local function unzip_text(epub, entry)
    local p = io.popen(string.format('unzip -p "%s" "%s" 2>/dev/null', epub, entry))
    local s = p and p:read("*a") or ""; if p then p:close() end
    return s
end
local function count_occ(s, pat, plain)
    local n = 0; local i = 1
    while true do
        local a = s:find(pat, i, plain); if not a then break end
        n = n + 1; i = a + 1
    end
    return n
end
local function max_chapter_size(epub)
    local p = io.popen(string.format('unzip -l "%s" 2>/dev/null | grep "OEBPS/chapter_" | awk "{print $1}" | sort -n | tail -1', epub))
    local v = tonumber(p and p:read("*a"):match("%d+") or "0"); if p then p:close() end
    return v or 0
end
local function zip_ok(epub)
    local p = io.popen(string.format('unzip -t "%s" >/dev/null 2>&1; echo $?', epub))
    local v = p and p:read("*a"):gsub("%s+", "") or "1"; if p then p:close() end
    return v == "0"
end

----------------------------------------------------------------------
-- [1] recover_docx_headings 纯函数
----------------------------------------------------------------------
print("\n---- [1] 标题恢复纯函数 ----")
-- 1a 标准 Word 样式：不触发兜底
do
    local ps = DocxReader.parse_document_xml(build_xml(book_paras(true, 8)))
    local _, st = Converter.recover_docx_headings(ps)
    check("标准样式文档：兜底未启用（保证既有行为不变）", st.enabled == false, tostring(st.enabled))
    check("标准样式文档：mode=word-style", st.mode == "word-style", tostring(st.mode))
    check("标准样式文档：样式标题数 > 0", st.word_headings > 0, tostring(st.word_headings))
end
-- 1b 无样式：从正文文本恢复
do
    local ps = DocxReader.parse_document_xml(build_xml(book_paras(false, 12)))
    local h0 = 0; for _, p in ipairs(ps) do if p.kind == "heading" then h0 = h0 + 1 end end
    check("无样式文档：解析后 heading=0（复现真机）", h0 == 0, tostring(h0))
    local ps2, st = Converter.recover_docx_headings(ps)
    check("无样式文档：兜底启用", st.enabled == true, tostring(st.enabled))
    check("无样式文档：mode=text-only", st.mode == "text-only", tostring(st.mode))
    check("无样式文档：文本候选标题 >= 10", st.text_titles >= 10, tostring(st.text_titles))
    check("无样式文档：提升数 == 候选数", st.promoted == st.text_titles,
        st.promoted .. "/" .. st.text_titles)
    local h1 = 0; for _, p in ipairs(ps2) do if p.kind == "heading" then h1 = h1 + 1 end end
    check("无样式文档：恢复后 heading 数 == 提升数", h1 == st.promoted, tostring(h1))
end
-- 1c 层级：卷 / 章 / 节 用 title_level 正确分级
do
    local ps = DocxReader.parse_document_xml(build_xml({
        para("第一卷　卷名"), para("第1章　章名"), para("第1节　节名"),
        para("第2章　章名"), para("第3章　章名"),
    }))
    local ps2 = Converter.recover_docx_headings(ps)
    local lv = {}
    for _, p in ipairs(ps2) do if p.kind == "heading" then lv[#lv + 1] = p.level end end
    check("层级：卷=0", lv[1] == 0, tostring(lv[1]))
    check("层级：章=1", lv[2] == 1 and lv[4] == 1, tostring(lv[2]) .. "," .. tostring(lv[4]))
    check("层级：节=2", lv[3] == 2, tostring(lv[3]))
end
-- 1d 全角空格 / 中文标点标题均可识别
do
    local ps = DocxReader.parse_document_xml(build_xml({
        para("第1章　全角空格标题"), para("第2章：中文冒号标题"),
        para("第3章（上）括号标题"), para("第4章 半角空格标题"),
    }))
    local _, st = Converter.recover_docx_headings(ps)
    check("全角空格/冒号/括号/半角 4 种标题全部识别", st.text_titles == 4, tostring(st.text_titles))
end
-- 1e 长正文段不被误判为标题（>80 字节保护）
do
    local longs = {}
    for k = 1, 5 do
        longs[#longs + 1] = para("第" .. k .. "章　" .. string.rep("这是一段很长的正文内容用于验证短段保护。", 8))
    end
    -- 再加 4 个真正的短标题，确保「候选>=3」的门槛本身是满足的
    for k = 1, 4 do longs[#longs + 1] = para("第" .. (10 + k) .. "章　短标题") end
    local ps = DocxReader.parse_document_xml(build_xml(longs))
    local _, st = Converter.recover_docx_headings(ps)
    check("长正文段(>80字节)不被误判：仅 4 个短标题计入", st.text_titles == 4, tostring(st.text_titles))
end
-- 1f 标题候选不足 3 个不触发
do
    local ps = DocxReader.parse_document_xml(build_xml({
        para("第1章　唯一标题"), para(BODY_MARK), para(BODY_MARK),
    }))
    local _, st = Converter.recover_docx_headings(ps)
    check("候选 < 3 不触发兜底", st.enabled == false, tostring(st.enabled) .. " cand=" .. st.text_titles)
end
-- 1g 显式关闭开关
do
    local ps = DocxReader.parse_document_xml(build_xml(book_paras(false, 6)))
    local _, st = Converter.recover_docx_headings(ps, { no_title_recovery = true })
    check("opts.no_title_recovery=true 时强制不恢复", st.enabled == false, tostring(st.enabled))
end
-- 1h 空输入安全
do
    local ok, res = pcall(Converter.recover_docx_headings, {})
    check("空 paragraphs 不抛错", ok and type(res) == "table")
end

----------------------------------------------------------------------
-- [2] 端到端：无样式 docx 生成完整多级目录（真机「共 9 章」场景）
----------------------------------------------------------------------
print("\n---- [2] 端到端：无样式 docx 目录修复 ----")
local no_style_path = "/tmp/t2e_notoc_nostyle.docx"
local with_style_path = "/tmp/t2e_notoc_styled.docx"
make_stored_docx(no_style_path, build_xml(book_paras(false, 12)))
make_stored_docx(with_style_path, build_xml(book_paras(true, 12)))
local out_ns = "/tmp/t2e_notoc_nostyle.epub"
local out_ws = "/tmp/t2e_notoc_styled.epub"
os.remove(out_ns); os.remove(out_ws)

local diag_ns
local ok_ns, n_ns, st_ns = Converter.build_epub_from_docx(no_style_path, out_ns,
    { book_title = "压力测试小说" }, { on_diag = function(r) diag_ns = r end })
check("无样式 docx 转换成功", ok_ns == true, tostring(ok_ns))
check("无样式 docx 诊断回调已触发", diag_ns ~= nil)
check("无样式 docx 诊断：兜底已启用", diag_ns and diag_ns.enabled == true)
local ok_ws, n_ws = Converter.build_epub_from_docx(with_style_path, out_ws,
    { book_title = "压力测试小说" })
check("标准样式 docx 转换成功", ok_ws == true, tostring(ok_ws))
check("无样式版章节数 == 标准样式版（结果等价）", n_ns == n_ws,
    tostring(n_ns) .. " vs " .. tostring(n_ws))
check("无样式版章节数 >= 15（含 12 章 + 3 节 + 卷 + 书名）", (n_ns or 0) >= 15, tostring(n_ns))
check("无样式版不再是 9 个硬切片", (n_ns or 0) > 9, tostring(n_ns))

local nav_ns = unzip_text(out_ns, "OEBPS/nav.xhtml")
local ncx_ns = unzip_text(out_ns, "OEBPS/toc.ncx")
check("nav 含卷标题「第一卷」", nav_ns:find("第一卷", 1, true) ~= nil)
check("nav 含章标题「第1章」", nav_ns:find("第1章", 1, true) ~= nil)
check("nav 含节标题「第1节」", nav_ns:find("第1节", 1, true) ~= nil)
check("nav 目录条目数 == 章节数（分片/章节全进目录）",
    count_occ(nav_ns, "<li", true) == n_ns, tostring(count_occ(nav_ns, "<li", true)) .. "/" .. tostring(n_ns))
check("ncx navPoint 数 == 章节数",
    count_occ(ncx_ns, "<navPoint", true) == n_ns, tostring(count_occ(ncx_ns, "<navPoint", true)))
check("生成 nav 存在多级嵌套 <ol>", count_occ(nav_ns, "<ol", true) >= 2,
    tostring(count_occ(nav_ns, "<ol", true)))
check("EPUB zip 校验通过", zip_ok(out_ns))
check("单章 XHTML < 300KB", max_chapter_size(out_ns) > 0 and max_chapter_size(out_ns) < 300 * 1024,
    tostring(max_chapter_size(out_ns)))
-- 正文完整性：任意抽一章，正文标记应存在
local c1 = unzip_text(out_ns, "OEBPS/chapter_0002.xhtml")
check("正文完整无损（BODY_MARK 出现在章节中）", c1:find("验证转换后正文完整无损", 1, true) ~= nil)
check("章节标题以 h1 排版", c1:find('class="chapter-title', 1, true) ~= nil)
check("stats.recovery 存在且 enabled", st_ns and st_ns.recovery and st_ns.recovery.enabled == true)

----------------------------------------------------------------------
-- [3] 端到端：纯正文零标题大 docx —— OOM 兜底 + 分片全进目录
----------------------------------------------------------------------
print("\n---- [3] 端到端：纯正文大 docx（OOM 兜底）----")
local big_paras = {}
local big_line = "这是没有任何章节标题的纯正文，用于验证超大章按字节分片且所有分片进入目录、不产生 2.2MB 整串。" .. string.rep("内容填充ABC123。", 8)
for k = 1, 1200 do big_paras[#big_paras + 1] = para(big_line) end
local big_path = "/tmp/t2e_notoc_bigplain.docx"
make_stored_docx(big_path, build_xml(big_paras))
local out_big = "/tmp/t2e_notoc_bigplain.epub"; os.remove(out_big)
local diag_big
local ok_big, n_big, st_big = Converter.build_epub_from_docx(big_path, out_big,
    { book_title = "纯正文大书" }, { on_diag = function(r) diag_big = r end })
check("纯正文大 docx 转换不 panic", ok_big == true, tostring(ok_big))
check("纯正文大 docx 未误触标题兜底", diag_big and diag_big.enabled == false,
    diag_big and tostring(diag_big.enabled) or "nil")
check("纯正文大 docx 分片数 > 1", (n_big or 0) > 1, tostring(n_big))
check("纯正文大 docx 分片数 == split_parts", st_big and st_big.split_parts == n_big,
    tostring(st_big and st_big.split_parts))
local nav_big = unzip_text(out_big, "OEBPS/nav.xhtml")
check("所有分片都进目录（nav 条目数 == 分片数，不再是 1 条）",
    count_occ(nav_big, "<li", true) == n_big, tostring(count_occ(nav_big, "<li", true)) .. "/" .. tostring(n_big))
check("纯正文大 docx 单章 < 300KB（未拼 2.2MB 整串）",
    max_chapter_size(out_big) > 0 and max_chapter_size(out_big) < 300 * 1024,
    tostring(max_chapter_size(out_big)))
check("纯正文大 docx zip 校验通过", zip_ok(out_big))

----------------------------------------------------------------------
-- [4] 回归护栏：标准样式文档的输出不被改变
----------------------------------------------------------------------
print("\n---- [4] 标准样式文档护栏 ----")
local nav_ws = unzip_text(out_ws, "OEBPS/nav.xhtml")
check("标准样式版 nav 仍含多级标题", nav_ws:find("第一卷", 1, true) ~= nil
    and nav_ws:find("第1章", 1, true) ~= nil and nav_ws:find("第1节", 1, true) ~= nil)
check("标准样式版 nav 条目数 == 章节数", count_occ(nav_ws, "<li", true) == n_ws,
    tostring(count_occ(nav_ws, "<li", true)))
check("标准样式版 zip 校验通过", zip_ok(out_ws))

-- 清理
for _, p in ipairs({ no_style_path, with_style_path, big_path, out_ns, out_ws, out_big }) do
    os.remove(p)
end

print(string.format("\n=== test_docx_notoc：%d 通过, %d 失败 ===", passes, fails))
if fails > 0 then os.exit(1) end
