-- test/test_fixes_v217.lua
-- v2.1.7 真机第五轮反馈修复的回归测试：
--   1) inflate.raw_stream 与 raw 逐字节一致（含消费者中止路径）
--   2) docx 流式「解压即解析」与旧 parse_document_xml 逐段完全一致
--      修复根因：旧做法瞬时峰值 ~10MB heap / 18MB RSS（2.8MB 全文 + 7000+ 段落表
--      同时驻留），叠加真机 28-30MB 基线堆触发 OOM Killed；流式后单次最大分配仅 32KB。
--   3) 真实 big_novel.docx 端到端：流式读取段落完整 + 生成 EPUB 章节/目录正确
-- 用法：lua5.3 / luajit test/test_fixes_v217.lua

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then pass = pass + 1
    else fail = fail + 1; print("[FAIL] " .. name .. "  got=" .. tostring(got)) end
end

local HERE = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = HERE .. "?.lua;" .. package.path

local I = require("inflate")
local D = require("docx")
local C = require("converter")

local fixture_dir = HERE .. "fixtures"
local function readfile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end

----------------------------------------------------------------------
-- 1) raw_stream 与 raw 一致
----------------------------------------------------------------------
for _, name in ipairs({ "short.deflate", "doc_xml.deflate", "big.deflate" }) do
    local comp = readfile(fixture_dir .. "/inflate_cases/" .. name)
    if comp then
        local full = I.raw(comp)
        check("inflate fixture 可解压: " .. name, full ~= nil)
        if full then
            local parts = {}
            local ok, err = I.raw_stream(comp, #full, function(s) parts[#parts+1] = s; return true end)
            check("raw_stream 成功: " .. name, ok == true, err)
            check("raw_stream 与 raw 逐字节一致: " .. name,
                table.concat(parts) == full, (#parts .. " 块"))
        end
    end
end
-- 消费者中止：sink 返回 false 应立即停止
do
    local comp = readfile(fixture_dir .. "/inflate_cases/big.deflate")
    if comp then
        local chunks = 0
        local ok, err = I.raw_stream(comp, nil, function(s) chunks = chunks + 1; return false end)
        check("raw_stream 消费者中止生效", chunks <= 2 and ok ~= true,
            ("chunks=" .. chunks .. " err=" .. tostring(err)))
    end
end
-- 流式与一次性在 expected_size 校验上行为一致（错误大小都拒绝）
do
    local comp = readfile(fixture_dir .. "/inflate_cases/short.deflate")
    if comp then
        local parts = {}
        local ok, err = I.raw_stream(comp, 999, function(s) parts[#parts+1]=s; return true end)
        check("raw_stream 大小不符被拒绝", ok ~= true and type(err) == "string", tostring(err))
    end
end

----------------------------------------------------------------------
-- 2) 真实 big_novel.docx：流式读取 vs 全文解析 逐段一致
----------------------------------------------------------------------
local big_path = fixture_dir .. "/big_novel.docx"
if readfile(big_path) then
    -- 捕获 inflate 输出拼成全文，用于对照旧 parse_document_xml
    local fullxml
    local capture_inflate = {
        raw = I.raw,
        raw_stream = function(comp, expected, sink)
            local r, e = I.raw(comp, expected)
            if not r then return nil, e end
            fullxml = r
            sink(r)
            return true
        end,
    }
    local saved_inflate = D._inflate
    D._inflate = capture_inflate
    local doc, derr = D.read(big_path)
    D._inflate = saved_inflate
    check("big_novel 流式读取成功", doc ~= nil, derr)
    if doc and fullxml then
        local old_paras = D.parse_document_xml(fullxml)
        local new_paras = doc.paragraphs
        check("big_novel 段落数一致(流式 vs 全文)", #new_paras == #old_paras,
            (#new_paras .. " vs " .. #old_paras))
        local same = (#new_paras == #old_paras)
        if same then
            for i = 1, #new_paras do
                local a, b = old_paras[i], new_paras[i]
                if a.kind ~= b.kind or a.level ~= b.level or a.text ~= b.text then
                    same = false; break
                end
            end
        end
        check("big_novel 流式与全文逐段完全一致", same)
        check("big_novel 书名正确", doc.title == "大文件压力测试小说", tostring(doc.title))
        check("big_novel 段落数 > 7000", #new_paras > 7000, tostring(#new_paras))

        -- 3) 端到端：用流式段落生成 EPUB，章节数与目录完整
        local out = HERE .. "_v217_big.epub"
        os.remove(out)
        local rp = {}
        for i = 1, #new_paras do rp[i] = new_paras[i] end
        local ok, cnt = C.build_epub_from_paragraphs(rp, doc.title, out, { title_page = true }, {})
        check("big_novel 端到端生成 EPUB 成功", ok == true and cnt and cnt > 100, tostring(cnt))
        local ef = io.open(out, "rb")
        check("big_novel EPUB 文件已生成", ef ~= nil)
        if ef then
            local data = ef:read("*a"); ef:close()
            check("big_novel EPUB 含 NAV/NCX 目录",
                data:find("nav.xhtml", 1, true) ~= nil and data:find("toc.ncx", 1, true) ~= nil)
            check("big_novel EPUB 含大量章节文件",
                select(2, data:gsub("chapter_%d+%.xhtml", "")) > 100)
        end
        os.remove(out)
        fullxml = nil
    end
else
    print("  [跳过] big_novel.docx fixture 不存在（测试包未随插件分发）")
end

print(string.format("\n=== v2.1.7 测试：%d 通过, %d 失败 ===", pass, fail))
os.exit(fail > 0 and 1 or 0)
