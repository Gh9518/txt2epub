-- markup.lua
-- Markdown(.md) / HTML(.html/.htm) 解析模块：把标记文档转换为与 docx.lua
-- 相同的「段落 + 标题层级」序列，供 converter.build_epub_from_paragraphs
-- 烘焙成带多级目录的 EPUB。
--
-- 设计要点：
--   * 插件自解析源文件（只读磁盘），不依赖 KOReader 是否支持该格式，
--     也不依赖 CreDocument 的 getToc()/getHTMLFromXPointers()。
--   * Markdown：ATX 标题（# ~ ######）、Setext 标题（=== / ---）、
--     代码块围栏、引用、列表、行内粗体/斜体/链接/代码标记剥离。
--   * HTML：<title> 作书名；<h1>~<h6> 作多级标题；<p>/<div>/<li>/<br>
--     等作段落边界；剥离 <script>/<style>/<head>；XML 实体解码。
--   * 纯函数、零外部依赖、不使用 utf8 库（真机为 LuaJIT / Lua 5.1），
--     编码解码由 converter.lua 在读取阶段完成。
--
-- 对外 API：
--   M.parse(text, kind) -> { title = string|nil,
--                            paragraphs = { {kind="heading", level=N, text=T}
--                                         | {kind="body", text=T}, ... } }
--   kind: "md" | "markdown" -> Markdown；其余（"html"/"htm"）-> HTML

local M = {}

------------------------------------------------------------------------
-- XML / HTML 实体解码（含数字字符实体；不依赖 utf8 库）
------------------------------------------------------------------------
local REPLACEMENT_CHAR = "\239\191\189"  -- U+FFFD

local function codepoint_to_utf8(u)
    if type(u) ~= "number" or u ~= u or u < 0 or u > 0x10FFFF
        or (u >= 0xD800 and u <= 0xDFFF) then
        return REPLACEMENT_CHAR
    end
    if u < 0x80 then
        return string.char(u)
    elseif u < 0x800 then
        return string.char(0xC0 + math.floor(u / 64), 0x80 + (u % 64))
    elseif u < 0x10000 then
        return string.char(
            0xE0 + math.floor(u / 4096),
            0x80 + (math.floor(u / 64) % 64),
            0x80 + (u % 64)
        )
    end
    return string.char(
        0xF0 + math.floor(u / 262144),
        0x80 + (math.floor(u / 4096) % 64),
        0x80 + (math.floor(u / 64) % 64),
        0x80 + (u % 64)
    )
end

