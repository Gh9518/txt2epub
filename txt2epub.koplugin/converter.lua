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
-- 真机（LuaJIT）走 bit.bxor；Lua 5.2+ 走 bit32；都没有时用「半字节查表」
-- 回退（8 次循环、无幂运算）。旧实现逐位循环 32 次且每轮算 2^i，
-- 对 2MB 的 EPUB 内容要跑 2 亿次级运算，在 Kindle ARM 上会把转换拖到
-- 分钟级 —— 这正是大 .docx 转换时进程被系统 Killed 的直接诱因。
local bxor
do
    local ok1, bitlib = pcall(require, "bit")
    if ok1 and type(bitlib) == "table" and type(bitlib.bxor) == "function" then
        bxor = function(a, b) return bitlib.bxor(a, b) % 4294967296 end
    else
        local ok2, bit32 = pcall(require, "bit32")
        if ok2 and type(bit32) == "table" and type(bit32.bxor) == "function" then
            bxor = function(a, b) return bit32.bxor(a, b) % 4294967296 end
        else
            -- 纯 Lua 5.1 回退：预计算 16x16 半字节异或表，之后每次异或只需 8 轮
            local xt = {}
            for i = 0, 15 do
                for j = 0, 15 do
                    local r, a2, b2, mul = 0, i, j, 1
                    for _ = 0, 3 do
                        if a2 % 2 ~= b2 % 2 then r = r + mul end
                        mul = mul * 2
                        a2 = math.floor(a2 / 2)
                        b2 = math.floor(b2 / 2)
                    end
                    xt[i * 16 + j + 1] = r
                end
            end
            bxor = function(a, b)
                local r, mul = 0, 1
                for _ = 1, 8 do
                    r = r + xt[(a % 16) * 16 + (b % 16) + 1] * mul
                    mul = mul * 16
                    a = math.floor(a / 16)
                    b = math.floor(b / 16)
                end
                return r % 4294967296
            end
        end
    end
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
-- 热路径：每字节只做一次查表 + 最多两次异或；bxor 已换成 bit 库/查表实现，
-- 避免旧版在 2MB 内容上产生上亿次逐位运算。
local function crc32(data)
    local c = 0xFFFFFFFF
    local ct = crc_table
    local byte = string.byte
    for i = 1, #data do
        local b = byte(data, i)
        local idx = bxor(c % 256, b) % 256 + 1
        c = bxor(math.floor(c / 256), ct[idx])
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

