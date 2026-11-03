--[[--
test_menu.lua
用真实的 KOReader MenuSorter 与阅读菜单 order，验证本插件的 addToMainMenu：
  1) 不会改写内置的 menu_items.tools（旧写法的崩溃根源）
  2) 生成合规的顶层菜单项（带 sorting_hint = "tools"）
  3) 能被 MenuSorter:mergeAndSort 正常合并排序（不抛错）
  4) TXT 转 EPUB 与其它插件都能出现在工具菜单（不再“整片消失”）

运行：cd txt2epub.koplugin && lua5.3 test/test_menu.lua
--]]

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")  -- 插件根目录

-- KOReader 运行时是 LuaJIT / Lua 5.1，自带 table.maxn；在 Lua 5.3+ 沙箱里需补一个兼容层
if not table.maxn then
    table.maxn = function(t)
        local m = 0
        for k, _ in pairs(t) do
            if type(k) == "number" and k > m then m = k end
        end
        return m
    end
end

------------------------------------------------------------------
-- 1) 桩：menusorter.lua / reader_menu_order.lua 的运行时依赖
------------------------------------------------------------------
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp" end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["logger"] = { warn = function() end, err = function() end, dbg = function() end }
-- Dbg.dassert 在真实环境会断言；测试里让它真正生效以便捕获错误 hint
package.loaded["dbg"] = { dassert = function(cond, msg) assert(cond, msg) end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
local Device = {
    isTouchDevice = function() return true end,
    hasFrontlight = function() return true end,
    hasKeys = function() return false end,
    model = "Test",
}
-- 任意其它 Device:* 方法（如 hasExitOptions/canRestart/canSuspend…）默认返回 false
setmetatable(Device, { __index = function() return function() return false end end })
package.loaded["device"] = Device
package.loaded["ffi/util"] = {
    basename = function(p) return (p:gsub("^.*/", "")) end,
    dirname  = function(p) return (p:gsub("/[^/]*$", "")) end,
    joinPath = function(a, b) return a .. "/" .. b end,
    fileExists = function() return false end,
    -- KOReader 的 orderedPairs：按 key 排序遍历（实现一份等价物用于测试）
    orderedPairs = function(t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local i = 0
        return function()
            i = i + 1
            if keys[i] ~= nil then return keys[i], t[keys[i]] end
        end
    end,
}

------------------------------------------------------------------
-- 2) 桩：main.lua 顶部的 KOReader UI 模块，使其可被 require
------------------------------------------------------------------
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(o)
        o = o or {}
        local cls = {}
        setmetatable(cls, { __index = o })
        cls.__index = cls
        cls.new = function(_, attr)
            local inst = {}
            if type(attr) == "table" then
                for k, v in pairs(attr) do
                    if inst[k] == nil then inst[k] = v end
                end
            end
            setmetatable(inst, { __index = cls })
            inst.__index = cls
            if inst.init then inst:init() end
            return inst
        end
        return cls
    end,
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    nextTick = function(_, f) f() end,
    close = function() end,
}
package.loaded["ui/widget/infomessage"]   = { new = function() return {} end }
package.loaded["ui/widget/confirmbox"]    = { new = function() return {} end }
package.loaded["ui/widget/inputdialog"]   = { new = function() return { getInputValue = function() return "" end } end }

-- G_reader_settings 桩：独立存储表，供各回调保存/读取（用于验证回调保存了“正确的值”）
local __store = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return __store[k] end,
    saveSetting = function(_, k, v) __store[k] = v end,
}
-- fontlist 桩：模拟 3 个字体，用于验证字体项回调各自保存正确的字体名
package.loaded["fontlist"] = {
    getFontList = function() return { "/fonts/a.ttf", "/fonts/b.ttf", "/fonts/c.ttf" } end,
    fontinfo = {
        ["/fonts/a.ttf"] = { { name = "FontA" } },
        ["/fonts/b.ttf"] = { { name = "FontB" } },
        ["/fonts/c.ttf"] = { { name = "FontC" } },
    },
}

------------------------------------------------------------------
-- 3) 加载真实 MenuSorter 与阅读菜单 order（来自 KOReader 源码）
------------------------------------------------------------------
package.path = here .. "fixtures/?.lua;" .. package.path
local MenuSorter = require("menusorter")
local order = require("reader_menu_order")

