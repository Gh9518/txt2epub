-- main.lua
-- txt2epub（TXT 排版助手）KOReader 插件主逻辑
-- 运行环境：KOReader（LuaJIT / Lua 5.1）
--
-- 重要：KOReader 通过 plugin.new(plugin, ui) 实例化插件，因此本模块必须是一个
--        WidgetContainer 子类（由 extend 提供 new 方法），并在阅读（文档）上下文加载
--        （is_doc_only = true，因为转换需要当前打开的 TXT 文档 self.ui.document）。

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local util = require("ffi/util")
local _ = require("gettext")

-- 核心转换模块（纯 Lua，无 KOReader 依赖）
local Converter = require("converter")

-- 文件是否存在：用 Lua 标准库 io.open 判断（所有 KOReader 版本均可用）。
-- 注意：不依赖 util.fileExists —— 部分 KOReader 版本该函数不存在，
-- 一旦调用即触发 "attempt to call field 'fileExists' (a nil value)" 并 panic 崩溃进程。
local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local TXT2EPUB = WidgetContainer:extend{
    name = "txt2epub",
    is_doc_only = true,
}

------------------------------------------------------------------------
-- 初始化：注册到阅读器主菜单
------------------------------------------------------------------------
function TXT2EPUB:init()
    self.ui.menu:registerToMainMenu(self)
end

-- KOReader 构建菜单时调用本函数并传入 menu_items 表。
-- 关键：必须用 sorting_hint 让框架把本插件归到对应菜单（"tools"=顶部工具菜单），
-- 绝不能手动改写内置的 menu_items.tools.sub_item_table —— 那样会破坏
-- MenuSorter:mergeAndSort 期望的结构，导致整个阅读器主菜单构建崩溃
-- （结果就是所有插件的菜单项都不再显示）。
function TXT2EPUB:addToMainMenu(menu_items)
    menu_items.txt2epub = {
        text = _("TXT2EPUB"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("开始转换"),
                callback = function()
                    self:convert()
                end,
                -- 注意：旧实现用 enabled_func 判断“当前文档是否为 .txt/.docx”，
                -- 一旦判断为否，TouchMenu 会把本项置灰且不可点击，且【没有任何提示】，
                -- 用户完全不知道为什么点不了、也不知道当前文件被识别成了什么 —— 即本次“按钮变灰”的根因。
                -- 改为：按钮始终可点，真正的类型校验放到 convert() 内，并在不支持时给出明确提示
                -- （含当前识别到的扩展名），让用户能立刻定位问题。
            },
            {
                text = _("排版预设…"),
                sub_item_table_func = function()
                    return self:gen_style_menu()
                end,
            },
            {
                text = _("正文字体…"),
                sub_item_table_func = function()
                    return self:gen_font_menu()
                end,
            },
            {
                text = _("设置章节标题正则…"),
                callback = function()
                    self:edit_pattern()
                end,
            },
            {
                text = _("恢复默认正则"),
                callback = function()
                    self:reset_pattern()
                end,
            },
            {
                text = _("设置首行缩进…"),
                callback = function()
                    self:edit_indent()
                end,
            },
            {
                text = _("设置缩进步长（空格数）…"),
                callback = function()
                    self:edit_indent_step()
                end,
            },
        },
    }
end

------------------------------------------------------------------------
-- 文件类型校验
------------------------------------------------------------------------
-- 可由插件「自解析」的扩展名（读磁盘源文件，结果与 KOReader 版本无关）：
--   .txt                  -> 章节正则 / 空格缩进
--   .docx                 -> OOXML（Word 标题样式 -> 多级目录）
--   .html/.htm/.md/.markdown -> markup.lua（<hN> / # 标题 -> 多级目录）
--   .rtf                  -> rtf.lua（直接解析源文件，正确解码 \u 负数转义；
--                            v2.1.6 起不再走 KOReader DOM，避免乱码/截断）
-- 其余格式（.doc/.fb2/.epub 等）走 KOReader 已打开文档的 DOM 兜底。
local SELF_PARSE_EXT = {
    [".txt"] = true, [".docx"] = true,
    [".html"] = true, [".htm"] = true,
    [".md"] = true, [".markdown"] = true,
    [".rtf"] = true,
}

function TXT2EPUB:is_txt_file()
    return self:file_ext() == ".txt"
end

-- 是否为 Word(.docx) 源文件（插件可自解析）。
-- 2.0.0：.doc（二进制 OLE2）与 .rtf/.fb2/epub/html 等由通用 DOM 流程兜底，
-- 不再属于"不支持"，故此类判断仅用于自解析分支的识别，不再用于置灰菜单项。
function TXT2EPUB:is_docx_file()
    return self:file_ext() == ".docx"
end

-- 取得文件扩展名（小写，含点），如 ".txt" / ".docx" / ".doc"
-- 优先使用传入的 file；未传则取当前已打开文档的路径。
-- 分派决策见 convert()：.txt/.docx 走插件自解析（读磁盘源路径，可靠），
-- 其余格式走通用 DOM 兜底。文件选择器仅在"完全没有已打开文档"时启用。
function TXT2EPUB:file_ext(file)
    file = file or self:_current_file()
    if not file or type(file) ~= "string" or file == "" then return nil end
    local e = string.lower(file:match("%.([^%.]+)$") or "")
    if e == "" then return nil end
    return "." .. e
end

-- 输出文件名：按「源格式」加一个小标记，避免同名不同格式互相覆盖。
-- 例如 big_novel.txt / big_novel.docx / big_novel.html 分别输出
--   big_novel_txt.epub / big_novel_docx.epub / big_novel_html.epub
-- 若 base 本身已经以该标记结尾（例如重复转换已带标记的源），则不重复追加。
-- 这里做成纯函数（可由单元测试直接调用）。
function TXT2EPUB.output_name_with_ext(base, ext)
    base = base or "未命名"
    local tag = nil
    if ext and ext ~= "" then
        tag = tostring(ext):gsub("^%.", ""):lower():gsub("[^%w]", "")
    end
    if not tag or tag == "" then return base .. ".epub" end
    local suffix = "_" .. tag
    -- 已带标记（大小写不敏感）则原样返回，防止 big_txt_txt.epub
    if base:lower():match(suffix:lower() .. "$") then
        return base .. ".epub"
    end
    return base .. suffix .. ".epub"
end

function TXT2EPUB:_output_name(base, ext)
    return TXT2EPUB.output_name_with_ext(base, ext)
end

-- 当前已打开文档的路径（容错：ui/document 未就绪时返回 nil）
function TXT2EPUB:_current_file()
    local ok, doc = pcall(function() return self.ui and self.ui.document end)
    return ok and doc and doc.file or nil
end

------------------------------------------------------------------------
-- 设置读取（持久化到 KOReader 全局设置）
------------------------------------------------------------------------
function TXT2EPUB:get_pattern()
    local p = G_reader_settings and G_reader_settings:readSetting("txt2epub_pattern")
    return (p and p ~= "") and p or nil
end

function TXT2EPUB:get_indent()
    local v = G_reader_settings and G_reader_settings:readSetting("txt2epub_indent")
    return (v and v ~= "") and v or "2em"
end

-- 缩进模式：每个子层级对应的前导空格数（默认 4）
function TXT2EPUB:get_indent_step()
    local v = G_reader_settings and G_reader_settings:readSetting("txt2epub_indent_step")
    v = tonumber(v)
    if not v or v < 1 then v = 4 end
    return math.floor(v)
end

------------------------------------------------------------------------
-- 排版预设（借鉴 txtstyle.koplugin 的“快速风格”）
--   注意：预设只在【转换时】一次性烘焙进 EPUB 的 style.css，不安装任何阅读期
--   钩子，因此不会增加 KOReader 的常驻内存 / CPU（对照 txtstyle 的持久钩子机制）。
------------------------------------------------------------------------
-- 当前生效的预设名（默认 standard；支持自定义 custom）
function TXT2EPUB:get_style_name()
    local s = G_reader_settings and G_reader_settings:readSetting("txt2epub_style")
    if s == "custom" then return "custom" end
    if type(s) ~= "string" or not Converter.STYLE_PRESETS[s] then return "standard" end
    return s
end

-- 当前生效的自定义参数表（仅 custom 预设使用；缺省回退到 standard）
function TXT2EPUB:get_custom_style()
    local t = G_reader_settings and G_reader_settings:readSetting("txt2epub_custom_style")
    if type(t) ~= "table" then t = {} end
    return t
end

-- 解析为完整的排版参数表（合并预设 / 自定义参数 + 自定义字体）
-- 说明：选择的预设会被持久化保存，因此“每次转换若不修改就默认用这个模式”——
-- 选了“自定义”并调好参数后，它即成为默认排版，直到用户再次更改。
function TXT2EPUB:get_style()
    local name = self:get_style_name()
    local style_arg
    if name == "custom" then
        style_arg = self:get_custom_style()  -- 已保存的自定义参数表
    else
        style_arg = name
    end
    local style = Converter.resolve_style(style_arg)
    local font = G_reader_settings and G_reader_settings:readSetting("txt2epub_font") or ""
    if type(font) == "string" and font ~= "" then style.font = font end
    return style
end

