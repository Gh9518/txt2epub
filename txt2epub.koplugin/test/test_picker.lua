-- test_picker.lua
-- 验证“开始转换”的文件选择 / 源判定逻辑：
--   1) file_ext 可接收显式路径参数（不再只依赖 document.file）
--   2) _list_sources 仅列出 .txt/.docx（及目录、..），过滤掉 epub/隐藏文件
--   3) convert() 决策：打开 epub/pdf 等非源文件时弹出文件选择器；
--      打开 .txt / .docx 时直接进入转换（不弹选择器）
-- 用法：lua5.3 test/test_picker.lua

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print(string.format("[PASS] %s", name))
    else fails = fails + 1; print(string.format("[FAIL] %s  %s", name, extra or "")) end
end

----------------------------------------------------------------------
-- 最小 KOReader 运行桩（移植自 test_runtime.lua）
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
local next_tick_queue = {}
local UI = {
    show = function(_, w) captured[#captured + 1] = w; return w end,
    close = function(_, w) end,
    nextTick = function(_, fn) next_tick_queue[#next_tick_queue + 1] = fn end,
}
package.loaded["ui/uimanager"] = UI
package.loaded["ui/widget/infomessage"] = { new = function(_, o) o = o or {}; o._type = "InfoMessage"; return o end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) o = o or {}; o._type = "ConfirmBox"; return o end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) o = o or {}; o._type = "InputDialog"; return o end }

-- G_reader_settings 桩
local __store = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return __store[k] end,
    saveSetting = function(_, k, v) __store[k] = v end,
}

-- lfs 桩：一个虚拟目录 /books，含 a.txt / b.docx / c.epub / notes(目录) / .hidden
local fake_fs = {
    ["/"] = { mode = "directory" },
    ["/books"] = { mode = "directory" },
    ["/books/a.txt"] = { mode = "file" },
    ["/books/b.docx"] = { mode = "file" },
    ["/books/c.epub"] = { mode = "file" },
    ["/books/notes"] = { mode = "directory" },
    ["/books/.hidden"] = { mode = "file" },
}
local fake_dirs = { ["/books"] = {".", "..", "a.txt", "b.docx", "c.epub", "notes", ".hidden"} }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(p) return fake_fs[p] end,
    dir = function(p)
        local t = fake_dirs[p]
        if not t then return function() end end
        local i = 0
        return function() i = i + 1; if i <= #t then return t[i] end end
    end,
    currentdir = function() return "/" end,
}

-- Menu 桩：记录被 show 的菜单对象
local Menu = { shown = {}, new = function(_, o) o = o or {}; o._type = "Menu"; Menu.shown[#Menu.shown + 1] = o; o.close = function() end; return o end }
package.loaded["ui/widget/menu"] = Menu

----------------------------------------------------------------------
-- 加载插件
----------------------------------------------------------------------
local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path
local ok_load, TXT2EPUB = pcall(require, "main")
check("main.lua 可被加载（含文件选择器代码）", ok_load, tostring(TXT2EPUB))

local inst = TXT2EPUB:new({ ui = { menu = { registerToMainMenu = function() end }, document = { file = "/x/书.txt" } } })

----------------------------------------------------------------------
-- 1) file_ext 接收显式路径
----------------------------------------------------------------------
check("file_ext 接收显式 .docx 路径", inst:file_ext("/x/报告.docx") == ".docx", inst:file_ext("/x/报告.docx"))
check("file_ext 接收显式 .EPUB 路径（小写化）", inst:file_ext("/x/书.EPUB") == ".epub", inst:file_ext("/x/书.EPUB"))
check("file_ext 无扩展名返回 nil", inst:file_ext("/x/无扩展名") == nil)

----------------------------------------------------------------------
-- 2) _list_sources 仅列出 .txt/.docx + 目录 + ..
----------------------------------------------------------------------
local items = inst:_list_sources("/books")
local names = {}
for _, it in ipairs(items) do names[it.text] = it end
check("_list_sources 含 a.txt", names["a.txt"] ~= nil and names["a.txt"].is_dir == false)
check("_list_sources 含 b.docx", names["b.docx"] ~= nil and names["b.docx"].is_dir == false)
-- 2.0.0 起选择器扩列：epub 也列入（在阅读器内打开后由 DOM 兜底转换）
check("_list_sources 含 c.epub（扩列后可列出）", names["c.epub"] ~= nil and names["c.epub"].is_dir == false)
check("_list_sources 含 notes/ 目录项", names["notes/"] ~= nil and names["notes/"].is_dir == true)
check("_list_sources 含 .. 上级项", names["⬆ .."] ~= nil and names["⬆ .."].is_dir == true)
check("_list_sources 过滤掉 .hidden", names[".hidden"] == nil)
-- 排序：目录在前
local first_is_dir = items[1] and items[1].is_dir == true
check("_list_sources 排序：目录/.. 在前", first_is_dir)

----------------------------------------------------------------------
-- 3) convert() 决策
--    stub 掉下游转换方法，只记录"选了哪条路"，避免真的读写磁盘
----------------------------------------------------------------------
local pick_called_epub = false
local dom_called = false
local selfparse_called = false
inst._set_log = function() end
inst._maintain_log = function() end
inst._log = function() end
inst._safe = function(self, fn) return fn() end
inst.pick_and_convert = function() pick_called_epub = true end
inst._convert_document = function() dom_called = true end
inst._dispatch_convert = function() selfparse_called = true end

-- 3a) 打开 epub（插件无专用解析器）-> 走通用 DOM 兜底，不弹选择器
inst.ui.document.file = "/books/c.epub"
Menu.shown = {}; captured = {}
pick_called_epub = false; dom_called = false; selfparse_called = false
local ok_e = pcall(function() inst:convert() end)
-- EPUB 重复转换防护会先弹确认框：模拟用户点「继续转换」后再判定路由
for _, w in ipairs(captured) do
    if w._type == "ConfirmBox" and type(w.ok_callback) == "function" then w.ok_callback() end
end
check("打开 epub 时 convert() 不 panic", ok_e, tostring(ok_e))
check("打开 epub -> 走通用 DOM 兜底", dom_called)
check("打开 epub -> 不弹选择器（有文档对象即可转换）", not pick_called_epub)

-- 3b) 打开 .txt -> 不应弹选择器，直接进入转换
inst.ui.document.file = "/books/a.txt"
pick_called_epub = false
local ok_t = pcall(function() inst:convert() end)
check("打开 txt 时 convert() 不 panic", ok_t, tostring(ok_t))
check("打开 txt -> 不弹选择器（走直接转换）", not pick_called_epub)

-- 3c) 打开 .docx -> 不应弹选择器，直接进入转换
inst.ui.document.file = "/books/b.docx"
pick_called_epub = false
local ok_d = pcall(function() inst:convert() end)
check("打开 docx 时 convert() 不 panic", ok_d, tostring(ok_d))
check("打开 docx -> 不弹选择器（走直接转换，拿原始路径）", not pick_called_epub)

-- 3d) 无已打开文档 -> 弹选择器
inst.ui.document = nil
pick_called_epub = false
local ok_n = pcall(function() inst:convert() end)
check("无文档时 convert() 不 panic", ok_n, tostring(ok_n))
check("无文档 -> 触发文件选择器", pick_called_epub)

----------------------------------------------------------------------
print(string.format("\n=== 文件选择器测试：%d 通过, %d 失败 ===", passes, fails))
os.exit(fails == 0 and 0 or 1)
