-- test_docapi.lua
-- 回归测试：KOReader 真机「文档对象 -> doc_api 适配层」的字段映射。
--
-- 背景（重要）：KOReader 的 TOC 条目真实字段是
--   title(标题) / page(页码) / depth(层级) / xpointer(章节起点)
-- 见 frontend/apps/reader/modules/readertoc.lua（v.title / v.depth / v.page / v.xpointer）。
-- 而 v2.0.0 初版的 _build_doc_api 误按 text / pos0 / pos1 读取，真机上 pos0 恒为 nil，
-- build_epub_from_document 会跳过全部条目 -> 落进「空书体检」-> .doc/.rtf/.fb2/.epub/.html
-- 等兜底格式在真机上一个都转不出来。此前所有测试都用「模拟 doc_api 手工灌 pos0/pos1」
-- 绕过了适配层，所以一路全绿却真机翻车。
--
-- 本测试用尽量贴近 KOReader 真实字段的 mock doc 对象，验证：
--   1) 字段映射（title/depth/xpointer、page -> xpointer 换算）
--   2) 文档末尾 xpointer 与末章右端边界
--   3) get_html 走 getHTMLFromXPointers（而非只返回单节点）
--   4) 端到端：适配层产出的 doc_api 交给 build_epub_from_document 能生成非空的完整 EPUB
--   5) 旧字段名（text/pos0/pos1）仍兼容、只有 getTOC 的旧版也能工作
--
-- 用法：lua5.3 test/test_docapi.lua   /   luajit test/test_docapi.lua

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print(string.format("[PASS] %s", name))
    else fails = fails + 1; print(string.format("[FAIL] %s  %s", name, extra or "")) end
end

----------------------------------------------------------------------
-- 最小 KOReader 运行桩（与 test_picker.lua / test_runtime.lua 一致）
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
package.loaded["ui/uimanager"] = {
    show = function() end, close = function() end, nextTick = function(_, fn) if fn then fn() end end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o or {} end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, o) return o or {} end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) return o or {} end }
package.loaded["ui/widget/menu"] = { new = function(_, o) return o or {} end }
package.loaded["libs/libkoreader-lfs"] = { currentdir = function() return "/" end,
    attributes = function() return nil end, dir = function() return function() end end }
_G.G_reader_settings = { readSetting = function() return nil end, saveSetting = function() end,
    has = function() return false end, hasNot = function() return true end }

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path

local ok_load, TXT2EPUB = pcall(require, "main")
check("main.lua 可被加载", ok_load, tostring(TXT2EPUB))
local Converter = require("converter")
local inst = TXT2EPUB:new({ ui = { menu = { registerToMainMenu = function() end }, document = { file = "/x/book.epub" } } })