-- 读取 KOReader 已安装的字体（用于“正文字体”选择）。
-- KOReader 的字体列表来自 require("fontlist") 单例：getFontList() 返回“字体文件路径”数组，
-- 友好族名在 FontList.fontinfo[path][1].name（如 "Noto Serif CJK SC"）。
-- 注意：ui/font 的 Font 对象【并没有】 getFontList 方法——旧实现误用 Font:getFontList()，
-- 被 pcall 吞掉后恒返回空表，导致字体菜单永远只显示“请手动输入”、无法预览/选择已有字体。
-- 取字体的“显示名”：本地化族名（中文界面→中文名）+ 样式（如 粗体/Bold）。
-- info 为 fontinfo[path][1]（getInfo() 产物，含 name / bold / italic / names）。
--   names 是 harfbuzz 名表：names[语言][name_id]，name_id 1=族名(FONT_FAMILY)、
--   2=样式(FONT_SUBFAMILY)、4=全名(FULL_NAME)。中文界面下优先取 names["zh"] 的中文族名与样式。
-- 取不到本地化名时，回退英文族名 + 由 bold/italic 推导的样式。
function TXT2EPUB:_font_display(fam_en, info, lang)
    local fam = fam_en
    local style
    local names = info and info.names
    if type(names) == "table" then
        -- 与 KOReader FontList:getLocalizedFontName 同口径：先精确语言，再退到语言主码（zh-CN→zh）
        local loc = names[lang] or names[lang and lang:match("%w+")] or names["en"] or names["en-us"]
        if type(loc) == "table" then
            fam = loc[1] or loc[4] or fam        -- 1=FONT_FAMILY, 4=FULL_NAME
            style = loc[2]                        -- 2=FONT_SUBFAMILY（如 “粗体”/“Bold”）
        end
    end
    -- 样式兜底：由 bold/italic 布尔推导（英文）
    if not style or style == "" then
        if info then
            local b = info.bold and true or false
            local i = info.italic and true or false
            if b and i then style = "Bold Italic"
            elseif b then style = "Bold"
            elseif i then style = "Italic"
            else style = "Regular" end
        else
            style = "Regular"
        end
    end
    if not fam or fam == "" then fam = fam_en end
    style = (type(style) == "string" and style or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- Regular/常规 视为默认样式，不额外标注，避免列表冗余
    if style:lower() == "regular" or style == "常规" or style == "标准" or style == "正常" or style == "" then
        return fam
    end
    return fam .. " · " .. style
end

function TXT2EPUB:get_font_list()
    -- 缓存：字体列表一经扫描即复用，避免每次打开「正文字体…」都重扫字体目录
    -- （首次扫描在 Kindle 上可能耗时，正是“卡在扫描目录”的另一来源）。
    if self._font_cache and #self._font_cache > 0 then return self._font_cache end
    local out = {}
    local seen = {}
    -- 当前 UI 语言主码（zh-CN→zh / en / ...），用于取本地化字体名
    local lang = "en"
    if G_reader_settings then
        local L = G_reader_settings:readSetting("language")
        if L then lang = tostring(L):lower():gsub("_", "-") end
    end
    local ok, FontList = pcall(require, "fontlist")
    if ok and FontList and type(FontList.getFontList) == "function" then
        local ok2, fl = pcall(function() return FontList:getFontList() end)
        self:_log(string.format("fontlist:getFontList ok=%s 类型=%s 条数=%s",
            tostring(ok2), type(fl), type(fl) == "table" and tostring(#fl) or "?"))
        if ok2 and type(fl) == "table" then
            for _, p in ipairs(fl) do
                if type(p) == "string" then
                    local fam
                    local info = FontList.fontinfo and FontList.fontinfo[p]
                    local face = (type(info) == "table" and info[1]) or nil
                    if face then
                        fam = face.name
                    end
                    if not fam or fam == "" then
                        fam = p:match("([^/]+)%.%w+$") or p:match("([^/]+)$") or p
                    end
                    if fam and not seen[fam] then
                        seen[fam] = true
                        -- name：英文族名，作为存储值与 CSS font-family（系统可识别）
                        -- display：本地化显示名（中文界面→中文名 + 样式），仅用于菜单展示
                        out[#out + 1] = { name = fam, display = self:_font_display(fam, face, lang), path = p }
                    end
                end
            end
        end
    end
    -- 降级：fontinfo 解析为空时，改用 fontnames（家族名 -> face 数组）的 key 作为字体名兜底
    if #out == 0 and ok and FontList and type(FontList.fontnames) == "table" then
        for name in pairs(FontList.fontnames) do
            if type(name) == "string" and name ~= "" and not seen[name] then
                seen[name] = true
                out[#out + 1] = { name = name, display = name, path = "" }
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
    end
    self:_log(string.format("解析到 %d 个可用字体", #out))
    self._font_cache = out
    return out
end

local STYLE_LABELS = {
    compact = "紧凑 (Compact)",
    standard = "标准 (Standard)",
    relaxed = "宽松大字 (Relaxed)",
}

-- 排版预设子菜单（一键套用；带 checked_func 的条目点击后不关菜单，方便连试）
function TXT2EPUB:gen_style_menu()
    local items = {}
    -- 注意：循环变量不能用 `_`，否则会遮蔽文件顶部的 gettext 函数 `_`，
    -- 导致循环体内 `_()` 调用把数字当函数（即本次“排版预设菜单崩溃”的根因）。
    for _i, key in ipairs({ "compact", "standard", "relaxed", "custom" }) do
        local label = (key == "custom") and _("自定义 (Custom)") or _(STYLE_LABELS[key])
        local this_key = key  -- 拷贝循环变量：Lua 5.1 里 for 循环变量是共享 upvalue，
                              -- 不拷贝会导致“选任何预设都存成最后一个（custom）”
        items[#items + 1] = {
            text = label,
            checked_func = function()
                return self:get_style_name() == this_key
            end,
            callback = function()
                if G_reader_settings then
                    G_reader_settings:saveSetting("txt2epub_style", this_key)
                end
            end,
        }
    end
    items[#items + 1] = {
        text = _("自定义参数…"),
        separator = true,
        -- 关键：必须用 sub_item_table_func（惰性子菜单）而不是 callback 打开独立 Menu。
        -- KOReader 的 TouchMenu 会调用 sub_item_table_func 展开子菜单；而旧实现用
        -- require("ui/widget/menu") 的 Menu（分页列表）打开独立菜单，但 Menu:onMenuSelect
        -- 只识别 sub_item_table（静态表），【不识别 sub_item_table_func】——导致自定义参数里的
        -- 数值项（全部用 sub_item_table_func 展开可选值）点了毫无反应，即「无法更改参数」。
        sub_item_table_func = function()
            return self:gen_custom_menu()
        end,
    }
    items[#items + 1] = {
        text = _("正文字体…"),
        sub_item_table_func = function()
            return self:gen_font_menu()
        end,
    }
    return items
end

-- 自定义参数子菜单：逐项调整排版参数并即时保存（构成可复用的“自定义预设”）。
-- 本菜单通过「排版预设 › 自定义参数…」的 sub_item_table_func 在 TouchMenu 里展开；
-- 数值参数用「预设选项列表」（sub_item_table_func）而非 InputDialog 自由输入——后者会弹出
-- 虚拟键盘，在部分设备/输入法插件（如 pinyin_enhancement）下会崩溃（crash.log 中
-- inputtext.lua 的 `added_charlist nil` 崩溃即源于此），且墨水屏上逐字输入体验差。
-- 点击选项即选、即保存，无需输入、不会崩溃、可连续修改。
function TXT2EPUB:gen_custom_menu()
    -- 数值参数项：子菜单列出可选值，checked_func 标记当前值，点击即保存。
    -- text/checked 均用实时读取（text_func / 动态 checked_func），确保改动后菜单刷新时
    -- 显示值与勾选标记立即更新（旧实现缓存 cur_val，改动后勾选与显示都停留在旧值）。
    local function num_item(label, field, values)
        return {
            text_func = function()
                local v = Converter.resolve_style(self:get_custom_style())[field]
                return label .. "：" .. tostring(v)
            end,
            sub_item_table_func = function()
                local items = {}
                for _i, v in ipairs(values) do
                    local this_v = v  -- 拷贝循环变量，避免闭包共享导致“选哪个都存成最后一个值”
                    items[#items + 1] = {
                        text = tostring(this_v),
                        checked_func = function()
                            return Converter.resolve_style(self:get_custom_style())[field] == this_v
                        end,
                        callback = function()
                            self:_save_custom_field(field, this_v)
                            UIManager:show(InfoMessage:new{ text = label .. "：" .. tostring(this_v), timeout = 1.2 })
                        end,
                    }
                end
                return items
            end,
        }
    end
    local items = {
        num_item(_("行高（%）"), "line_height", { 120, 140, 155, 180, 200 }),
        num_item(_("段间距（0.01em）"), "para_spacing", { 0, 20, 30, 50, 80 }),
        num_item(_("首行缩进（0.01em）"), "text_indent", { 0, 100, 200, 300 }),
        num_item(_("字号缩放（%）"), "font_scale", { 85, 100, 110, 125, 140 }),
        num_item(_("字距（0.01em）"), "letter_spacing", { 0, 25, 50, 100 }),
        {
            text_func = function()
                local j = Converter.resolve_style(self:get_custom_style()).justify
                return _("两端对齐（当前：") .. (j and _("开") or _("关")) .. "）"
            end,
            checked_func = function() return self:get_custom_style().justify ~= false end,
            callback = function()
                local t = self:get_custom_style()
                t.justify = not (t.justify ~= false)  -- 切换（默认开）
                if G_reader_settings then
                    G_reader_settings:saveSetting("txt2epub_custom_style", t)
                    G_reader_settings:saveSetting("txt2epub_style", "custom")
                end
                -- 带 checked_func，TouchMenu 点击后会自动 updateItems 刷新（含 text_func），无需手动重开
            end,
        },
        {
            text = _("恢复自定义参数为标准值"),
            separator = true,
            callback = function(menu_instance)
                if G_reader_settings then
                    G_reader_settings:saveSetting("txt2epub_custom_style", {})
                    G_reader_settings:saveSetting("txt2epub_style", "custom")
                end
                -- 无 checked_func，TouchMenu 不会自动刷新；手动刷新当前菜单，更新各参数显示
                if menu_instance and menu_instance.updateItems then
                    menu_instance:updateItems()
                end
            end,
        },
    }
    return items
end

-- 保存单个自定义参数（并自动把当前预设切到 custom）
function TXT2EPUB:_save_custom_field(field, value)
    local t = self:get_custom_style()
    t[field] = value
    if G_reader_settings then
        G_reader_settings:saveSetting("txt2epub_custom_style", t)
        G_reader_settings:saveSetting("txt2epub_style", "custom")
    end
end

-- 正文字体子菜单：列出 KOReader 已安装字体，点击即选用（预览本地字体）。
-- 「默认（衬线体）」始终可选，不依赖字体扫描结果，保证任何情况下都有可点选项。
function TXT2EPUB:gen_font_menu()
    local fonts = self:get_font_list()  -- { {name=家族名, path=文件路径}, ... }
    local items = {}
    items[#items + 1] = {
        text = _("默认（衬线体）"),
        checked_func = function()
            local cur = G_reader_settings and G_reader_settings:readSetting("txt2epub_font") or ""
            return cur == ""
        end,
        callback = function()
            if G_reader_settings then G_reader_settings:saveSetting("txt2epub_font", nil) end
        end,
    }
    for _i, f in ipairs(fonts) do
        local font = f  -- 拷贝循环变量，避免闭包共享导致“选哪个字体都存成最后一个”
        items[#items + 1] = {
            -- display：本地化显示名（中文界面→中文名 + 样式）；font.name 仅用于存储/勾选/CSS
            text = font.display or font.name,
            checked_func = function()
                -- 实时读取当前选中字体（旧实现缓存 current，改动后勾选停留在旧值，用户以为“没选上”）
                local cur = G_reader_settings and G_reader_settings:readSetting("txt2epub_font") or ""
                return cur == font.name
            end,
            callback = function()
                if G_reader_settings then G_reader_settings:saveSetting("txt2epub_font", font.name) end
            end,
        }
    end
    if #fonts == 0 then
        items[#items + 1] = {
            text = _("（未读到本地字体列表）"),
            enabled = false,
        }
    end
    items[#items + 1] = {
        text = _("预览当前字体…"),
        separator = true,
        callback = function() self:preview_font() end,
    }
    items[#items + 1] = {
        text = _("手动输入字体名…"),
        callback = function() self:edit_font() end,
    }
    return items
end

-- 预览当前选中的字体：用 TextWidget 以该字体（face）渲染一行样例，供确认字形。
-- 用 pcall 逐项获取控件；任一控件不可用时降级为纯文本提示，绝不因预览崩溃。
function TXT2EPUB:preview_font()
    local current = G_reader_settings and G_reader_settings:readSetting("txt2epub_font") or ""
    local path
    local display = current ~= "" and current or _("默认衬线体")
    for _, f in ipairs(self:get_font_list()) do
        if f.name == current then path = f.path; display = f.display or f.name break end
    end
    local fallback = function()
        UIManager:show(InfoMessage:new{ text = _("当前字体：") .. display, timeout = 2 })
    end
    if not path then fallback() return end

    local ok1, Font = pcall(require, "ui/font")
    local ok2, TextWidget = pcall(require, "ui/widget/textwidget")
    local ok3, CenterContainer = pcall(require, "ui/widget/container/centercontainer")
    local ok4, FrameContainer = pcall(require, "ui/widget/container/framecontainer")
    local ok5, VerticalGroup = pcall(require, "ui/widget/container/verticalgroup")
    local ok6, Button = pcall(require, "ui/widget/button")
    if not (ok1 and ok2 and ok3 and ok4 and ok5 and ok6) then fallback() return end

    local face
    local okf, fv = pcall(Font.getFace, path, 24)
    if okf and fv then face = fv end
    if not face then fallback() return end

    local widget
    widget = CenterContainer:new{
        FrameContainer:new{
            margin = 24,
            padding = 24,
            bordersize = 1,
            VerticalGroup:new{ align = "center",
                TextWidget:new{ text = "永 中文风 abc ABC 0123", face = face },
                TextWidget:new{ text = current },
                Button:new{
                    text = _("关闭"),
                    callback = function() UIManager:close(widget) end,
                },
            },
        },
    }
    UIManager:show(widget)
end

function TXT2EPUB:edit_font()
    local dialog
    dialog = InputDialog:new{
        title = _("正文指定字体（留空使用默认衬线字体）"),
        input = (G_reader_settings and G_reader_settings:readSetting("txt2epub_font")) or "",
        input_hint = _("如 Noto Serif CJK SC"),
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local v = (dialog:getInputValue() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if G_reader_settings then
                        G_reader_settings:saveSetting("txt2epub_font", v ~= "" and v or nil)
                    end
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存字体设置：") .. (v ~= "" and v or _("（默认）")), timeout = 1.5 })
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function TXT2EPUB:edit_pattern()
    local dialog
    dialog = InputDialog:new{
        title = _("章节标题正则（Lua 模式）"),
        input = self:get_pattern() or "",
        input_hint = _("留空用内置默认。常用示例见下，按需套用（^ 表示行首，% 需写成 %%）"),
        buttons = {
            {
                text = _("示例"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[
章节标题正则示例（每行一个，匹配即视为新章）：
① 第N章： ^%s*第[%d一二三四五六七八九十百千零〇]+章
② 第N回： ^%s*第[%d一二三四五六七八九十百千零〇]+回
③ 卷/部：   ^%s*第[%d一二三四五六七八九十百千零〇]+卷
④ 数字章：  ^%s*第?%d+%s*章
⑤ 纯英文：  ^[Cc]hapter%s+%d+
⑥ 序号标题： ^【%d+】
⑦ 含“第”：  ^第.+[章卷回部篇节]
（无需前缀可留空，直接用内置稳健识别）]]),
                        timeout = 8,
                    })
                end,
            },
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local v = (dialog:getInputValue() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if G_reader_settings then
                        G_reader_settings:saveSetting("txt2epub_pattern", v ~= "" and v or nil)
                    end
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存正则设置"), timeout = 1.5 })
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function TXT2EPUB:reset_pattern()
    if G_reader_settings then
        G_reader_settings:saveSetting("txt2epub_pattern", nil)
    end
    UIManager:show(InfoMessage:new{ text = _("已恢复默认正则"), timeout = 1.5 })
end

function TXT2EPUB:edit_indent()
    local dialog
    dialog = InputDialog:new{
        title = _("首行缩进值（CSS 长度）"),
        input = self:get_indent() or "2em",
        input_hint = _("如 2em / 0 / 1.5em"),
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local v = (dialog:getInputValue() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if v ~= "" and G_reader_settings then
                        G_reader_settings:saveSetting("txt2epub_indent", v)
                    end
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{ text = _("已保存缩进设置：") .. v, timeout = 1.5 })
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function TXT2EPUB:edit_indent_step()
    local dialog
    dialog = InputDialog:new{
        title = _("缩进步长（每个子层级的空格数）"),
        input = tostring(self:get_indent_step()),
        input_type = "number",
        input_hint = _("默认 4；即每行多 4 个空格降一级（如 3.1 小节 比 第3章 多缩进 4 空格）"),
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("保存"),
                callback = function()
                    local raw = (dialog:getInputValue() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local n = tonumber(raw)
                    if n and n >= 1 and G_reader_settings then
                        G_reader_settings:saveSetting("txt2epub_indent_step", tostring(math.floor(n)))
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("已保存缩进步长：") .. math.floor(n) .. _(" 空格"), timeout = 1.5 })
                    else
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("请输入大于等于 1 的整数") })
                    end
                end,
            },
        },
    }
    UIManager:show(dialog)
end

------------------------------------------------------------------------
-- 转换入口
------------------------------------------------------------------------
------------------------------------------------------------------------
-- 诊断日志：把关键步骤追加写到 TXT 同目录的 .txt2epub.log。
-- 崩溃时即便 KOReader 主日志难以获取，也能凭此文件定位卡在哪一步、
-- 以及是否发生了 Lua 错误及其调用栈。
------------------------------------------------------------------------
function TXT2EPUB:_set_log(file)
    self._logpath = nil
    if file then
        local ok, dir = pcall(util.dirname, file)
        if ok and dir and dir ~= "" then
            self._logpath = util.joinPath(dir, ".txt2epub.log")
        end
    end
end

function TXT2EPUB:_log(msg)
    if not self._logpath then return end
    local ok, f = pcall(io.open, self._logpath, "a")
    if not ok or not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg) .. "\n")
    f:close()
end

------------------------------------------------------------------------
-- 日志维护（用户需求 D）
--   策略一（大小上限）：日志文件超过 LOG_MAX_BYTES 时，下次转换开始即清空重建，
--                       避免无限增长占用设备存储。
--   策略二（周期清理）：每累计运行 3 次，删除源文件所在目录中 3 天前修改的旧
--                       .txt2epub.log（同一目录可能为不同 TXT 各留一份日志）。
--   两者为“或”关系，任一触发即可；整体以 pcall 守护，绝不因此中断转换。
------------------------------------------------------------------------
local LOG_MAX_BYTES = 512 * 1024  -- 512 KB

-- 转换开始前调用：只按「大小上限」策略处理当前日志，绝不遍历整个书籍目录。
-- （旧版曾有「每 3 次运行扫描同目录、删除 3 天前旧日志」的周期清理，用 lfs.dir 遍历
--  整个书籍目录；在 Kindle 的慢速大目录（数百上千本书）上会卡住数秒到数十秒，
--  表现为「点开始转换后卡在扫描目录」。已彻底移除目录遍历，仅保留 O(1) 的大小检查。）
function TXT2EPUB:_maintain_log(file)
    if not self._logpath then return end
    -- 大小超限 -> 清空重建（只检查当前这一个文件，不做任何目录遍历）
    local ok, sz = pcall(function()
        local f = io.open(self._logpath, "rb")
        if not f then return 0 end
        local s = f:seek("end") or 0
        f:close()
        return s
    end)
    if ok and sz and sz > LOG_MAX_BYTES then
        pcall(os.remove, self._logpath)
        self:_log(string.format("日志超过 %d KB 上限，已清空重建", LOG_MAX_BYTES / 1024))
    end
end

------------------------------------------------------------------------
-- 进度提示（用户需求 A/B/C）
--   转换期间常驻一个 InfoMessage（dismissable=false 防止误触关闭，timeout=nil
--   防止超时自动消失），用 ASCII 进度条 + 百分比 + 章节计数实时刷新，
--   既给出明确进度，又让屏幕持续“活着”，消除“假死”观感；
--   转换结束时关闭进度框并弹出“转换完成”提示。
------------------------------------------------------------------------
-- 进度文案：参考「月读」(moon) 排版优化，按阶段给出明确反馈：
--   stage == "scan"  → 正在识别章节（预检标题）
--   stage == "build" → 正在写入 EPUB（流式构建，随写随报已写入章节数）
function TXT2EPUB:_progress_text(i, total, stage)
    local pct = (total and total > 0) and math.min(1, i / total) or 0
    local pct_int = math.floor(pct * 100 + 0.5)
    local width = 20
    local filled = math.max(0, math.min(width, math.floor(pct * width + 0.5)))
    local bar = string.rep("=", filled) .. string.rep("-", width - filled)
    if stage == "scan" then
        return _("正在识别章节…")
    end
    if total and total > 0 then
        return string.format(_("正在写入…  %d%%\n[%s]\n%d / %d 章"), pct_int, bar, i, total)
    end
    return string.format(_("正在写入…\n[%s]\n已写入 %d 章"), bar, i)
end

-- 刷新进度框。
-- 关键修复：旧实现首行 `if not self._progress then return end` 会在「首次调用」
-- （_open_progress 先把 _progress 置 nil 再调本函数）时直接 return，导致进度框
-- 从始至终从未被创建 —— 这正是「转换过程页面卡住、毫无提示」的根因。
-- 现改为：仅当进度框已存在时才做节流判断，首次调用必定创建。
function TXT2EPUB:_set_progress(i, total, stage)
    if self._progress then
        -- 节流：已存在进度框时，仅当跨过阈值或到末尾才重绘，避免每章一闪
        if total and total > 0 then
            local step = math.max(1, math.floor(total / 50))
            if i ~= total and self._progress_last and (i - self._progress_last) < step then
                return
            end
        else
            -- 未知总数（大书流式构建，避免整本预扫描）：每 10 章刷新一次，减少重绘开销
            if self._progress_last and i ~= 0 and (i - self._progress_last) < 10 then
                return
            end
        end
    end
    self._progress_last = i
    if self._progress then
        UIManager:close(self._progress)
    end
    self._progress = InfoMessage:new{
        text = self:_progress_text(i, total, stage),
        dismissable = false,  -- 转换中不允许误触/按键关闭
        timeout = nil,        -- 常驻，直到转换结束由 _close_progress 关闭
        show_icon = false,    -- 去掉图标更紧凑
    }
    UIManager:show(self._progress)
end

function TXT2EPUB:_close_progress()
    if self._progress then
        UIManager:close(self._progress)
        self._progress = nil
    end
    self._progress_last = nil
    self._progress_i = nil
    self._progress_total = nil
    self._progress_stage = nil
end

-- 在转换开始时创建常驻进度框；stage 决定阶段文案（"scan" / "build"）
function TXT2EPUB:_open_progress(total, stage)
    -- 关键：先关闭任何残留的旧进度框。旧实现只把 self._progress 置 nil 再建新框，
    -- 但「正在识别章节」（scan）框是 dismissable=false 的常驻框，一旦在进入 build 阶段时
    -- 没被 UIManager:close，就会残留在屏幕栈底；转换完成提示（timeout=5）消失后，
    -- 这个残留的常驻框会重新露出、且无法点击关闭 —— 正是「转换完成后卡在正在识别章节」的根因。
    self:_close_progress()
    self._progress_i = 0
    self._progress_total = total
    self._progress_stage = stage or "build"
    self:_set_progress(0, total, self._progress_stage)
end

-- 把底层异常转成面向用户的简明中文提示（技术细节只写诊断日志，不弹在屏幕上）。
-- 典型：损坏的 docx / 非 ZIP 文件、图片资源错误、空文件、不支持的格式等。
function TXT2EPUB:_friendly_error(err)
    local s = tostring(err or "")
    -- 只取第一行，去掉 "xxx.lua:1234:" 前缀与 stack traceback
    local first = s:match("^([^\n]*)") or s
    first = first:gsub("^.-%.lua:%d+:%s*", "")
    first = first:gsub("%s*stack traceback.*$", "")
    -- 按已知错误类型给出可操作提示
    if s:find("EOCD", 1, true) or s:find("不是合法的 ZIP", 1, true)
       or s:find("ZIP / .docx", 1, true) or s:find("损坏", 1, true) then
        return _("此文件不是有效的 .docx（Word 文档已损坏或并非真正的 Word 文件），无法转换。\n请重新导出/另存为 .docx 后再试。")
    end
    if s:find("图片", 1, true) or s:find("image", 1, true) then
        return _("文档中的图片无法读取，本次转换无法完成。\n请另存为纯文字 .docx 或 .txt 后重试。")
    end
    if s:find("空", 1, true) and (s:find("文件", 1, true) or s:find("内容", 1, true)) then
        return _("文件内容为空，无需转换。")
    end
    if s:find("权限", 1, true) or s:find("permission", 1, true) then
        return _("没有写入权限，无法保存 EPUB。请检查目录权限。")
    end
    if s:find("磁盘", 1, true) or s:find("空间", 1, true) or s:find("no space", 1, true) then
        return _("存储空间不足，无法保存 EPUB。请释放空间后重试。")
    end
    return _("转换失败，无法完成本次转换。\n原因：") .. first
end

-- 安全执行：捕获任何 Lua 错误，写入诊断日志并提示，绝不向上 panic 崩溃进程。
function TXT2EPUB:_safe(fn, ctx)
    local ok, err = pcall(fn)
    if not ok then
        local _, tb = pcall(debug.traceback, "", 2)
        self:_log("【捕获异常】" .. (ctx or "操作") .. "：\n" .. tostring(err) .. "\n" .. tostring(tb or ""))
        self:_close_progress()  -- 失败时关闭可能残留的常驻进度框，避免挡住错误提示
        UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        return false
    end
    return true
end

------------------------------------------------------------------------
-- 文件选择器：直接用文件浏览器点选磁盘上的 .txt / .docx 源文件
-- 这是 DOCX 转换的可靠入口 —— KOReader 打开 DOCX 后 document.file 不一定指向
-- 原始 .docx 路径，故不依赖打开的文档对象，改由用户显式选择源文件。
------------------------------------------------------------------------
function TXT2EPUB:pick_and_convert(start_path)
    local lfs = require("libs/libkoreader-lfs")
    local Screen = require("device").screen
    local Menu = require("ui/widget/menu")

    local path = self:_normalize_dir(start_path or self:_start_dir())
    local items = self:_list_sources(path)

    local picker = Menu:new{
        title = _("选择要转换的文件（.txt / .docx / .html / .htm / .md / .doc / .epub）") .. "\n" .. path,
        item_table = items,
        is_popout = false,
        is_borderless = false,
        width = math.floor(Screen:getWidth() * 0.92),
        height = math.floor(Screen:getHeight() * 0.85),
        callback = function(item)
            if not item or not item.path then return end
            UIManager:close(picker)
            if item.is_dir then
                -- 进入子目录 / 返回上级
                self:pick_and_convert(item.path)
            else
                -- 选中源文件，交给 convert() 按扩展名自动分派
                self:convert(item.path)
            end
        end,
    }
    UIManager:show(picker)
end

-- 选择器起始目录：若当前打开的是插件可自解析的格式则用它所在目录；
-- 否则回退到 KOReader 主页目录 / 当前工作目录，避免落在 KOReader 内部临时目录。
function TXT2EPUB:_start_dir()
    local lfs = require("libs/libkoreader-lfs")
    local cur = self:_current_file()
    if cur then
        local e = self:file_ext(cur)
        if SELF_PARSE_EXT[e] then
            local d = cur:match("(.*)/") or cur:match("(.*)\\")
            if d and lfs.attributes(d, "mode") == "directory" then return d end
        end
    end
    if G_reader_settings then
        local h = G_reader_settings:readSetting("home_dir")
        if h and lfs.attributes(h, "mode") == "directory" then return h end
    end
    return lfs.currentdir() or "/"
end

-- 规整目录路径：统一斜杠、校验存在性，不存在则回退
function TXT2EPUB:_normalize_dir(p)
    local lfs = require("libs/libkoreader-lfs")
    if not p or p == "" then return lfs.currentdir() or "/" end
    p = p:gsub("\\", "/")
    if lfs.attributes(p, "mode") ~= "directory" then
        return lfs.currentdir() or "/"
    end
    return p
end

-- 列出目录内可选项：父目录“..”、子目录、以及可转换格式的文件；目录在前、文件在后
function TXT2EPUB:_list_sources(path)
    local lfs = require("libs/libkoreader-lfs")
    local items = {}
    if path ~= "/" then
        table.insert(items, { text = "⬆ ..", path = self:_parent(path), is_dir = true })
    end
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if ok then
        for f in iter, dir_obj do
            if f ~= "." and f ~= ".." then
                local full = path .. "/" .. f
                local attr = lfs.attributes(full) or {}
                if attr.mode == "directory" then
                    table.insert(items, { text = f .. "/", path = full, is_dir = true })
                elseif attr.mode == "file" then
                    local e = string.lower(f:match("%.([^%.]+)$") or "")
                    if e == "txt" or e == "docx" or e == "html" or e == "htm"
                        or e == "md" or e == "markdown"
                        or e == "doc" or e == "rtf" or e == "fb2" or e == "epub" then
                        table.insert(items, { text = f, path = full, is_dir = false })
                    end
                end
            end
        end
    end
    table.sort(items, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.text:lower() < b.text:lower()
    end)
    if #items == 0 then
        table.insert(items, { text = _("（此目录没有可选择的文件；其它格式请在阅读器内打开后转换）"), path = nil, is_dir = false })
    end
    return items
end

function TXT2EPUB:_parent(path)
    local p = path:gsub("/$", "")
    local d = p:match("(.*)/")
    return d or "/"
end

------------------------------------------------------------------------
-- 通用文档转换（2.0.0）：直接利用 KOReader 已打开文档的 DOM（TOC + 渲染 HTML）
--   不区分 .doc / .docx / .rtf / .fb2 / .epub / .html —— KOReader 已替我们完成
--   格式解析，我们只需把它的“已转换结果”再打包成 EPUB。
------------------------------------------------------------------------

-- 从真实 KOReader 文档对象适配出 converter 需要的抽象接口（doc_api）。
-- 所有 KOReader 专属调用都收敛在这里，并用 pcall 守护，确保任一接口缺失都不会 panic。
function TXT2EPUB:_build_doc_api(doc)
    local doc_api = { title = nil, author = nil, toc = {}, page_count = 0,
                      get_html = nil, get_page_xp = nil, end_xp = nil }

    -- 书名 / 作者（CreDocument 等支持 getProps）
    local ok, props = pcall(function() return doc:getProps() end)
    if ok and type(props) == "table" then
        doc_api.title = props.title or nil
        doc_api.author = props.authors or nil
    end

    -- 页数（先取，后面换算「文档末尾 xpointer」要用）
    pcall(function()
        local pc = (doc.info and doc.info.number_of_pages) or 0
        if pc == 0 and type(doc.getPageCount) == "function" then pc = doc:getPageCount() end
        doc_api.page_count = pc or 0
    end)

    -- 目录：KOReader 真实 TOC 条目字段是
    --   title(标题) / page(页码) / depth(层级) / xpointer(章节起点 xpointer)
    -- （见 readertoc.lua：v.title、v.depth、v.page、v.xpointer）。
    -- 早期实现误按 text / pos0 / pos1 读取 —— 真机上 pos0 恒为 nil，
    -- build_epub_from_document 会跳过全部条目，最终只落进「空书体检」提示，
    -- 使 .doc/.rtf/.fb2/.epub/.html 等兜底格式在真机上一个都转不出来。
    -- 这里同时兼容新旧字段名；没有 xpointer 时用页码经 getPageXPointer 换算。
    local toc
    pcall(function()
        if type(doc.getToc) == "function" then toc = doc:getToc() end
        if toc == nil and type(doc.getTOC) == "function" then toc = doc:getTOC() end
    end)
    if type(toc) == "table" then
        for _, e in ipairs(toc) do
            if type(e) == "table" then
                local xp = e.xpointer or e.pos0
                if (not xp or xp == "") and (e.page or e.pageno)
                    and type(doc.getPageXPointer) == "function" then
                    local okx, x = pcall(doc.getPageXPointer, doc, e.page or e.pageno)
                    if okx and x and x ~= "" then xp = x end
                end
                doc_api.toc[#doc_api.toc + 1] = {
                    text = e.title or e.text,
                    depth = e.depth or 1,
                    pos0 = xp,
                    pos1 = e.pos1,
                }
            end
        end
    end

    -- 文档末尾 xpointer：末章区间 [pos0, end_xp) 才能覆盖到全书结尾。
    -- 依次尝试 页数+1（末尾边界）/ 最后一页 / 倒数第二页，取第一个有效值。
    local function resolve_end_xp()
        if type(doc.getPageXPointer) ~= "function" then return nil end
        local pc = doc_api.page_count or 0
        local candidates = { pc + 1, pc, (pc > 1) and (pc - 1) or nil }
        for _, p in ipairs(candidates) do
            if p and p > 0 then
                local okx, x = pcall(doc.getPageXPointer, doc, p)
                if okx and x and x ~= "" then return x end
            end
        end
        return nil
    end
    doc_api.end_xp = resolve_end_xp()

    -- 末章补上右端边界（原本 pos1 通常为空），build_epub_from_document 据此切出末章正文。
    if doc_api.end_xp and #doc_api.toc > 0 then
        local last = doc_api.toc[#doc_api.toc]
        if not last.pos1 or last.pos1 == "" then last.pos1 = doc_api.end_xp end
    end

    -- 渲染 HTML 提取：仅 CreDocument 提供；用 pcall 包裹避免个别版本签名差异导致崩溃
    if type(doc.getHTMLFromXPointers) == "function" then
        doc_api.get_html = function(pos0, pos1)
            if not pos0 or pos0 == "" then return nil end
            local xp1 = pos1
            if (not xp1 or xp1 == "") and doc_api.end_xp then xp1 = doc_api.end_xp end
            if xp1 and xp1 ~= "" and xp1 ~= pos0 then
                local okh, h = pcall(doc.getHTMLFromXPointers, doc, pos0, xp1, 0, false)
                return okh and h or nil
            end
            -- 拿不到右端边界：退回单节点 HTML（旧行为），至少不抛错；
            -- 上层「空书体检」会拦住由此产生的空壳 EPUB。
            if type(doc.getHTMLFromXPointer) == "function" then
                local okh, h = pcall(doc.getHTMLFromXPointer, doc, pos0, 0, false)
                return okh and h or nil
            end
            return nil
        end
    end

    -- 翻页回退（无 TOC 时按页聚合）
    if type(doc.getPageXPointer) == "function" then
        doc_api.get_page_xp = function(p)
            local okp, xp = pcall(doc.getPageXPointer, doc, p)
            return okp and xp or nil
        end
    end

    return doc_api
end

-- 通用文档转换入口
function TXT2EPUB:_convert_document(doc, file)
    local doc_api = self:_build_doc_api(doc)
    local base = (doc_api.title and doc_api.title ~= "") and doc_api.title
        or (file and util.basename(file):gsub("%.[^.]+$", "")) or "未命名"
    -- 清洗书名中的非法文件名字符（KOReader 书名可能含 / \ : 等）
    base = (base:gsub('[\\/:*?"<>|]', "_")):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local lfs = require("libs/libkoreader-lfs")
    local out_dir = (file and util.dirname(file)) or (lfs.currentdir() or "/")
    -- 按源格式加标记，避免 .doc/.docx/.rtf/.epub 等同名文件互相覆盖
    local out_path = util.joinPath(out_dir, self:_output_name(base, file and self:file_ext(file) or nil))

    self:_set_log(file or out_path)
    self:_maintain_log(file or out_path)
    self:_log("== 开始通用文档转换（KOReader 已打开文档），源：" .. tostring(file) .. "  书名：" .. tostring(base))

    if file_exists(out_path) then
        UIManager:show(ConfirmBox:new{
            text = _("输出文件已存在，是否覆盖？\n") .. out_path,
            ok_text = _("覆盖"),
            cancel_text = _("取消"),
            ok_callback = function() self:_run_document(doc_api, out_path, base) end,
        })
        return
    end
    self:_run_document(doc_api, out_path, base)
end

function TXT2EPUB:_run_document(doc_api, out_path, base)
    self:_open_progress(nil, "build")
    self:_async_run(
        function()
            self._in_async = true
            local r = self:_do_convert_document(doc_api, out_path, base)
            self._in_async = false
            return r
        end,
        function(err)
            self._in_async = false
            self:_close_progress()
            UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        end,
        function(res)
            self:_close_progress()
            res = res or {}
            UIManager:show(InfoMessage:new{
                text = string.format(_("✓ 转换完成：共 %d 章\n已保存：\n%s"), res.count or 0, out_path),
                timeout = 5,
            })
        end
    )
end

function TXT2EPUB:_do_convert_document(doc_api, out_path, base)
    local opts = {
        indent = self:get_indent(),
        style = self:get_style(),
        book_title = base,
        uid = "urn:uuid:" .. Converter.gen_uid(),
        modified = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title_page = true,  -- 书名页：标题单独成目录首项（真机反馈「无书名页」）
    }
    self:_log("开始由已打开文档生成 EPUB：" .. out_path)
    local build_ok, count, stats
    local status, perr = pcall(function()
        build_ok, count, stats = Converter.build_epub_from_document(doc_api, out_path, opts, {
            on_yield = function()
                if self._in_async then coroutine.yield() end
            end,
            on_progress = function(i)
                self._progress_i = i
                self._progress_total = nil
                if i % 25 == 0 then
                    self:_log(string.format("写入进度：%d 章", i))
                end
            end,
        })
    end)
    if not status then
        error("生成 EPUB 失败：" .. tostring(perr))
    end
    if not build_ok then
        error("生成 EPUB 失败")
    end

    -- 空结果体检：若提取到的正文可见字符极少（CreDocument 对 Word/DOC 常见），
    -- 说明 KOReader 的 DOM 没能给出可用正文。删除半成品，明确告知用户，
    -- 绝不再交出一本"只剩标题"的空壳 EPUB。
    stats = stats or {}
    local visible = stats.visible_chars or 0
    local toc_n = stats.toc_entries or 0
    self:_log(string.format("DOM 提取体检：可见正文 %d 字符，TOC 条目 %d，正文标题 %d，重切分 %s（%s），章节 %d",
        visible, toc_n, stats.detected_titles or 0,
        stats.resplit and "是" or "否", tostring(stats.resplit_mode or "否"), count or 0))
    local sample = tostring(stats.html_sample or ""):gsub("%c", " ")
    if sample ~= "" then
        self:_log("DOM HTML 样本（前 160 字节）：" .. sample)
    end
    if (stats.detected_titles or 0) == 0 then
        self:_log("提示：正文未识别到章节标题，目录已按分片逐条生成（可跳转但无语义层级）")
    end
    if Converter.is_empty_document_result(stats) then
        pcall(os.remove, out_path)
        error(_("无法从阅读器提取该文档正文。\n\nKOReader 对此格式的解析结果不含可用正文/目录。\n建议：在 Word / WPS 中「另存为 .docx」后重新转换（.docx 由插件直接解析，结果最完整）。"))
    end
    self:_set_progress(count, nil)
    self:_log("EPUB 生成成功（通用文档），共 " .. count .. " 章：" .. out_path)
    return { count = count }
end

function TXT2EPUB:convert(file)
    -- 2.0.0 统一入口：用户只需「打开文档 → 点开始转换」，无需区分 doc / docx、
    -- 也无需另存为。插件内部按"能否可靠自解析"自动选路（对用户透明）：
    --   .txt   -> 插件自解析：标题正则 / 空格缩进（中文网文最佳）
    --   .docx  -> 插件自解析：直接读 OOXML，Word 标题样式 -> 多级目录 + 完整正文
    --            ★ 不走 KOReader DOM：真机验证 CreDocument 对 Word 文档 getToc()
    --              只有 1 条、getHTMLFromXPointer 只返回单节点，会产出空书。
    --   .html / .htm / .md / .markdown
    --          -> 插件自解析：markup.lua 按 <hN> / # 标题生成多级目录
    --   .doc / .rtf / .fb2 / .epub 等
    --          -> 通用 DOM 流程兜底（KOReader 能打开但插件无专用解析器），
    --             带空结果体检，提取不到正文时明确提示而非交出空壳 EPUB。
    local doc = self.ui and self.ui.document or nil
    file = file or self:_current_file()
    local ext = file and self:file_ext(file) or nil

    if not doc and not file then
        -- 没有任何已打开文档：打开文件选择器
        self:pick_and_convert()
        return
    end
    if not SELF_PARSE_EXT[ext] then
        -- EPUB 重复转换防护（真机反馈）：.epub 本身多为转换产物，若再次转换，
        -- KOReader 已渲染的书名页/目录会被当成正文再包一层，点进正文出现「两个目录标题」。
        -- 这里默认拦一道确认，误点可取消；确需重新打包才继续。
        if ext == ".epub" then
            UIManager:show(ConfirmBox:new{
                text = _("检测到源文件是 .epub（通常已是转换结果）。\n重复转换会把原有目录/书名页当成正文再包一层，导致正文出现重复目录标题。\n如非必要请点「取消」；确需重新打包请点「继续转换」。"),
                ok_text = _("继续转换"),
                cancel_text = _("取消"),
                ok_callback = function()
                    if doc then
                        self:_convert_document(doc, file)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("请在 KOReader 中打开该 EPUB 后再转换。"),
                        })
                    end
                end,
            })
            return
        end
        -- 插件无专用解析器的格式：交给通用 DOM 流程（或提示在 KOReader 中打开）
        if doc then
            self:_convert_document(doc, file)
        else
            UIManager:show(InfoMessage:new{
                text = _("请在 KOReader 中打开该文档后再转换。\n本插件可直接转换 .txt / .docx / .html / .htm / .md 文件；.doc / .rtf / .fb2 / .epub 等请在阅读器内打开后转换。"),
            })
        end
        return
    end

    -- .txt / .docx：走插件自解析（读磁盘源文件，可靠、与 KOReader 版本无关）
    self:_set_log(file)
    self:_maintain_log(file)
    self:_log("== 开始转换流程（自解析），源文件：" .. tostring(file) .. "  类型：" .. tostring(ext))

    self:_safe(function()
        local name = util.basename(file)
        -- 去掉最后一个扩展名即可（.txt/.docx/.html/.htm/.md/.markdown 通用）
        local base = name:gsub("%.[^%.]+$", "")
        if base == "" then base = "未命名" end
        -- 按格式加标记：big_novel.txt/.docx/.html/.md 各自输出独立文件，不再覆盖
        local out_path = util.joinPath(util.dirname(file), self:_output_name(base, ext))

        -- 输出已存在 -> 询问是否覆盖
        if file_exists(out_path) then
            UIManager:show(ConfirmBox:new{
                text = _("输出文件已存在，是否覆盖？\n") .. out_path,
                ok_text = _("覆盖"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self:_dispatch_convert(file, out_path, base, ext)
                end,
            })
            return
        end

        self:_dispatch_convert(file, out_path, base, ext)
    end, "convert")
end

-- 按文件类型分派到对应的转换流程
function TXT2EPUB:_dispatch_convert(file, out_path, base, ext)
    if ext == ".docx" then
        self:_safe(function() self:_run_docx(file, out_path, base) end, "docx 转换")
    elseif ext == ".rtf" then
        self:_safe(function() self:_run_rtf(file, out_path, base) end, "RTF 转换")
    elseif ext == ".html" or ext == ".htm" or ext == ".md" or ext == ".markdown" then
        self:_safe(function() self:_run_markup(file, out_path, base) end, "标记文档转换")
    else
        self:_check_title_and_run(file, out_path, base)
    end
end

-- 预检标题；若无任何章节标题，提示可用“空格缩进”识别目录层级
function TXT2EPUB:_check_title_and_run(file, out_path, base)
    self:_safe(function()
        local patterns = self:get_pattern() and { self:get_pattern() } or Converter.default_patterns()
        -- 预检阶段先给出「正在识别章节…」反馈（大文件 has_title 也要流式扫一遍，
        -- 可能耗时数秒，不能无提示干等，避免“点了没反应”的观感）
        self:_open_progress(nil, "scan")
        local has = Converter.has_title(file, patterns)
        self:_log("has_title 预检结果：" .. tostring(has))
        if not has then
            self:_close_progress()  -- 关闭“识别章节”框，腾出屏幕给确认对话框
            local step = self:get_indent_step()
            UIManager:show(ConfirmBox:new{
                text = string.format(
                    _("未检测到常规章节标题（如“第一章”）。\n\n可用「空格缩进」识别目录层级：\n每行 %d 个空格 = 1 个子层级\n（例：“3.1 小节”比“第3章”多缩进 %d 空格，即隶属于它）\n缩进步长可在设置中自定义。"),
                    step, step),
                ok_text = _("按缩进切分"),
                cancel_text = _("整本作一章"),
                other_buttons = {
                    {
                        { text = _("取消"),
                          callback = function() end },
                    },
                },
                ok_callback = function()
                    self:_safe(function() self:_run_indent(file, out_path, base) end, "缩进转换")
                end,
                cancel_callback = function()
                    self:_safe(function() self:_run(file, out_path, base, true) end, "单章转换")
                end,
            })
            return
        end
        self:_safe(function() self:_run(file, out_path, base, false) end, "标题转换")
    end, "预检标题")
end

-- 关键：在协程中执行重活，每写完一个章节就 yield 回 UI 线程一次。
-- 这样 KOReader 主线程不会被长时间占用，屏幕能持续刷新，绝不会被设备
-- 看门狗 / Android ANR 判定为“无响应”而杀掉进程。
-- 同时用 coroutine.resume 的返回值捕获协程内任意 Lua 错误，转交 on_fail
-- 显示“转换失败”提示 —— 错误绝不会向上冒泡 panic 整个 KOReader。
-- 注意：不能在 pcall/xpcall 内部 yield（Lua 5.1 限制），因此这里让错误
-- 由 resume 捕获，而不是在协程体里包 pcall。
function TXT2EPUB:_async_run(work_fn, on_fail, on_done)
    local co = coroutine.create(work_fn)
    local function step()
        -- 关键：进度刷新只发生在主线程（这里），绝不放在协程内部。
        -- 协程内只通过 self._progress_i 记录“已写入章节数”，由本函数在每次
        -- nextTick 时统一调用 UIManager:show 刷新 —— 避免“协程里弹界面”在部分
        -- KOReader 主循环时序下触发 panic / 崩溃（这是“点开始转换即崩溃”的另一嫌疑）。
        if self._progress_i then
            self:_set_progress(self._progress_i, self._progress_total, self._progress_stage)
        end
        local ok, msg = coroutine.resume(co)
        if not ok then
            -- work_fn 内抛错（resume 已捕获，msg 为错误信息）
            local _, tb = pcall(debug.traceback, co, "")
            self:_log("【协程异常】转换过程中出错（已捕获，未崩溃）：\n"
                .. tostring(msg) .. "\n" .. tostring(tb or ""))
            if on_fail then on_fail(msg) end
            -- 连续转换多个大文件时，失败路径同样是内存累积源：立即归还系统
            co = nil
            msg = nil
            collectgarbage("collect")
            collectgarbage("collect")
            return
        end
        if coroutine.status(co) ~= "dead" then
            -- 协程让出了控制权，等下一个 UI tick 再继续（保持 UI 响应）
            UIManager:nextTick(step)
        else
            -- 协程正常结束：msg 即 work_fn 的返回值（转换结果表），交回 on_done 做收尾
            if on_done then on_done(msg) end
            -- 连续转换崩溃（crash.log 只有 Killed、无 Lua 堆栈 = 内核 OOM）：
            -- 每完成一次大文件转换就彻底回收，避免 8 次转换后内存累积到 OOM。
            -- 两次 collect 让带 __gc 的对象（ZIP/文档句柄）在 LuaJIT 下确实释放；
            -- 并断开协程与结果表引用，防止闭包把它们一直挂在 UIManager 队列里。
            msg = nil
            co = nil
            work_fn = nil
            collectgarbage("collect")
            collectgarbage("collect")
        end
    end
    UIManager:nextTick(step)
end

-- 单章/标题模式入口
function TXT2EPUB:_run(file, out_path, base, single)
    -- 不再预扫描整本书统计章节数：同一大文件在阅读器已打开时再完整读一遍，
    -- 会叠加磁盘 IO 与 GC 压力，极易在 Kindle 低内存下被 OOM 强杀。
    -- total 传 nil，进度条显示“已写入 N 章”（构建时随写随累加），全程只保留构建这一遍流式读取。
    self:_open_progress(nil, "build")
    self:_async_run(
        function()
            self._in_async = true   -- 标记：当前处于 _async_run 创建的协程内，on_yield 方可让出主线程
            local r = self:_do_convert(file, out_path, base, single, nil)
            self._in_async = false
            return r
        end,
        function(err)
            self._in_async = false
            self:_close_progress()
            UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        end,
        function(res)
            self:_close_progress()
            res = res or {}
            if res.fallback then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("转换完成：按单章处理\n共 1 章，已保存：\n%s"), out_path),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("✓ 转换完成：共 %d 章\n已保存：\n%s"), res.count or 0, out_path),
                    timeout = 5,
                })
            end
        end
    )
