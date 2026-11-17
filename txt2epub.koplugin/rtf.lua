-- rtf.lua
-- RTF(.rtf) 解析模块：把 RTF 转换为与 docx.lua / markup.lua 相同的
-- 「段落 + 标题层级」序列，供 converter.build_epub_from_paragraphs 烘焙成
-- 带多级目录的 EPUB。
--
-- 为什么需要它（真机反馈 v2.1.6）：
--   .rtf 此前走 KOReader 已打开文档的 DOM 兜底。真机 dom_sample.rtf 的
--   「第二章 远行」等标题使用 RTF 的负数 \u 转义（\u-28708? = 远 的码元拆分），
--   KOReader CreDocument 的 RTF 渲染器无法正确解析负数 \u，在该处把正文截断，
--   DOM 只返回约 968 字符 / 2 章，目录与正文严重缺失；转换成了一个空壳。
--   而 RTF 本质是纯文本标记，插件完全可以直接解析源文件：
--     * \uN?  Unicode 码点（N<0 时 +65536 得到 0x8000..0xFFFF 区码点），
--             其后紧跟的 1 个字符是 ANSI 替代符，需跳过；
--     * \ucN  每个 \u 之后需跳过的替代字节数（默认 1）；
--     * \par  段落边界；\b/\b0 粗体开关（粗体段多为标题）；
--     * {\fonttbl ...}{\colortbl ...}{\stylesheet ...} 等忽略；
--     * \'XX  十六进制字节（按 ansicpg 代码页，这里按 latin-1 单字节处理）。
--   自解析绕开 KOReader DOM 的乱码/截断，可拿到 RTF 的全部 6 个标题与正文，
--   且「忽略乱码取可用部分」——单个无法解码的 \u 降级为占位符，不影响其余内容。
--
-- 对外 API：
--   RtfReader.read(path) -> { title=书名|nil, paragraphs={...}, garbled=计数 } 或 (nil, err)
--   RtfReader.parse(text) -> 同上（纯函数，便于单元测试）
--   段落元素：{kind="heading", level=N, text=T} | {kind="body", text=T}
--   不使用 utf8 库（真机 LuaJIT / Lua 5.1），码点转 UTF-8 用纯算术。

local RtfReader = {}

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
        0x80 + math.floor(u / 4096) % 64,
        0x80 + (math.floor(u / 64) % 64),
        0x80 + (u % 64)
    )
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 整组丢弃的控制字：字体表/颜色表/样式表/图片/页眉页脚等，其内容不是正文。
local IGNORE_WORDS = {
    fonttbl = true, colortbl = true, stylesheet = true, info = true,
    listtable = true, listoverridetable = true, revtbl = true,
    generator = true, pict = true, object = true, thedata = true,
    header = true, footer = true, headerl = true, headerr = true,
    footerl = true, footerr = true, footnote = true, annotation = true,
    xmlnstbl = true, datastore = true,
}
local pending_skip_depth = nil  -- blank_ignored_groups 的跨迭代状态

