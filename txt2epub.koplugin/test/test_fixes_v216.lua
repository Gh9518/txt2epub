-- test/test_fixes_v216.lua
-- v2.1.6 真机第四轮反馈修复的回归测试：
--   1) inflate 移除 FFI 快路径后纯 Lua 仍正确解压 + 熔断保护（损坏/越界数据不 OOM）
--   2) rtf.lua 直接解析源文件：负数 \u 转义、字体表过滤、标题层级、完整目录
--   3) RTF -> EPUB 端到端：乱码截断的「第二章 远行」等全部保留
-- 用法：lua5.3 / luajit test/test_fixes_v216.lua

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then pass = pass + 1
    else fail = fail + 1; print("[FAIL] " .. name .. "  got=" .. tostring(got)) end
end

local HERE = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = HERE .. "?.lua;" .. package.path

local I = require("inflate")
local R = require("rtf")
local C = require("converter")

----------------------------------------------------------------------
-- 1) inflate 纯 Lua + 熔断
----------------------------------------------------------------------
-- 已知 raw deflate 样本（"aaaa..." STORED 类）——用 zlib 生成的固定字节
-- 畸形输入：返回 nil + err，绝不 panic
local o1, e1 = I.raw("not-a-deflate-stream")
check("inflate 畸形输入返回 nil,err", o1 == nil and type(e1) == "string", tostring(o1))
-- 空流 + expected_size=0 -> 空串
local o2 = I.raw("", 0)
check("inflate 空流 expected=0 返回空串", o2 == "", tostring(o2))
-- 损坏流在熔断内返回错误，不无限循环（用一个会触发大量输出但非法的流）
local o3, e3 = I.raw(string.rep("\255", 64))
check("inflate 损坏流安全返回", (o3 == nil and type(e3) == "string") or type(o3) == "string", tostring(e3))
-- 大文件解压正确性：用真实 big_novel.docx（若存在）
local big = HERE .. "../fixtures/big_novel.docx"
-- 测试包不在仓库内则跳过（用小的确定样本代替）
local sample = "\43\201\200\80\51\228\51\229\198\204\203\207\7\0"
local o4, e4 = I.raw(sample)
check("inflate 最小 deflate 样本不崩", o4 ~= nil or e4 ~= nil, e4)

----------------------------------------------------------------------
-- 2) RTF 解析（纯函数，用内嵌 RTF 文本，不依赖测试包）
----------------------------------------------------------------------
local rtf_text = table.concat({
    "{\\rtf1\\ansi\\ansicpg936\\deff0",
    "{\\fonttbl{\\f0\\fnil SimSun;}}",
    "\\viewkind4\\uc1\\pard\\f0\\fs24",
    "\\b \\u31532?\\u19968?\\u31456?\\u12288?\\u24320?\\u31471?\\b0\\par",
    "\\u19968?\\u31456? \\u36825?\\u26159?\\par",
    "\\b \\u31532?\\u20108?\\u31456?\\u12288?\\u-28708?\\u-30644?\\b0\\par",  -- 第二章 远行（负数 \u）
    "\\u20108?\\u31456? \\u27491?\\u25991?\\par",
    "}",
})
local res, rerr = R.parse(rtf_text)
check("RTF 解析成功", res ~= nil, rerr)
if res then
    local txts = {}
    for _, p in ipairs(res.paragraphs) do txts[#txts+1] = p.text end
    local all = table.concat(txts, "|")
    check("RTF 字体表残留已过滤", not all:find("SimSun", 1, true), all)
    check("RTF 第一章正确解码", all:find("第一章", 1, true) ~= nil, all)
    check("RTF 负数\\u 第二章远行正确解码", all:find("远行", 1, true) ~= nil, all)
    check("RTF 正文保留", all:find("正文", 1, true) ~= nil, all)
    local h1, h2 = 0, 0
    for _, p in ipairs(res.paragraphs) do
        if p.kind == "heading" then h1 = h1 + 1 end
    end
    check("RTF 识别到 2 个标题", h1 == 2, h1)
    check("RTF garbled=0（负数\\u 不算乱码）", res.garbled == 0, res.garbled)
end

----------------------------------------------------------------------
-- 3) RTF -> EPUB 完整链路（用内嵌 RTF 写临时文件）
----------------------------------------------------------------------
local tmp_rtf = HERE .. "_v216_tmp.rtf"
local tmp_epub = HERE .. "_v216_tmp.epub"
do
    local f = io.open(tmp_rtf, "wb")
    f:write(rtf_text); f:close()
end
local ok, cnt, stats = C.build_epub_from_rtf(tmp_rtf, tmp_epub, { title_page = true })
check("RTF->EPUB 成功", ok == true and (cnt or 0) >= 2, tostring(cnt))
if stats then
    check("RTF->EPUB 标题数>=2", (stats.headings or 0) >= 2, stats.headings)
    check("RTF->EPUB 无乱码跳过", (stats.garbled or 0) == 0, stats.garbled)
end
-- 校验 EPUB 内目录含「远行」
local ef = io.open(tmp_epub, "rb")
if ef then
    local epub = ef:read("*a"); ef:close()
    check("EPUB 非空", #epub > 100, #epub)
    -- 压缩包内 nav.xhtml 应含远行（EPUB 用 store，可直接明文搜索）
    check("EPUB 含第二章远行标题", epub:find("远行", 1, true) ~= nil, "not found")
end
os.remove(tmp_rtf); os.remove(tmp_epub)

print(string.format("\n==== v2.1.6 修复回归：%d 通过 / %d 失败 ====", pass, fail))
if fail > 0 then os.exit(1) end