end

-- 缩进模式入口：基于空格缩进切分层级。
-- 同样在协程中执行并逐章 yield，保证任何错误都只提示、不 panic 退出。
function TXT2EPUB:_run_indent(file, out_path, base)
    -- 同 _run：不做整本预扫描统计，避免大书在低内存设备上被 OOM 强杀。
    self:_open_progress(nil, "build")
    self:_async_run(
        function()
            self._in_async = true   -- 标记：当前处于 _async_run 创建的协程内，on_yield 方可让出主线程
            local r = self:_do_convert_indent(file, out_path, base, nil)
            self._in_async = false
            return r
        end,
        function(err)
            self._in_async = false
            self:_close_progress()
            UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        end,
        function(res)
            self:_close_progress()
            res = res or {}
            if res.empty then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("转换完成：按单章处理\n已保存：\n%s"), out_path),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("✓ 转换完成（按空格缩进切分）：共 %d 个目录条目\n已保存：\n%s"), res.count or 0, out_path),
                    timeout = 5,
                })
            end
        end
    )
end

-- 实际转换：真·流式——逐章读取、写盘即释放，内存只保留“一章”量级，
-- 避免把整本书堆进内存导致 Kindle 等低内存设备 OOM 重启。
function TXT2EPUB:_do_convert(file, out_path, base, single, total)
    local opts = {
        indent = self:get_indent(),
        style = self:get_style(),
        book_title = base,
        uid = "urn:uuid:" .. Converter.gen_uid(),
        modified = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title_page = true,  -- 书名页：标题单独成目录首项（真机反馈「无书名页」）
    }
    local kind = single and "single" or "title"
    local arg = single and nil or (self:get_pattern() or nil)  -- 标题模式传 patterns（nil=用默认）

    self:_log("开始流式生成 EPUB（" .. kind .. "）：" .. out_path)
    -- 用 pcall 包裹，确保无论成功或失败都释放“解码临时文件”（GBK/UTF-16 解码落盘的产物），
    -- 避免转换中途出错导致临时文件残留、下次又重复堆积占用存储。
    -- 注意：必须借内层函数接收多返回值（ok, count, empty），直接用 pcall(fn, ...) 会把
    -- build_epub_streaming 返回的 (true, 章节数, empty) 包成 (true, true, 章节数, empty)，
    -- 导致 count 误拿到首个 true 而丢失真实章节数。
    local build_ok, count, empty
    local status, perr = pcall(function()
        build_ok, count, empty = Converter.build_epub_streaming(
            Converter.lines(file), kind, arg, base, out_path, opts, {
                -- 在协程内每写完一个章节就 yield 一次，交还 UI 线程；
                -- 非协程环境（单元测试）下 coroutine.running() 为 nil，自动跳过。
                on_yield = function()
                    -- 仅当处于 _async_run 创建的协程内（self._in_async 置位）才让出主线程；
                    -- 用显式标志位避开 Lua 5.1/5.2/5.3/LuaJIT 各自不同的 coroutine.running() 语义
                    -- （Lua 5.3 主线程也返回主线程对象而非 nil，直接调用 yield 会报错）。
                    if self._in_async then coroutine.yield() end
                end,
                on_progress = function(i)
                    -- 注意：绝不在此处触碰 UIManager！协程内只记录数值，
                    -- 由主线程的 step 在每次 nextTick 时统一刷新进度（见 _async_run），
                    -- 避免“协程内弹 UI”在某些 KOReader 主循环时序下 panic 崩溃。
                    self._progress_i = i
                    self._progress_total = total
                    if i % 25 == 0 then
                        self:_log(string.format("写入进度：%d 章", i))
                    end
                end,
            })
    end)
    Converter.release_lines(file)
    if not status then
        error("生成 EPUB 失败：" .. tostring(perr))
    end
    if not build_ok then
        error("生成 EPUB 失败")
    end
    self:_set_progress(count, total)  -- 收尾刷新到 100%
    self:_log("EPUB 生成成功，共 " .. count .. " 章：" .. out_path)
    return { count = count, fallback = single }
