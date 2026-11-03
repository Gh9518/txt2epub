-- test_edge.lua
-- 边界用例：在 luajit（Lua5.1，最贴近 KOReader 运行时）下，验证各种易触发崩溃的真实场景。
-- 覆盖：UTF-8 BOM（流式路径）、GBK 解码、超长单行、特殊字符转义、中文输出路径、空文件。
--
-- 用法：luajit test/test_edge.lua

----------------------------------------------------------------------
-- 最小 KOReader 运行桩
----------------------------------------------------------------------
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["logger"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["dbg"] = { dassert = function(c, m) assert(c, m) end }
package.loaded["device"] = setmetatable({}, { __index = function() return function() return false end end })
package.loaded["ffi/util"] = {
    basename = function(p) return (string.gsub(p, "^.*/", "")) end,
    dirname  = function(p) return (string.gsub(p, "/[^/]*$", "")) end,
    joinPath = function(a, b) return a .. "/" .. b end,
    fileExists = function(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end,
}
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(o)
        o = o or {}
        local cls = {}; setmetatable(cls, { __index = o }); cls.__index = cls
        cls.new = function(_, attr)
            local inst = {}
            if type(attr) == "table" then for k, v in pairs(attr) do if inst[k] == nil then inst[k] = v end end end
            setmetatable(inst, { __index = cls }); inst.__index = cls
            if inst.init then inst:init() end
            return inst
        end
        return cls
    end,
}
local captured = {}
package.loaded["ui/uimanager"] = {
    show = function(_, w) captured[#captured + 1] = w; return w end,
    close = function() end,
    nextTick = function(_, fn)
        local ok, err = pcall(fn)
        if not ok then error("nextTick 回调 panic（真实环境会整体崩溃）: " .. tostring(err)) end
    end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, o) o = o or {}; o._type = "InfoMessage"; return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) o = o or {}; o._type = "ConfirmBox"; return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) o = o or {}; o._type = "InputDialog"; o.getInputValue = function() return o._value or o.input or "" end; return o end }
local __store = {}
_G.G_reader_settings = { readSetting = function(_, k) return __store[k] end, saveSetting = function(_, k, v) __store[k] = v end }

----------------------------------------------------------------------
-- 加载插件
----------------------------------------------------------------------
local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path
local TXT2EPUB = require("main")
local inst = TXT2EPUB:new({ ui = { menu = { registerToMainMenu = function() end }, document = { file = "/x/x.txt" } } })

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------
local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print("[PASS] " .. name)
    else fails = fails + 1; print("[FAIL] " .. name .. "  " .. (extra or "")) end
end

os.execute("mkdir -p /tmp/t2e_edge")
local function write_file(path, data, bin)
    local f = io.open(path, bin and "wb" or "w")
    f:write(data); f:close()
end
local function epub_ok(path)
    if not io.open(path, "rb") then return false end
    local p = io.popen(string.format("unzip -l '%s' >/dev/null 2>&1 && echo YES || echo NO", path))
    local r = p:read("*a"):match("YES") ~= nil; p:close()
    return r
end

----------------------------------------------------------------------
-- 边界 1：UTF-8 带 BOM（走 Converter.lines 的流式路径）
----------------------------------------------------------------------
local bom_txt = "/tmp/t2e_edge/bom.txt"
write_file(bom_txt, "\239\187\191" .. "书名：带BOM的小说\n\n第一章 开篇\n\n正文第一段。\n第二段。\n\n第二章 发展\n\n更多内容。\n")
local out_bom = "/tmp/t2e_edge/bom.epub"
local ok1, r1 = pcall(function() return inst:_do_convert(bom_txt, out_bom, "带BOM的小说", false) end)
check("BOM 文件：_do_convert 不抛错", ok1, tostring(r1))
check("BOM 文件：生成合法 EPUB", ok1 and epub_ok(out_bom))
if ok1 then check("BOM 文件：切出 2 章", r1.count == 2, "count=" .. tostring(r1.count)) end

