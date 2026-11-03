-- converter.lua
-- txt2epub（TXT 排版助手）核心模块（纯 Lua 5.1，不依赖 KOReader UI，可被测试直接 require）
--
-- 本模块负责：
--   1. 读取 TXT 并按行流式处理（避免一次性把超大文件拼进内存）
--   2. 编码检测：UTF-8（含 BOM）/ UTF-16（含 BOM）/ GBK / GB18030
--   3. 章节识别与切分（默认内置一组 Lua 模式，支持中文与英文标题）
--   4. 生成 EPUB 所需的全部文件内容（xhtml / nav / ncx / opf / css / container）
--   5. 纯 Lua 写 ZIP（Store 方式，mimetype 必须是第一个条目且不压缩）
--
-- 注意：Lua 5.1 按字节处理字符串，本模块中所有多字节（UTF-8）处理均手动实现，
--       不依赖 utf8 标准库，因此可在 KOReader（LuaJIT）与普通 Lua 5.1 下运行。

local Converter = {}

------------------------------------------------------------------------
-- 1. 32 位无符号整数 / 位运算（不依赖 C 扩展或 Lua 5.3 原生位运算）
------------------------------------------------------------------------
-- 32 位按位异或（输入、输出均视为 0..2^32-1 的无符号整数）
local function bxor(a, b)
    local r = 0
    for i = 0, 31 do
        local ab = a % 2
        local bb = b % 2
        if ab ~= bb then
            r = r + 2 ^ i
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return r
end

-- 小端 16 / 32 位写出
local function le16(v)
    return string.char(math.floor(v % 256), math.floor((v / 256) % 256))
end
local function le32(v)
    v = v % 4294967296
    return string.char(
        math.floor(v % 256),
        math.floor((v / 256) % 256),
        math.floor((v / 65536) % 256),
        math.floor((v / 16777216) % 256)
    )
end

-- 预计算 CRC-32 表（多项式 0xEDB88320）
local crc_table = {}
do
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c % 2 == 1 then
                c = bxor(math.floor(c / 2), 0xEDB88320)
            else
                c = math.floor(c / 2)
            end
        end
        crc_table[i + 1] = c % 4294967296
    end
end

-- 计算字符串的 CRC-32（返回无符号 32 位整数）
local function crc32(data)
    local c = 0xFFFFFFFF
    for i = 1, #data do
        local b = string.byte(data, i)
        local idx = bxor(c % 256, b) % 256 + 1
        c = bxor(math.floor(c / 256), crc_table[idx]) % 4294967296
    end
    return bxor(c, 0xFFFFFFFF) % 4294967296
end

------------------------------------------------------------------------
-- 2. UTF-8 基础处理
------------------------------------------------------------------------
-- 返回某个 UTF-8 首字节对应的字符长度（1..4），无效首字节返回 0
local function utf8_char_len(b)
    if b < 0x80 then return 1 end
    if b >= 0xC0 and b <= 0xDF then return 2 end
    if b >= 0xE0 and b <= 0xEF then return 3 end
    if b >= 0xF0 and b <= 0xF4 then return 4 end
    return 0
end

-- 是否为 UTF-8 续字节（10xxxxxx）
local function is_cont(b)
    return b >= 0x80 and b <= 0xBF
end

-- 判断整段字符串是否为合法 UTF-8
local function is_valid_utf8(s)
    local i = 1
    local n = #s
    while i <= n do
        local b = string.byte(s, i)
        local len = utf8_char_len(b)
        if len == 0 then return false end
        if i + len - 1 > n then return false end
        for j = 1, len - 1 do
            local cb = string.byte(s, i + j)
            if not (cb >= 0x80 and cb <= 0xBF) then return false end
        end
        i = i + len
    end
    return true
end

-- 判断是否为合法 UTF-8，允许“末尾被截断的多字节字符”。
-- 用于按块读取时：块边界可能正好切断一个多字节字符，若只用 is_valid_utf8 会误判
-- 为非法（从而把合法的 UTF-8 文件错误路由到整本载入的 GBK 解码分支，导致 OOM）。
-- 整段为合法 UTF-8、或仅为合法 UTF-8 的前缀（仅最后一个字符不完整）均返回 true。
local function is_valid_utf8_prefix(s)
    local i = 1
    local n = #s
    while i <= n do
        local b = string.byte(s, i)
        local len = utf8_char_len(b)
        if len == 0 then return false end
        if i + len - 1 > n then
            -- 末尾可能被截断：仅当从 i 开始构成“合法的 UTF-8 起始片段”才放行
            if b < 0xC0 or b > 0xF4 then return false end
            for j = i + 1, n do
                local cb = string.byte(s, j)
                if not (cb >= 0x80 and cb <= 0xBF) then return false end
            end
            return true
        end
        for j = 1, len - 1 do
            local cb = string.byte(s, i + j)
            if not (cb >= 0x80 and cb <= 0xBF) then return false end
        end
        i = i + len
    end
    return true
end

-- 码点 -> UTF-8 字节串
local function codepoint_to_utf8(u)
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
    else
        return string.char(
            0xF0 + math.floor(u / 262144),
            0x80 + (math.floor(u / 4096) % 64),
            0x80 + (math.floor(u / 64) % 64),
            0x80 + (u % 64)
        )
    end
end