end

-- 缩进模式：按前导空格层级切分（流式逐行处理，内存只保留一章量级）
function TXT2EPUB:_do_convert_indent(file, out_path, base, total)
    local opts = {
        indent = self:get_indent(),
        style = self:get_style(),
        book_title = base,
        uid = "urn:uuid:" .. Converter.gen_uid(),
        modified = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title_page = true,  -- 书名页：标题单独成目录首项（真机反馈「无书名页」）
    }
    local step = self:get_indent_step()
    self:_log("开始流式生成 EPUB（缩进模式）：" .. out_path)
    -- 同样用 pcall 包裹，确保失败也释放解码临时文件；内层函数接收多返回值 (ok, n, empty)
    local build_ok, n, empty
    local status, perr = pcall(function()
        build_ok, n, empty = Converter.build_epub_streaming(
            Converter.lines(file), "indent", step, base, out_path, opts, {
                on_yield = function()
                    -- 仅当处于 _async_run 创建的协程内（self._in_async 置位）才让出主线程；
                    -- 用显式标志位避开 Lua 5.1/5.2/5.3/LuaJIT 各自不同的 coroutine.running() 语义
                    -- （Lua 5.3 主线程也返回主线程对象而非 nil，直接调用 yield 会报错）。
                    if self._in_async then coroutine.yield() end
                end,
                on_progress = function(i)
                    self._progress_i = i
                    self._progress_total = total
                    if i % 25 == 0 then
                        self:_log(string.format("写入进度：%d 条目", i))
                    end
                end,
            })
    end)
    Converter.release_lines(file)
    if not status then error("生成 EPUB 失败：" .. tostring(perr)) end
    if not build_ok then error("生成 EPUB 失败") end
    self:_set_progress(n, total)  -- 收尾刷新到 100%
    if empty then
        self:_log("缩进模式未切出任何条目，已回退为整本单章：" .. out_path)
    else
        self:_log("EPUB 生成成功（缩进模式），共 " .. n .. " 个条目：" .. out_path)
    end
    return { count = n, empty = empty }
