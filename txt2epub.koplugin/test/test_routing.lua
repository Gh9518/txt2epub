-- test/test_routing.lua
-- v2.0.1 回归测试：锁定「Word(.docx) 走插件自解析，不走 KOReader DOM」这一决策，
-- 防止再退化成 v2.0.0 那样产出「只剩标题」的空书。
--
-- 覆盖：
--   1) convert() 分派：.txt/.docx -> _dispatch_convert（自解析）；
--      .doc/.rtf/.epub/.fb2 -> _convert_document（DOM 兜底）
--   2) 空结果体检：is_empty_document_result 能识别"疑似空书"
--   3) build_epub_from_document 第三返回值 stats 含 visible_chars
--   4) build_epub_from_docx 对 sample_stored.docx 仍产出多级目录 + 完整正文（端到端）
-- 用法：lua5.3 test/test_routing.lua

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print(string.format("[PASS] %s", name))
    else fails = fails + 1; print(string.format("[FAIL] %s  %s", name, extra or "")) end
end

----------------------------------------------------------------------
-- 最小 KOReader 运行桩
----------------------------------------------------------------------
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["logger"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["dbg"] = { dassert = function(c, m) assert(c, m) end }
package.loaded["device"] = {
    screen = { getWidth = function() return 800 end, getHeight = function() return 1000 end },
}
package.loaded["ffi/util"] = {
    basename = function(p) return (string.gsub(p, "^.*/", "")) end,
    dirname  = function(p) return (string.gsub(p, "/[^/]*$", "")) end,
    joinPath = function(a, b) return a .. "/" .. b end,
    orderedPairs = function(t)
        local keys = {}; for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local i = 0; return function() i = i + 1; if keys[i] ~= nil then return keys[i], t[keys[i]] end end
    end,
}
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(o)
        o = o or {}; local cls = {}; setmetatable(cls, { __index = o })
        cls.__index = cls
        cls.new = function(_, attr)
            local inst = {}; if type(attr) == "table" then for k, v in pairs(attr) do if inst[k] == nil then inst[k] = v end end end
            setmetatable(inst, { __index = cls }); inst.__index = cls
            if inst.init then inst:init() end; return inst
        end
        return cls
    end,
}
local captured = {}
local UI = {
    show = function(_, w) captured[#captured + 1] = w; return w end,
    close = function(_, w) end,
    nextTick = function(_, fn) end,
}
package.loaded["ui/uimanager"] = UI
package.loaded["ui/widget/infomessage"] = { new = function(_, o) o = o or {}; o._type = "InfoMessage"; return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) o = o or {}; o._type = "ConfirmBox"; return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) o = o or {}; o._type = "InputDialog"; return o end }
package.loaded["ui/widget/menu"] = { new = function(_, o) o = o or {}; o.close = function() end; return o end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    dir = function() return function() end end,
    currentdir = function() return "/" end,
}
local __store = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return __store[k] end,
    saveSetting = function(_, k, v) __store[k] = v end,
    has = function() return false end,
}

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path
local Converter = require("converter")
local ok_load, TXT2EPUB = pcall(require, "main")
check("main.lua 可加载", ok_load, tostring(TXT2EPUB))