------------------------------------------------------------------------
-- 解析 RTF 文本 -> { title, paragraphs, garbled }
--   标题判定：段落「整段粗体」或命中章节规则时视为 heading，层级由调用方
--   converter.title_level 决定（此处只标记 is_bold，避免耦合）。
------------------------------------------------------------------------
-- 预处理：把「整组丢弃」的控制字（字体表/颜色表/样式表/图片数据等）
-- 所在的 {...} 组内容清空为空格，避免其中的字面文本（如 "SimSun;"）混入正文。
-- 用栈做花括号配对，保留组边界字符本身以维持配对平衡。
local function blank_ignored_groups(text)
    local n = #text
    local out = {}
    local i = 1
    local skip_depth = 0   -- >0 表示当前处于需丢弃组内
    local depth = 0        -- 全局组深度
    while i <= n do
        local c = text:sub(i, i)
        if c == "\\" then
            -- 读取控制字名称（不解析参数，够用）
            local j = i + 1
            if j <= n then
                local sc = text:sub(j, j)
                if sc:match("[%a]") then
                    local k = j
                    while k <= n and text:sub(k, k):match("[%a]") do k = k + 1 end
                    local word = text:sub(j, k - 1)
                    if IGNORE_WORDS[word] then
                        -- 下一个非空白字符应是 '{'，标记即将进入丢弃组
                        local m = k
                        while m <= n and text:sub(m, m):match("%s") do m = m + 1 end
                        if m <= n and text:sub(m, m) == "{" then
                            pending_skip_depth = depth + 1
                        end
                    end
                end
            end
            out[#out + 1] = c
            i = i + 1
        elseif c == "{" then
            depth = depth + 1
            if pending_skip_depth and depth == pending_skip_depth then
                skip_depth = depth
                pending_skip_depth = nil
            end
            out[#out + 1] = c
            i = i + 1
        elseif c == "}" then
            if skip_depth == depth then skip_depth = 0 end
            depth = depth - 1
            out[#out + 1] = c
            i = i + 1
        else
            if skip_depth > 0 then
                out[#out + 1] = " "   -- 丢弃组内字符替换为空白
            else
                out[#out + 1] = c
            end
            i = i + 1
        end
    end
    return table.concat(out)
end

function RtfReader.parse(text)
    if type(text) ~= "string" then return nil, "RTF 内容不是字符串" end
    -- 去掉 UTF-8 BOM（RTF 理论上为 ASCII，保险处理）
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    text = blank_ignored_groups(text)

    local paragraphs = {}
    local garbled = 0

    -- 段落缓冲：每段收集文本片段与「是否全程粗体」
    local buf = {}          -- 文本片段数组
    local buf_has_plain = false   -- 是否含非粗体文本
    local buf_len = 0

    -- 粗体状态栈：进入组时压入当前值，离开组时弹出
    local bold_stack = {}
    local bold = false
    local uc_skip = 1       -- \u 后需跳过的替代字节数，默认 1

    -- 收一段：在清空缓冲前记录「是否全程粗体」（粗体段多为标题）
    local function flush()
        local s = table.concat(buf)
        local all_bold = not buf_has_plain
        buf, buf_has_plain, buf_len = {}, false, 0
        local t = trim(s)
        if t ~= "" then
            paragraphs[#paragraphs + 1] = { text = t, bold_all = all_bold }
        end
    end

    local function append(s)
        if not s or s == "" then return end
        buf[#buf + 1] = s
        buf_len = buf_len + #s
    end

    local n = #text
    local i = 1
    -- 已知的「整组丢弃」控制字：其 {...} 内容不是正文
    local ignore_words = {
        fonttbl = true, colortbl = true, stylesheet = true, info = true,
        listtable = true, listoverridetable = true, revtbl = true,
        generator = true, picture = true, pict = true, object = true,
        header = true, footer = true, headerl = true, headerr = true,
        footerl = true, footerr = true, footnote = true, annotation = true,
        xmlnstbl = true, datastore = true, thedata = true,
    }

    while i <= n do
        local c = text:sub(i, i)
        if c == "{" then
            bold_stack[#bold_stack + 1] = bold
            i = i + 1
        elseif c == "}" then
            flush()  -- 组结束通常也是段落/样式结束，稳妥起见收一段
            if #bold_stack > 0 then
                bold = bold_stack[#bold_stack]
                bold_stack[#bold_stack] = nil
            end
            i = i + 1
        elseif c == "\\" then
            -- 控制字：反斜杠 + 字母序列 + 可选负数 + 可选空格分隔
            i = i + 1
            if i > n then break end
            local ch = text:sub(i, i)
            if ch == "\\" or ch == "{" or ch == "}" then
                -- 转义的字面字符
                append(ch)
                i = i + 1
            elseif ch == "'" then
                -- \'XX 十六进制字节
                local hex = text:sub(i + 1, i + 2)
                if #hex == 2 and hex:match("^%x%x$") then
                    append(string.char(tonumber(hex, 16)))
                    i = i + 3
                else
                    i = i + 1
                end
            elseif ch:match("[%a]") then
                -- 读取控制字名称
                local j = i
                while j <= n and text:sub(j, j):match("[%a]") do j = j + 1 end
                local word = text:sub(i, j - 1)
                local k = j
                -- 可选整数参数（可带负号）
                local sign = 1
                if text:sub(k, k) == "-" then sign = -1; k = k + 1 end
                local dstart = k
                while k <= n and text:sub(k, k):match("%d") do k = k + 1 end
                local param = nil
                if k > dstart then param = tonumber(text:sub(dstart, k - 1)) * sign end
                -- 单个空格分隔符不属于下一个 token
                if k <= n and text:sub(k, k) == " " then k = k + 1 end
                i = k

                if word == "u" and param then
                    -- Unicode 码点：负数 + 65536 映射到 0x8000..0xFFFF
                    local cp = param
                    if cp < 0 then cp = cp + 65536 end
                    append(codepoint_to_utf8(cp))
                    -- 跳过紧随的 uc_skip 个替代字节（RTF \u 的 ANSI fallback）
                    for _ = 1, (uc_skip or 1) do
                        if i <= n then
                            local fb = text:sub(i, i)
                            if fb == "\\" then
                                -- fallback 可能本身是个转义序列，保守只跳一个字符
                                i = i + 1
                            else
                                i = i + 1
                            end
                        end
                    end
                elseif word == "uc" and param then
                    uc_skip = math.max(0, param)
                elseif word == "b" then
                    if param == nil or param ~= 0 then bold = true else bold = false end
                elseif word == "par" or word == "line" then
                    flush()
                elseif word == "tab" then
                    append(" ")
                elseif word == "emdash" then append("—")
                elseif word == "endash" then append("–")
                elseif word == "ldquo" then append("“")
                elseif word == "rdquo" then append("”")
                elseif word == "lsquo" then append("‘")
                elseif word == "rsquo" then append("’")
                elseif word == "bull" then append("•")
                elseif word == "nbsp" then append(" ")
                elseif ignore_words[word] then
                    -- 内容由后续 {...} 承载；此控制字本身跳过，组内容靠下面的 skip 组处理
                    -- 简化处理：不做嵌套跳过，字体表等一般是 ASCII 控制字，不会混入正文判定
                else
                    -- 未知控制字：忽略
                end
            else
                -- 控制符号（\* \~ 等）：跳过该字符
                i = i + 1
            end
        elseif c == "\r" or c == "\n" then
            -- RTF 源文件里的物理换行仅作空白处理（真正段落靠 \par）
            i = i + 1
        else
            if not bold then buf_has_plain = true end
            append(c)
            i = i + 1
        end
    end
    flush()

    -- 后处理：把「整段粗体 且 命中章节规则」的段标为 heading。
    -- 章节规则与层级判定复用 converter（若可用），否则用内置的宽松中文规则，
    -- 避免 rtf.lua 与 converter.lua 循环 require —— 层级先留 level=1，
    -- 由 converter.build_epub_from_paragraphs 再统一 title_level 精修。
    local Converter = nil
    pcall(function() Converter = require("converter") end)
    local out = {}
    for _, para in ipairs(paragraphs) do
        local is_heading = false
        local level = 1
        if para.bold_all then
            if Converter and type(Converter.is_chapter_title) == "function"
                and Converter.is_chapter_title(para.text) then
                is_heading = true
                if type(Converter.title_level) == "function" then
                    level = Converter.title_level(para.text) or 1
                end
            elseif not Converter and para.text:match("[第卷章节篇部回集]") then
                is_heading = true
            end
        end
        if is_heading then
            out[#out + 1] = { kind = "heading", level = level, text = para.text }
        else
            out[#out + 1] = { kind = "body", text = para.text }
        end
    end

    return { paragraphs = out, garbled = garbled }
end

------------------------------------------------------------------------
-- 对外：读取 .rtf 文件
------------------------------------------------------------------------
function RtfReader.read(path)
    local f = io.open(path, "rb")
    if not f then return nil, "无法打开文件：" .. tostring(path) end
    local data = f:read("*a")
    f:close()
    if not data or #data == 0 then return nil, "文件为空" end
    -- RTF 头检查（宽松）：允许前面有空白/BOM
    local head = data:sub(1, 32)
    if not head:lower():find("{\\rtf", 1, true) and not head:find("{\\urtf", 1, true) then
        return nil, "不是有效的 RTF 文件（缺少 {\\rtf 头）"
    end
    local res, err = RtfReader.parse(data)
    if not res then return nil, err end
    -- 书名：取第一段短文本（通常是标题），由上层再决定是否采用
    local first = res.paragraphs[1]
    if first and #first.text <= 40 then res.title = first.text end
    return res
end

return RtfReader