end

------------------------------------------------------------------------
-- Word(.docx) 转换入口（参照 _run，但在协程中执行、逐章 yield，避免主线程阻塞）
------------------------------------------------------------------------
------------------------------------------------------------------------
-- RTF 转换入口（v2.1.6）：插件直接解析源文件，绕开 KOReader DOM 对负数 \u 的
-- 乱码/截断问题。协程逐章 yield，错误只提示不 panic。
------------------------------------------------------------------------
function TXT2EPUB:_run_rtf(file, out_path, base)
    self:_open_progress(nil, "build")
    self:_async_run(
        function()
            self._in_async = true
            local r = self:_do_convert_rtf(file, out_path, base)
            self._in_async = false
            return r
        end,
        function(err)
            self._in_async = false
            self:_close_progress()
            UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        end,
        function(res)
            self:_close_progress()
            res = res or {}
            local extra = ""
            if res.garbled and res.garbled > 0 then
                extra = string.format(_("\n（已跳过 %d 处无法识别的字符，其余内容正常转换）"), res.garbled)
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_("✓ 转换完成：共 %d 章\n已保存：\n%s%s"), res.count or 0, out_path, extra),
                timeout = 5,
            })
        end
    )
end

function TXT2EPUB:_do_convert_rtf(file, out_path, base)
    local opts = {
        indent = self:get_indent(),
        style = self:get_style(),
        book_title = base,
        uid = "urn:uuid:" .. Converter.gen_uid(),
        modified = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title_page = true,
    }
    pcall(collectgarbage, "collect")
    pcall(collectgarbage, "collect")
    self:_log("开始由 RTF 源文件解析生成 EPUB（不经 KOReader DOM）：" .. out_path)
    local build_ok, count, stats
    local status, perr = pcall(function()
        build_ok, count, stats = Converter.build_epub_from_rtf(file, out_path, opts, {
            on_yield = function()
                if self._in_async then coroutine.yield() end
            end,
            on_progress = function(i)
                self._progress_i = i
                self._progress_total = nil
                if i % 25 == 0 then
                    self:_log(string.format("写入进度：%d 章", i))
                end
            end,
        })
    end)
    if not status then
        error("生成 EPUB 失败：" .. tostring(perr))
    end
    if not build_ok then
        error("生成 EPUB 失败")
    end
    stats = stats or {}
    self:_log(string.format("RTF 自解析：可见正文段落 %d，标题 %d，跳过乱码 %d，共 %d 章",
        stats.body_paras or 0, stats.headings or 0, stats.garbled or 0, count or 0))
    self:_set_progress(count, nil)
    return { count = count, garbled = stats.garbled or 0 }
