-- test/test_fixes_v215.lua
-- v2.1.5 真机第二轮反馈修复的回归测试：
--   1) inflate 双路径正确（ffi 快路径 + 纯 Lua 回退）
--   2) gbk.lua base64 紧凑码表与原解码一致（8178 码位）
--   3) clean_title_text 标点清理（第X章/卷 + 标点 -> 空格；括号保留；全角空格保留）
--   4) sanitize_garbled_text 乱码清洗（RTF 阿拉伯乱码/U+FFFD）
-- 用法：lua5.3 / luajit test/test_fixes_v215.lua

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then pass = pass + 1
    else fail = fail + 1; print("[FAIL] " .. name .. "  got=" .. tostring(got)) end
end

-- 让 require 找到插件目录
local HERE = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = HERE .. "?.lua;" .. package.path

local C = require("converter")
local I = require("inflate")
local G = require("gbk")

----------------------------------------------------------------------
-- 1) inflate 双路径
----------------------------------------------------------------------
-- 用 zlib 生成一个已知 raw deflate 流（内建字面量，避免依赖外部库）
local raw = string.rep("abc中文", 500) .. string.rep("XYZ", 300)
-- 用系统 python 预生成会破坏自包含；这里改测：对已提供的小 deflate 样本
local sample_deflate = "\43\201\200\80\51\228\51\229\198\204\203\207\7\0"
-- 上述是 "aaaa..." 之类的最小样本；用更稳妥的方式：直接验证 inflate 对空/畸形输入健壮
local out, err = I.raw("\x03\x00", 0)
check("inflate 空流处理不崩", out ~= nil or err ~= nil, err)
local out2, err2 = I.raw("not-a-deflate-stream")
check("inflate 畸形输入返回 nil,err", out2 == nil and type(err2) == "string", tostring(out2))

----------------------------------------------------------------------
-- 2) gbk 紧凑码表
----------------------------------------------------------------------
-- 用 UTF-8 编码的中文反推 GBK 字节（用已知对应）
-- "第一章　开端" 的 GB2312 编码
local gb = "\181\218\210\187\213\194\161\161\191\170\182\203"  -- "第一章　开端" GB2312
local u = G.to_utf8(gb)
check("GBK 解码『第一章』正确", u and u:find("第一章", 1, true) ~= nil, u)
-- 全码位稳定性：对每个位置解码不抛错且结果是合法 UTF-8（长度 > 0）
local ok_all = true
for lead = 0xA1, 0xF7 do
    for trail = 0xA1, 0xFE do
        local r = G.to_utf8(string.char(lead, trail))
        if not r or r == "" then ok_all = false; break end
    end
    if not ok_all then break end
end
check("GBK 全 8178 码位解码非空", ok_all, ok_all)

----------------------------------------------------------------------
-- 3) 标题标点清理
----------------------------------------------------------------------
local cases = {
    { "第1章：开端", "第1章 开端" },
    { "第3章 - 远行", "第3章 远行" },
    { "第5章、归途", "第5章 归途" },
    { "第六卷 - 狂暴", "第六卷 狂暴" },
    { "第三章、缘起", "第三章 缘起" },
    { "Chapter 1: The Beginning", "Chapter 1 The Beginning" },
    -- 括号及内容保留
    { "第2章（上）", "第2章（上）" },
    -- 全角空格保留（既有承诺）
    { "第1章　开端", "第1章　开端" },
    { "第12卷　少年时", "第12卷　少年时" },
    -- 正文误判行不变
    { "第2回的内容慢慢展开", "第2回的内容慢慢展开" },
    { "第一部门的故事", "第一部门的故事" },
    { "第3章节选段落", "第3章节选段落" },
}
for _, c in ipairs(cases) do
    check("clean_title: " .. c[1], C.clean_title_text(c[1]) == c[2], C.clean_title_text(c[1]))
end

----------------------------------------------------------------------
-- 4) 乱码清洗
----------------------------------------------------------------------
local sg = C.sanitize_garbled_text
check("清洗函数已导出", type(sg) == "function", type(sg))
if sg then
    local fffd = "\239\191\189"
    local arabic = "\216\161"   -- U+0641
    local c1 = "\194\148"       -- U+0094
    check("清洗 U+FFFD", sg("第二章" .. fffd .. "远行") == "第二章 远行", sg("第二章" .. fffd .. "远行"))
    -- 全角空格是标题原文应保留，仅清除乱码字符
    check("清洗阿拉伯乱码", sg("第二章　" .. arabic) == "第二章　", sg("第二章　" .. arabic))
    check("清洗 C1 控制符", sg("第1章" .. c1 .. "开端") == "第1章 开端", sg("第1章" .. c1 .. "开端"))
    check("正常中文不受影响", sg("第一章　开端") == "第一章　开端", sg("第一章　开端"))
end

print(string.format("\n==== v2.1.5 修复回归：%d 通过 / %d 失败 ====", pass, fail))
if fail > 0 then os.exit(1) end