----------------------------------------------------------------------
-- 边界 2：GBK 编码（走 decode_via_iconv）
----------------------------------------------------------------------
local gbk_src = "/tmp/t2e_edge/gbk_utf8.txt"
write_file(gbk_src, "书名：GBK测试\n\n第一章 测试\n\n这是中文正文。\n\n第二章 结束\n\n再见。\n")
local gbk_bin = "/tmp/t2e_edge/gbk.txt"
os.execute(string.format("iconv -f UTF-8 -t GBK '%s' > '%s' 2>/dev/null", gbk_src, gbk_bin))
local out_gbk = "/tmp/t2e_edge/gbk.epub"
local ok2, r2 = pcall(function() return inst:_do_convert(gbk_bin, out_gbk, "GBK测试", false) end)
check("GBK 文件：_do_convert 不抛错", ok2, tostring(r2))
check("GBK 文件：生成合法 EPUB", ok2 and epub_ok(out_gbk))
if ok2 then
    -- 校验解码正确：EPUB 内应能看到“第一章 测试”而非乱码
    local p = io.popen(string.format("unzip -p '%s' OEBPS/chapter_0001.xhtml 2>/dev/null", out_gbk))
    local x = p:read("*a"); p:close()
    check("GBK 文件：章节标题解码为中文（非乱码）", x:find("第一章 测试") ~= nil, x:sub(1, 60))
end

----------------------------------------------------------------------
-- 边界 3：超长单行（>64KB 无换行）—— 压力流式路径，验证不 panic / 不死循环
----------------------------------------------------------------------
local big_txt = "/tmp/t2e_edge/big.txt"
local f = io.open(big_txt, "w")
f:write("第一章 超长\n")  -- 先放一个标题
for i = 1, 200000 do f:write("这是一段很长的连续文本没有换行用于测试流式读取的健壮性。") end  -- 约 9MB 单行
f:write("\n第二章 结尾\n短内容。\n")
f:close()
local out_big = "/tmp/t2e_edge/big.epub"
local ok3, r3 = pcall(function() return inst:_do_convert(big_txt, out_big, "超长", false) end)
check("超长单行：_do_convert 不 panic", ok3, tostring(r3))
check("超长单行：生成合法 EPUB", ok3 and epub_ok(out_big))

----------------------------------------------------------------------
-- 边界 4：大量特殊字符（& < > " '）—— 验证 HTML 转义不崩溃
----------------------------------------------------------------------
local sp_txt = "/tmp/t2e_edge/special.txt"
write_file(sp_txt, "第一章 特殊字符\n\n这里有 <tag> & \"引号\" '单引号' <p> &amp; 测试。\n第二行 <b>bold</b>。\n\n第二章 完\n\n结尾。\n")
local out_sp = "/tmp/t2e_edge/special.epub"
local ok4, r4 = pcall(function() return inst:_do_convert(sp_txt, out_sp, "特殊", false) end)
check("特殊字符：_do_convert 不抛错", ok4, tostring(r4))
check("特殊字符：生成合法 EPUB", ok4 and epub_ok(out_sp))
if ok4 then
    local p = io.popen(string.format("unzip -p '%s' OEBPS/chapter_0001.xhtml 2>/dev/null", out_sp))
    local x = p:read("*a"); p:close()
    check("特殊字符：& < > 已正确转义（无裸 <tag>）", x:find("&lt;tag&gt;") ~= nil and x:find("<tag>") == nil, x:sub(1, 80))
end

----------------------------------------------------------------------
-- 边界 5：中文输出路径（io.open 中文文件名）
----------------------------------------------------------------------
local zh_txt = "/tmp/t2e_edge/中文书.txt"
write_file(zh_txt, "第一章 中文名\n\n内容。\n\n第二章 完\n\n结尾。\n")
local out_zh = "/tmp/t2e_edge/中文书.epub"
local ok5, r5 = pcall(function() return inst:_do_convert(zh_txt, out_zh, "中文书", false) end)
check("中文输出路径：_do_convert 不抛错", ok5, tostring(r5))
check("中文输出路径：生成合法 EPUB", ok5 and epub_ok(out_zh))

----------------------------------------------------------------------
-- 边界 6：空文件（回退单章，不 panic）
----------------------------------------------------------------------
local empty_txt = "/tmp/t2e_edge/empty.txt"
write_file(empty_txt, "")
local out_empty = "/tmp/t2e_edge/empty.epub"
local ok6, r6 = pcall(function() return inst:_do_convert(empty_txt, out_empty, "空书", false) end)
check("空文件：_do_convert 不抛错", ok6, tostring(r6))
check("空文件：生成合法 EPUB（回退单章）", ok6 and epub_ok(out_empty))

----------------------------------------------------------------------
-- 汇总
----------------------------------------------------------------------
print(string.format("\n===== 边界测试（luajit）：%d 通过 / %d 失败 =====", passes, fails))
os.exit(fails == 0 and 0 or 1)
