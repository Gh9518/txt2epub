-- test/test_inflate.lua
-- 纯 Lua raw DEFLATE 解压器（inflate.lua）的回归测试。
-- 运行：lua5.3 test/test_inflate.lua   （在插件根目录执行）
--
-- 背景：真机上报 "ffi/zlib.lua:29: assertion failed!"，根因是 KOReader 的
--   zlib_uncompress() 只认 zlib 格式，而 ZIP 条目是 raw DEFLATE。修复改为纯 Lua
--   解压（inflate.lua）。本测试用「真实 docx 的压缩条目」+ 多种 block 类型/压缩
--   级别/大文件样本逐字节比对，锁定正确性（沙箱即可验证，不再依赖真机 zlib）。
--
-- 样本由 test/fixtures/gen_inflate_cases.py 生成（可重复生成）。

local plugin_dir = arg and arg[0] and arg[0]:match("(.*/)") or "./"
if plugin_dir == "" then plugin_dir = "./" end
package.path = package.path .. ";" .. plugin_dir .. "?.lua" .. ";" .. plugin_dir .. "../?.lua"
package.path = package.path .. ";./?.lua"

local inflate = require("inflate")

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

local dir = plugin_dir .. "fixtures/inflate_cases/"
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

------------------------------------------------------------------------
-- 1) 模块 API
------------------------------------------------------------------------
check("inflate.raw 是函数", type(inflate.raw) == "function")
local r0 = inflate.raw(read(dir .. "short.deflate"))
check("解压基础字符串 = 'hello world, KOReader txt2epub!'",
    r0 == "hello world, KOReader txt2epub!", tostring(r0))
check("expected_size 校验正确时通过", inflate.raw(read(dir .. "short.deflate"), 31) ~= nil)
check("expected_size 不符时明确报错", (function()
    local v, e = inflate.raw(read(dir .. "short.deflate"), 999)
    return v == nil and e ~= nil
end)())

------------------------------------------------------------------------
-- 2) 全样本逐字节比对（含真实 docx 压缩流、STORED/fixed/dynamic、大文件）
------------------------------------------------------------------------
local names = {}
local p = io.popen("ls " .. dir .. "*.deflate 2>/dev/null")
if p then
    for line in p:lines() do
        local nm = line:match("([^/]+)%.deflate$")
        if nm then names[#names + 1] = nm end
    end
    p:close()
end
table.sort(names)
check("样本集非空（>= 15 个）", #names >= 15, "got " .. #names)

for _, nm in ipairs(names) do
    local comp = read(dir .. nm .. ".deflate")
    local plain = read(dir .. nm .. ".plain") or ""
    local out, err = inflate.raw(comp, #plain)
    check("解压一致: " .. nm .. string.format(" (%d -> %d B)", #comp, #plain),
        out == plain, out and ("长度 " .. #out) or tostring(err))
end

------------------------------------------------------------------------
-- 3) 真实 docx 的 document.xml 压缩流必须能解出完整 XML
------------------------------------------------------------------------
local dx = inflate.raw(read(dir .. "doc_xml.deflate"), 1465)
check("doc_xml.deflate 解出 1465 字节", dx ~= nil and #dx == 1465, dx and tostring(#dx) or "nil")
if dx then
    check("解出的 XML 含 <w:document", dx:find("<w:document") ~= nil or dx:find("<w:document", 1, true) ~= nil)
    check("解出的 XML 含正文文字", dx:find("第一章") ~= nil)
    check("解出的 XML 含二级标题样式", dx:find("Heading2") ~= nil)
end

------------------------------------------------------------------------
-- 4) 损坏数据不应 panic，应返回 nil + err（而非崩溃/死循环）
------------------------------------------------------------------------
check("空数据返回明确错误", (function()
    local v, e = inflate.raw("", nil)
    return v == nil and e ~= nil
end)())
check("非字符串返回明确错误", (function()
    local v, e = inflate.raw(nil, nil)
    return v == nil and e ~= nil
end)())
check("截断流不 panic", (function()
    local c = read(dir .. "doc_xml.deflate")
    local ok, v = pcall(inflate.raw, c:sub(1, 20), nil)
    return ok and (v == nil or type(v) == "string")  -- 只要不抛异常即可（可能返回部分或 nil）
end)())
check("BTYPE=3 保留值被拒绝", (function()
    -- 构造 BFINAL=1, BTYPE=3 -> 首字节低 3 位 = 1 + 3<<1 = 0b111 = 7
    local ok, v, e = pcall(inflate.raw, string.char(7), nil)
    return ok and v == nil and e ~= nil
end)())

------------------------------------------------------------------------
-- 5) 性能护栏：1.84MB 大文件在合理时间内完成（防止退化成 O(n^2)）
------------------------------------------------------------------------
local big = read(dir .. "big.deflate")
if big then
    local t0 = os.clock()
    local bo = inflate.raw(big, 1840000)
    local dt = os.clock() - t0
    check("大文件解压结果正确 (1.84MB)", bo ~= nil and #bo == 1840000,
        bo and tostring(#bo) or "nil")
    check("大文件解压耗时 < 5s", dt < 5, string.format("%.3fs", dt))
end

------------------------------------------------------------------------
print(string.format("\n=== inflate 测试：%d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