------------------------------------------------------------------
-- 4) 构造最小但合规的 menu_items（模拟 KOReader 阅读菜单框架传入的结构）
------------------------------------------------------------------
local menu_items = {}
-- 顶部菜单按钮骨架（KOMenu:menu_buttons 必须存在，否则 MenuSorter 第140行崩溃）
menu_items["KOMenu:menu_buttons"] = {
    { id = "navi",    sub_item_table = {} },
    { id = "typeset", sub_item_table = {} },
    { id = "setting", sub_item_table = {} },
    { id = "tools",   sub_item_table = {} },   -- 菜单按钮骨架里的 tools 按钮
    { id = "search",  sub_item_table = {} },
}
-- 内置“工具”菜单项本身（KOReader 由 getDefaultMenuButtons 创建，MenuSorter 通过顶层 key 处理）
menu_items["tools"] = { id = "tools", sorting_hint = "tools", sub_item_table = {} }
-- order["tools"] 里引用的若干内置子项（让 MenuSorter 不告警即可）
menu_items["bookmark"]  = { text = "Bookmark" }
menu_items["highlight"] = { text = "Highlight" }
-- 一个“其它插件”的菜单项，用来验证它不会消失
local orig_other = { text = "其它插件示例", sorting_hint = "tools" }
menu_items["other_plugin"] = orig_other

-- 记录内置 tools 的原始 sub_item_table 引用，用于验证未被改写
local orig_tools_sub = menu_items["tools"].sub_item_table

------------------------------------------------------------------
-- 5) 加载本插件并调用 addToMainMenu（等价于 KOReader 框架调用）
------------------------------------------------------------------
package.path = root .. "?.lua;" .. package.path
local TXT2EPUB = require("main")
-- 不通过 :new() 触发 init（避免涉及 self.ui.menu），直接用类作为 self
local self = setmetatable({}, { __index = TXT2EPUB })
self.ui = { document = { file = "/mnt/onboard/books/测试.txt" } }

self:addToMainMenu(menu_items)

------------------------------------------------------------------
-- 6) 断言
------------------------------------------------------------------
local failures = 0
local function check(name, cond, extra)
    if cond then
        print("  PASS  " .. name)
    else
        failures = failures + 1
        print("  FAIL  " .. name .. (extra and ("  -> " .. extra) or ""))
    end
end

-- (1) 内置 tools 未被改写
check("内置 tools.sub_item_table 未被改写",
    menu_items["tools"].sub_item_table == orig_tools_sub,
    "addToMainMenu 不应触碰内置 tools 内部结构")

-- (2) 顶层插件项存在且带 sorting_hint
check("menu_items.txt2epub 已注册", type(menu_items.txt2epub) == "table")
check("txt2epub 带 sorting_hint = \"tools\"",
    menu_items.txt2epub and menu_items.txt2epub.sorting_hint == "tools",
    "缺少 sorting_hint 会让 MenuSorter 报 hint 错误")
