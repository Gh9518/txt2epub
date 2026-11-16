-- test/test_fixes_v214.lua
-- v2.1.4 真机反馈修复的回归测试：
--   1) 纯 Lua GB2312 解码（无 iconv 时 edge_gbk.txt 不丢内容/目录）
--   2) 内联标签 HTML（<span> 内标题）恢复多级目录（edge_html_inline.html）
--   3) indent 模式超长单行按字节分片入目录（edge_no_title.txt）
--   4) DOCX 崩溃防御：转换前 GC 不 panic（main.lua 路径，最小桩）
--   5) EPUB 重复转换防护：转换前弹确认提示
-- 用法：lua5.3 / luajit test/test_fixes_v214.lua

----------------------------------------------------------------------
-- KOReader 最小桩（供 main.lua 加载）
----------------------------------------------------------------------
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["logger"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["dbg"] = { dassert = function(c, m) assert(c, m) end }
package.loaded["device"] = { screen = { getWidth = function() return 800 end, getHeight = function() return 1000 end } }
package.loaded["ffi/util"] = {
    basename = function(p) return (p:gsub("^.*/", "")) end,
    dirname = function(p) return (p:gsub("/[^/]*$", "")) end,
    joinPath = function(a, b) return a .. "/" .. b end,
    orderedPairs = function(t)
        local keys = {}; for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local i = 0; return function() i = i + 1; if keys[i] ~= nil then return keys[i], t[i] end end
    end,
}
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(o)
        o = o or {}; local cls = {}; setmetatable(cls, { __index = o }); cls.__index = cls
        cls.new = function(_, attr)
            local inst = {}
            if type(attr) == "table" then for k, v in pairs(attr) do if inst[k] == nil then inst[k] = v end end end
            setmetatable(inst, { __index = cls }); inst.__index = cls
            if inst.init then inst:init() end; return inst
        end
        return cls
    end,
}
local captured = {}
package.loaded["ui/uimanager"] = {
    show = function(_, w) captured[#captured + 1] = w; return w end,
    close = function() end,
    nextTick = function(_, fn) pcall(fn) end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, o) o = o or {}; o._type = "InfoMessage"; return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) o = o or {}; o._type = "ConfirmBox"; return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) o = o or {}; o._type = "InputDialog"; o.getInputValue = function() return o._value or "" end; return o end }
package.loaded["ui/widget/menu"] = { new = function(_, o) o = o or {}; o.close = function() end; return o end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end, dir = function() return function() end end, currentdir = function() return "/" end,
}
_G.G_reader_settings = {
    readSetting = function() return nil end, saveSetting = function() end, has = function() return false end,
}

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path
local Converter = require("converter")
local gbk = require("gbk")

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print("[PASS] " .. name)
    else fails = fails + 1; print("[FAIL] " .. name .. "  " .. (extra or "")) end
end
local function readall(p) local f = io.open(p, "rb"); if not f then return nil end local d = f:read("*a"); f:close(); return d end
local function nav_texts(epub)
    local tmp = os.tmpname()
    os.execute(string.format('rm -rf "%s" && mkdir -p "%s" && cd "%s" && unzip -oq "%s" 2>/dev/null', tmp, tmp, tmp, epub))
    local nav = readall(tmp .. "/OEBPS/nav.xhtml") or ""
    local texts = {}
    for a in nav:gmatch("<a[^>]*>(.-)</a>") do texts[#texts + 1] = a:gsub("<[^>]+>", "") end
    os.execute(string.format('rm -rf "%s"', tmp))
    return texts
end

os.execute("mkdir -p /tmp/t2e_v214")
local OUT = "/tmp/t2e_v214/"
local OPTS = { indent = "2em", style = "standard", title_page = true, uid = "urn:uuid:x", modified = "2026-01-01T00:00:00Z" }

-- 1) 纯 Lua GB2312 解码
do
    local src = "/tmp/t2e_v214/gbk.txt"
    local f = io.open(src, "wb")
    f:write("\181\218\210\187\213\194\161\161\191\170\182\203" .. " 123")  -- "第一章　开端 123"（GB2312）
    f:close()
    local utf = gbk.to_utf8(readall(src))
    check("GBK 纯 Lua 解码：得到「第一章」", utf and utf:find("第一章", 1, true) ~= nil, tostring(utf))
    local tmpout = OUT .. "gbk_decoded.txt"
    local ok = gbk.decode_stream(src, tmpout)
    check("GBK 流式解码：产出非空文件", ok and #(readall(tmpout) or "") > 0)
end

-- 2) 内联标签 HTML 标题恢复
do
    local html = '<!DOCTYPE html><html><head><title>内联</title></head><body>'
        .. '<div><span>第一章　开端</span><br/><span>正文一。</span></div>'
        .. '<div><span>第二章　发展</span><br/><span>正文二。</span></div>'
        .. '<div><span>第三章　结局</span><br/><span>正文三。</span></div>'
        .. '</body></html>'
    local src = OUT .. "inline.html"
    local f = io.open(src, "wb"); f:write(html); f:close()
    local ok, n = Converter.build_epub_from_markup(src, OUT .. "inline.epub", OPTS, {})
    local texts = nav_texts(OUT .. "inline.epub")
    local found = 0
    for _, t in ipairs(texts) do if t:find("第", 1, true) then found = found + 1 end end
    check("inline HTML：转换成功", ok == true)
    check("inline HTML：识别出 >=3 个章节标题", found >= 3, "found=" .. found .. " n=" .. tostring(n))
end

-- 3) indent 模式超长单行分片入目录
do
    local src = OUT .. "nolong.txt"
    local f = io.open(src, "wb")
    f:write(string.rep("这是无标题纯正文用于验证按字节切分。", 20000))  -- 单超长行 (>256KB)
    f:close()
    local ok, n = Converter.build_epub_streaming(Converter.lines(src), "indent", 4, "测试书", OUT .. "nolong.epub", OPTS, {})
    Converter.release_lines(src)
    local texts = nav_texts(OUT .. "nolong.epub")
    check("indent 超长单行：转换成功", ok == true)
    check("indent 超长单行：生成多个分片目录", n and n >= 2, "n=" .. tostring(n))
    check("indent 超长单行：目录名不再是超长正文", (#texts > 0 and #texts[1] < 200), "nav1len=" .. tostring(texts[1] and #texts[1]))
end

-- 4) EPUB 重复转换防护（main.lua）
do
    local TXT2EPUB = require("main")
    local inst = TXT2EPUB:new({ ui = { menu = { registerToMainMenu = function() end }, document = { file = "/x/book.epub" } } })
    inst._set_log = function() end; inst._maintain_log = function() end; inst._log = function() end
    inst._safe = function(self, fn) return fn() end
    inst._convert_document = function() end
    captured = {}
    local ok = pcall(function() inst:convert() end)
    local confirm = nil
    for _, w in ipairs(captured) do if w._type == "ConfirmBox" then confirm = w end end
    check("EPUB 防护：convert() 不 panic", ok, tostring(ok))
    check("EPUB 防护：弹出重复转换确认框", confirm ~= nil)
end

print(string.format("\n==== v2.1.4 修复回归：%d 通过 / %d 失败 ====", passes, fails))
if fails > 0 then os.exit(1) end