-- UTF-16（LE/BE）-> UTF-8，包含代理对处理
local function utf16_to_utf8(raw, le)
    local out = {}
    local i = 1
    local n = #raw
    while i + 1 <= n do
        local b1 = string.byte(raw, i)
        local b2 = string.byte(raw, i + 1)
        local u = le and (b1 + b2 * 256) or (b1 * 256 + b2)
        i = i + 2
        if u >= 0xD800 and u <= 0xDBFF and i + 1 <= n then
            local b3 = string.byte(raw, i)
            local b4 = string.byte(raw, i + 1)
            local u2 = le and (b3 + b4 * 256) or (b3 * 256 + b4)
            if u2 >= 0xDC00 and u2 <= 0xDFFF then
                u = 0x10000 + ((u - 0xD800) * 0x400) + (u2 - 0xDC00)
                i = i + 2
            end
        end
        out[#out + 1] = codepoint_to_utf8(u)
    end
    return table.concat(out)
end

------------------------------------------------------------------------
-- 3. 编码检测与解码
------------------------------------------------------------------------
-- 检测文件头部 BOM；返回 enc 与需要跳过的字节数
local function detect_bom(head)
    if string.sub(head, 1, 3) == "\239\187\191" then
        return "utf8", 3 -- EF BB BF
    elseif string.sub(head, 1, 2) == "\255\254" then
        return "utf16le", 2 -- FF FE
    elseif string.sub(head, 1, 2) == "\254\255" then
        return "utf16be", 2 -- FE FF
    end
    return "unknown", 0
end

-- 通过系统 iconv 尝试把非 UTF-8 字节流转成 UTF-8（GBK / GB18030 / GB2312）
local function decode_via_iconv(raw)
    local candidates = { "GBK", "GB18030", "GB2312" }
    local tmpin = os.tmpname()
    local tmpout = os.tmpname()
    local f = io.open(tmpin, "wb")
    if not f then return nil end
    f:write(raw)
    f:close()
    for _, enc in ipairs(candidates) do
        os.execute(string.format('iconv -f %s -t UTF-8 "%s" > "%s" 2>/dev/null', enc, tmpin, tmpout))
        local o = io.open(tmpout, "rb")
        if o then
            local data = o:read("*a") or ""
            o:close()
            if #data > 0 then
                os.remove(tmpin)
                os.remove(tmpout)
                return data
            end
        end
    end
    os.remove(tmpin)
    os.remove(tmpout)
    return nil
end

-- 找到 chunk 中最后一个“完整 UTF-8 字符”的结束下标；若无则回退到 0
local function utf8_boundary(chunk)
    local len = #chunk
    local i = len
    while i >= 1 and is_cont(string.byte(chunk, i)) do
        i = i - 1
    end
    if i < 1 then return 0 end
    local b = string.byte(chunk, i)
    local clen = utf8_char_len(b)
    if i + clen - 1 <= len then
        return i + clen - 1
    end
    return i - 1
end

-- 字符串按行迭代器（已解码为整段 UTF-8 的场景：UTF-16 / GBK 解码后）
local function string_lines(full)
    local pos = 1
    local done = false
    return function()
        if done then return nil end
        local nl = string.find(full, "\n", pos)
        if nl then
            local line = string.sub(full, pos, nl - 1)
            if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
            pos = nl + 1
            return line
        else
            local line = string.sub(full, pos)
            if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
            done = true
            return line ~= "" and line or nil
        end
    end
end

-- 混合迭代器：先消费 prefix 字符串，再从 fh 分块流式读取（64KB/块）。
-- 处理多字节字符跨块边界（utf8_boundary），按 \n 切行，去掉行尾 \r。
local function stream_lines(fh, prefix)
    local buf = prefix or ""
    local carry = ""
    local closed = (fh == nil)
    return function()
        if closed and buf == "" and carry == "" then return nil end
        while true do
            local nl = string.find(buf, "\n")
            if nl then
                local line = string.sub(buf, 1, nl - 1)
                buf = string.sub(buf, nl + 1)
                if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
                return line
            end
            if closed then
                if buf == "" then return nil end
                local rest = buf
                buf = ""
                if string.sub(rest, -1) == "\r" then rest = string.sub(rest, 1, -2) end
                return rest ~= "" and rest or nil
            end
            local chunk = fh:read(65536)
            if not chunk then
                fh:close()
                closed = true
                buf = buf .. carry
                carry = ""
            else
                chunk = carry .. chunk
                local boundary = utf8_boundary(chunk)
                buf = buf .. string.sub(chunk, 1, boundary)
                carry = string.sub(chunk, boundary + 1)
            end
        end
    end
end

------------------------------------------------------------------------
-- 返回按行迭代的闭包；自动处理编码与多字节跨块边界
-- 每行已去掉行尾 \r；文件结束时返回 nil
-- 内存原则：UTF-8 走 64KB 分块流式读取；UTF-16 / GBK 等先解码到临时文件，
--   再流式读回（64KB 分块）。任何编码都不会把“整本解码文本”驻留内存——
--   这是为避免在 Kindle 等低内存设备上 OOM 重启的关键。
------------------------------------------------------------------------
------------------------------------------------------------------------
-- 编码探测与解码（解码“一次”缓存）。
-- 关键：同一本书在转换流程里会被 has_title / count_chapters / build_epub_streaming
-- 各读一遍。若每次都 fork 一个 iconv 子进程做 GBK/UTF-16 解码，在内存吃紧的
-- Kindle 上反复创建子进程极易触发 OOM 强杀——这正是“点开始转换即崩溃”的主要
-- 嫌疑之一。因此这里把“解码临时文件”按 path 缓存，整条转换流程只解码一次。
-- 转换结束时由 main.lua 调用 Converter.release_lines(path) 清理临时文件。
-- 解码临时文件落在源文件同目录（避免 /tmp 多为 tmpfs 占用宝贵内存）。
------------------------------------------------------------------------
local _decoded_cache = {}  -- path -> 已解码临时文件路径（string）；false 表示原生 UTF-8 无需解码；nil 表示尚未探测

-- 把文件用 iconv 解码到“源文件同目录”的临时文件（落盘、不占 Lua 堆）。
-- 返回临时文件路径（string）；iconv 不可用时返回 false（回退为按原始字节流式读，内存有界、不崩）。
function Converter._decode_tmp(path, enc)
    local out = Converter._temp_path(path, ".txt2epub_decode.tmp")
    if enc then
        os.execute(string.format('iconv -f %s -t UTF-8 "%s" > "%s" 2>/dev/null', enc, path, out))
    else
        os.execute(string.format(
            'iconv -f GBK -t UTF-8 "%s" > "%s" 2>/dev/null || iconv -f GB18030 -t UTF-8 "%s" > "%s" 2>/dev/null || iconv -f GB2312 -t UTF-8 "%s" > "%s" 2>/dev/null',
            path, out, path, out, path, out))
    end
    local rfh = io.open(out, "rb")
    if not rfh then
        return false
    end
    rfh:close()
    return out
end

-- 探测编码：返回“已解码临时文件路径”或 false（原生 UTF-8，无需解码）
function Converter._probe_encoding(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local first = f:read(4) or ""
    local enc, skip = detect_bom(first)
    if enc == "utf16le" or enc == "utf16be" then
        f:close()
        return Converter._decode_tmp(path, "UTF-16")
    end
    if enc == "utf8" then
        f:close()
        return false  -- 原生 UTF-8（仅去掉 BOM），无需解码
    end
    local rest = f:read(65536) or ""
    if is_valid_utf8_prefix(first .. rest) then
        f:close()
        return false  -- 无 BOM 的合法 UTF-8，无需解码
    end
    f:close()
    -- 非 UTF-8（多为 GBK / GB18030 等）：解码到临时文件后流式读回
    return Converter._decode_tmp(path, nil)
end

-- 在源文件所在目录生成临时文件名（避免 /tmp 多为 tmpfs 占用宝贵内存）
function Converter._temp_path(path, suffix)
    local dir = string.match(path, "^(.*)/") or "."
    return dir .. "/" .. (suffix or ".txt2epub.tmp")
end

function Converter.lines(path)
    if _decoded_cache[path] == nil then
        _decoded_cache[path] = Converter._probe_encoding(path)
    end
    local decoded = _decoded_cache[path]
    if decoded then
        -- 已从 GBK/UTF-16 解码到临时文件：每次读取重新打开该文件从头流式读（互不干扰）
        local f = io.open(decoded, "rb")
        if f then return stream_lines(f, "") end
        -- 临时文件已丢失：退回原始字节流（可能乱码但内存有界、不崩）
        local g = io.open(path, "rb")
        return g and stream_lines(g, "") or function() return nil end
    end
    -- 原生 UTF-8：直接打开源文件，按 BOM / UTF-8 前缀流式读取（不重复解码）
    local fh = io.open(path, "rb")
    if not fh then
        return function() return nil end
    end
    local first = fh:read(4) or ""
    local enc, skip = detect_bom(first)
    if enc == "utf8" then
        fh:seek("set", skip)
        return stream_lines(fh, "")
    end
    local rest = fh:read(65536) or ""
    local combined = first .. rest
    if is_valid_utf8_prefix(combined) then
        return stream_lines(fh, combined)
    end
    -- 兜底：原始字节流（内存有界、不崩）
    return stream_lines(fh, "")
end

-- 转换结束时调用：删除解码临时文件并清缓存（pcall 守护，失败不影响转换结果）
function Converter.release_lines(path)
    if _decoded_cache[path] then
        pcall(os.remove, _decoded_cache[path])
        _decoded_cache[path] = nil
    end
end

-- 读取整个文件并解码为 UTF-8 文本（用于回退场景：整本书作一章）
function Converter.read_all(path)
    local parts = {}
    local iter = Converter.lines(path)
    local line = iter()
    while line ~= nil do
        parts[#parts + 1] = line
        line = iter()
    end
    return table.concat(parts, "\n")
end

------------------------------------------------------------------------
-- 4. 文本工具：trim / 空白行 / HTML 转义
------------------------------------------------------------------------
local function trim(s)
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function is_blank(s)
    return string.find(s, "^%s*$") ~= nil
end

-- 计算一行的前导“空格等价宽度”（tab 按 step 个空格计），用于缩进层级识别
-- 例：step=4 时 "    行"（3 空格）宽度 3，"		行"（2 tab）宽度 8（=2*4）
local function leading_width(line, step)
    local w = 0
    local i = 1
    local n = #line
    while i <= n do
        local c = string.sub(line, i, i)
        if c == " " then
            w = w + 1
        elseif c == "\t" then
            w = w + step
        else
            break
        end
        i = i + 1
    end
    return w
end

-- 转义 XML 文本节点（& < >）
local function escape_xml(s)
    s = string.gsub(s, "&", "&amp;")
    s = string.gsub(s, "<", "&lt;")
    s = string.gsub(s, ">", "&gt;")
    return s
end

-- 转义 XML 属性（额外处理 " '）
local function escape_attr(s)
    s = escape_xml(s)
    s = string.gsub(s, '"', "&quot;")
    s = string.gsub(s, "'", "&apos;")
    return s
end

-- 转义整段正文（用于 <p> 内容；正文只需转义 & < >，无需转义引号，少两次 gsub 更快）
local function escape_html(s)
    return escape_xml(s)
end

------------------------------------------------------------------------
-- 4b. 排版优化（参考 moon.koplugin）：段落回流 + 硬行判定
------------------------------------------------------------------------
-- 判断一行是否为“硬行”（列表项 / 对话句首），应独立成段
local function is_hard_line(line)
    return line:match("^%s*[-*•·●○]") ~= nil
        or line:match("^%s*%d+[%.、)]") ~= nil
        or line:match("^[“\"「『]") ~= nil
end

-- 把多行合并为连贯文本：中文直接拼接（无空格），仅当英文单词跨行时在中间补一个空格。
-- 参考 moon.koplugin 的 paragraphText 思路，避免把一行当成一段（否则段首缩进与两端对齐失效）。
local function merge_lines(lines)
    local out = { lines[1] or "" }
    for i = 2, #lines do
        local prev = lines[i - 1]
        local cur = lines[i]
        local left = prev:sub(-1)
        local right = cur:sub(1, 1)
        if left:match("[%w]") and right:match("[%w]") then
            out[#out + 1] = " "
        end
        out[#out + 1] = cur
    end
    return table.concat(out)
end

-- 段落回流：把若干“物理行”规整为若干“逻辑段落”。
-- 规则（参考 moon.koplugin）：空行分段；行末为句末标点（。！？!?；;）则结束当前段；
--       硬行（列表/对话）独立成段。返回字符串数组（每段一段纯文本）。
local function reflow_block(lines)
    local paras = {}
    local cur = {}
    local function flushp()
        if #cur > 0 then
            paras[#paras + 1] = merge_lines(cur)
            cur = {}
        end
    end
    for _, raw in ipairs(lines) do
        local line = trim(raw)
        if line == "" then
            flushp()
        elseif is_hard_line(line) then
            flushp()
            paras[#paras + 1] = line
        else
            if #cur > 0 and cur[#cur]:match("[。！？!?；;]$") then
                flushp()
            end
            cur[#cur + 1] = line
        end
    end
    flushp()
    return paras
end

------------------------------------------------------------------------
-- 4c. 排版预设（借鉴 txtstyle.koplugin 的“快速风格”与参数模型）
--   这些预设在【转换时】一次性烘焙进 EPUB 的 style.css，不安装任何常驻阅读
--   钩子 —— 因此【不会】增加 KOReader 的常驻内存 / CPU（对照 txtstyle 的持久
--   钩子机制，本方案在内存占用上是零增量）。
------------------------------------------------------------------------
-- 各字段含义（与 txtstyle 对齐）：
--   line_height   : 行距 %，150 为阅读舒适基准（KOReader 默认约 1.5）
--   para_spacing  : 段落间距，单位 0.01em（值 30 = 0.3em）
--   text_indent   : 首行缩进，单位 0.01em（值 200 = 2 字宽，中文段首缩进惯例）
--   font_scale    : 字号缩放 %，100 = 不缩放
--   letter_spacing: 字距，单位 0.01em（0 = 不干预）
--   justify       : 是否两端对齐
--   font          : 指定字体名（空 = 用 serif 衬线字体族）
Converter.STYLE_PRESETS = {
    compact  = { line_height = 130, para_spacing = 0,  text_indent = 0,   font_scale = 100, letter_spacing = 0, justify = true, font = "" },
    standard = { line_height = 155, para_spacing = 30, text_indent = 200, font_scale = 100, letter_spacing = 0, justify = true, font = "" },
    relaxed  = { line_height = 185, para_spacing = 60, text_indent = 200, font_scale = 115, letter_spacing = 0, justify = true, font = "" },
}
Converter.STYLE_DEFAULTS = { line_height = 155, para_spacing = 30, text_indent = 200, font_scale = 100, letter_spacing = 0, justify = true, font = "" }

-- 把 preset 名或自定义表规整为一个完整、数值兜底过的 style 表
function Converter.resolve_style(style)
    local s = {}
    for k, v in pairs(Converter.STYLE_DEFAULTS) do s[k] = v end
    if type(style) == "string" then
        local p = Converter.STYLE_PRESETS[style]
        if p then for k, v in pairs(p) do s[k] = v end end
    elseif type(style) == "table" then
        for k, v in pairs(style) do s[k] = v end
    end
    s.line_height    = tonumber(s.line_height) or 155
    s.para_spacing   = tonumber(s.para_spacing) or 0
    s.text_indent    = tonumber(s.text_indent) or 0
    s.font_scale     = tonumber(s.font_scale) or 100
    s.letter_spacing = tonumber(s.letter_spacing) or 0
    s.justify        = (s.justify == nil) and true or s.justify
    s.font           = type(s.font) == "string" and s.font or ""
    return s
end

-- 章节标题层级（借鉴 toc_extractor 的多级目录思路，在转换时一次性算好）：
--   卷/部/册/篇/Book/Volume -> 顶层(0)
--   章/回                   -> 一级(1)
--   节/集/幕/Section        -> 二级(2)
--   序章/楔子/番外等特例      -> 一级(1)
-- 用于在 nav / ncx 中生成真正的多级嵌套目录（而非平铺一长串）。
-- 注意：title_level 仅在已被 is_title_line 判定为标题的行上调用，
--       因此“第一部门”这类被过滤的伪标题不会进入。
-- 注意：Lua 模式的字符类 [] 对多字节中文支持不可靠（会把“章”误并入“卷部册篇”集合），
--       故这里改用「纯子串定位 + 取最先出现的标记」来判定层级，规避该坑。
local LV_MARKERS = { ["卷"] = 0, ["部"] = 0, ["册"] = 0, ["篇"] = 0,
                     ["章"] = 1, ["回"] = 1,
                     ["节"] = 2, ["集"] = 2, ["幕"] = 2 }
local function title_level(line)
    line = trim(line)
    line = line:gsub("^=+%s*", ""):gsub("%s*=+$", "")
    -- 英文标记优先（用 %w 确保后面确实跟了内容，避免误判）
    if line:match("^[Vv]olume%s+%w") or line:match("^[Bb]ook%s+%w") then
        return 0
    end
    if line:match("^[Ss]ection%s+%w") then
        return 2
    end
    if line:match("^[Cc]hapter%s+%w") then
        return 1
    end
    -- 中文：用纯子串（find 的 plain 模式）定位各标记首次出现的位置，
    -- 取最早出现者决定层级 —— 这样“第一章 卷宗”仍判为章级而非卷级。
    local best_pos, best_lv = nil, 1
    for ch, lv in pairs(LV_MARKERS) do
        local p = line:find(ch, 1, true)
        if p and (best_pos == nil or p < best_pos) then
            best_pos = p
            best_lv = lv
        end
    end
    return best_lv
end
function Converter.title_level(line)
    return title_level(line)
end

------------------------------------------------------------------------
-- 5. 章节识别
------------------------------------------------------------------------
-- 默认标题识别规则（Lua 模式；注意 Lua 模式按字节匹配，中文以原字节字面量参与）
--   中文：第一章 / 第1章 / 第001章 / 第十二章 / 卷一 / 楔子 / 番外 / 后记 …
--   英文：Chapter 1 / Chapter One
Converter.default_patterns = function()
    return {
        "^%s*第[%d一二三四五六七八九十百千零〇]+章",
        "^%s*第[%d一二三四五六七八九十百千零〇]+卷",
        "^%s*第[%d一二三四五六七八九十百千零〇]+[%s]*[节部回幕集篇话]%s",
        "^%s*卷[%d一二三四五六七八九十百千零〇]+[%s]+",
        "^%s*[Cc]hapter%s+[%w]+",
        "^%s*楔子",
        "^%s*番外",
        "^%s*后记",
        "^%s*序章",
        "^%s*引子",
        "^%s*序言",
        "^%s*前言",
        "^%s*尾声",
        "^%s*附录",
        "^%s*第[%d]+[%s]*篇",
    }
end

------------------------------------------------------------------------
-- 章节标题识别（参考 moon.koplugin 的稳健识别，取长补短）
--   中文：第X章/回/节/集/幕/卷/部/篇（含中文数字校验、无效卷名过滤）
--   英文：Chapter / Section / Page + 序号（含 Chapter One 这类英文数词）
--   特例：序章/序言/前言/楔子/引子/尾声/后记/番外/终章/最终章/完本感言/附录
------------------------------------------------------------------------
local CHINESE_NUMBER_CHARS = { "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "两" }
local SPECIAL_TITLES = {
    ["序章"] = true, ["序言"] = true, ["前言"] = true, ["楔子"] = true,
    ["引子"] = true, ["尾声"] = true, ["后记"] = true, ["番外"] = true,
    ["终章"] = true, ["最终章"] = true, ["完本感言"] = true, ["附录"] = true,
}
-- “第一部”是卷名；“第一部门/部队/分队…”是正文，不是“部”章节
local INVALID_VOLUME_SUFFIX = { ["门"] = true, ["队"] = true, ["属"] = true, ["分"] = true, ["件"] = true, ["落"] = true }

-- 字符串是否为“数字型标记”（阿拉伯数字 / 罗马数字 / 中文数字）
local function isNumberToken(value)
    value = value:gsub("%s+", "")
    if value == "" then return false end
    if value:match("^%d+$") or value:match("^[IVXLCDMivxlcdm]+$") then return true end
    local rest = value
    for _i, ch in ipairs(CHINESE_NUMBER_CHARS) do
        rest = rest:gsub(ch, "")
    end
    return rest == ""
end

-- 判断一行是否为章节标题（返回标题字符串或 nil）；参考 moon.koplugin/chapterTitle
local function chapterTitle(line)
    line = trim(line)
    -- 常见 TXT 用 === 包裹标题：仅剥离等号，避免吞掉正文
    line = line:gsub("^=+%s*", ""):gsub("%s*=+$", "")
    if line:match("^[Cc]hapter%s+[%w]+")
        or line:match("^[Ss]ection%s+[%w]+")
        or line:match("^[Pp]age%s+%d+") then
        return line
    end
    if line:sub(1, 3) == "第" then
        for _i, marker in ipairs({ "章", "回", "节", "集", "幕", "卷", "部", "篇" }) do
            local number, suffix = line:match("^第%s*(.-)%s*" .. marker .. "(.*)$")
            if number and isNumberToken(number) then
                -- 标记字之后必须是空白 / 标点（或行末），避免把“第二回的内容”这类正文行误判为标题
                local ok_suffix = (suffix == "" or suffix:match("^%s") or suffix:match("^%p"))
                -- “第一部门/部队”是正文，不是“第一部”章节
                if ok_suffix and (marker ~= "部" or not INVALID_VOLUME_SUFFIX[suffix:sub(1, 3)]) then
                    return line
                end
            end
        end
    end
    for title in pairs(SPECIAL_TITLES) do
        if line == title
            or line:match("^" .. title .. "[%s:%-].+$")
            or line:match("^" .. title .. "：.+$") then
            return line
        end
    end
    return nil
end

function Converter.is_chapter_title(line)
    return chapterTitle(line) ~= nil
end

-- 判断一行是否为章节标题；patterns 为自定义 Lua 模式表（优先），nil 则用默认稳健识别
local function is_title_line(line, patterns)
    local t = trim(line)
    if t == "" then return false end
    if patterns then
        for _, p in ipairs(patterns) do
            if string.find(t, p) then return true end
        end
        return false
    end
    return chapterTitle(t) ~= nil
end

-- 在“内存文本”中判断是否含章节标题（供菜单交互前预检）
function Converter.has_title_text(text, pattern)
    local patterns = pattern and { pattern } or nil
    local pos = 1
    while true do
        local nl = string.find(text, "\n", pos)
        local line
        if nl then
            line = string.sub(text, pos, nl - 1)
            pos = nl + 1
        else
            line = string.sub(text, pos)
            pos = nil
        end
        if line and string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
        if line and is_title_line(line, patterns) then return true end
        if not nl then break end
    end
    return false
end

-- 在文件中判断是否含章节标题（流式，不把整文件读入内存）
function Converter.has_title(path, patterns)
    patterns = patterns
    local iter = Converter.lines(path)
    local line = iter()
    while line ~= nil do
        if is_title_line(line, patterns) then return true end
        line = iter()
    end
    return false
end

------------------------------------------------------------------------
-- 预统计章节总数（供转换前显示进度百分比，不生成任何 EPUB 构件）
-- kind / arg 语义与 build_epub_streaming 一致：
--   "title"  -> arg：自定义 Lua 模式串（可空，用默认稳健识别）
--   "single" -> 整本一章，直接返回 1
--   "indent" -> arg：缩进步长 step（整数）
-- 返回估计的章节数（至少 1，避免除零）
------------------------------------------------------------------------
function Converter.count_chapters(path, kind, arg)
    local iter = Converter.lines(path)
    if kind == "single" then
        return 1
    end
    local count = 0
    if kind == "indent" then
        local step = (type(arg) == "number" and arg) or 4
        if step < 1 then step = 1 end
        local line = iter()
        while line ~= nil do
            if not is_blank(line) then count = count + 1 end
            line = iter()
        end
    else
        local patterns
        if type(arg) == "table" then
            patterns = arg
        elseif arg and arg ~= "" then
            patterns = { arg }
        else
            patterns = nil
        end
        local line = iter()
        while line ~= nil do
            if is_title_line(line, patterns) then count = count + 1 end
            line = iter()
        end
    end
    return count > 0 and count or 1
end

-- 把整段文本切分为段落（每段一段纯文本；参考 moon.koplugin 做段落回流合并）
function Converter.text_to_paras(text)
    local paras = {}
    local buffer = {}
    local function flush()
        if #buffer > 0 then
            local ps = reflow_block(buffer)
            for _, p in ipairs(ps) do paras[#paras + 1] = p end
            buffer = {}
        end
    end
    for line in string.gmatch(text .. "\n", "[^\n]*\n") do
        local l = string.sub(line, 1, -2) -- 去掉 \n
        if is_blank(l) then
            flush()
        else
            buffer[#buffer + 1] = l
        end
    end
    flush()
    return paras
end

-- 回退逻辑：整本书作为一个章节
function Converter.wrap_single_chapter(text, title)
    title = title or "正文"
    return { { title = title, paras = Converter.text_to_paras(text) } }
end

-- 核心：把若干行聚合成章节数组
-- 章节结构：{ title = 字符串, paras = { {行,...}, ... } }
-- 规则：
--   - 首个标题之前的正文（如书名行）并入第一章，而非单独成章
--   - 全书无任何标题时，所有正文作为单章（回退）
local function build_chapters(line_iter, patterns, book_title)
    local chapters = {}
    local current = nil
    local buffer = {}
    local leading = nil -- 首个标题之前的正文，将并入第一章
    local seen_title = false

    local function flush_into(target)
        if #buffer > 0 then
            local ps = reflow_block(buffer)
            for _, p in ipairs(ps) do
                target.paras[#target.paras + 1] = p
            end
            buffer = {}
        end
    end
    local function close_current()
        if current then
            flush_into(current)
            chapters[#chapters + 1] = current
            current = nil
        end
    end

    local line = line_iter()
    while line ~= nil do
        if is_title_line(line, patterns) then
            if not seen_title then
                -- 首个标题：把前置正文并入本章开头
                if leading then flush_into(leading) end
                current = { title = trim(line), paras = leading and leading.paras or {}, level = Converter.title_level(line), children = {} }
                leading = nil
                seen_title = true
            else
                close_current()
                current = { title = trim(line), paras = {}, level = Converter.title_level(line), children = {} }
            end
        else
            if seen_title then
                if not current then current = { title = book_title, paras = {}, level = 0, children = {} } end
                if is_blank(line) then flush_into(current) else buffer[#buffer + 1] = line end
            else
                if not leading then leading = { title = book_title, paras = {}, level = 0, children = {} } end
                if is_blank(line) then flush_into(leading) else buffer[#buffer + 1] = line end
            end
        end
        line = line_iter()
    end
    close_current()
    -- 全书无任何章节标题：把前置正文（即整本书）作为单章
    if leading and #leading.paras > 0 then
        chapters[#chapters + 1] = leading
    end
    return chapters
end

-- 流式切分（接收 Converter.lines 返回的迭代器），供 main.lua 使用
function Converter.collect_chapters(line_iter, pattern, book_title)
    local patterns
    if type(pattern) == "table" then
        patterns = pattern
    elseif pattern and pattern ~= "" then
        patterns = { pattern }
    else
        patterns = nil
    end
    return build_chapters(line_iter, patterns, book_title or "未命名")
end

-- 供测试使用的纯函数：直接对内存文本切分
function Converter.split_chapters(text, pattern)
    local patterns = pattern and { pattern } or nil
    local pos = 1
    local function iter()
        if not pos then return nil end
        local nl = string.find(text, "\n", pos)
        local line
        if nl then
            line = string.sub(text, pos, nl - 1)
            pos = nl + 1
        else
            line = string.sub(text, pos)
            pos = nil
        end
        if line and string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
        return line
    end
    return build_chapters(iter, patterns, "未命名")
end

------------------------------------------------------------------------
-- 5b. 缩进模式：基于“前导空格数”识别目录层级
------------------------------------------------------------------------
-- 当 TXT 未使用“第X章”这类显式标题，而是用空格缩进来表达目录层级时启用。
-- 规则：每行前导空格数 / step = 层级；step 默认 4（可在设置中自定义）。
--   0 空格   -> 顶层（第1级）
--   4 空格   -> 子层级（第2级），如 “3.1 小节” 隶属 “第3章”
--   8 空格   -> 再下一级
-- 每一行（非空）即一个目录条目（节点），依缩进形成父子嵌套树。
-- 返回：顶层节点数组（森林），以及节点总数。
function Converter.build_chapters_indent(line_iter, step, book_title)
    step = step or 4
    if step < 1 then step = 1 end
    local root = { title = book_title, level = -1, children = {}, paras = {} }
    local stack = { root }
    local count = 0

    local line = line_iter()
    while line ~= nil do
        if not is_blank(line) then
            local w = leading_width(line, step)
            local level = math.floor(w / step)
            local node = { title = trim(line), level = level, children = {}, paras = {} }
            -- 弹出栈顶，直到栈顶层级 < 当前层级（找到父节点）
            while #stack > 1 and stack[#stack].level >= level do
                table.remove(stack)
            end
            local parent = stack[#stack]
            parent.children[#parent.children + 1] = node
            stack[#stack + 1] = node
            count = count + 1
        end
        line = line_iter()
    end
    return root.children, count
end

-- 把“扁平有序 + 含 level 字段”的节点列表，按 level 重新组装为嵌套树
-- 供 build_nav / build_ncx 渲染多级目录使用
function Converter.nest_toc(flat)
    local root = { title = "", level = -1, children = {}, file = "", paras = {} }
    local stack = { root }
    for _, nd in ipairs(flat) do
        local level = nd.level or 0
        local node = { title = nd.title, file = nd.file, level = level, children = {}, paras = nd.paras }
        while #stack > 1 and stack[#stack].level >= level do
            table.remove(stack)
        end
        stack[#stack].children[#stack[#stack].children + 1] = node
        stack[#stack + 1] = node
    end
    return root.children
end

------------------------------------------------------------------------
-- 6. EPUB 各文件内容生成
------------------------------------------------------------------------
-- 单个章节 XHTML；level 用于子层级标题的视觉区分（lv-N 类）
function Converter.build_chapter_xhtml(title, paras, indent, level)
    indent = indent or "2em"
    level = level or 0
    local lv_class = level > 0 and (" lv-" .. level) or ""
    local blocks = {}
    blocks[#blocks + 1] = '<?xml version="1.0" encoding="UTF-8"?>'
    blocks[#blocks + 1] = '<!DOCTYPE html>'
    blocks[#blocks + 1] = '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh" xml:lang="zh">'
    blocks[#blocks + 1] = '<head>'
    blocks[#blocks + 1] = '<meta charset="UTF-8"/>'
    blocks[#blocks + 1] = '<title>' .. escape_xml(title) .. '</title>'
    blocks[#blocks + 1] = '<link rel="stylesheet" type="text/css" href="style.css"/>'
    blocks[#blocks + 1] = '</head>'
    blocks[#blocks + 1] = '<body>'
    blocks[#blocks + 1] = '<h1 class="chapter-title' .. lv_class .. '">' .. escape_xml(title) .. '</h1>'
    -- paras 为“每行一段纯文本”的字符串数组（已做段落回流合并）
    for _, para in ipairs(paras) do
        blocks[#blocks + 1] = '<p>' .. escape_html(para) .. '</p>'
    end
    blocks[#blocks + 1] = '</body>'
    blocks[#blocks + 1] = '</html>'
    return table.concat(blocks, "\n")
end

-- 样式表（排版优化：借鉴 txtstyle.koplugin 的参数模型，在【转换时】一次性烘焙进
--   EPUB 静态 CSS；不安装任何阅读期钩子，因此【不会】增加 KOReader 常驻内存 / CPU）。
--   opts: { indent = "2em", style = 预设名 | 参数表 }
--   为兼容旧调用，opts 也可直接传 indent 字符串。
function Converter.build_style_css(opts)
    if type(opts) == "string" then opts = { indent = opts } end
    opts = opts or {}
    local indent = opts.indent or "2em"
    local s = Converter.resolve_style(opts.style)

    local font_decl
    if s.font and s.font ~= "" then
        font_decl = string.format('  font-family: "%s", serif;\n', s.font:gsub('["\\]', ""))
    else
        font_decl = "  font-family: serif;\n"
    end
    local font_size = (s.font_scale ~= 100)
        and string.format("  font-size: %d%%;\n", s.font_scale) or ""
    local body_lh = string.format("  line-height: %d%%;\n", s.line_height)
    local letter = (s.letter_spacing ~= 0)
        and string.format("  letter-spacing: %.2fem;\n", s.letter_spacing / 100) or ""
    local justify = s.justify and "  text-align: justify;\n" or "  text-align: left;\n"
    local p_indent = string.format("%.2fem", s.text_indent / 100)
    local p_margin = string.format("%.2fem", s.para_spacing / 100)

    return [[
body {
]] .. font_decl .. [[
  margin: 0 0.8em;
]] .. font_size .. body_lh .. justify .. letter .. [[
  word-break: break-word;
  -webkit-line-break: normal;
}
p {
  text-indent: ]] .. p_indent .. [[;
  line-height: ]] .. (s.line_height / 100) .. [[;
  margin: 0 0 ]] .. p_margin .. [[ 0;
  orphans: 2;
  widows: 2;
}
.chapter-title {
  text-align: center;
  font-weight: bold;
  font-size: 1.2em;
  text-indent: 0;
  margin: 1em 0 1.5em 0;
  page-break-after: avoid;
}
/* 缩进模式下的子层级标题：层级越深字号略小，体现目录层级 */
.chapter-title.lv-1 { font-size: 1.1em; }
.chapter-title.lv-2 { font-size: 1.0em; }
.chapter-title.lv-3 { font-size: 0.95em; }
.chapter-title.lv-4 { font-size: 0.9em; }
]]
end

-- EPUB3 目录 nav.xhtml（支持嵌套层级）
function Converter.build_nav(nodes, book_title)
    local function render(items)
        if not items or #items == 0 then return "" end
        local out = { "  <ol>" }
        for _, it in ipairs(items) do
            local href = string.gsub(it.file, "^OEBPS/", "")
            out[#out + 1] = '    <li><a href="' .. escape_attr(href) .. '">' .. escape_xml(it.title) .. '</a>'
            if it.children and #it.children > 0 then
                out[#out + 1] = render(it.children)
            end
            out[#out + 1] = "    </li>"
        end
        out[#out + 1] = "  </ol>"
        return table.concat(out, "\n")
    end
    return [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh" xml:lang="zh">
<head><meta charset="UTF-8"/><title>目录</title></head>
<body>
<nav epub:type="toc" id="toc">
<h1>目录</h1>
]] .. render(nodes) .. [[
</nav>
</body>
</html>]]
end

-- EPUB2 兼容目录 toc.ncx（KOReader 旧版读取，支持嵌套 navPoint）
function Converter.build_ncx(nodes, book_title, uid)
    uid = uid or Converter.gen_uid()
    local max_depth = 1
    local function calc_depth(items, d)
        for _, it in ipairs(items) do
            if d > max_depth then max_depth = d end
            if it.children and #it.children > 0 then calc_depth(it.children, d + 1) end
        end
    end
    calc_depth(nodes, 1)

    local counter = { n = 0 }
    local function render(items)
        local out = {}
        for _, it in ipairs(items) do
            counter.n = counter.n + 1
            local href = string.gsub(it.file, "^OEBPS/", "")
            out[#out + 1] = '<navPoint id="navpoint-' .. counter.n .. '" playOrder="' .. counter.n .. '">' ..
                '<navLabel><text>' .. escape_xml(it.title) .. '</text></navLabel>' ..
                '<content src="' .. escape_attr(href) .. '"/>'
            if it.children and #it.children > 0 then
                out[#out + 1] = render(it.children)
            end
            out[#out + 1] = '</navPoint>'
        end
        return table.concat(out, "\n")
    end
    return [[<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="zh">
<head>
<meta name="dtb:uid" content="]] .. escape_attr(uid) .. [["/>
<meta name="dtb:depth" content="]] .. max_depth .. [["/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. escape_xml(book_title) .. [[</text></docTitle>
<navMap>
]] .. render(nodes) .. [[
</navMap>
</ncx>]]
end

-- content.opf：元数据 / manifest / spine
function Converter.build_opf(toc, book_title, uid, modified)
    uid = uid or Converter.gen_uid()
    modified = modified or os.date("!%Y-%m-%dT%H:%M:%SZ")
    local manifest = {}
    manifest[#manifest + 1] = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    manifest[#manifest + 1] = '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
    manifest[#manifest + 1] = '<item id="css" href="style.css" media-type="text/css"/>'
    local spine = {}
    for i, ch in ipairs(toc) do
        local href = string.gsub(ch.file, "^OEBPS/", "")
        manifest[#manifest + 1] = '<item id="chap' .. i .. '" href="' .. escape_attr(href) .. '" media-type="application/xhtml+xml"/>'
        spine[#spine + 1] = '<itemref idref="chap' .. i .. '"/>'
    end
    return [[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">]] .. escape_xml(uid) .. [[</dc:identifier>
<dc:title>]] .. escape_xml(book_title) .. [[</dc:title>
<dc:language>zh</dc:language>
<dc:creator>txt2epub</dc:creator>
<meta property="dcterms:modified">]] .. escape_xml(modified) .. [[</meta>
</metadata>
<manifest>
]] .. table.concat(manifest, "\n") .. [[
</manifest>
<spine toc="ncx">
]] .. table.concat(spine, "\n") .. [[
</spine>
</package>]]
end

-- META-INF/container.xml
function Converter.build_container()
    return [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles>
<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
</rootfiles>
</container>]]
end

------------------------------------------------------------------------
-- 7. 生成 UID（伪 UUID v4）
------------------------------------------------------------------------
function Converter.gen_uid()
    if not Converter._seeded then
        math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000))
        Converter._seeded = true
    end
    local hex = {}
    for _ = 1, 16 do
        hex[#hex + 1] = string.format("%02x", math.random(0, 255))
    end
    local s = table.concat(hex)
    return string.format("%s-%s-%s-%s-%s",
        s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

------------------------------------------------------------------------
-- 8. 纯 Lua ZIP 写入器（Store 方式，无压缩）
--    - 满足 EPUB 规范：mimetype 必须是第一个条目且使用不压缩（Stored）
--    - 不依赖任何第三方库或系统命令
------------------------------------------------------------------------
local ZipWriter = {}
ZipWriter.__index = ZipWriter

function ZipWriter:new(path)
    local o = setmetatable({}, ZipWriter)
    o.fh = io.open(path, "wb")
    if not o.fh then error("无法创建输出文件：" .. tostring(path)) end
    o.entries = {}
    o.offset = 0
    return o
end

-- 添加一个文件（content 为字符串）。name 使用 EPUB 内部路径，如 "mimetype"、"OEBPS/chapter_0001.xhtml"
function ZipWriter:add(name, content)
    content = content or ""
    local crc = crc32(content)
    local size = #content
    -- mimetype 必须 Stored 且 general purpose bit flag = 0；其余文件标记 UTF-8 文件名
    local flag = (name == "mimetype") and 0 or 0x0800
    local method = 0 -- 0 = Store（不压缩）

    local local_header = table.concat({
        le32(0x04034b50), -- 本地文件头签名
        le16(20),         -- version needed to extract
        le16(flag),
        le16(method),
        le16(0),          -- 最后修改时间
        le16(0),          -- 最后修改日期
        le32(crc),
        le32(size),       -- 压缩后大小
        le32(size),       -- 未压缩大小
        le16(#name),      -- 文件名长度
        le16(0),          -- 扩展字段长度
    })
    self.fh:write(local_header)
    self.fh:write(name)
    self.fh:write(content)

    local local_offset = self.offset
    self.offset = self.offset + #local_header + #name + #content

    self.entries[#self.entries + 1] = {
        name = name,
        crc = crc,
        size = size,
        flag = flag,
        method = method,
        offset = local_offset,
    }
end

function ZipWriter:close()
    local cd_offset = self.offset
    local cd_size = 0
    for _, e in ipairs(self.entries) do
        local rec = table.concat({
            le32(0x02014b50), -- 中央目录头签名
            le16(20),         -- version made by
            le16(20),         -- version needed
            le16(e.flag),
            le16(e.method),
            le16(0),          -- 时间
            le16(0),          -- 日期
            le32(e.crc),
            le32(e.size),
            le32(e.size),
            le16(#e.name),
            le16(0),          -- extra
            le16(0),          -- comment
            le16(0),          -- disk number start
            le16(0),          -- internal attrs
            le32(0),          -- external attrs
            le32(e.offset),
            e.name,
        })
        self.fh:write(rec)
        cd_size = cd_size + #rec
    end
    local eocd = table.concat({
        le32(0x06054b50), -- 结束中央目录记录签名
        le16(0), le16(0),
        le16(#self.entries), le16(#self.entries),
        le32(cd_size),
        le32(cd_offset),
        le16(0),
    })
    self.fh:write(eocd)
    self.fh:close()
end

Converter.ZipWriter = ZipWriter

------------------------------------------------------------------------
-- 9. 便捷：把章节数组打包成完整 EPUB（供测试与 main 复用）
--    chapters: { {title, paras}, ... }
--    返回是否成功、章节数
------------------------------------------------------------------------
-- chapters：顶层节点数组（森林）；每个节点
--   { title=字符串, paras={段落...}, level=整数(>=0), children={子节点...} }
-- 标题模式：每个章节即一个 level=0 节点，children 为空。
-- 缩进模式：依据前导空格形成多级嵌套树。
-- 返回：是否成功、扁平化后的节点总数（即 XHTML 文件数）。
-- hooks（可选）：{ on_yield = function() ... end }
--   on_yield 在“每写完一个章节文件”后被调用。在 KOReader 内我们会让它
--   coroutine.yield()，从而把控制权交还 UI 线程，避免长时间阻塞主线程被
--   设备看门狗 / Android ANR 杀掉进程。不传则同步执行（测试场景）。
function Converter.build_epub(chapters, out_path, opts, hooks)
    opts = opts or {}
    local indent = opts.indent or "2em"
    local book_title = opts.book_title or "未命名"
    local uid = opts.uid or ("urn:uuid:" .. Converter.gen_uid())
    local modified = opts.modified or os.date("!%Y-%m-%dT%H:%M:%SZ")

    -- 前序遍历，把树形章节扁平化为有序列表（用于生成 XHTML 文件与 OPF spine）
    local flat = {}
    local function walk(nodes)
        for _, nd in ipairs(nodes) do
            flat[#flat + 1] = nd
            walk(nd.children)
        end
    end
    walk(chapters)

    local zip = ZipWriter:new(out_path)
    -- 1) mimetype 必须是第一个条目且不压缩
    zip:add("mimetype", "application/epub+zip")

    -- 2) 各章节 XHTML（每个节点一个文件）
    for i, ch in ipairs(flat) do
        local fname = string.format("OEBPS/chapter_%04d.xhtml", i)
        ch.file = fname -- 记录内部路径，供目录引用
        zip:add(fname, Converter.build_chapter_xhtml(ch.title, ch.paras, indent, ch.level))
        -- 让出 UI：每写完一个章节就交还主线程一次（仅在协程内生效），
        -- 保证 KOReader 主线程不被长时间占用，避免进程被看门狗/ANR 杀掉。
        if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
        -- 进度回调（供诊断日志使用，每章一次；调用方自行决定是否落盘）
        if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, #flat) end
    end

    -- 3) 嵌套目录（nav / ncx）
    local nested = Converter.nest_toc(flat)

    -- 4) 其余构件
    zip:add("OEBPS/style.css", Converter.build_style_css({ indent = indent, style = opts.style }))
    zip:add("OEBPS/nav.xhtml", Converter.build_nav(nested, book_title))
    zip:add("OEBPS/toc.ncx", Converter.build_ncx(nested, book_title, uid))
    zip:add("OEBPS/content.opf", Converter.build_opf(flat, book_title, uid, modified))
    zip:add("META-INF/container.xml", Converter.build_container())
    zip:close()
    return true, #flat
end

------------------------------------------------------------------------
-- 9c. 流式构建 EPUB（内存仅占用“一章”量级，专为 Kindle 等低内存设备设计）
--   与 build_epub(chapters, ...) 不同：本函数直接消费行迭代器，逐章生成 XHTML
--   并【立即写入 ZIP、随即释放该章正文】，只保留轻量目录元数据
--   （标题 + 内部路径 + 层级），从而避免把整本书堆进内存导致 OOM / 设备重启。
-- line_iter : Converter.lines(path) 返回的按行迭代器
-- kind      : "title"（按章节标题切分）| "single"（整本合并为一章）| "indent"（按空格缩进切分）
-- arg       : title 模式 -> patterns 表（可空，用默认）；indent 模式 -> step（整数）；single 模式忽略
-- book_title: 书名（用于无标题回退 / OPF）
-- out_path/opts/hooks 同 build_epub
-- 返回：true, count, empty（empty 仅 indent 模式有意义：true 表示未切出任何条目已回退单章）
------------------------------------------------------------------------
function Converter.build_epub_streaming(line_iter, kind, arg, book_title, out_path, opts, hooks)
    opts = opts or {}
    local indent = opts.indent or "2em"
    local uid = opts.uid or ("urn:uuid:" .. Converter.gen_uid())
    local modified = opts.modified or os.date("!%Y-%m-%dT%H:%M:%SZ")

    local zip = ZipWriter:new(out_path)
    zip:add("mimetype", "application/epub+zip")

    local toc = {}          -- 轻量目录元数据：{file=..., title=..., level=...}
    local i = 0
    local empty = false

    -- 单个章节允许的最大 XHTML 体积（字节）；超出则切分为多个文件，
    -- 仅首个分片计入目录，其余为续篇（不入目录但进入正文流）。
    -- 参考 moon.koplugin 的稳定性做法：避免单文件过大导致阅读器渲染卡顿/崩溃。
    local MAX_CHAPTER_BYTES = 256 * 1024

    -- 写出一章：立即写入 ZIP 后释放该章正文（内存只保留一章量级）。
    -- paras 为“每行一段纯文本”的字符串数组（已做段落回流合并）。
    local function emit(title, paras, level)
        level = level or 0
        i = i + 1
        local xhtml = Converter.build_chapter_xhtml(title, paras, indent, level)
        if #xhtml > MAX_CHAPTER_BYTES and #paras > 1 then
            -- 超长章节：按段落切分为多个文件
            local chunk = {}
            local size = 0
            local part = 1
            local function flush_part()
                if #chunk == 0 then return end
                local t = (part == 1) and title or (title .. "（" .. part .. "）")
                local px = Converter.build_chapter_xhtml(t, chunk, indent, level)
                local fname = string.format("OEBPS/chapter_%04d%s.xhtml", i, (part == 1) and "" or ("_" .. part))
                zip:add(fname, px)
                toc[#toc + 1] = { file = fname, title = t, level = level, toc = (part == 1) }
                part = part + 1
                chunk = {}
                size = 0
                if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
                if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
                if i % 5 == 0 then collectgarbage("collect") end
            end
            for _, p in ipairs(paras) do
                if size > 0 and size + #p + 64 > MAX_CHAPTER_BYTES then
                    flush_part()
                end
                chunk[#chunk + 1] = p
                size = size + #p
            end
            flush_part()
        else
            local fname = string.format("OEBPS/chapter_%04d.xhtml", i)
            zip:add(fname, xhtml)
            toc[#toc + 1] = { file = fname, title = title, level = level, toc = true }
            paras = nil            -- 释放正文（已写入磁盘）
            if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
            if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
            -- 周期性全量回收，主动把内存还给系统（墨水屏/低内存设备关键）
            if i % 5 == 0 then collectgarbage("collect") end
        end
    end

    if kind == "single" then
        ----------------------------------------------------------------
        -- 整本合并为一章（按空行分段 + 段落回流合并，内存即单章内容，仅一章）
        ----------------------------------------------------------------
        local current = { title = book_title, paras = {} }
        local buffer = {}
        local function flush_single()
            if #buffer > 0 then
                local ps = reflow_block(buffer)
                for _, p in ipairs(ps) do current.paras[#current.paras + 1] = p end
                buffer = {}
            end
        end
        local line = line_iter()
        while line ~= nil do
            if is_blank(line) then
                flush_single()
            else
                buffer[#buffer + 1] = line
            end
            line = line_iter()
        end
        flush_single()
        emit(current.title, current.paras, 0)
        if #toc == 0 then emit(book_title, {}, 0) end

    elseif kind == "indent" then
        ----------------------------------------------------------------
        -- 缩进模式：每行一个节点，按前导空格层级嵌套（保留原始行为：节点正文为空）
        ----------------------------------------------------------------
        local step = (type(arg) == "number" and arg) or 4
        if step < 1 then step = 1 end
        local found = false
        local line = line_iter()
        while line ~= nil do
            if not is_blank(line) then
                found = true
                local w = leading_width(line, step)
                local level = math.floor(w / step)
                emit(trim(line), {}, level)
            end
            line = line_iter()
        end
        if not found then
            emit(book_title, {}, 0)   -- 空文件/全空行：回退单章
            empty = true
        end

    else
        ----------------------------------------------------------------
        -- 标题模式：复用 build_chapters 的聚合规则，但逐章写出、不堆积
        ----------------------------------------------------------------
        local patterns
        if type(arg) == "table" then
            patterns = arg
        elseif arg and arg ~= "" then
            patterns = { arg }
        else
            patterns = nil
        end

        local current = nil
        local buffer = {}
        local leading = nil
        local seen_title = false

        local function flush_into(t)
            if #buffer > 0 then
                local ps = reflow_block(buffer)
                for _, p in ipairs(ps) do t.paras[#t.paras + 1] = p end
                buffer = {}
            end
        end
        local function close_current()
            if current then
                flush_into(current)
                emit(current.title, current.paras, 0)
                current = nil
            end
        end

        local line = line_iter()
        while line ~= nil do
            if is_title_line(line, patterns) then
                if not seen_title then
                    if leading then flush_into(leading) end
                    current = { title = trim(line), paras = leading and leading.paras or {}, level = Converter.title_level(line) }
                    leading = nil
                    seen_title = true
                else
                    close_current()
                    current = { title = trim(line), paras = {}, level = Converter.title_level(line) }
                end
            else
                if seen_title then
                    if not current then current = { title = book_title, paras = {} } end
                    if is_blank(line) then flush_into(current) else buffer[#buffer + 1] = line end
                else
                    if not leading then leading = { title = book_title, paras = {} } end
                    if is_blank(line) then flush_into(leading) else buffer[#buffer + 1] = line end
                end
            end
            line = line_iter()
        end
        close_current()
        if leading and #leading.paras > 0 then
            emit(leading.title, leading.paras, 0)
        end
        if #toc == 0 then
            emit(book_title, leading and leading.paras or {}, 0)
        end
    end

    -- 目录与清单：仅使用轻量 toc 元数据，不再持有任何章节正文。
    -- 超长章节切分出的“续篇”文件（toc=false）进入正文流但不计入目录。
    local toc_for_nav = {}
    for _, e in ipairs(toc) do
        if e.toc ~= false then toc_for_nav[#toc_for_nav + 1] = e end
    end
    local nested = Converter.nest_toc(toc_for_nav)
    zip:add("OEBPS/style.css", Converter.build_style_css({ indent = indent, style = opts.style }))
    zip:add("OEBPS/nav.xhtml", Converter.build_nav(nested, book_title))
    zip:add("OEBPS/toc.ncx", Converter.build_ncx(nested, book_title, uid))
    zip:add("OEBPS/content.opf", Converter.build_opf(toc, book_title, uid, modified))
    zip:add("META-INF/container.xml", Converter.build_container())
    zip:close()
    collectgarbage("collect")  -- 构建结束整体回收，及时把内存还给系统
    return true, #toc, empty
end

return Converter
