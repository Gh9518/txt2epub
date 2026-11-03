--[[--
test_font_display.lua
验证「正文字体」菜单的本地化显示名逻辑（txt2epub.koplugin 修复项）：
  - 中文界面下，中文字体显示中文族名 + 样式（如 "思源宋体 · 粗体"）
  - 英文字体显示英文族名 + 样式（如 "Liberation Serif · Bold"）
  - Regular 样式不额外标注（避免列表冗余）
  - 取不到本地化名时，回退英文族名 + 由 bold/italic 推导的样式
  - 存储值（font.name）始终是英文族名，确保 CSS font-family 可被系统识别

运行：cd txt2epub.koplugin && lua5.3 test/test_font_display.lua
--]]

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
if not table.maxn then
    table.maxn = function(t)
        local m = 0
        for k, _ in pairs(t) do
            if type(k) == "number" and k > m then m = k end
        end
        return m
    end
end

package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["logger"] = { warn = function() end, err = function() end, dbg = function() end }
package.loaded["dbg"] = { dassert = function(cond, msg) assert(cond, msg) end }
package.loaded["device"] = setmetatable({}, { __index = function() return function() return false end end })
package.loaded["ffi/util"] = {
    basename = function(p) return (p:gsub("^.*/", "")) end,
    dirname  = function(p) return (p:gsub("/[^/]*$", "")) end,
    joinPath = function(a, b) return a .. "/" .. b end,
}
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(o)
        o = o or {}
        local cls = {}
        setmetatable(cls, { __index = o })
        cls.__index = cls
        cls.new = function(_, attr)
            local inst = {}
            if type(attr) == "table" then
                for k, v in pairs(attr) do if inst[k] == nil then inst[k] = v end end
            end
            setmetatable(inst, { __index = cls })
            return inst
        end
        return cls
    end,
}
package.loaded["ui/uimanager"]  = { show = function() end, nextTick = function(_, f) f() end, close = function() end }
package.loaded["ui/widget/infomessage"] = { new = function() return {} end }
package.loaded["ui/widget/confirmbox"]  = { new = function() return {} end }
package.loaded["ui/widget/inputdialog"] = { new = function() return { getInputValue = function() return "" end } end }

-- G_reader_settings 桩：
--   language = "zh_CN" 模拟中文界面；字体名走本地化名表
local __store = { language = "zh_CN" }
_G.G_reader_settings = {
    readSetting = function(_, k) return __store[k] end,
    saveSetting = function(_, k, v) __store[k] = v end,
    has = function(_, k) return __store[k] ~= nil end,
}

-- fontlist 桩：
--   1) 中文字体 Noto Serif CJK SC（含 zh 本地化族名"思源宋体"与样式"常规/粗体"）
--   2) 英文字体 Liberation Serif（无 zh 名，靠 bold/italic 推导样式）
--   3) 仅英文族名、无 names 的老字体（强制回退路径）
--   names 结构：names[语言][name_id]，1=族名 2=样式 4=全名（与 KOReader harfbuzz 名表一致）
package.loaded["fontlist"] = {
    getFontList = function()
        return { "/fonts/noto_cjk.ttf", "/fonts/liberation.ttf", "/fonts/legacy.ttf" }
    end,
    fontinfo = {
        ["/fonts/noto_cjk.ttf"] = {
            { name = "Noto Serif CJK SC", bold = false, italic = false,
              names = { zh = { [1] = "思源宋体", [2] = "常规", [4] = "思源宋体 常规" },
                        en = { [1] = "Noto Serif CJK SC", [2] = "Regular", [4] = "Noto Serif CJK SC Regular" } } },
            { name = "Noto Serif CJK SC", bold = true, italic = false,
              names = { zh = { [1] = "思源宋体", [2] = "粗体", [4] = "思源宋体 粗体" },
                        en = { [1] = "Noto Serif CJK SC", [2] = "Bold", [4] = "Noto Serif CJK SC Bold" } } },
        },
        ["/fonts/liberation.ttf"] = {
            { name = "Liberation Serif", bold = false, italic = true, names = {} },
        },
        ["/fonts/legacy.ttf"] = {
            { name = "Legacy Font", bold = false, italic = false },  -- 无 names 表
        },
    },
}

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then
        passes = passes + 1
        print(string.format("[PASS] %s", name))
    else
        fails = fails + 1
        print(string.format("[FAIL] %s  %s", name, extra or ""))
    end