-- 纯 Lua GB2312 解码兜底（真机无 iconv 时用）：把 inpath 解码写入 outpath。
-- gbk.lua 是紧凑码表（约 16KB 字符串常量），零外部依赖、流式内存有界。
-- 返回 true / false；模块缺失或解码失败均安全返回 false，由调用方决定下一步。
local function decode_gbk_lua(inpath, outpath)
    local ok, gbk = pcall(require, "gbk")
    if not ok or type(gbk) ~= "table" or type(gbk.decode_stream) ~= "function" then
        return false
    end
    local dok, derr = pcall(gbk.decode_stream, inpath, outpath)
    if not dok then return false end
    local r = io.open(outpath, "rb")
    if not r then return false end
    local sz = r:seek("end")
    r:close()
    return not not (sz and sz > 0)
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
    -- iconv 不可用（真机常见）时回退纯 Lua GB2312 解码：复用已写入的 tmpin
    local tmpout2 = os.tmpname()
    if decode_gbk_lua(tmpin, tmpout2) then
        local o = io.open(tmpout2, "rb")
        local data = o and o:read("*a") or nil
        if o then o:close() end
        os.remove(tmpout2)
        os.remove(tmpin)
        os.remove(tmpout)
        if data and #data > 0 then return data end
    end
    pcall(os.remove, tmpout2)
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
    local sz = rfh:seek("end")
    rfh:close()
    -- iconv 不可用 / 解码失败时，shell 重定向仍会创建一个「空」的 out 文件。
    -- 若不判空就把它当作解码结果返回，lines() 会读到空内容 → 生成空书，
    -- 并在源文件目录残留一个空临时文件。这里删除空文件并返回 false，
    -- 让 lines() 回退为「按原始字节流式读」（内存有界、不崩溃、不空书），
    -- 与 README「设备无 iconv 时按原始字节处理」的承诺一致。
    if not sz or sz == 0 then
        pcall(os.remove, out)
        -- ★ 真机（Kindle 等）常无 iconv 命令：此时 iconv 路线产出空文件，
        --   旧逻辑回退“原始 GBK 字节流”→ 标题识别失效 / 正文乱码 / 目录丢失
        --   （edge_gbk.txt 真机反馈）。这里在 GBK 路径（enc==nil）改用纯 Lua
        --   GB2312 解码兜底，零外部依赖、内存有界，保证目录与正文都不丢。
        if enc == nil and decode_gbk_lua(path, out) then
            return out
        end
        return false
    end
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
    local cached = _decoded_cache[path]
    if cached then
        pcall(os.remove, cached)
    end
    -- 无论缓存的是临时路径还是 false（原生 UTF-8），都要清除条目：
    -- 否则连续转换大量不同文件时 false 项永久累积（内存 + 表膨胀）。
    _decoded_cache[path] = nil
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
-- 4a-2. 超长文本拆分（防止「一整章不分段」产出单个数百 KB 的 XHTML）
--   Word 里把一整章写进同一个 <w:p> 很常见；若不拆，build_epub_from_docx
--   的按段切分（要求 #paras > 1）会失效，直接写出 500KB+ 的单章 XHTML，
--   在 Kindle 这类低内存设备上容易触发 indexer 卡死 / 重启（历史故障诱因）。
--   按 UTF-8 字符边界切，绝不把多字节汉字切成半个。
------------------------------------------------------------------------
local function split_utf8_text(s, max)
    if #s <= max then return { s } end
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local j = math.min(i + max - 1, n)
        if j < n then
            -- 下一段起点若在续字节(0x80..0xBF)上，说明 j 切在字符中间，回退
            local b = s:byte(j + 1)
            while j > i and b and b >= 0x80 and b < 0xC0 do
                j = j - 1
                b = s:byte(j + 1)
            end
        end
        out[#out + 1] = s:sub(i, j)
        i = j + 1
    end
    return out
end

-- 把超过 limit 的单个段落拆成 <= piece 字节的子段（其余段落原样保留）。
-- 只有确实存在超长段落时才重建数组，正常情况下零开销。
local function expand_long_paras(paras, limit, piece)
    local out, changed = {}, false
    for _, p in ipairs(paras) do
        if #p > limit then
            for _, seg in ipairs(split_utf8_text(p, piece)) do out[#out + 1] = seg end
            changed = true
        else
            out[#out + 1] = p
        end
    end
    return changed and out or paras
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

-- Unicode 罗马数字（U+2160..U+216B ⅠⅡⅢ…Ⅻ）归一化为 ASCII，
-- 让「Part Ⅱ」「Chapter Ⅳ」这类写法也能被 isNumberToken / title_level 识别。
local ROMAN_UNICODE = {
    ["\226\133\160"] = "I",   ["\226\133\161"] = "II",  ["\226\133\162"] = "III",
    ["\226\133\163"] = "IV",  ["\226\133\164"] = "V",   ["\226\133\165"] = "VI",
    ["\226\133\166"] = "VII", ["\226\133\167"] = "VIII",["\226\133\168"] = "IX",
    ["\226\133\169"] = "X",   ["\226\133\170"] = "XI",  ["\226\133\171"] = "XII",
}

local function title_level(line)
    line = trim(line)
    line = line:gsub("^=+%s*", ""):gsub("%s*=+$", "")
    -- 英文标记优先（用 %w 确保后面确实跟了内容，避免误判）
    -- Part / Volume / Book 为卷级(0)；Chapter 为章级(1)；Section 为节级(2)。
    -- Unicode 罗马数字（Ⅰ Ⅱ …）先转 ASCII 再判定。
    local ascii_line = line
    for u, a in pairs(ROMAN_UNICODE) do ascii_line = ascii_line:gsub(u, a) end
    if ascii_line:match("^[Vv]olume%s+%w") or ascii_line:match("^[Bb]ook%s+%w")
        or ascii_line:match("^[Pp]art%s+%w") then
        return 0
    end
    if ascii_line:match("^[Ss]ection%s+%w") then
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

-- 标题里的 Unicode 空白归一化为 ASCII 空格。
-- Lua 的 %s 只认 ASCII 空白，而中文网文 / Word 标题普遍用 U+3000 全角空格
-- （真机 big_novel.doc 的 363 个标题全是「第1章　章节标题1」这种写法）。
-- 不归一化的话，chapterTitle 里「标记字之后必须是空白/标点」的校验会
-- 把每一条标题都判成正文，DOM 兜底路径最终识别到 0 个标题、目录只剩 1 条。
local function normalize_title_ws(s)
    if not s or s == "" then return s or "" end
    s = s:gsub("\227\128\128", " ")          -- U+3000 全角空格（E3 80 80）
    s = s:gsub("\194\160", " ")              -- U+00A0 不换行空格
    s = s:gsub("\226\128[\128-\138]", " ")   -- U+2000..U+200A 各类排版空格
    s = s:gsub("\226\128\175", " ")          -- U+202F 窄不换行空格
    s = s:gsub("\226\128\139", "")           -- U+200B 零宽空格
    s = s:gsub("\239\187\191", "")           -- UTF-8 BOM
    return s
end

-- 章节标记字之后的分隔符是否合法：ASCII 空白/标点 + 中文全角标点 +
-- CJK 标点区（U+3000..U+303F）、全角标点区（U+FF00..U+FFFF）、
-- 通用标点区（U+2010..U+203F，含中文破折号、引号）。
-- 旧实现只检查 ^%s / ^%p，对「第1章：章节标题」「第1章（上）」也误判为正文。
local function is_title_separator(rest)
    if rest == "" then return true end
    if rest:match("^[%s%p]") then return true end
    local b1, b2, b3 = rest:byte(1, 3)
    if not b1 then return true end
    if b1 == 0xE3 and b2 == 0x80 then return true end                    -- U+3000..U+303F
    if b1 == 0xEF and (b2 == 0xBC or b2 == 0xBD) then return true end    -- U+FF00..U+FFFF
    if b1 == 0xE2 and b2 == 0x80 and b3 and b3 >= 0x90 and b3 <= 0xBF then
        return true                                                       -- U+2010..U+203F
    end
    return false
end

-- 字符串是否为“数字型标记”（阿拉伯数字 / 罗马数字 / 中文数字）
local function isNumberToken(value)
    value = value:gsub("%s+", "")
    for u, a in pairs(ROMAN_UNICODE) do value = value:gsub(u, a) end
    if value == "" then return false end
    if value:match("^%d+$") or value:match("^[IVXLCDMivxlcdm]+$") then return true end
    local rest = value
    for _i, ch in ipairs(CHINESE_NUMBER_CHARS) do
        rest = rest:gsub(ch, "")
    end
    return rest == ""
end

-- 标题落盘到 nav/ncx 与 <h1> 前使用的“显示文本”清理：
--   * 去首尾空白
--   * 剥离 === / —— 等包裹符（如「=== 第4章 风起 ===」→「第4章 风起」），
--     否则目录里会出现多余的「===」（真机 title_punct.txt 反馈）。
--   * v2.1.5：把「第X章/卷/节 + 标点分隔符 + 标题」中的分隔符统一成单个空格，
--     让目录整洁有序（「第1章：开端」→「第1章 开端」，「第六卷 - 狂暴」→「第六卷 狂暴」，
--     「第5章、归途」→「第5章 归途」）。括号及其内容（（）""[]《》【】〈〉〔〕［］「」｛｝『』〖〗）
--     属于标题本身，一律保留，不视为分隔符。
-- 注意：不做 normalize_title_ws —— 保留原文里的 U+3000 全角空格，
--      与「目录文本保留原文」的既有承诺一致。
-- 分隔符：逐项列举（避免在多字节字符类里混入 UTF-8 破坏匹配）。
--   —— 特意不含任何成对括号，避免误伤「第2章（上）」这类标题。
local TITLE_SEPS = {
    "：", ":", "、", "，", ",", "。", "·", "・",
    "－", "-", "–", "—", "~", "～", "/", "＼", "｜", "|", "　",
}
local function is_title_sep_bytewise(rest)
    -- 返回 (剩余内容) 若 rest 以「真实标点」开头（可夹带空白）；否则 nil。
    -- 关键：若分隔符只是空白（ASCII 空格 / U+3000 全角空格），保持原样返回 nil，
    --       以遵守「目录文本保留原文全角空格」的既有承诺（dom_unicode 用例依赖）。
    local consumed = 0
    local has_punct = false
    while true do
        local matched = false
        for _, sep in ipairs(TITLE_SEPS) do
            if sep ~= "　" and rest:sub(consumed + 1, consumed + #sep) == sep then
                consumed = consumed + #sep
                has_punct = true
                matched = true
                break
            end
        end
        if not matched then
            -- 吞掉 ASCII / 全角空白（但单独存在不算标点）
            local c = rest:sub(consumed + 1, consumed + 1)
            if c and c:match("%s") then consumed = consumed + 1; matched = true
            elseif rest:sub(consumed + 1, consumed + 3) == "　" then consumed = consumed + 3; matched = true end
        end
        if not matched then break end
    end
    if consumed == 0 or not has_punct then return nil end
    return rest:sub(consumed + 1)
end

-- 章节量词（多字节中文，不能用 Lua 字符类，须显式列举逐个匹配）
local CN_MARKERS = { "章", "回", "卷", "部", "册", "篇", "集", "幕", "期", "节" }
local CN_DIGITS = { "零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
                    "百", "千", "两", "〇", "壹", "贰", "叁", "肆", "伍", "陆", "柒",
                    "捌", "玖", "拾", "廿", "卅" }

local function tidy_chapter_punct(s)
    -- 中文：行首「第 <数字/中文数字等> <章节量词>」之后若紧跟分隔符，统一成单个空格
    local di = "第"
    if s:sub(1, #di) == di then
        local p = #di + 1
        -- 跳过数字：ASCII 数字逐字节，中文数字按完整串
        while p <= #s do
            local c = s:sub(p, p)
            if c:match("%d") or c == " " then
                p = p + 1
            else
                local adv = nil
                for _, d in ipairs(CN_DIGITS) do
                    if s:sub(p, p + #d - 1) == d then adv = #d; break end
                end
                if adv then p = p + adv else break end
            end
        end
        -- 在 p 处尝试匹配一个量词
        for _, mk in ipairs(CN_MARKERS) do
            if s:sub(p, p + #mk - 1) == mk then
                local rest = s:sub(p + #mk)
                if rest ~= "" then
                    local body = is_title_sep_bytewise(rest)
                    if body and body ~= "" then
                        return s:sub(1, p + #mk - 1) .. " " .. trim(body)
                    end
                end
                break
            end
        end
    end
    -- 英文：Chapter/Part/Volume/Section/Book + 序号 + 分隔符（如 "Chapter 1: The Beginning"）
    local en_patterns = {
        "^([Cc]hapter%s+[%w]+)(.*)$", "^([Ss]ection%s+[%w]+)(.*)$",
        "^([Pp]art%s+[%w]+)(.*)$", "^([Vv]olume%s+[%w]+)(.*)$",
        "^([Bb]ook%s+[%w]+)(.*)$",
    }
    for _, pat in ipairs(en_patterns) do
        local ehead, erest = s:match(pat)
        if ehead and erest and erest ~= "" then
            local body = is_title_sep_bytewise(erest)
            if body and body ~= "" then return ehead .. " " .. trim(body) end
        end
    end
    return s
end

local function clean_title_text(line)
    line = trim(line or "")
    line = line:gsub("^=+%s*", ""):gsub("%s*=+$", "")
    line = trim(line)
    line = tidy_chapter_punct(line)
    return trim(line)
end
function Converter.clean_title_text(line)
    return clean_title_text(line)
end

-- 判断一行是否为章节标题（返回标题字符串或 nil）；参考 moon.koplugin/chapterTitle
local function chapterTitle(line)
    line = trim(normalize_title_ws(line or ""))
    -- 常见 TXT 用 === 包裹标题：仅剥离等号，避免吞掉正文
    line = line:gsub("^=+%s*", ""):gsub("%s*=+$", "")
    -- 英文：Chapter / Section / Part / Volume / Book + 序号；Page + 数字。
    -- 关键修复（big_english.txt 误判）：正文行以「Chapter N paragraph K.」开头，
    -- 旧规则 ^Chapter%s+[%w]+ 会把 4500 段正文当成章节。这里要求序号之后的
    -- 剩余部分必须“像标题”——即行末、空白+标点、或空白+较短标题；若剩余内容是
    -- 一个完整句子（含 . 后跟空格且很长）则以正文论处，直接拒绝。
    local en_key, en_rest = line:match("^([Cc]hapter)%s+[%w]+(.*)$")
    if not en_key then en_key, en_rest = line:match("^([Ss]ection)%s+[%w]+(.*)$") end
    if not en_key then en_key, en_rest = line:match("^([Bb]ook)%s+%w+(.*)$") end
    -- Part / Volume 的序号可能是 Unicode 罗马数字（Ⅱ=多字节，%w 匹配不到），
    -- 故单独按「到首个空白」取 token 再校验。
    if not en_key then
        local pkey, prest = line:match("^([Pp]art)%s+(%S+.*)$")
        if not pkey then pkey, prest = line:match("^([Vv]olume)%s+(%S+.*)$") end
        if pkey and prest then
            local tok = prest:match("^(%S+)")
            if tok and isNumberToken(tok) then en_key, en_rest = pkey, prest end
        end
    end
    if en_key then
        en_rest = en_rest or ""
        -- 正文句子特征：序号后紧跟段落词（paragraph/para/section/chapter 后跟数字），
        -- 或出现「单词. + 空格 + 词」结构（如 "Chapter 5 paragraph 3. The wind..."），
        -- 或整行过长（>80 字节）。这些都判为正文，避免 big_english.txt 4500 段误判。
        local body_word = en_rest:match("^%s+[Pp][Aa][Rr][Aa]")
            or en_rest:match("^%s+[Pp][Aa][Rr][Aa][Gg][Rr][Aa][Pp][Hh]")
            or en_rest:match("^%s+[Ss]ection%s+%d")
            or en_rest:match("^%s+[Cc]hapter%s+%d")
        local sentence_like = (#line > 80)
            or body_word ~= nil
            or en_rest:match("%w+%.%s+%S") ~= nil
            or en_rest:match("^%s*%w+%.%s") ~= nil
        if not sentence_like then return line end
    end
    if line:match("^[Pp]age%s+%d+") then
        return line
    end
    -- 中文：允许「第一章开端」这类无分隔符标题（title_no_separator.txt 反馈）。
    -- 判定：第X章/回/节/集/幕/卷/部/篇 后直接跟内容也算标题，但必须：
    --   ① 整行较短（≤ 40 字节，约 13 汉字）；② 后缀是标题式短语——不含句末标点，
    --   且不以「的/了/和/在/是/有/中/里/上/下」等常见正文虚词开头，
    --   也不含「内容/故事/时候」这类正文高频收尾。避免把「第二回的内容慢慢展开」
    --   「第一部门的故事」误判为标题。
    if line:sub(1, 3) == "第" then
        local no_sep = false
        local FUNC_LEAD = { "的", "了", "和", "在", "是", "有", "中", "里", "上", "下", "地", "得" }
        for _i, marker in ipairs({ "章", "回", "节", "集", "幕", "卷", "部", "篇" }) do
            local number, suffix = line:match("^第%s*(.-)%s*" .. marker .. "(.*)$")
            if number and not no_sep and isNumberToken(number) and suffix and suffix ~= "" then
                if #line <= 40 then
                    local lead = suffix:sub(1, 3)
                    local bad_lead = false
                    for _j, fw in ipairs(FUNC_LEAD) do
                        if lead:sub(1, #fw) == fw then bad_lead = true; break end
                    end
                    -- 首字节非 ASCII（中文）；且不以虚词开头（虚词开头多为正文接续）；
                    -- 「第一部门/部队」是正文（INVALID_VOLUME_SUFFIX），不是「第一部」。
                    local bad_volume = (marker == "部" and INVALID_VOLUME_SUFFIX[suffix:sub(1, 3)] ~= nil)
                    -- suffix 以另一章节标记字开头（如「第3章节选段落」的「节选」）多为正文描述
                    local sfirst = suffix:sub(1, 3)
                    local bad_suffix_lead = (LV_MARKERS[sfirst] ~= nil)
                        or suffix:match("^节选") ~= nil or suffix:match("^摘录") ~= nil
                    if suffix:sub(1, 1):match("[%z\1-\127]") == nil
                        and not bad_lead and not bad_volume and not bad_suffix_lead then
                        no_sep = true
                    end
                end
            end
        end
        if no_sep then return line end
    end
    if line:sub(1, 3) == "第" then
        for _i, marker in ipairs({ "章", "回", "节", "集", "幕", "卷", "部", "篇" }) do
            local number, suffix = line:match("^第%s*(.-)%s*" .. marker .. "(.*)$")
            if number and isNumberToken(number) then
                local rest = suffix or ""
                -- 标记字之后必须是空白 / 标点 / 行末，避免把“第二回的内容”
                -- 这类正文行误判为标题；同时兼容全角空格与中文全角标点。
                -- “第一部门/部队”是正文，不是“第一部”章节。
                if is_title_separator(rest)
                    and (marker ~= "部" or not INVALID_VOLUME_SUFFIX[rest:sub(1, 3)]) then
                    return line
                end
            end
        end
    end
    for title in pairs(SPECIAL_TITLES) do
        if line == title then return line end
        if line:sub(1, #title) == title then
            local rest = line:sub(#title + 1)
            if rest ~= "" and is_title_separator(rest) then return line end
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
            -- 目录/正文标题统一剥离「===」等包裹符（title_punct.txt 反馈）
            local ctitle = clean_title_text(line)
            if not seen_title then
                -- 首个标题：把前置正文并入本章开头
                if leading then flush_into(leading) end
                current = { title = ctitle, paras = leading and leading.paras or {}, level = Converter.title_level(ctitle), children = {} }
                leading = nil
                seen_title = true
            else
                close_current()
                current = { title = ctitle, paras = {}, level = Converter.title_level(ctitle), children = {} }
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

------------------------------------------------------------------------
-- 书名页（封面页）：真机反馈「所有转换文件都没有书名页 / 标题未单独成目录」。
-- 生成一页居中显示书名的 XHTML，并作为目录(nav/ncx)与 spine 的首项。
-- 通过 opts.title_page 开启（main.lua 真机转换时置 true；测试默认关闭，
-- 以维持既有「章节数 == 目录数」断言不变）。
------------------------------------------------------------------------
Converter.TITLE_PAGE_FILE = "OEBPS/title_page.xhtml"

function Converter.build_title_page(book_title)
    book_title = book_title or "未命名"
    local blocks = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE html>',
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh" xml:lang="zh">',
        '<head>',
        '<meta charset="UTF-8"/>',
        '<title>' .. escape_xml(book_title) .. '</title>',
        '<link rel="stylesheet" type="text/css" href="style.css"/>',
        '</head>',
        '<body>',
        '<h1 class="book-title">' .. escape_xml(book_title) .. '</h1>',
        '</body>',
        '</html>',
    }
    return table.concat(blocks, "\n")
end

-- 书名页专用 CSS（居中、大字号、分页），仅当开启书名页时追加。
function Converter.build_title_page_css()
    return [[
/* 书名页 */
.book-title {
  text-align: center;
  font-weight: bold;
  font-size: 1.8em;
  text-indent: 0;
  margin: 3em 0;
  page-break-after: always;
}
]]
end

-- 把书名页节点插入轻量 toc 列表开头（供 nav/ncx/opf 共用），返回新表。
function Converter.prepend_title_page(toc_list, book_title)
    local out = { { file = Converter.TITLE_PAGE_FILE, title = book_title or "未命名",
                    level = -1, toc = true, children = {} } }
    for i, e in ipairs(toc_list or {}) do out[#out + 1] = e end
    return out
end

-- 统一的收尾写入：style.css / nav.xhtml / toc.ncx / content.opf。
-- 当 opts.title_page 为真时，追加书名页 CSS 并把书名页作为目录与 spine 首项。
-- book_title: 书名；nested: 已 nest 的目录树；opf_list: 扁平章节列表；
-- uid/modified: OPF 元数据。
function Converter.write_epub_tail(zip, opts, book_title, nested, opf_list, uid, modified)
    local indent = opts.indent or "2em"
    local tp = opts.title_page == true
    local css = Converter.build_style_css({ indent = indent, style = opts.style })
    if tp then css = css .. Converter.build_title_page_css() end
    zip:add("OEBPS/style.css", css)
    local nav_nodes, opf_toc = nested, opf_list
    if tp then
        nav_nodes = Converter.prepend_title_page(nested, book_title)
        opf_toc = Converter.prepend_title_page(opf_list, book_title)
        zip:add(Converter.TITLE_PAGE_FILE, Converter.build_title_page(book_title))
    end
    zip:add("OEBPS/nav.xhtml", Converter.build_nav(nav_nodes, book_title))
    zip:add("OEBPS/toc.ncx", Converter.build_ncx(nav_nodes, book_title, uid))
    zip:add("OEBPS/content.opf", Converter.build_opf(opf_toc, book_title, uid, modified))
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
    Converter.write_epub_tail(zip, opts, book_title, nested, flat, uid, modified)
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
    -- 每段 XHTML 包装开销上界：<p>\n…\n</p>\n 约 9 字节 + XML 转义预留。
    -- 分片累加必须计入它，否则「原始文本刚好 256KB」的章生成后会被包装
    -- 撑到 264KB+（真机 .docx 曾产出 279927 字节单章）。
    local XHTML_PARA_OVERHEAD = 64

    -- 写出一章：立即写入 ZIP 后释放该章正文（内存只保留一章量级）。
    -- paras 为“每行一段纯文本”的字符串数组（已做段落回流合并）。
    local function emit(title, paras, level)
        level = level or 0
        -- 单段超长保护：一整章写在同一段时，先把 >256KB 的段落按 UTF-8 边界
        -- 拆成 64KB 子段，让下面的按段切分真正生效，避免产出单个 500KB+ 的
        -- XHTML（Kindle indexer / 渲染卡顿、甚至重启的已知诱因）。
        paras = expand_long_paras(paras, MAX_CHAPTER_BYTES, 64 * 1024)
        i = i + 1
        -- v2.1.7：先按「每段字节 + 包装开销」估算整章体积，超限直接走分片，
        -- 不再先用 build_chapter_xhtml 拼出整章大串（那会造成与 docx 旧路径
        -- 同类的瞬时内存尖峰，叠加高基线堆可触发 OOM）。与 paragraphs 路径一致。
        local approx = 0
        for k = 1, #paras do approx = approx + #paras[k] + XHTML_PARA_OVERHEAD end
        if approx > MAX_CHAPTER_BYTES and #paras > 1 then
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
                -- 所有分片都进目录：与其他格式(paragraphs/DOM)保持一致，
                -- 便于真机逐片核对内容完整（真机反馈「TXT 超长章不分割 / 目录缺片」）。
                toc[#toc + 1] = { file = fname, title = t, level = level, toc = true }
                part = part + 1
                chunk = {}
                size = 0
                if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
                if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
                if i % 5 == 0 then collectgarbage("collect") end
            end
            for _, p in ipairs(paras) do
                local cost = #p + XHTML_PARA_OVERHEAD
                if size > 0 and size + cost > MAX_CHAPTER_BYTES then
                    flush_part()
                end
                chunk[#chunk + 1] = p
                size = size + cost
            end
            flush_part()
        else
            local xhtml = Converter.build_chapter_xhtml(title, paras, indent, level)
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
        -- 真机 edge_no_title.txt：整本是一行 744KB 纯正文，无缩进、无标题。
        -- 旧实现把这一整行当作「目录节点标题」、正文传空表 {}，于是产出一个
        -- 744KB 的超长目录名且正文全丢（用户反馈「相当于转换失败」）。
        -- 修复：超过阈值的行视为正文而非目录项——把行文本按 UTF-8 边界拆成
        -- 64KB 段作为 paras 交给 emit，由 emit 的 256KB 分片逻辑切成多片、
        -- 每片进目录。短行（正常缩进目录项）仍保持原「每行一节点、正文为空」语义。
        local LONG_LINE_BYTES = 512
        local line = line_iter()
        while line ~= nil do
            if not is_blank(line) then
                found = true
                local trimmed = trim(line)
                local w = leading_width(line, step)
                local level = math.floor(w / step)
                if #trimmed > LONG_LINE_BYTES then
                    -- 超长行 = 正文：拆成段回流后由 emit 分片入目录，标题用书名+序号
                    local body_paras = split_utf8_text(trimmed, 64 * 1024)
                    emit(book_title, body_paras, 0)
                else
                    emit(trimmed, {}, level)
                end
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
                -- 修复：沿用创建章节时算好的层级，而非硬编码 0。
                -- 旧实现把所有章节 level 压成 0，导致 TXT 多级目录（卷/章/节）
                -- 在 nav/ncx 中全部平铺、"不折叠"。
                emit(current.title, current.paras, current.level or 0)
                current = nil
            end
        end

        local line = line_iter()
        while line ~= nil do
            if is_title_line(line, patterns) then
                local ctitle = clean_title_text(line)  -- 剥离「===」等包裹符
                if not seen_title then
                    if leading then flush_into(leading) end
                    current = { title = ctitle, paras = leading and leading.paras or {}, level = Converter.title_level(ctitle) }
                    leading = nil
                    seen_title = true
                else
                    close_current()
                    current = { title = ctitle, paras = {}, level = Converter.title_level(ctitle) }
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
        -- 收尾 flush：全文无标题时正文都在 leading 里，而 flush_into(leading)
        -- 只在「遇到空行」时触发；若文件末尾没有空行（例如整本是一行 744KB
        -- 的纯正文），buffer 中的残留行会在这里被静默丢弃，最终只产出空章。
        -- 有标题时 close_current() 会自行 flush_into(current)，无需重复处理。
        if not current and leading then
            flush_into(leading)
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
    Converter.write_epub_tail(zip, opts, book_title, nested, toc, uid, modified)
    zip:add("META-INF/container.xml", Converter.build_container())
    zip:close()
    collectgarbage("collect")  -- 构建结束整体回收，及时把内存还给系统
    return true, #toc, empty
end

------------------------------------------------------------------------
-- 9d. 从 Word(.docx) 转换：解析 OOXML -> 按 Word 标题层级生成多级 EPUB
--   与 build_epub_streaming 同样“逐章写出、随即释放”，内存只保留一章量级。
--   path     : .docx 文件完整路径
--   out_path : 输出 .epub 路径
--   opts     : { indent, style, book_title, uid, modified }
--   hooks    : { on_yield, on_progress }（同 build_epub_streaming）
--   返回：true, count（EPUB 章节文件数）
------------------------------------------------------------------------
-- 9d-0. 从正文文本恢复章节标题（.docx 专用兜底，纯函数、无 IO）
--   背景（真机日志 2026-11-15 17:17:12，big_novel_STORED.docx）：
--     「EPUB 生成成功（Word），共 9 章」但目录严重不全。
--   根因：设备上那份 .docx 的 Word 标题样式（w:pStyle / w:outlineLvl）在
--   KOReader 打开/另存后丢失或未被识别，DocxReader 得到 heading=0；于是
--   6960 个正文段全被并入「首个标题之前的正文」，聚成一个 2.2MB 超大章：
--     (a) 旧 emit 先拼出 2.2MB 整串，叠加 KOReader 已打开的 docx DOM ->
--         内核 OOM killer（16:52 那次 crash.log 只有 Killed、无 Lua 堆栈）；
--     (b) 再按 256KB 硬切成 9 片、且只有首片进目录 -> nav/ncx 仅 1 条。
--   .doc 走 DOM 路径早有「从正文文本重切标题」兜底（真机识别 364 标题、
--   生成 370 章，正常），故问题只在 docx 自解析路径。
--
--   策略：仅当「Word 样式标题缺失或严重不足」时启用，把正文中「短段落 +
--   命中 chapterTitle 规则」的段落提升为 heading（层级用 title_level，与
--   .txt / DOM 路径完全一致）。短段阈值 80 字节：真机正文段 373 字节、
--   标题段约 20 字节，可精准区分，不会把正文误判成标题。
--   返回 stats 供上层写诊断日志，便于真机直接判断是否生效。
------------------------------------------------------------------------
local RECOVER_TITLE_MAX_BYTES = 80

function Converter.recover_docx_headings(paragraphs, opts)
    opts = opts or {}
    local stats = {
        word_headings = 0, text_titles = 0, promoted = 0,
        enabled = false, mode = "word-style", body_paras = 0,
    }
    if type(paragraphs) ~= "table" or #paragraphs == 0 then
        return paragraphs, stats
    end
    local n = #paragraphs
    -- 1) 统计 Word 样式标题
    for k = 1, n do
        local p = paragraphs[k]
        if p and p.kind == "heading" then
            stats.word_headings = stats.word_headings + 1
        end
    end
    -- 2) 找正文里的「短段落标题候选」（只记录下标，先不改）
    local cand = {}
    for k = 1, n do
        local p = paragraphs[k]
        if p and p.kind ~= "heading" and p.text and p.text ~= "" then
            stats.body_paras = stats.body_paras + 1
            local t = trim(p.text)
            if #t > 0 and #t <= RECOVER_TITLE_MAX_BYTES
                and Converter.is_chapter_title(t) then
                cand[#cand + 1] = { idx = k, level = Converter.title_level(t) }
            end
        end
    end
    stats.text_titles = #cand
    -- 3) 触发条件：样式标题为 0，或文本候选远多于样式标题（样式严重缺失）
    local need = (stats.word_headings == 0 and #cand >= 3)
        or (#cand >= 3 and #cand > stats.word_headings * 2)
    if opts.no_title_recovery or not need then
        return paragraphs, stats
    end
    -- 4) 提升：把候选正文段就地改成 heading（保留原文本作为章标题）
    for _, c in ipairs(cand) do
        local p = paragraphs[c.idx]
        if p then
            p.kind = "heading"
            p.level = c.level
            stats.promoted = stats.promoted + 1
        end
    end
    stats.enabled = true
    stats.mode = (stats.word_headings == 0) and "text-only" or "text-merged"
    return paragraphs, stats
end

------------------------------------------------------------------------
-- 「段落序列 -> EPUB」统一流水线。
--   .docx / .html / .htm / .md 先各自解析成同样的段落序列：
--     { {kind="heading", level=N, text=T} | {kind="body", text=T}, ... }
--   本函数负责聚合成章节、逐章写出、生成 nav/ncx/opf。
--   逐段消费并即时置空，避免 7000+ 个 table 与全文字符串同时驻留 Lua 堆，
--   在 Kindle 低内存设备上被 OOM killer 杀掉。
function Converter.build_epub_from_paragraphs(paragraphs, book_title, out_path, opts, hooks)
    opts = opts or {}
    local indent = opts.indent or "2em"
    local uid = opts.uid or ("urn:uuid:" .. Converter.gen_uid())
    local modified = opts.modified or os.date("!%Y-%m-%dT%H:%M:%SZ")

    paragraphs = paragraphs or {}
    book_title = book_title or opts.book_title or "未命名"

    local zip = ZipWriter:new(out_path)
    zip:add("mimetype", "application/epub+zip")

    local toc = {}
    local i = 0
    local split_parts = 0
    local MAX_CHAPTER_BYTES = 256 * 1024
    -- 每段 XHTML 包装开销上界：估算必须计入，否则 180 段的章按原始文本
    -- 切到 256KB、生成后被 <p></p> 撑到 264KB+（真机 docx 279927 字节）。
    local XHTML_PARA_OVERHEAD = 64

    -- 低内存安全的分片写出：先按「累计字节」估算整章体积，超限时直接按段
    -- 切成 <=256KB 的 chunk、逐片生成 XHTML 写盘，绝不先 table.concat 出整章
    -- 大字符串。真机 docx 样式丢失时曾把 2.2MB 正文一次性拼成单个 XHTML，
    -- 叠加 KOReader 已打开的 docx DOM 直接触发内核 OOM killer（crash.log 只有
    -- Killed、无 Lua 堆栈）。每个分片都进目录，避免「共 9 章但 nav 仅 1 条」。
    local function emit(title, paras, level)
        level = level or 0
        -- 单段超长保护：一整章写在同一段时，先把 >256KB 的段落按 UTF-8 边界
        -- 拆成 64KB 子段，让下面的按段切分真正生效。
        paras = expand_long_paras(paras, MAX_CHAPTER_BYTES, 64 * 1024)
        i = i + 1
        local approx = 0
        for k = 1, #paras do approx = approx + #paras[k] + XHTML_PARA_OVERHEAD end
        if approx > MAX_CHAPTER_BYTES and #paras > 1 then
            local chunk, size, part = {}, 0, 1
            local function flush_part()
                if #chunk == 0 then return end
                local t = (part == 1) and title or (title .. "（" .. part .. "）")
                local px = Converter.build_chapter_xhtml(t, chunk, indent, level)
                local fname = string.format("OEBPS/chapter_%04d%s.xhtml", i, (part == 1) and "" or ("_" .. part))
                zip:add(fname, px)
                toc[#toc + 1] = { file = fname, title = t, level = level, toc = true }
                split_parts = split_parts + 1
                part = part + 1
                chunk, size = {}, 0
                if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
                if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
                if i % 5 == 0 then collectgarbage("collect") end
            end
            for k = 1, #paras do
                local p = paras[k]
                local cost = #p + XHTML_PARA_OVERHEAD
                if size > 0 and size + cost > MAX_CHAPTER_BYTES then
                    flush_part()
                end
                chunk[#chunk + 1] = p
                size = size + cost
            end
            flush_part()
        else
            local xhtml = Converter.build_chapter_xhtml(title, paras, indent, level)
            local fname = string.format("OEBPS/chapter_%04d.xhtml", i)
            zip:add(fname, xhtml)
            toc[#toc + 1] = { file = fname, title = title, level = level, toc = true }
            paras = nil
            if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
            if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
            if i % 5 == 0 then collectgarbage("collect") end
        end
    end

    --------------------------------------------------------------------
    -- 把 docx 段落序列聚合成章节：标题段开启新章（带 Word 层级），
    -- 其后的正文段成为该章段落；首标题之前的 body 并入首章开头。
    --------------------------------------------------------------------
    local current = nil
    local leading = {}          -- 首个标题之前的正文
    local seen_heading = false
    local norm = function(s) return (s or ""):gsub("%s+", "") end

    local function start_chapter(title, level)
        if #leading > 0 then
            current = { title = title, paras = leading, level = level }
            leading = {}
        else
            current = { title = title, paras = {}, level = level }
        end
        seen_heading = true
    end

    -- 数值 for + 逐段置空：处理完的段落立刻可被 GC 回收（ipairs 无法这样用）
    local n_paras = #paragraphs
    for idx = 1, n_paras do
        local p = paragraphs[idx] or { kind = "body", text = "" }
        paragraphs[idx] = nil
        if p.kind == "heading" then
            local title = (p.text and p.text ~= "") and p.text or ("（未命名标题 " .. (p.level or 1) .. "）")
            -- 首个标题若与书名相同（如 Word 的 Title 样式段落），视为书名，不单独成章
            if not seen_heading and norm(title) == norm(book_title) then
                seen_heading = true
                current = nil
            else
                if current then
                    emit(current.title, current.paras, current.level)
                    current = nil
                end
                start_chapter(title, p.level or 1)
            end
        else
            if p.text and p.text ~= "" then
                if seen_heading then
                    if not current then
                        current = { title = book_title, paras = {}, level = 1 }
                    end
                    current.paras[#current.paras + 1] = p.text
                else
                    leading[#leading + 1] = p.text
                end
            end
        end
        if idx % 200 == 0 then collectgarbage("step") end
    end
    paragraphs = nil
    if current then
        emit(current.title, current.paras, current.level)
    end
    if #toc == 0 then
        -- 文档无任何标题（理论上不会发生，保险回退）
        emit(book_title, leading, 0)
    end

    local toc_for_nav = {}
    for _, e in ipairs(toc) do
        if e.toc ~= false then toc_for_nav[#toc_for_nav + 1] = e end
    end
    local nested = Converter.nest_toc(toc_for_nav)
    Converter.write_epub_tail(zip, opts, book_title, nested, toc, uid, modified)
    zip:add("META-INF/container.xml", Converter.build_container())
    zip:close()
    collectgarbage("collect")
    return true, #toc, { chapter_count = #toc, split_parts = split_parts }
end

------------------------------------------------------------------------
-- 9d-1a. Word(.docx) 入口：读 OOXML -> 段落序列 -> 统一流水线
------------------------------------------------------------------------
function Converter.build_epub_from_docx(path, out_path, opts, hooks)
    opts = opts or {}
    hooks = hooks or {}
    local ok, DocxReader = pcall(require, "docx")
    if not ok or not DocxReader then
        error("无法加载 docx 解析模块（docx.lua 缺失）")
    end
    local doc, derr = DocxReader.read(path)
    if not doc then
        error("读取 Word 文档失败：" .. tostring(derr))
    end
    local book_title = doc.title or opts.book_title or "未命名"
    local paragraphs = doc.paragraphs or {}
    doc.paragraphs = nil
    doc = nil
    collectgarbage("step")

    -- 兜底：Word 样式标题缺失时从正文文本恢复（详见 9d-0 注释）。
    -- 统计通过 hooks.on_diag 回传，由 main.lua 写入 .txt2epub.log。
    local rst
    paragraphs, rst = Converter.recover_docx_headings(paragraphs, opts)
    if type(hooks.on_diag) == "function" then
        pcall(hooks.on_diag, rst)
    end

    local bok, cnt, stats = Converter.build_epub_from_paragraphs(
        paragraphs, book_title, out_path, opts, hooks)
    stats = stats or {}
    stats.recovery = rst
    return bok, cnt, stats
end

------------------------------------------------------------------------
-- 9d-1a-2. RTF 入口（v2.1.6）：插件直接解析源文件，不依赖 KOReader DOM。
--   KOReader 对负数 \u 转义的 RTF 会在该处乱码/截断，导致目录与正文缺失；
--   rtf.lua 自行解码 \u（含负数）、\par、\b，拿到完整标题与正文。
--   返回第三个值 stats（含 garbled/headings/body_paras）供日志与提示。
------------------------------------------------------------------------
function Converter.build_epub_from_rtf(path, out_path, opts, hooks)
    opts = opts or {}
    hooks = hooks or {}
    local ok, RtfReader = pcall(require, "rtf")
    if not ok or not RtfReader then
        error("无法加载 RTF 解析模块（rtf.lua 缺失）")
    end
    local doc, derr = RtfReader.read(path)
    if not doc then
        error("读取 RTF 文档失败：" .. tostring(derr))
    end
    local book_title = doc.title or opts.book_title or "未命名"
    local paragraphs = doc.paragraphs or {}
    local garbled = doc.garbled or 0
    doc.paragraphs = nil
    doc = nil
    collectgarbage("step")

    -- 标题兜底：若 rtf.lua 未识别到任何标题（非粗体标题写法），从正文文本恢复
    local has_heading = false
    for _, p in ipairs(paragraphs) do
        if p and p.kind == "heading" then has_heading = true break end
    end
    local rst
    if not has_heading then
        paragraphs, rst = Converter.recover_docx_headings(paragraphs, opts)
    end

    local headings, body_paras = 0, 0
    for _, p in ipairs(paragraphs) do
        if p and p.kind == "heading" then headings = headings + 1
        elseif p and p.kind == "body" then body_paras = body_paras + 1 end
    end

    local bok, cnt, stats = Converter.build_epub_from_paragraphs(
        paragraphs, book_title, out_path, opts, hooks)
    stats = stats or {}
    stats.garbled = garbled
    stats.headings = headings
    stats.body_paras = body_paras
    stats.recovery = rst
    return bok, cnt, stats
end

------------------------------------------------------------------------
-- 9d-1b. Markdown / HTML 入口：插件自解析，不依赖 KOReader DOM
------------------------------------------------------------------------
function Converter.build_epub_from_markup(path, out_path, opts, hooks)
    local ok, M = pcall(require, "markup")
    if not ok or not M then
        error("无法加载标记文档解析模块（markup.lua 缺失）")
    end
    local f = io.open(path, "rb")
    if not f then error("无法打开文件：" .. tostring(path)) end
    local raw = f:read("*a") or ""
    f:close()
    local text = raw
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    if not is_valid_utf8(text) then
        -- GBK / GB18030 的 .md/.html 也常见；落到临时文件解码，内存有界
        local dec = decode_via_iconv(raw)
        if dec then text = dec end
    end
    local ext = (path:match("%.([^%.]+)$") or ""):lower()
    local kind = (ext == "md" or ext == "markdown") and "md" or "html"
    local parsed = M.parse(text, kind) or {}
    local book_title = parsed.title or (opts and opts.book_title) or "未命名"
    local paragraphs = parsed.paragraphs or {}
    text, raw, parsed = nil, nil, nil
    collectgarbage("step")
    -- 内联标签 HTML（如 <div><span>第一章…</span><br/><span>正文…</span></div>）
    -- 没有 <hN>，markup 解析后全是 body 段 → 无目录（edge_html_inline 真机反馈）。
    -- 当解析结果完全没有 heading 时，复用 docx 的正文标题恢复：把「短段 +
    -- 命中章节标题规则」的段落提升为 heading，与 .txt/.docx 标题识别一致。
    local has_heading = false
    for _, p in ipairs(paragraphs) do
        if p and p.kind == "heading" then has_heading = true break end
    end
    if not has_heading then
        local rst
        paragraphs, rst = Converter.recover_docx_headings(paragraphs, opts)
        if hooks and type(hooks.on_diag) == "function" then
            pcall(hooks.on_diag, rst)
        end
    end
    return Converter.build_epub_from_paragraphs(paragraphs, book_title, out_path, opts, hooks)
end

------------------------------------------------------------------------
-- 9e. 从“已打开文档”转换：直接利用 KOReader 解析后的 DOM
--   不再区分 .doc / .docx / .rtf / .fb2 / .epub / .html —— 只要 KOReader
--   能打开（经 CreDocument 渲染），我们就用其内存中的 TOC + 渲染 HTML
--   直接生成 EPUB。这就是“直接转换 KOReader 已转换过的内容”，无需
--   关心源文件到底是 doc 还是 docx（也顺带支持 epub / html / fb2 等）。
-- doc_api : 抽象文档接口（由 main.lua 从真实 KOReader 文档对象适配而来）：
--   { title = string|nil,
--     author = string|nil,
--     toc    = { {text=..., depth=..., pos0=..., pos1=...}, ... }（可空），
--     get_html(pos0, pos1) -> string|nil,   -- 取 [pos0, pos1) 区间的渲染 HTML
--     page_count = number,
--     get_page_xp(p) -> string|nil }         -- 无 TOC 时的按页回退
--   get_html 由 CreDocument:getHTMLFromXPointers / getHTMLFromXPointer 适配而来；
--   非 CreDocument 格式（如 PDF/MuPDF）没有该方法，此时本函数会安全回退。
-- out_path/opts/hooks 同 build_epub
-- 返回：true, count（EPUB 章节文件数）
------------------------------------------------------------------------

-- 判定 DOM 提取结果是否为「疑似空书」：正文可见字符过少即认为没提取到正文。
-- 抽成纯函数便于 main 与测试共用同一阈值（默认 20 个可见字符）。
function Converter.is_empty_document_result(stats, threshold)
    if type(stats) ~= "table" then return false end
    local v = stats.visible_chars or 0
    return v < (threshold or 20)
end

-- 去掉 cre 个别版本可能吐出的文档级包裹与非正文内容，只保留正文片段。
-- 按页聚合时「每一页」都可能自带一份完整包裹，若只去首尾，重切分后的章节里
-- 会残留嵌套的 <body>/<head>，导致 EPUB 解析异常，故这里做全局剥离。
-- <style>/<script> 文本必须一并删掉：否则它和「本页第一个标题」落在同一个
-- 文本块里，标题判定会被 "p{color:#000} 第一卷 …" 这类前缀污染而漏识别。
local function sanitize_document_html(html)
    if not html or html == "" then return "" end
    html = html:gsub("<%?xml.-%?>", "")
    html = html:gsub("<!DOCTYPE[^>]*>", "")
    html = html:gsub("<head.->.-</head>", "")
    html = html:gsub("<style.->.-</style>", "")
    html = html:gsub("<script.->.-</script>", "")
    html = html:gsub("</?html[^>]*>", "")
    html = html:gsub("</?body[^>]*>", "")
    -- KOReader 对 .rtf/.fb2 常产生双重转义（&amp;lt; / &amp;gt; / &amp;amp;），
    -- 读者会看到「&lt;」字面量。这里把它们降为单重 XML 实体（&lt; 在 XHTML 中
    -- 会正确显示为 <），不动已是单重的实体，避免破坏标签结构。
    html = html:gsub("&amp;lt;", "&lt;"):gsub("&amp;gt;", "&gt;")
    html = html:gsub("&amp;quot;", "&quot;"):gsub("&amp;apos;", "&apos;")
    html = html:gsub("&amp;amp;", "&amp;")
    return (html:gsub("^%s+", ""))
end

-- 章节 XHTML（原始 HTML 直出，不转义正文；标题仍做 XML 转义）
function Converter.build_chapter_xhtml_raw(title, raw_html, level)
    level = level or 0
    local lv_class = level > 0 and (" lv-" .. level) or ""
    local body = sanitize_document_html(raw_html or "")
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
    blocks[#blocks + 1] = body
    blocks[#blocks + 1] = '</body>'
    blocks[#blocks + 1] = '</html>'
    return table.concat(blocks, "\n")
end

-- 把过长的 raw_html 在 </p> 边界处切分为若干 <= max 字节的片段
local function split_html_at_p(html, max)
    local frags = {}
    local buf = {}
    local len = 0
    local pos = 1
    local n = #html
    while pos <= n do
        local p = string.find(html, "</p>", pos)
        local seg
        if p then
            seg = string.sub(html, pos, p + 3)  -- 含 </p>
            pos = p + 4
        else
            seg = string.sub(html, pos)
            pos = n + 1
        end
        if len + #seg > max and #buf > 0 then
            frags[#frags + 1] = table.concat(buf)
            buf = {}
            len = 0
        end
        buf[#buf + 1] = seg
        len = len + #seg
    end
    if #buf > 0 then frags[#frags + 1] = table.concat(buf) end
    if #frags == 0 then frags[1] = html end
    -- 二次保险：整章若没有任何 </p> 边界（如只有一个超长 <p>，或 cre 用
    -- <div> 分段），frags 仍是单个超大片段，切分等于没生效。再按 max 硬切
    -- 一次（UTF-8 边界），保证写出的 XHTML 不会是数百 KB 的单文件。
    -- DOM 兜底路径本就是「尽力而为」，宁可片段边界落在标签中间，也不能 OOM。
    local final = {}
    for _, frag in ipairs(frags) do
        if #frag > max then
            for _, sub in ipairs(split_utf8_text(frag, max)) do final[#final + 1] = sub end
        else
            final[#final + 1] = frag
        end
    end
    if #final == 0 then final[1] = html end
    return final
end

------------------------------------------------------------------------
-- 9d-2. DOM 兜底格式的「正文标题识别 + 重切分」
--   背景（真机日志 2026-11-15 11:22:32，big_novel.doc）：
--     「DOM 提取体检：可见正文 2204261 字符，TOC 条目 0，章节 15」
--   .doc / .rtf / .fb2 经 KOReader CreDocument 渲染后，Word 的「标题 1」
--   样式往往只是普通 <p>，DOM 里没有 <h1>~<h6>，getToc() 返回 0 条。
--   于是全书被按页聚合成 1 个大章、再按 256KB 硬切成十几个「（2）（3）」
--   续篇：nav/ncx 只剩 1 条无意义目录，正文里的「第一卷 / 第X章 /
--   第X节」也全是普通 <p>，既无目录、也无标题排版。
--   修复：把提取到的 raw_html 拆成块，用与 .txt 路径完全相同的
--   chapterTitle / title_level 规则识别章节标题，据此重切章节，生成
--   真正的多级嵌套目录 + <h1 class="chapter-title lv-N"> 居中标题。
------------------------------------------------------------------------

-- HTML 片段 -> 纯文本（去标签 + 实体解码 + 折叠空白），仅用于「标题判定」。
-- 不用 utf8.char：真机 LuaJIT 无该库，且超范围码点在 Lua 5.3 上会抛错。
local function html_block_text(frag)
    -- 保留原文（含 U+3000 全角空格）：归一化只在 chapterTitle 内部用于「判定」，
    -- 若在这里先归一化，写进目录/标题的就会是改造过的文本，与原文不一致。
    local t = frag
    t = t:gsub("<[^>]*>", "")
    -- 反复解码实体：KOReader 对 .rtf/.fb2 常产生双重/三重转义（&amp;lt; -> &lt; -> <），
    -- 只解一次会让读者看到「&lt;」字面量（真机 dom_sample.rtf 图2 反馈）。
    -- 最多 3 轮，并在本轮无任何变化时提前退出，避免对普通文本做无谓扫描。
    for _ = 1, 3 do
        local before = t
        t = t:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
             :gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
        if t == before then break end
    end
    local function cp(u)
        if not u or u ~= u or u < 0 or u > 0x10FFFF
            or (u >= 0xD800 and u <= 0xDFFF) then
            return "\239\191\189" -- U+FFFD
        end
        return codepoint_to_utf8(u)
    end
    t = t:gsub("&#x([%x]+);", function(h) return cp(tonumber(h, 16)) end)
    t = t:gsub("&#(%d+);", function(d) return cp(tonumber(d, 10)) end)
    t = t:gsub("%s+", " ")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 可切分的块级闭合标签；命中即认为一个「段落块」结束
local BLOCK_END_TAGS = {
    p = true, div = true, li = true, tr = true, td = true, blockquote = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
}
local HEADING_LEVEL = { h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6 }

-- 把渲染 HTML 拆成 { html=原片段, text=纯文本, heading=<hN> 层级|nil }。
-- 单次线性扫描所有标签，避免对 2MB+ 正文做 O(n²) 查找。
local function html_to_blocks(html)
    local blocks = {}
    if not html or html == "" then return blocks end
    -- 先剥离文档级包裹 / <style> / <script>，保证「首个标题块」的文本干净
    html = sanitize_document_html(html)
    if html == "" then return blocks end
    local cuts = {}
    local pending_heading = nil
    -- 结尾的 () 捕获的是「标签结束后下一个位置」，故片段右端取 e-1。
    for s, e in html:gmatch("()<[^>]+>()") do
        local tag = html:sub(s, e - 1)
        local close_name = tag:match("^</%s*([%a%d]+)")
        local open_name = tag:match("^<%s*([%a%d]+)")
        if close_name then
            local ln = close_name:lower()
            if BLOCK_END_TAGS[ln] then
                cuts[#cuts + 1] = { e = e - 1, heading = HEADING_LEVEL[ln] or pending_heading }
                pending_heading = nil
            end
        elseif open_name then
            local ln = open_name:lower()
            if HEADING_LEVEL[ln] then pending_heading = HEADING_LEVEL[ln] end
            -- cre 部分版本用 <br> / <br/> 分段（而非 </p>），必须也作为切点，
            -- 否则整章会落成单个巨型文本块，标题判定因「长度 > 80」全部失效。
            if ln == "br" then
                cuts[#cuts + 1] = { e = e - 1, heading = nil }
            end
        end
    end
    -- cre 偶尔返回纯文本 + 换行（无块标签）：按行兜底切分
    if #cuts == 0 then
        for s, e in html:gmatch("()[^\r\n]+()") do
            cuts[#cuts + 1] = { e = e - 1, heading = nil }
        end
    end
    local last = 1
    local function push(frag, heading)
        if frag and frag ~= "" then
            blocks[#blocks + 1] = { html = frag, text = html_block_text(frag), heading = heading }
        end
    end
    for _, c in ipairs(cuts) do
        if c.e >= last then
            push(html:sub(last, c.e), c.heading)
            last = c.e + 1
        end
    end
    if last <= #html then push(html:sub(last), nil) end
    return blocks
end

-- 清洗 KOReader 渲染 .rtf/.fb2 时产生的乱码字符，用于「标题判定」与显示文本。
-- 典型：U+FFFD 替换符、U+FFD0..U+FFF9 乱码区、U+0080..U+009F 的 C1 控制字符
-- （真机 dom_sample.rtf 第二章标题后出现阿拉伯乱码 / ￔ，正文混入此类字符）。
-- 只替换不可读的孤立乱码为空格，不动正常中文/英文/标点，避免整章因个别乱码丢失。
local function sanitize_garbled_text(s)
    if not s or s == "" then return s end
    -- U+FFFD (EF BF BD) 与 U+FFD0..U+FFFF 区（EF BF 90..EF BF BF 等）→ 空格
    s = s:gsub("\239\191[\189\190\191]", " ")
    s = s:gsub("\239\191[%128-\255]", " ")
    -- C1 控制字符 U+0080..U+009F (C2 80..C2 9F) → 空格
    s = s:gsub("\194[%128-\159]", " ")
    -- 阿拉伯字母区 U+0600..U+06FF（UTF-8 两字节 D8 80..DB BF）：RTF 负 \u 码点
    -- 被 KOReader 误渲染成阿拉伯字符（图2「第二章 ف」）→ 空格
    s = s:gsub("\216[%128-\191]", " ")
    s = s:gsub("\217[%128-\191]", " ")
    s = s:gsub("\218[%128-\191]", " ")
    s = s:gsub("\219[%128-\191]", " ")
    -- 孤立的 0xEF/0xBF 残缺字节序列（畸形 UTF-8）→ 空格
    s = s:gsub("\239\191", " ")
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end
Converter.sanitize_garbled_text = sanitize_garbled_text

-- 识别到 >= 2 个标题才重切：避免正文里偶然出现一行「第X章」就破坏原结构。
-- 首个标题之前的正文并入第一章开头（与 .txt 路径 build_chapters 一致）。
-- 返回 (chapters|nil, 识别到的标题数)
local function resplit_chapters_by_heading(chapters, book_title)
    local blocks = {}
    for _, ch in ipairs(chapters) do
        if ch.raw_html and ch.raw_html ~= "" then
            for _, b in ipairs(html_to_blocks(ch.raw_html)) do blocks[#blocks + 1] = b end
        end
    end
    if #blocks == 0 then return nil, 0 end

    -- 标题判定：文本正则优先（含中文数字、卷/章/节多级），其次 DOM 自带 <hN>。
    -- 限制长度，避免把一整段正文误判为标题。
    local function heading_of(b)
        local t = b.text
        if t == "" or #t > 80 then return nil, nil end
        -- 判定与显示都用「去乱码」文本：真机 RTF 标题后跟阿拉伯乱码时仍能识别，
        -- 且目录里不会残留 U+FFFD / 控制字符（图2 反馈）。
        local clean = sanitize_garbled_text(t)
        if Converter.is_chapter_title(clean) then return clean, Converter.title_level(clean) end
        if b.heading then return clean, b.heading end
        return nil, nil
    end

    local hits = 0
    for _, b in ipairs(blocks) do
        local t = heading_of(b)
        if t then hits = hits + 1 end
    end
    if hits < 2 then return nil, hits end

    local out = {}
    local cur = nil
    local leading = {}
    local function finish()
        if cur then
            cur.raw_html = table.concat(cur.parts)
            cur.parts = nil
            out[#out + 1] = cur
            cur = nil
        end
    end
    for _, b in ipairs(blocks) do
        local title, level = heading_of(b)
        if title then
            finish()
            local ct = clean_title_text(title)
            cur = { title = ct, level = (Converter.title_level(ct) ~= nil and Converter.title_level(ct) or level), parts = {} }
            -- 首个标题之前的正文并入第一章，不单独生成「前言」章
            for _, f in ipairs(leading) do cur.parts[#cur.parts + 1] = f end
            leading = {}
        elseif b.html and b.html ~= "" then
            if cur then cur.parts[#cur.parts + 1] = b.html
            else leading[#leading + 1] = b.html end
        end
    end
    finish()
    if #out == 0 and #leading > 0 then
        out[1] = { title = book_title, level = 0, raw_html = table.concat(leading) }
    end
    return (#out > 0) and out or nil, hits
end

-- 第二层兜底：DOM 的块级标签完全没识别出标题时（例如 cre 把整章压成单行
-- 纯文本、或标签结构异常），把 HTML 转成纯文本行再识别标题并重建章节。
-- 此路径退化为 <p> 段落（不保留原始 HTML 样式），但能保证「有目录 + 正文完整」，
-- 优于只有 1 条目录的 256KB 硬切结果。
local function html_to_plain_lines(html)
    local s = sanitize_document_html(html or "")
    s = s:gsub("<[Bb][Rr]%s*/?>", "\n")
    -- 任意闭合标签都视为段落边界：cre 有时用 <span>/<font> 包裹段落而
    -- 完全不出现 </p>，此时主路径切不出块，这一层仍能把标题逐行找出来。
    s = s:gsub("</[^>]+>", "\n")
    s = s:gsub("<[^>]*>", "")
    -- 同上：不在此归一化 Unicode 空白，标题判定由 chapterTitle 内部完成，
    -- 目录文本才能保留原文的全角空格。
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
         :gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    local function cp(u)
        if not u or u ~= u or u < 0 or u > 0x10FFFF
            or (u >= 0xD800 and u <= 0xDFFF) then
            return "\239\191\189"
        end
        return codepoint_to_utf8(u)
    end
    s = s:gsub("&#x([%x]+);", function(h) return cp(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return cp(tonumber(d, 10)) end)
    return s
end

local function resplit_by_plain_text(chapters, book_title)
    local all = {}
    for _, ch in ipairs(chapters) do
        if ch.raw_html and ch.raw_html ~= "" then all[#all + 1] = ch.raw_html end
    end
    if #all == 0 then return nil, 0 end
    local plain = html_to_plain_lines(table.concat(all))
    local lines = {}
    for ln in plain:gmatch("[^\r\n]+") do
        local t = trim(ln)
        if t ~= "" then lines[#lines + 1] = t end
    end
    local function title_of(t)
        if #t > 80 or not Converter.is_chapter_title(t) then return nil end
        return t
    end
    local hits = 0
    for _, t in ipairs(lines) do if title_of(t) then hits = hits + 1 end end
    if hits < 2 then return nil, hits end

    local out, cur, leading = {}, nil, {}
    local function finish()
        if cur then
            cur.raw_html = table.concat(cur.parts)
            cur.parts = nil
            out[#out + 1] = cur
            cur = nil
        end
    end
    for _, t in ipairs(lines) do
        if title_of(t) then
            finish()
            local ct = clean_title_text(t)
            cur = { title = ct, level = Converter.title_level(ct), parts = {} }
            for _, f in ipairs(leading) do cur.parts[#cur.parts + 1] = f end
            leading = {}
        else
            local p = "<p>" .. escape_html(t) .. "</p>"
            if cur then cur.parts[#cur.parts + 1] = p
            else leading[#leading + 1] = p end
        end
    end
    finish()
    if #out == 0 and #leading > 0 then
        out[1] = { title = book_title, level = 0, raw_html = table.concat(leading) }
    end
    return (#out > 0) and out or nil, hits
end

function Converter.build_epub_from_document(doc_api, out_path, opts, hooks)
    opts = opts or {}
    local indent = opts.indent or "2em"
    local book_title = opts.book_title or doc_api.title or "未命名"
    local uid = opts.uid or ("urn:uuid:" .. Converter.gen_uid())
    local modified = opts.modified or os.date("!%Y-%m-%dT%H:%M:%SZ")

    local get_html = (type(doc_api.get_html) == "function") and doc_api.get_html or nil

    --------------------------------------------------------------------
    -- 1) 由 TOC / 渲染 HTML 构造章节（title / level / raw_html）
    --------------------------------------------------------------------
    local chapters = {}
    local toc = doc_api.toc or {}
    if #toc > 0 and get_html then
        for i, entry in ipairs(toc) do
            if entry.pos0 then
                -- 本段 HTML = [本条目 pos0, 下一个「有 pos0」的条目) ；
                -- 末条目用其 pos1，再不行用 doc_api.end_xp（文档末尾 xpointer）。
                -- 不能简单取 toc[i+1].pos0：中间若有无效条目，会让本章错误地
                -- 一路延伸到文档末尾、与后续章节重复。
                local next_pos = nil
                for j = i + 1, #toc do
                    if toc[j].pos0 and toc[j].pos0 ~= "" then next_pos = toc[j].pos0; break end
                end
                if not next_pos or next_pos == "" then next_pos = entry.pos1 end
                if not next_pos or next_pos == "" then next_pos = doc_api.end_xp end
                local html = ""
                local ok, h = pcall(get_html, entry.pos0, next_pos)
                if ok and type(h) == "string" then html = h end
                chapters[#chapters + 1] = {
                    title = (entry.text and entry.text ~= "") and entry.text or (book_title .. " " .. i),
                    level = entry.depth or 1,
                    raw_html = html,
                }
            end
        end
    end
    -- TOC 层级修复（真机 fb2 目录不折叠）：部分格式（如 FB2/部分 RTF）的
    -- getToc() 返回的所有 depth 都是 1（平级），但标题文本本身是「第一卷 /
    -- 第一章 / 第一节」多级写法。当检测到 depth 无层级信息（取值种类 ≤1）
    -- 且标题能被 title_level 识别出至少两种不同的层级时，改用文本层级，
    -- 让目录正确嵌套折叠。
    if #chapters >= 2 then
        local levels, lvset, lvcount = {}, {}, 0
        for _, ch in ipairs(chapters) do
            local d = ch.level or 1
            levels[#levels + 1] = d
            if not lvset[d] then lvset[d] = true; lvcount = lvcount + 1 end
        end
        if lvcount <= 1 then
            local tset, tcount = {}, 0
            for _, ch in ipairs(chapters) do
                local tl = Converter.title_level(ch.title or "")
                ch._text_level = tl
                if not tset[tl] then tset[tl] = true; tcount = tcount + 1 end
            end
            if tcount >= 2 then
                for _, ch in ipairs(chapters) do ch.level = ch._text_level end
            end
            for _, ch in ipairs(chapters) do ch._text_level = nil end
        end
    end

    -- 无 TOC：按页聚合为单章（PDF 等非 CreDocument 即便有页也无法取 HTML，此处仅作回退）
    if #chapters == 0 and get_html and doc_api.page_count and doc_api.page_count > 0
        and type(doc_api.get_page_xp) == "function" then
        local parts = {}
        for p = 1, doc_api.page_count do
            local ok, h = pcall(get_html, doc_api.get_page_xp(p), doc_api.get_page_xp(p + 1))
            if ok and type(h) == "string" and h ~= "" then parts[#parts + 1] = h end
        end
        chapters[#chapters + 1] = { title = book_title, level = 0, raw_html = table.concat(parts) }
    end
    if #chapters == 0 then
        -- 兜底：什么都拿不到（如 PDF 等非 CreDocument 格式），至少生成一个空章节，保证 EPUB 合法
        chapters[#chapters + 1] = { title = book_title, level = 0, raw_html = "" }
    end

    --------------------------------------------------------------------
    -- 1b) DOM 兜底：从正文 HTML 识别章节标题并重切分。
    --     真机 .doc 的 getToc() 常为 0 条，若不重切，全书只会变成 1 个
    --     按 256KB 硬切的大章，nav/ncx 只有 1 条目录且标题完全没有排版。
    --     只有「重切后章节数明显更多」才替换，避免破坏已有的完整 TOC。
    --------------------------------------------------------------------
    -- 记录原始 DOM HTML 片段样本，供 .txt2epub.log 诊断真机渲染结构
    local dom_html_sample = ""
    for _, ch in ipairs(chapters) do
        if ch.raw_html and ch.raw_html ~= "" then
            dom_html_sample = ch.raw_html:sub(1, 160):gsub("[\r\n\t]", " ")
            break
        end
    end

    local detected_titles, resplit, resplit_mode = 0, false, "否"
    do
        local toc_n0 = #toc
        local rebuilt, hits = resplit_chapters_by_heading(chapters, book_title)
        detected_titles = hits or 0
        -- 无 TOC 时原有 chapters 只是按 256KB 硬切的产物，只要识别到 >=2 个
        -- 标题就替换；已有完整 TOC 时仍要求「重切后章节更多」，避免破坏原结构。
        if rebuilt and (toc_n0 == 0 or #rebuilt > #chapters) then
            chapters = rebuilt
            resplit, resplit_mode = true, "标题重切"
        else
            local rebuilt2, hits2 = resplit_by_plain_text(chapters, book_title)
            if rebuilt2 and (toc_n0 == 0 or #rebuilt2 > #chapters) then
                chapters = rebuilt2
                detected_titles = hits2
                resplit, resplit_mode = true, "纯文本重建"
            end
        end
    end

    -- 空结果体检：统计所有章节「正文」去掉标签/实体后的可见字符数。
    -- 真机上 CreDocument 对 Word 文档常返回「TOC 仅 1 条 + 单节点 HTML」，
    -- 结果就是一本只剩标题的空书；这里把"疑似空书"量化，交给上层提示用户。
    local visible_chars = 0
    for _, ch in ipairs(chapters) do
        local h = ch.raw_html
        if h and h ~= "" then
            local t = h:gsub("<[^>]*>", ""):gsub("&%w+;", ""):gsub("&#%d+;", ""):gsub("%s+", "")
            visible_chars = visible_chars + #t
        end
    end
    local stats = {
        chapter_count = #chapters,
        toc_entries = #toc,
        visible_chars = visible_chars,
        detected_titles = detected_titles,
        resplit = resplit,
        resplit_mode = resplit_mode,
        html_sample = dom_html_sample,
    }
    -- 让上层能在写盘前就能复用同一判定（也可用 opts.hooks 之外的独立函数）
    stats.empty = Converter.is_empty_document_result(stats)

    --------------------------------------------------------------------
    -- 2) 逐章写出（复用同一套 EPUB 构件与轻量 toc 元数据）
    --------------------------------------------------------------------
    local zip = ZipWriter:new(out_path)
    zip:add("mimetype", "application/epub+zip")

    local toc_meta = {}
    local i = 0
    local MAX_CHAPTER_BYTES = 256 * 1024

    local function emit(title, raw_html, level)
        level = level or 0
        i = i + 1
        local xhtml = Converter.build_chapter_xhtml_raw(title, raw_html, level)
        if #xhtml > MAX_CHAPTER_BYTES and #raw_html > 1 then
            -- 超长章节：在 </p> 边界切分为多个文件（仅首个分片计入目录）
            local parts = split_html_at_p(raw_html, MAX_CHAPTER_BYTES)
            local part = 1
            for _, seg in ipairs(parts) do
                local t = (part == 1) and title or (title .. "（" .. part .. "）")
                local px = Converter.build_chapter_xhtml_raw(t, seg, level)
                local fname = string.format("OEBPS/chapter_%04d%s.xhtml", i, (part == 1) and "" or ("_" .. part))
                zip:add(fname, px)
                -- 每个硬切分片都进目录：真机 .doc 在标题识别失败时，旧实现
                -- 只让第 1 片进 nav/ncx，结果全书只有 1 条目录。全部列入后
                -- 至少可逐段跳转（标题为「书名（N）」）。
                toc_meta[#toc_meta + 1] = { file = fname, title = t, level = level, toc = true }
                part = part + 1
                if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
                if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
            end
            if i % 5 == 0 then collectgarbage("collect") end
        else
            local fname = string.format("OEBPS/chapter_%04d.xhtml", i)
            zip:add(fname, xhtml)
            toc_meta[#toc_meta + 1] = { file = fname, title = title, level = level, toc = true }
            raw_html = nil            -- 已写入磁盘，释放正文
            if hooks and type(hooks.on_yield) == "function" then hooks.on_yield() end
            if hooks and type(hooks.on_progress) == "function" then hooks.on_progress(i, nil) end
            if i % 5 == 0 then collectgarbage("collect") end
        end
    end

    for _, ch in ipairs(chapters) do
        emit(ch.title, ch.raw_html, ch.level)
    end

    local toc_for_nav = {}
    for _, e in ipairs(toc_meta) do
        if e.toc ~= false then toc_for_nav[#toc_for_nav + 1] = e end
    end
    local nested = Converter.nest_toc(toc_for_nav)
    Converter.write_epub_tail(zip, opts, book_title, nested, toc_meta, uid, modified)
    zip:add("META-INF/container.xml", Converter.build_container())
    zip:close()
    collectgarbage("collect")
    -- 第三返回值 stats 供上层做"空结果体检"：visible_chars 过少说明 DOM 没提取到正文
    return true, #toc_meta, stats
end

return Converter