----------------------------------------------------------------------
-- 1) 贴近真机的 CreDocument mock（title / depth / page / xpointer）
----------------------------------------------------------------------
local html_calls = {}
local function make_cre_doc()
    local doc = {
        info = { number_of_pages = 5 },
        getProps = function() return { title = "测试书名", authors = "某作者" } end,
        getToc = function()
            return {
                { title = "第一章 开篇",   depth = 1, page = 1, xpointer = "/body/ch[1]" },
                { title = "第一节 细节",   depth = 2, page = 2, xpointer = "/body/ch[2]" },
                { title = "第二章 发展",   depth = 1, page = 3, xpointer = "/body/ch[3]" },
                -- 末章故意不给 xpointer，验证 page -> xpointer 换算
                { title = "第三章 结局",   depth = 1, page = 5 },
            }
        end,
        getPageXPointer = function(_, p) return "XP_PAGE_" .. tostring(p) end,
        getPageCount = function() return 5 end,
        getHTMLFromXPointers = function(_, xp0, xp1, flags, from_root)
            html_calls[#html_calls + 1] = { xp0 = xp0, xp1 = xp1, flags = flags, from_root = from_root }
            return "<p>" .. tostring(xp0) .. " 到 " .. tostring(xp1) .. " 的正文内容，含有足够多的可见文字。</p>"
        end,
        getHTMLFromXPointer = function() return "<p>单个节点</p>" end,
        getXPointer = function() return "XP_CURRENT" end,
    }
    return doc
end

local doc = make_cre_doc()
local api = inst:_build_doc_api(doc)

check("适配层返回 table", type(api) == "table")
check("书名来自 getProps().title", api.title == "测试书名", tostring(api.title))
check("作者来自 getProps().authors", api.author == "某作者", tostring(api.author))
check("TOC 条目数 = 4", #api.toc == 4, tostring(#api.toc))
check("[1] 标题取自 title 字段", api.toc[1].text == "第一章 开篇", tostring(api.toc[1] and api.toc[1].text))
check("[1] 起点取自 xpointer 字段", api.toc[1].pos0 == "/body/ch[1]", tostring(api.toc[1] and api.toc[1].pos0))
check("[2] depth=2 被保留（多级目录）", api.toc[2].depth == 2, tostring(api.toc[2] and api.toc[2].depth))
check("[4] 无 xpointer 时用 page 换算", api.toc[4].pos0 == "XP_PAGE_5", tostring(api.toc[4] and api.toc[4].pos0))
check("所有条目都有有效 pos0", (function()
    for _, e in ipairs(api.toc) do if not e.pos0 or e.pos0 == "" then return false end end
    return true
end)())
check("end_xp（文档末尾 xpointer）已解析", type(api.end_xp) == "string" and api.end_xp ~= "", tostring(api.end_xp))
check("末章补上 pos1 = end_xp", api.toc[4].pos1 == api.end_xp,
    tostring(api.toc[4] and api.toc[4].pos1) .. " vs " .. tostring(api.end_xp))

----------------------------------------------------------------------
-- 2) get_html 必须走区间提取（而非只返回单节点）
----------------------------------------------------------------------
html_calls = {}
local h = api.get_html("A", "B")
check("get_html(A,B) 返回正文", type(h) == "string" and h:find("正文内容", 1, true) ~= nil, tostring(h))
check("调用 getHTMLFromXPointers 而非单节点", #html_calls == 1, tostring(#html_calls))
if html_calls[1] then
    check("xp0 透传正确", html_calls[1].xp0 == "A", tostring(html_calls[1].xp0))
    check("xp1 透传正确", html_calls[1].xp1 == "B", tostring(html_calls[1].xp1))
    check("flags=0 / from_root=false", html_calls[1].flags == 0 and html_calls[1].from_root == false)
end
html_calls = {}
api.get_html("A", nil)
check("末章无 pos1 时自动回退到 end_xp（不退化成单节点）",
    #html_calls == 1 and html_calls[1].xp1 == api.end_xp,
    #html_calls == 1 and tostring(html_calls[1].xp1) or ("calls=" .. #html_calls))
check("pos0 为空时 get_html 安全返回 nil", api.get_html(nil, "B") == nil)

----------------------------------------------------------------------
-- 3) 端到端：适配层产出的 doc_api -> 生成完整（非空）EPUB
----------------------------------------------------------------------
local out = "/tmp/test_docapi.epub"
os.remove(out)
html_calls = {}
local bok, _, cnt, stats = pcall(Converter.build_epub_from_document, api, out, { book_title = "测试书名" })
check("端到端生成 EPUB 不 panic", bok, tostring(cnt))
if bok then
    check("章节数 = 4（TOC 全被识别，不再被跳过）", cnt == 4, tostring(cnt))
    check("空书体检：未被误判为空", stats and stats.empty == false,
        stats and tostring(stats.empty) .. " / visible=" .. tostring(stats.visible_chars) or "nil")
    check("可见正文字符数充足", stats and (stats.visible_chars or 0) > 100,
        stats and tostring(stats.visible_chars) or "nil")
    -- 末章也应走区间提取（xp1 = end_xp），而不是单节点
    check("末章调用也使用区间提取", (function()
        for _, c in ipairs(html_calls) do if c.xp1 == api.end_xp then return true end end
        return false
    end)(), "html_calls=" .. #html_calls)

    -- 解包校验目录含真实章节标题
    os.execute("rm -rf /tmp/test_docapi_unzip && mkdir -p /tmp/test_docapi_unzip")
    os.execute("cd /tmp/test_docapi_unzip && unzip -o -q " .. out .. " >/dev/null 2>&1")
    local nf = io.open("/tmp/test_docapi_unzip/OEBPS/nav.xhtml", "r")
    if nf then
        local nav = nf:read("*a"); nf:close()
        check("nav 含「第一章 开篇」", nav:find("第一章 开篇", 1, true) ~= nil)
        check("nav 含「第一节 细节」", nav:find("第一节 细节", 1, true) ~= nil)
        check("nav 含末章「第三章 结局」", nav:find("第三章 结局", 1, true) ~= nil)
        check("nav 含嵌套 <ol>（多级目录）", nav:find("<ol", 1, true) ~= nil)
    else
        check("nav.xhtml 存在", false)
    end
end

----------------------------------------------------------------------
-- 4) 兼容性：旧字段名（text/pos0/pos1）与只有 getTOC 的旧版
----------------------------------------------------------------------
local legacy_doc = {
    info = { number_of_pages = 2 },
    getProps = function() return { title = "旧版书" } end,
    getTOC = function()  -- 故意只提供大写别名
        return { { text = "旧式标题", depth = 1, pos0 = "XP0", pos1 = "XP1" } }
    end,
    getPageXPointer = function(_, p) return "XP" .. p end,
    getHTMLFromXPointers = function() return "<p>旧版正文内容足够长，不会被判为空书。</p>" end,
    getHTMLFromXPointer = function() return "" end,
}
local lapi = inst:_build_doc_api(legacy_doc)
check("只有 getTOC 的旧版也能取到 TOC", #lapi.toc == 1, tostring(#lapi.toc))
check("旧字段 text/pos0 仍兼容", lapi.toc[1] and lapi.toc[1].text == "旧式标题"
    and lapi.toc[1].pos0 == "XP0", lapi.toc[1] and tostring(lapi.toc[1].text) or "nil")
check("旧字段 pos1 不被 end_xp 覆盖", lapi.toc[1] and lapi.toc[1].pos1 == "XP1",
    lapi.toc[1] and tostring(lapi.toc[1].pos1) or "nil")

----------------------------------------------------------------------
-- 5) 无 HTML 接口（PDF/MuPDF 等）时安全回退，不 panic
----------------------------------------------------------------------
local pdf_doc = {
    info = { number_of_pages = 3 },
    getProps = function() return {} end,
    getToc = function() return { { title = "页1", depth = 1, page = 1 } } end,
    getPageXPointer = function(_, p) return "P" .. p end,
}
local pok, papi = pcall(function() return inst:_build_doc_api(pdf_doc) end)
check("非 CreDocument（无 HTML 接口）适配不 panic", pok, tostring(papi))
if pok then
    check("无 HTML 接口时 get_html = nil", papi.get_html == nil)
    -- build_epub_from_document 应安全回退为单章（空书体检会拦，但本身不崩）
    local eok = pcall(Converter.build_epub_from_document, papi, "/tmp/test_docapi_pdf.epub", { book_title = "PDF" })
    check("无 HTML 接口时 converter 安全回退不 panic", eok)
end

os.remove("/tmp/test_docapi.epub"); os.remove("/tmp/test_docapi_pdf.epub")
os.execute("rm -rf /tmp/test_docapi_unzip")
print(string.format("\n=== test_docapi：%d 通过, %d 失败 ===", passes, fails))
os.exit(fails == 0 and 0 or 1)