end

function TXT2EPUB:_run_docx(file, out_path, base)
    self:_open_progress(nil, "build")
    self:_async_run(
        function()
            self._in_async = true   -- 标记：当前处于 _async_run 创建的协程内，on_yield 方可让出主线程
            local r = self:_do_convert_docx(file, out_path, base)
            self._in_async = false
            return r
        end,
        function(err)
            self._in_async = false
            self:_close_progress()
            UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        end,
        function(res)
            self:_close_progress()
            res = res or {}
            UIManager:show(InfoMessage:new{
                text = string.format(_("✓ 转换完成：共 %d 章\n已保存：\n%s"), res.count or 0, out_path),
                timeout = 5,
            })
        end
    )
end

-- 实际转换：直接调用 converter 的 docx 流水线（逐章写出、随即释放，内存只保留一章量级）
function TXT2EPUB:_do_convert_docx(file, out_path, base)
    local opts = {
        indent = self:get_indent(),
        style = self:get_style(),
        book_title = base,
        uid = "urn:uuid:" .. Converter.gen_uid(),
        modified = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title_page = true,  -- 书名页：标题单独成目录首项（真机反馈「无书名页」）
    }
    -- 大 DOCX 崩溃防御（真机 11-16 22:24 big_novel.docx / 11-17 04:18 long_chapter.docx）：
    -- crash.log 显示 Killed 发生在 KOReader「opening file」阶段、早于插件转换日志，
    -- 主因是 KOReader 原生打开/渲染 Word 的 DOM 内存占用。插件无法释放已渲染 DOM，
    -- 但可在转换前把可回收的临时对象尽量归还，并记录 Lua 堆占用；若随后仍 Killed，
    -- 即可由日志确认是原生 DOM 而非本插件逻辑（真机可改用「文件选择器直接选 docx」绕开）。
    pcall(collectgarbage, "collect")
    pcall(collectgarbage, "collect")
    local heap_kb = tonumber(collectgarbage("count")) or 0
    self:_log(string.format("Word 转换前 Lua 堆约 %d KB（转换在独立协程读磁盘源，不依赖已渲染 DOM）",
        math.floor(heap_kb)))
    self:_log("开始由 Word 生成 EPUB：" .. out_path)
    local build_ok, count
    local status, perr = pcall(function()
        build_ok, count = Converter.build_epub_from_docx(file, out_path, opts, {
            -- 仅当处于 _async_run 创建的协程内（self._in_async 置位）才让出主线程，
            -- 用显式标志位避开各 Lua 版本 coroutine.running() 语义差异。
            on_yield = function()
                if self._in_async then coroutine.yield() end
            end,
            -- 标题来源体检：Word 样式标题为 0 时会从正文文本兜底恢复章节。
            -- 真机排查「目录不全 / 崩溃」时看这一行即可确认是否生效。
            on_diag = function(rst)
                self:_log(string.format(
                    "Word 标题体检：样式标题 %d，正文段 %d，文本候选标题 %d，兜底重切 %s（提升 %d，模式 %s）",
                    rst.word_headings or 0, rst.body_paras or 0, rst.text_titles or 0,
                    rst.enabled and "是" or "否", rst.promoted or 0, rst.mode or "-"))
            end,
            on_progress = function(i)
                self._progress_i = i
                self._progress_total = nil
                if i % 25 == 0 then
                    self:_log(string.format("写入进度：%d 章", i))
                end
            end,
        })
    end)
    if not status then
        error("生成 EPUB 失败：" .. tostring(perr))
    end
    if not build_ok then
        error("生成 EPUB 失败")
    end
    self:_set_progress(count, nil)  -- 收尾刷新到 100%
    self:_log("EPUB 生成成功（Word），共 " .. count .. " 章：" .. out_path)
    return { count = count }