check("txt2epub 有 7 个子菜单项",
    menu_items.txt2epub and #menu_items.txt2epub.sub_item_table == 7,
    menu_items.txt2epub and ("实际=" .. #menu_items.txt2epub.sub_item_table) or "nil")
check("开始转换项带 enabled_func",
    menu_items.txt2epub and type(menu_items.txt2epub.sub_item_table[1].enabled_func) == "function")

-- (3) 用真实 MenuSorter 跑合并排序，必须不抛错
local ok, res = pcall(function()
    return MenuSorter:mergeAndSort("reader", menu_items, order)
end)
check("MenuSorter:mergeAndSort 不崩溃", ok, ok and "" or tostring(res))

-- (4) 验证最终菜单：tools 菜单存在，且包含 TXT 转 EPUB 与其它插件
if ok then
    local tools_btn
    if type(res) == "table" then
        for _, btn in ipairs(res) do
            if btn and btn.id == "tools" then tools_btn = btn; break end
        end
    end
    check("工具菜单按钮存在（否则工具菜单整片消失）", tools_btn ~= nil)

    if tools_btn then
        local found_self, found_other
        for _, it in ipairs(tools_btn.sub_item_table or {}) do
            if it.text == "TXT2EPUB" then found_self = it end
            if it == orig_other then found_other = it end
        end
        check("工具菜单包含“TXT2EPUB”", found_self ~= nil)
        check("TXT2EPUB 有 7 个子菜单项",
            found_self and #found_self.sub_item_table == 7,
            found_self and ("实际=" .. #found_self.sub_item_table) or "nil")
        check("其它插件菜单项仍在（未消失）", found_other ~= nil)
    end
end

------------------------------------------------------------------
-- (5) 回归测试：排版预设子菜单（sub_item_table_func）不得因“for _,”遮蔽
--     gettext 函数 `_` 而崩溃，且每个菜单项的 text 必须是字符串。
--     此前该 bug 表现为：进入「排版预设…」即触发
--     "attempt to call local '_' (a number value)" 使 KOReader 整体崩溃退出。
------------------------------------------------------------------
do
    local ok_gen, menu = pcall(function() return self:gen_style_menu() end)
    check("gen_style_menu() 不崩溃（sub_item_table_func）", ok_gen, ok_gen and "" or tostring(menu))
    if ok_gen then
        check("排版预设子菜单返回 6 个条目（4 预设 + 自定义参数 + 正文字体）",
            type(menu) == "table" and #menu == 6,
            type(menu) == "table" and ("实际=" .. #menu) or "非 table")
        local all_str = true
        for i, it in ipairs(menu or {}) do
            -- text 必须是字符串；若 `_` 被数字遮蔽调用，此处会拿到 number 而失败
            if type(it.text) ~= "string" then all_str = false end
            check("  条目#" .. i .. " text 为字符串（非被遮蔽的 _ 数字）",
                type(it.text) == "string", "类型=" .. type(it.text))
        end
        check("排版预设所有条目 text 均为字符串", all_str)
        -- 前 4 项应为预设（含自定义），回调可安全执行
        local keys_ok = (menu[1].text ~= nil) and (menu[2].text ~= nil)
            and (menu[3].text ~= nil) and (menu[4].text ~= nil)
        check("四套预设条目存在且可调用回调", keys_ok
            and type(menu[1].callback) == "function"
            and type(menu[2].callback) == "function"
            and type(menu[3].callback) == "function"
            and type(menu[4].callback) == "function")
        -- 第 5 项为“自定义参数…”入口（sub_item_table_func 惰性子菜单，在 TouchMenu 里展开）；
        -- 第 6 项为“正文字体…”子菜单入口
        check("含“自定义参数…”子菜单入口", type(menu[5].sub_item_table_func) == "function")
        check("含“正文字体…”子菜单入口", type(menu[6].sub_item_table_func) == "function")
        -- 子菜单可被惰性构建且不崩溃
        local ok_c, cm = pcall(function() return self:gen_custom_menu() end)
        check("gen_custom_menu() 可构建", ok_c, ok_c and "" or tostring(cm))
        local ok_f, fm = pcall(function() return self:gen_font_menu() end)
        check("gen_font_menu() 可构建（无 ui/font 时回退手动输入）", ok_f, ok_f and "" or tostring(fm))
    end
end

------------------------------------------------------------------
-- (6) 回归测试：Lua 5.1 闭包捕获 —— for 循环变量是“共享 upvalue”，
--     若不拷贝，所有 callback 都会保存“最后一个值”（选哪个都存成最后一项）。
--     验证：点第 N 项，保存的正是第 N 项的值。
------------------------------------------------------------------
do
    -- 预设：点第 N 项应保存第 N 个 key
    local ok_g, menu = pcall(function() return self:gen_style_menu() end)
    if ok_g and menu then
        __store.txt2epub_style = nil
        menu[1].callback()
        check("预设#1 回调保存 compact", __store.txt2epub_style == "compact", tostring(__store.txt2epub_style))
        menu[2].callback()
        check("预设#2 回调保存 standard", __store.txt2epub_style == "standard", tostring(__store.txt2epub_style))
        menu[3].callback()
        check("预设#3 回调保存 relaxed", __store.txt2epub_style == "relaxed", tostring(__store.txt2epub_style))
        menu[4].callback()
        check("预设#4 回调保存 custom", __store.txt2epub_style == "custom", tostring(__store.txt2epub_style))
    end

    -- 字体：点第 N 个字体应保存第 N 个名字（fm[1]=默认, fm[2..4]=FontA/B/C）
    local ok_f, fm = pcall(function() return self:gen_font_menu() end)
    if ok_f and fm then
        __store.txt2epub_font = nil
        fm[2].callback()
        check("字体#1 回调保存 FontA", __store.txt2epub_font == "FontA", tostring(__store.txt2epub_font))
        fm[3].callback()
        check("字体#2 回调保存 FontB", __store.txt2epub_font == "FontB", tostring(__store.txt2epub_font))
        fm[4].callback()
        check("字体#3 回调保存 FontC", __store.txt2epub_font == "FontC", tostring(__store.txt2epub_font))
        fm[1].callback()
        check("默认项回调清除字体", __store.txt2epub_font == nil, tostring(__store.txt2epub_font))
    end

    -- 自定义参数：点第 N 个选项应保存第 N 个值（行高 {120,140,155,180,200}）
    local ok_c, cm = pcall(function() return self:gen_custom_menu() end)
    if ok_c and cm and type(cm[1].sub_item_table_func) == "function" then
        local opts = cm[1].sub_item_table_func()
        __store.txt2epub_custom_style = {}
        opts[1].callback()
        check("行高选项#1 保存 120", __store.txt2epub_custom_style.line_height == 120, tostring(__store.txt2epub_custom_style.line_height))
        opts[3].callback()
        check("行高选项#3 保存 155", __store.txt2epub_custom_style.line_height == 155, tostring(__store.txt2epub_custom_style.line_height))
        opts[5].callback()
        check("行高选项#5 保存 200", __store.txt2epub_custom_style.line_height == 200, tostring(__store.txt2epub_custom_style.line_height))
    end
end

print("")
if failures == 0 then
    print("ALL MENU TESTS PASSED")
else
    print(failures .. " MENU TEST(S) FAILED")
    os.exit(1)
end