local function decode_entities(s)
    if not s or s == "" then return s or "" end
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&amp;", "&")  -- 必须最后，避免污染已展开的实体
    s = s:gsub("&#x([%x]+);", function(h) return codepoint_to_utf8(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return codepoint_to_utf8(tonumber(d, 10)) end)
    return s
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------------------
-- Markdown 行内标记剥离（保留可读文字；输出会由 EPUB 层做 XML 转义）
------------------------------------------------------------------------
local function strip_inline_md(s)
    s = s:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")     -- 图片 -> alt 文本
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")       -- 链接 -> 锚文本
    s = s:gsub("`([^`]*)`", "%1")                     -- 行内代码
    s = s:gsub("%*%*%*(.-)%*%*%*", "%1")             -- 粗斜体
    s = s:gsub("%*%*(.-)%*%*", "%1")                 -- 粗体
    s = s:gsub("__(.-)__", "%1")
    s = s:gsub("%*(.-)%*", "%1")                     -- 斜体
    s = s:gsub("~~(.-)~~", "%1")                     -- 删除线
    return s
end

local function split_lines(text)
    local lines, pos = {}, 1
    local n = #text
    while pos <= n do
        local nl = text:find("\n", pos, true)
        if not nl then
            lines[#lines + 1] = text:sub(pos)
            break
        end
        local ln = text:sub(pos, nl - 1)
        if ln:sub(-1) == "\r" then ln = ln:sub(1, -2) end
        lines[#lines + 1] = ln
        pos = nl + 1
    end
    return lines
end

local function parse_markdown(text)
    local paras, title = {}, nil
    local lines = split_lines(text)
    local pending = {}
    local in_code = false

    local function flush()
        if #pending > 0 then
            local t = trim(table.concat(pending, " "):gsub("%s+", " "))
            if t ~= "" then paras[#paras + 1] = { kind = "body", text = t } end
            pending = {}
        end
    end
    local function add_heading(t, level)
        t = trim(strip_inline_md(decode_entities(t)):gsub("%s+#+%s*$", ""))
        if t == "" then return end
        paras[#paras + 1] = { kind = "heading", level = level, text = t }
        if not title and level == 1 then title = t end
    end
    local function clean_body(ln)
        local b = ln:gsub("^%s*>%s*", "")           -- 引用
        b = b:gsub("^%s*%*%s+", "• ")             -- 无序列表
        b = b:gsub("^%s*%-%s+", "• ")
        b = b:gsub("^%s*%+%s+", "• ")
        b = b:gsub("^%s*%d+%.%s+", "")            -- 有序列表
        return trim(strip_inline_md(decode_entities(b)))
    end

    local i = 1
    while i <= #lines do
        local ln = lines[i]
        if ln:match("^%s*```") or ln:match("^%s*~~~") then
            flush()
            in_code = not in_code
        elseif in_code then
            if ln ~= "" then paras[#paras + 1] = { kind = "body", text = ln } end
        else
            local hashes, htext = ln:match("^(#+)%s+(.*)$")
            if hashes and #hashes <= 6 and htext then
                flush()
                add_heading(htext, #hashes)
            elseif ln:match("^%s*$") then
                flush()
            elseif ln:match("^%s*[%*%-_]%s*[%*%-_]%s*[%*%-_]%s*$") then
                flush()  -- 水平线
            else
                local body = clean_body(ln)
                local nxt = lines[i + 1] or ""
                if body ~= "" and nxt:match("^%s*=+=%s*$") then
                    flush()
                    add_heading(body, 1)
                    i = i + 1
                elseif body ~= "" and nxt:match("^%s*%-+%-+%s*$") then
                    flush()
                    add_heading(body, 2)
                    i = i + 1
                elseif body ~= "" then
                    pending[#pending + 1] = body
                end
            end
        end
        i = i + 1
    end
    flush()
    return { title = title, paragraphs = paras }
end

------------------------------------------------------------------------
-- HTML / HTM
------------------------------------------------------------------------
local function parse_html(text)
    local paras = {}
    local title = text:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
    if title then
        title = trim(decode_entities(title))
        if title == "" then title = nil end
    end

    local s = text
    s = s:gsub("<%?xml.-%?>", "")
    s = s:gsub("<!DOCTYPE[^>]*>", "")
    s = s:gsub("<!%-%-.-%-%->", "")                                   -- 注释
    s = s:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
    s = s:gsub("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]>", "")
    s = s:gsub("<[Hh][Ee][Aa][Dd][^>]*>.-</[Hh][Ee][Aa][Dd]>", "")

    -- <h1>~<h6> 打上哨兵，保留层级信息；用 \1H<N>\2 前缀，去标签后再解析
    for lv = 1, 6 do
        local pat = "<[Hh]" .. lv .. "[^>]*>(.-)</[Hh]" .. lv .. ">"
        s = s:gsub(pat, function(inner)
            return "\n\1H" .. lv .. "\2" .. (inner or "") .. "\n"
        end)
    end
    s = s:gsub("<[Bb][Rr]%s*/?>", "\n")
    s = s:gsub("</[^>]+>", "\n")     -- 任意闭合标签作为段落边界
    s = s:gsub("<[^>]*>", "")       -- 其余标签直接去掉
    s = decode_entities(s)

    for ln in (s .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local t = trim(ln)
        local lv, rest = t:match("^\1H([1-6])\2(.*)$")
        if lv then
            local ht = trim(decode_entities(rest or ""))
            if ht ~= "" then
                paras[#paras + 1] = { kind = "heading", level = tonumber(lv), text = ht }
                if not title and tonumber(lv) == 1 then title = ht end
            end
        elseif t ~= "" then
            paras[#paras + 1] = { kind = "body", text = t }
        end
    end
    return { title = title, paragraphs = paras }
end

function M.parse(text, kind)
    text = text or ""
    if kind == "md" or kind == "markdown" then
        return parse_markdown(text)
    end
    return parse_html(text)
end

return M