end

------------------------------------------------------------------------
-- Markdown / HTML 转换入口（与 docx 一样在协程里逐章 yield，避免阻塞主线程）
------------------------------------------------------------------------
function TXT2EPUB:_run_markup(file, out_path, base)
    self:_open_progress(nil, "build")
    self:_async_run(
        function()
            self._in_async = true
            local r = self:_do_convert_markup(file, out_path, base)
            self._in_async = false
            return r
        end,
        function(err)
            self._in_async = false
            self:_close_progress()
            UIManager:show(InfoMessage:new{ text = self:_friendly_error(err) })
        end,
        function(res)
            self:_close_progress()
            res = res or {}
            UIManager:show(InfoMessage:new{
                text = string.format(_("✓ 转换完成：共 %d 章\n已保存：\n%s"), res.count or 0, out_path),
                timeout = 5,
            })
        end
    )
end

function TXT2EPUB:_do_convert_markup(file, out_path, base)
    local opts = {
        indent = self:get_indent(),
        style = self:get_style(),
        book_title = base,
        uid = "urn:uuid:" .. Converter.gen_uid(),
        modified = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        title_page = true,  -- 书名页：标题单独成目录首项（真机反馈「无书名页」）
    }
    -- 同 DOCX：超大 HTML/MD 也可能叠加已打开文档内存，转换前先做两轮全量回收
    pcall(collectgarbage, "collect")
    pcall(collectgarbage, "collect")
    self:_log("开始由标记文档生成 EPUB：" .. out_path)
    local build_ok, count
    local status, perr = pcall(function()
        build_ok, count = Converter.build_epub_from_markup(file, out_path, opts, {
            on_yield = function()
                if self._in_async then coroutine.yield() end
            end,
            on_progress = function(i)
                self._progress_i = i
                self._progress_total = nil
                if i % 25 == 0 then
                    self:_log(string.format("写入进度：%d 章", i))
                end
            end,
        })
    end)
    if not status then
        error("生成 EPUB 失败：" .. tostring(perr))
    end
    if not build_ok then
        error("生成 EPUB 失败")
    end
    self:_set_progress(count, nil)
    self:_log("EPUB 生成成功（标记文档），共 " .. count .. " 章：" .. out_path)
    return { count = count }
end

return TXT2EPUB
