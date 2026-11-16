-- verify_all_types.lua
-- 按「各类型」对生成的测试文件做一次全面端到端验证（v2.1.1 交付闸门）。
-- 覆盖：征集测试包 48 样本 + 大文件目录 + 本次真机复现的无样式/纯正文 .docx。
-- 逐文件生成 EPUB，校验：pcall 不抛错、返回 true、EPUB 存在、unzip -t 通过、
-- nav.xhtml / toc.ncx 目录条数、单章 XHTML < 300KB、章节数。
-- 双解释器运行（lua5.3 / luajit），输出 TSV 到 stdout 供汇总脚本消费。
-- 用法：lua5.3 test/fixtures/verify_all_types.lua > /tmp/alltypes_53.tsv
package.path = "/workspace/txt2epub.koplugin/?.lua;" .. package.path
local C = require("converter")

local ROOT = "/workspace/txt2epub_testfiles_v2.1.0"
local BIG  = "/workspace/测试文件"
local OUT  = "/tmp/t2e_alltypes"
os.execute("rm -rf " .. OUT .. " && mkdir -p " .. OUT)

----------------------------------------------------------------------
-- 纯 Lua 生成 STORED docx（本次真机复现用，自包含、不依赖外部 fixture）
----------------------------------------------------------------------
local function le16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function make_stored_docx(path, xml)
    local name, data = "word/document.xml", xml
    local lfh = string.char(0x50,0x4b,0x03,0x04) .. le16(20) .. le16(0) .. le16(0)
        .. le16(0) .. le16(0) .. le32(0) .. le32(#data) .. le32(#data)
        .. le16(#name) .. le16(0) .. name .. data
    local cd = string.char(0x50,0x4b,0x01,0x02) .. le16(20) .. le16(20) .. le16(0) .. le16(0)
        .. le16(0) .. le16(0) .. le32(0) .. le32(#data) .. le32(#data)
        .. le16(#name) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
        .. le32(0) .. le32(0) .. name
    local eocd = string.char(0x50,0x4b,0x05,0x06) .. le16(0) .. le16(0) .. le16(1) .. le16(1)
        .. le32(#cd) .. le32(#lfh) .. le16(0)
    local f = assert(io.open(path,"wb")); f:write(lfh,cd,eocd); f:close()
end
local function para(text, style)
    local pr = style and ('<w:pPr><w:pStyle w:val="'..style..'"/></w:pPr>') or ""
    return '<w:p>'..pr..'<w:r><w:t>'..text..'</w:t></w:r></w:p>'
end
-- 复现 A：无 Word 样式、正文含短标题（真机「共 9 章」场景）
local nostyle_paras = {}
nostyle_paras[#nostyle_paras+1] = para("真机复现小说")
for c = 1, 60 do
    nostyle_paras[#nostyle_paras+1] = para("第"..c.."章　章节标题")
    for k = 1, 4 do
        nostyle_paras[#nostyle_paras+1] = para("这是本章的正文段落用于验证转换完整无损，讲述故事内容。"..string.rep("填充内容ABC123。", 9))
    end
    if c % 10 == 0 then nostyle_paras[#nostyle_paras+1] = para(string.format("第%d节　小结", math.floor(c/10))) end
end
make_stored_docx("/tmp/t2e_repro_nostyle.docx",
    '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'..table.concat(nostyle_paras)..'</w:body></w:document>')
-- 复现 B：纯正文、零标题、超大（OOM 兜底场景）
local plain = {}
local line = "这是没有任何章节标题的纯正文用于验证超大章分片与内存有界。"..string.rep("内容填充ABC123。", 10)
for k = 1, 900 do plain[#plain+1] = para(line) end
make_stored_docx("/tmp/t2e_repro_plain.docx",
    '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'..table.concat(plain)..'</w:body></w:document>')

----------------------------------------------------------------------
-- 文件清单：{grp, fmt, path, label}
----------------------------------------------------------------------
local jobs = {}
-- A. 征集测试包：读 manifest.tsv
local mf = io.open(ROOT .. "/manifest.tsv", "r")
if mf then
    mf:read("*l")
    for line in mf:lines() do
        if line ~= "" then
            local t = {}
            for p in (line.."\t"):gmatch("([^\t]*)\t") do t[#t+1] = p end
            local rel, grp, fmt = t[1], t[2], t[3]
            if rel and fmt then
                jobs[#jobs+1] = { grp = grp, fmt = fmt, path = ROOT.."/"..rel, label = rel }
            end
        end
    end
    mf:close()
end
-- B. 大文件目录（真机同款 6 个）
local big_add = {
    { "big_novel.txt", "txt" }, { "big_novel.md", "md" }, { "big_novel.html", "html" },
    { "big_novel.docx", "docx-DEFLATE" }, { "big_novel_STORED.docx", "docx-STORED" },
}
for _, x in ipairs(big_add) do
    jobs[#jobs+1] = { grp = "大文件目录", fmt = x[2], path = BIG.."/"..x[1], label = x[1] }
end
-- C. 本次真机复现
jobs[#jobs+1] = { grp = "本次真机复现", fmt = "docx-STORED", path = "/tmp/t2e_repro_nostyle.docx", label = "repro_nostyle.docx" }
jobs[#jobs+1] = { grp = "本次真机复现", fmt = "docx-STORED", path = "/tmp/t2e_repro_plain.docx", label = "repro_plain.docx" }

----------------------------------------------------------------------
-- EPUB 校验工具
----------------------------------------------------------------------
local function sh(cmd)
    local p = io.popen(cmd); local s = p and p:read("*a") or ""; if p then p:close() end
    return (s:gsub("%s+", ""))
end
local function epub_check(out)
    local zipok = sh(string.format('unzip -t "%s" >/dev/null 2>&1; echo $?', out)) == "0"
    local nav = tonumber(sh(string.format('unzip -p "%s" OEBPS/nav.xhtml 2>/dev/null | grep -o "<li" | wc -l', out))) or 0
    local ncx = tonumber(sh(string.format('unzip -p "%s" OEBPS/toc.ncx 2>/dev/null | grep -o "<navPoint" | wc -l', out))) or 0
    -- 注意：awk 必须用单引号包住 $1，否则 shell 会把 $1 展开为空，
    -- 导致 maxchapter 恒为 0、「单章 < 300KB」校验形同虚设。
    local maxc = tonumber(sh("unzip -l \"" .. out .. "\" 2>/dev/null | grep OEBPS/chapter_ | awk '{print $1}' | sort -n | tail -1")) or 0
    return zipok, nav, ncx, maxc
end

----------------------------------------------------------------------
-- 主循环
----------------------------------------------------------------------
print("grp\tfmt\tlabel\tstatus\tchapters\tnav\tncx\tmaxchapter\tzip\tdiag\terr")
local tally = { OK = 0, SKIP_DOM = 0, FAIL = 0 }
for idx, j in ipairs(jobs) do
    local out = string.format("%s/%03d.epub", OUT, idx)
    os.remove(out)
    local book = (j.label:match("([^/]+)$") or "sample"):gsub("%.[^%.]+$", "")
    local fmt = j.fmt
    local status, chapters, err, diag = "SKIP_DOM", "0", "", ""

    local function run_txt()
        local it = C.lines(j.path)
        return C.build_epub_streaming(it, "title", nil, book, out, { indent = "2em" })
    end
    local function run_markup() return C.build_epub_from_markup(j.path, out, { book_title = book }) end
    local function run_docx()
        local d
        local a, b = C.build_epub_from_docx(j.path, out, { book_title = book }, {
            on_diag = function(r)
                d = string.format("wh=%d/tt=%d/rec=%s",
                    r.word_headings or -1, r.text_titles or -1, tostring(r.enabled))
            end })
        diag = d or ""
        return a, b
    end

    local selfparse = false
    local fn
    if fmt == "txt" or fmt:match("^txt%-") then fn = run_txt; selfparse = true
    elseif fmt == "md" or fmt == "markdown" or fmt == "html" or fmt == "htm" then fn = run_markup; selfparse = true
    elseif fmt == "docx-DEFLATE" or fmt == "docx-STORED" then fn = run_docx; selfparse = true
    elseif fmt == "docx-broken" then
        -- 畸形 docx：要求明确报错、不得抛未捕获异常
        local okR, D = pcall(require, "docx")
        if okR and D then
            local ok, doc, msg = pcall(D.read, j.path)
            if ok and doc == nil then status, chapters = "OK", "0"; diag = "明确报错"
            else status = "FAIL"; err = "畸形文件未按要求报错" end
        else status = "FAIL"; err = "docx 模块加载失败" end
    end

    if selfparse then
        local ok, a, b = pcall(fn)
        if ok then
            status = (a == true) and "OK" or "FAIL"
            chapters = tostring(b or 0)
            if a ~= true then err = tostring(b):gsub("[\r\n]"," "):sub(1,120) end
        else
            status = "FAIL"; err = tostring(a):gsub("[\r\n]"," "):sub(1,160)
        end
    end

    -- 校验生成物
    local nav, ncx, maxc, zipok = 0, 0, 0, false
    if status == "OK" and selfparse then
        local f = io.open(out, "rb")
        if f then local sz = f:seek("end"); f:close(); if not sz or sz == 0 then status = "FAIL"; err = "EPUB 为空" end
        else status = "FAIL"; err = "EPUB 未生成" end
        if status == "OK" then
            zipok, nav, ncx, maxc = epub_check(out)
            if not zipok then status = "FAIL"; err = "EPUB zip 校验失败" end
            if maxc >= 300 * 1024 then status = "FAIL"; err = "单章 XHTML >= 300KB" end
            if nav == 0 then status = "FAIL"; err = "nav 无目录条目" end
        end
    end

    tally[status] = (tally[status] or 0) + 1
    print(string.format("%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s",
        j.grp, fmt, j.label, status, chapters, nav, ncx, maxc,
        zipok and "OK" or "-", diag, err))
    -- 每个文件处理完立即释放该文件的解码临时文件（GBK/UTF-16 落盘产物）。
    -- Converter.lines() 对非 UTF-8 样本会在「源文件同目录」留下
    -- .txt2epub_decode.tmp，验证脚本若不调用 release_lines 就会污染样本目录，
    -- 甚至被误打包进征集测试包。用 pcall 守护，保证成功/失败路径都清理。
    pcall(C.release_lines, j.path)
end
io.stderr:write(string.format("\n=== 合计 %d 文件：OK %d / SKIP_DOM(仅真机) %d / FAIL %d ===\n",
    #jobs, tally.OK or 0, tally.SKIP_DOM or 0, tally.FAIL or 0))