end

package.path = root .. "?.lua;" .. package.path
local TXT2EPUB = require("main")
local self = setmetatable({}, { __index = TXT2EPUB })

local fonts = self:get_font_list()
local by_name = {}
for _, f in ipairs(fonts) do by_name[f.name] = f end

-- 1) 中文字体 Regular：显示中文族名，不标注 Regular/常规
check("中文字体(Regular)显示中文名且无样式后缀",
    by_name["Noto Serif CJK SC"] and by_name["Noto Serif CJK SC"].display == "思源宋体",
    by_name["Noto Serif CJK SC"] and by_name["Noto Serif CJK SC"].display)

-- 2) get_font_list 按族名去重，中文字体只保留首个 face（Regular），其 display 为中文名且无样式后缀
--    （Bold face 的展示由下方 _font_display 单测覆盖）
check("中文字体去重后仅一个条目且为中文名",
    by_name["Noto Serif CJK SC"] and by_name["Noto Serif CJK SC"].display == "思源宋体"
    and (function()
        local n = 0
        for _, f in ipairs(fonts) do if f.name == "Noto Serif CJK SC" then n = n + 1 end end
        return n == 1
    end)(), by_name["Noto Serif CJK SC"] and by_name["Noto Serif CJK SC"].display)

-- 3) 英文字体 Italic：无 zh 名 → 英文族名 + 由 italic 推导 Bold/Italic
local lib = by_name["Liberation Serif"]
check("英文字体(Italic)显示英文族名+Italic", lib and lib.display == "Liberation Serif · Italic", lib and lib.display)

-- 4) 老字体无 names：回退英文族名，样式由 bold/italic 推导（此处 Regular → 仅族名）
local leg = by_name["Legacy Font"]
check("无 names 字体回退英文族名(Regular不标注)", leg and leg.display == "Legacy Font", leg and leg.display)

-- 5) 存储值始终是英文族名（保证 CSS font-family 可用）
check("存储 name 为英文族名 (Noto)", by_name["Noto Serif CJK SC"] and by_name["Noto Serif CJK SC"].name == "Noto Serif CJK SC")
check("存储 name 为英文族名 (Liberation)", lib and lib.name == "Liberation Serif")

-- 6) 单测 _font_display：中文字体 Bold face 应显示 "思源宋体 · 粗体"
local bold_face = { name = "Noto Serif CJK SC", bold = true, italic = false,
    names = { zh = { [1] = "思源宋体", [2] = "粗体" }, en = { [1] = "Noto Serif CJK SC", [2] = "Bold" } } }
check("_font_display 中文Bold=思源宋体 · 粗体",
    self:_font_display("Noto Serif CJK SC", bold_face, "zh-cn") == "思源宋体 · 粗体",
    self:_font_display("Noto Serif CJK SC", bold_face, "zh-cn"))

-- 7) 英文界面下同一 Bold face：显示英文 "Noto Serif CJK SC · Bold"
check("_font_display 英文界面Bold=英文名 · Bold",
    self:_font_display("Noto Serif CJK SC", bold_face, "en") == "Noto Serif CJK SC · Bold",
    self:_font_display("Noto Serif CJK SC", bold_face, "en"))

-- 8) 无 names、bold+italic → "Bold Italic"
check("_font_display 无names bold+italic=Bold Italic",
    self:_font_display("X", { name = "X", bold = true, italic = true }, "zh-cn") == "X · Bold Italic",
    self:_font_display("X", { name = "X", bold = true, italic = true }, "zh-cn"))

-- 9) 样式为 nil / 空 → 仅族名
check("_font_display 样式缺失=仅族名",
    self:_font_display("Y", { name = "Y" }, "zh-cn") == "Y",
    self:_font_display("Y", { name = "Y" }, "zh-cn"))

print(string.format("\n字体显示测试：%d 通过，%d 失败", passes, fails))
os.exit(fails == 0 and 0 or 1)