----------------------------------------------------------------------
-- 1) convert() 分派决策
--    用桩替换掉 4 条转换/流程方法，只记录"被选中了哪条路径"
----------------------------------------------------------------------
local function new_inst(file)
    local inst = TXT2EPUB:new({
        ui = { menu = { registerToMainMenu = function() end },
               document = file and { file = file } or nil },
    })
    -- 屏蔽日志 / 进度 / 设置读取，专注分派
    inst._set_log = function() end
    inst._maintain_log = function() end
    inst._log = function() end
    inst._safe = function(self, fn) return fn() end
    inst.get_indent = function() return "2em" end
    inst.get_style = function() return "standard" end
    -- file_exists：让输出路径"不存在"，避免弹覆盖确认框
    -- （真实 file_exists 用 io.open；这里 /x/*.epub 本就不存在，天然为 false）
    return inst
end

local function route_of(file)
    local inst = new_inst(file)
    local route = "none"
    inst._dispatch_convert = function(self, f, out, base, ext) route = "selfparse:" .. tostring(ext) end
    inst._convert_document = function(self, doc, f) route = "dom" end
    inst.pick_and_convert = function(self) route = "picker" end
    local ok = pcall(function() inst:convert() end)
    return route, ok, inst
end

local r, ok = route_of("/x/书.txt")
check(".txt -> 插件自解析（_dispatch_convert）", r == "selfparse:.txt", r)
check(".txt 分派不 panic", ok)

r, ok = route_of("/x/报告.docx")
check(".docx -> 插件自解析（不走 DOM）", r == "selfparse:.docx", r)
check(".docx 分派不 panic", ok)

r, ok = route_of("/x/旧版.doc")
check(".doc -> 通用 DOM 兜底", r == "dom", r)

r, ok = route_of("/x/a.rtf")
check(".rtf -> 通用 DOM 兜底", r == "dom", r)

r, ok = route_of("/x/a.epub")
check(".epub -> 通用 DOM 兜底", r == "dom", r)

r, ok = route_of("/x/a.fb2")
check(".fb2 -> 通用 DOM 兜底", r == "dom", r)

----------------------------------------------------------------------
-- 2) 空结果体检（纯函数）
----------------------------------------------------------------------
check("is_empty_document_result：空 stats -> true",
    Converter.is_empty_document_result({ visible_chars = 0 }) == true)
check("is_empty_document_result：少量正文(6字) -> true",
    Converter.is_empty_document_result({ visible_chars = 6 }) == true)
check("is_empty_document_result：充足正文 -> false",
    Converter.is_empty_document_result({ visible_chars = 500 }) == false)
check("is_empty_document_result：stats 为 nil -> false（不误伤）",
    Converter.is_empty_document_result(nil) == false)
check("is_empty_document_result：可自定义阈值",
    Converter.is_empty_document_result({ visible_chars = 50 }, 100) == true)

----------------------------------------------------------------------
-- 3) build_epub_from_document 第三返回值 stats
----------------------------------------------------------------------
local tmp = os.tmpname()
local out = tmp .. "_doc.epub"
-- 模拟真机"空书"：TOC 1 条 + HTML 只有标题段
local empty_doc = {
    title = "sample_stored",
    toc = { { text = "sample_stored", depth = 1, pos0 = "a", pos1 = nil } },
    get_html = function() return "<p>测试小说书名</p>" end,
}
local bok, cnt, stats = Converter.build_epub_from_document(empty_doc, out, {})
check("build_epub_from_document 返回成功", bok == true)
check("build_epub_from_document 返回 stats 表", type(stats) == "table")
check("空书样本 stats.empty 为 true", stats and stats.empty == true,
    stats and tostring(stats.empty))
check("空书样本 visible_chars 很小", stats and stats.visible_chars < 20,
    stats and tostring(stats.visible_chars))
os.remove(out)

-- 正常样本：正文充足，不应判空
local good_doc = {
    title = "正常书",
    toc = { { text = "第一章", depth = 1, pos0 = "a", pos1 = "b" },
            { text = "第二章", depth = 1, pos0 = "b", pos1 = nil } },
    get_html = function() return "<p>" .. string.rep("正文内容", 20) .. "</p>" end,
}
out = tmp .. "_good.epub"
bok, cnt, stats = Converter.build_epub_from_document(good_doc, out, {})
check("正常样本 stats.empty 为 false", stats and stats.empty == false)
check("正常样本章节数 = 2", cnt == 2, tostring(cnt))
os.remove(out)

----------------------------------------------------------------------
-- 4) 端到端：build_epub_from_docx 对 sample_stored.docx 仍产出完整目录+正文
----------------------------------------------------------------------
local docx = root .. "test/fixtures/sample_stored.docx"
out = tmp .. "_docx.epub"
local dok, dcnt = Converter.build_epub_from_docx(docx, out, { book_title = "sample_stored" })
check("build_epub_from_docx 成功", dok == true)
check("build_epub_from_docx 章节数 = 5（含多级）", dcnt == 5, tostring(dcnt))
local function unzip_entry(path, entry)
    local f = io.popen(string.format('unzip -p "%s" "%s" 2>/dev/null', path, entry), "r")
    local d = f and f:read("*a") or ""; if f then f:close() end; return d
end
local nav = unzip_entry(out, "OEBPS/nav.xhtml")
check("生成 nav 含「第一章 风起」", nav:find("第一章") ~= nil)
check("生成 nav 含嵌套 <ol>（多级目录）", nav:find("<ol>.*<ol>", 1, false) ~= nil)
local c1 = unzip_entry(out, "OEBPS/chapter_0001.xhtml")
check("第一章含完整正文", c1:find("这是第一章的第一段正文") ~= nil)
os.remove(out)
if tmp then os.remove(tmp) end

----------------------------------------------------------------------
print(string.format("\n=== 分派/体检回归测试：%d 通过, %d 失败 ===", passes, fails))
os.exit(fails == 0 and 0 or 1)
