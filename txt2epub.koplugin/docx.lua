-- docx.lua
-- Word (.docx) 解析模块：把 .docx 转换为“段落 + 标题层级”列表，供 converter 烘焙成 EPUB。
--
-- 设计要点：
--   * .docx 本质是一个 ZIP（OOXML）包；本模块用纯 Lua 解析 ZIP 容器（EOCD + 中央目录 + 本地头），
--     条目数据若 deflate 压缩（method 8）则用同目录 inflate.lua 做 raw DEFLATE 解压，
--     Stored（method 0）直接取用。
--   * 注意：ZIP 条目是「裸 deflate 流」(raw, RFC1951)，不带 zlib 头与 adler32 尾，
--     因此不能用 KOReader 的 ffi/zlib.zlib_uncompress()（其内部是 zlib uncompress()，
--     只认 zlib 格式，喂 raw deflate 会 assert(res==0) 失败）。inflate.lua 为纯 Lua 实现，
--     零 C 库/ffi 依赖，跨 Lua 5.1/5.3/LuaJIT 与所有设备一致，且内存有界。
--   * 解析 word/document.xml：逐段（<w:p>）提取文本，并通过 <w:pStyle w:val> / <w:outlineLvl w:val>
--     判定该段是否为“标题”及其层级（Heading1 -> 1，Heading2 -> 2 …），从而天然支持多级目录。
--   * 完全不依赖任何第三方 Lua/C 库：ZIP 解析与 DEFLATE 解压都是纯 Lua 算术。
--
-- 对外 API：
--   DocxReader.read(path)        -> { title=书名, paragraphs = { {kind="heading", level=N, text=T} | {kind="body", text=T} } } 或 (nil, err)
--   DocxReader.parse_document_xml(xml) -> paragraphs（纯函数，便于单元测试，不触碰 ZIP）
-- 测试钩子：
--   DocxReader._entry_reader = function(name) -> 解压后的条目内容（字符串）  -- 注入用于绕过真实 ZIP 读取

local DocxReader = {}

------------------------------------------------------------------------
-- 小工具：小端整数读取（data 为完整文件字符串，off 为 1-based 字节下标）
------------------------------------------------------------------------
local function le16(s, off)
    return s:byte(off) + s:byte(off + 1) * 256
end
local function le32(s, off)
    return s:byte(off)
        + s:byte(off + 1) * 256
        + s:byte(off + 2) * 65536
        + s:byte(off + 3) * 16777216
end

------------------------------------------------------------------------
-- XML 实体解码（OOXML 文本可能含 &amp; &lt; &gt; &quot; &apos; 及 &#NNN; / &#xHH;）
--
-- 重要：不要用 utf8.char()。KOReader 真机运行在 LuaJIT（Lua 5.1 兼容）上，
-- 并没有 Lua 5.3 才引入的全局 `utf8` 库；一旦文档含数字字符实体
-- （如 Word/WPS/在线转换工具常输出的 &#20013; / &#x4E2D;），
-- 调用 utf8.char 会直接抛 "attempt to index global 'utf8' (a nil value)"
-- 导致整次转换失败。而 utf8.char 对超范围/代理区码点在 Lua 5.3 上同样会抛
-- "bad argument #1 to 'char' (value out of range)"。
-- 因此这里用纯 Lua 算术实现码点 -> UTF-8，并对非法码点安全降级为 U+FFFD。
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
    if not s or s == "" then return s end
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    s = s:gsub("&amp;", "&")  -- 必须最后替换，避免污染上面已经展开的实体
    s = s:gsub("&#x([%x]+);", function(h) return codepoint_to_utf8(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return codepoint_to_utf8(tonumber(d, 10)) end)
    return s
end

------------------------------------------------------------------------
-- 标签定位：在 s 中从 i 起查找“本地名为 localname”的起始 '<' 下标（忽略命名空间前缀）
--   同时返回该标签名（含前缀）。找不到返回 nil。
------------------------------------------------------------------------
local function find_tag(s, localname, i)
    local p = i or 1
    while true do
        local lt = s:find("<", p, true)
        if not lt then return nil end
        -- 取到标签名（到空白或 '>' 或 '/'）
        local name = s:match("^<([%w_:-]+)", lt)
        if name then
            local ln = name:match(":(%w+)$") or name
            if ln == localname then return lt, name end
        end
        p = lt + 1
    end
end

-- 在 s 中从 i 起查找“</localname”闭合标签的起始 '<' 下标
local function find_close_tag(s, localname, i)
    local p = i or 1
    while true do
        local lt = s:find("<", p, true)
        if not lt then return nil end
        local name = s:match("^</([%w_:-]+)", lt)
        if name then
            local ln = name:match(":(%w+)$") or name
            if ln == localname then return lt end
        end
        p = lt + 1
    end
end

-- 判断从 open_idx（'<' 位置）开始的标签是否自闭合（<.../>）
local function is_self_closing(s, open_idx)
    local gt = s:find(">", open_idx, true)
    if not gt then return false end
    return s:sub(gt - 1, gt - 1) == "/"
end

------------------------------------------------------------------------
-- 从一段 <w:p> ... </w:p> 切片里提取纯文本（含 <w:t>、<w:tab/>、<w:br/>、<w:cr/>）
------------------------------------------------------------------------
local function extract_text(slice)
    local out = {}
    local i = 1
    local n = #slice
    while i <= n do
        local lt_t = slice:find("<", i, true)
        if not lt_t then break end
        local name = slice:match("^<([%w_:-]+)", lt_t)
        local ln = name and (name:match(":(%w+)$") or name) or ""
        if ln == "t" then
            -- 文本：<w:t ...>内容</w:t> 或自闭合（罕见，视为空）
            local gt = slice:find(">", lt_t, true)
            if gt and slice:sub(gt - 1, gt - 1) == "/" then
                -- 自闭合 <w:t/>
                i = gt + 1
            else
                local close = slice:find("</", gt + 1, true)
                local text
                if close then
                    text = slice:sub(gt + 1, close - 1)
                else
                    text = slice:sub(gt + 1)
                end
                out[#out + 1] = decode_entities(text)
                i = (close and slice:find(">", close, true) or gt) + 1
            end
        elseif ln == "tab" then
            out[#out + 1] = " "
            local gt = slice:find(">", lt_t, true)
            i = (gt or lt_t) + 1
        elseif ln == "br" or ln == "cr" then
            out[#out + 1] = "\n"
            local gt = slice:find(">", lt_t, true)
            i = (gt or lt_t) + 1
        else
            local gt = slice:find(">", lt_t, true)
            i = (gt or lt_t) + 1
        end
    end
    return table.concat(out)
end

------------------------------------------------------------------------
-- 由样式值推断标题层级
--   返回 1..9 表示对应 Heading 层级；nil 表示正文。
--   支持：Title、Heading1..9（含 "Heading 1" 带空格、Heading1Char 等变体）、
--         中文“标题 N”、日文“見出し N”、法文“Titre N”、德文“Überschrift N”。
--   同时支持 w:outlineLvl（0 基）-> 层级 = val + 1。
------------------------------------------------------------------------
local function style_level(val)
    if not val or val == "" then return nil end
    -- 取第一式（Word 偶见 "Heading1;..." 链接写法）
    val = val:match("^([^;]+)") or val
    if val == "Title" then return 1 end
    local h = val:match("^[Hh]eading%s*(%d)$")
        or val:match("^标题%s*(%d)$")
        or val:match("^見出し%s*(%d)$")
        or val:match("^Titre%s*(%d)$")
        or val:match("^Überschrift%s*(%d)$")
    if h then
        h = tonumber(h)
        if h and h >= 1 and h <= 9 then return h end
    end
    return nil
end

-- 从一段 <w:p> 切片里取标题层级（先看 <w:pStyle w:val>，再看 <w:outlineLvl w:val>）
local function paragraph_level(slice)
    -- pStyle：<w:pStyle w:val="X"/>（用非贪心 [^>]- 在标签内定位 w:val，避免自闭合场景匹配失败）
    local pstyle = slice:match("<[%w_:-]*:?pStyle[^>]-w:val%s*=%s*\"([^\"]*)\"")
    if not pstyle then
        pstyle = slice:match("<[%w_:-]*:?pStyle[^>]*>%s*<[%w_:-]*:?val>([^<]*)</")
    end
    if pstyle then
        local lv = style_level(pstyle)
        if lv then return lv end
    end
    -- outlineLvl：<w:outlineLvl w:val="N"/>（0 基）
    local ol = slice:match("<[%w_:-]*:?outlineLvl[^>]-w:val%s*=%s*\"([^\"]*)\"")
    if ol then
        local n = tonumber(ol)
        if n and n >= 0 and n <= 8 then return n + 1 end
    end
    return nil
end

------------------------------------------------------------------------
-- 纯函数：解析 document.xml 字符串为段落列表
--   每个元素：{kind="heading", level=N, text=T} 或 {kind="body", text=T}
------------------------------------------------------------------------
function DocxReader.parse_document_xml(xml)
    local paras = {}
    if not xml or xml == "" then return paras end
    local i = 1
    while true do
        local pstart = find_tag(xml, "p", i)
        if not pstart then break end
        local close = find_close_tag(xml, "p", pstart)
        local pslice
        if close then
            -- 取闭合 '>' 之后的位置作为切片结束
            local cgt = xml:find(">", close, true)
            pslice = xml:sub(pstart, cgt or close)
        else
            pslice = xml:sub(pstart)
        end

        local level = paragraph_level(pslice)
        local text = extract_text(pslice)
        if level then
            paras[#paras + 1] = { kind = "heading", level = level, text = text }
        else
            paras[#paras + 1] = { kind = "body", text = text }
        end

        -- 若段为自闭合（<w:p/>）则无闭合标签，避免死循环
        if close then
            local cgt = xml:find(">", close, true)
            i = (cgt or close) + 1
        else
            -- 没有闭合标签，整段已处理，结束
            break
        end
    end
    return paras
end

------------------------------------------------------------------------
-- 从 docProps/core.xml 取书名（<dc:title>...</dc:title>）
------------------------------------------------------------------------
local function extract_core_title(xml)
    if not xml then return nil end
    local t = xml:match("<[%w_:-]*:?title[^>]*>(.-)</[%w_:-]*:?title>")
    if t then t = decode_entities(t):match("^%s*(.-)%s*$") end
    return (t and t ~= "") and t or nil
end

------------------------------------------------------------------------
-- ZIP 读取（纯 Lua）
--   返回 { entries = { [name] = {method, comp_size, uncomp_size, local_off} }, data = 整个文件内容 }
------------------------------------------------------------------------
local function parse_zip(data)
    local n = #data
    local function find_sig(sig, from, to)
        -- 返回 1-based 起始下标；从 to 向前扫描取最后一次命中（EOCD 取最后一份最稳）
        local last = nil
        local p = from
        while p <= to do
            local pos = data:find(sig, p, true)
            if not pos or pos > to then break end
            last = pos
            p = pos + 1
        end
        return last
    end
    local eocd = find_sig(string.char(0x50, 0x4b, 0x05, 0x06), 1, n)
    if not eocd then return nil, "不是合法的 ZIP / .docx 文件（找不到 EOCD）" end
    local total = le16(data, eocd + 10)
    local cd_off = le32(data, eocd + 16)
    local entries = {}
    -- 中央目录偏移为 0 基，Lua 字符串索引为 1 基，需 +1
    local off = cd_off + 1
    for _ = 1, total do
        if le32(data, off) ~= 0x02014b50 then
            return nil, "中央目录结构异常"
        end
        local method = le16(data, off + 10)
        local comp_size = le32(data, off + 20)
        local uncomp_size = le32(data, off + 24)
        local fnlen = le16(data, off + 28)
        local extralen = le16(data, off + 30)
        local commentlen = le16(data, off + 32)
        local local_off = le32(data, off + 42)
        local name = data:sub(off + 46, off + 45 + fnlen)
        entries[name] = {
            method = method,
            comp_size = comp_size,
            uncomp_size = uncomp_size,
            local_off = local_off,
        }
        off = off + 46 + fnlen + extralen + commentlen
    end
    return { entries = entries, data = data }
end

-- 读取某条目解压后的内容（字符串）；入口统一走这里（可被 _entry_reader 注入覆盖）
local function read_entry(self, name)
    if DocxReader._entry_reader then
        return DocxReader._entry_reader(name)
    end
    local e = self.entries[name]
    if not e then return nil end
    -- 本地文件头偏移为 0 基，转为 1 基
    local lo = e.local_off + 1
    if le32(self.data, lo) ~= 0x04034b50 then
        return nil, "本地文件头签名错误：" .. name
    end
    local fnlen = le16(self.data, lo + 26)
    local extralen = le16(self.data, lo + 28)
    local data_start = lo + 30 + fnlen + extralen
    local comp = self.data:sub(data_start, data_start + e.comp_size - 1)
    if e.method == 0 then
        return comp
    elseif e.method == 8 then
        -- deflate：ZIP 条目是 raw DEFLATE，用纯 Lua 的 inflate.lua 解压。
        -- 不能用 ffi/zlib.zlib_uncompress（只认 zlib 格式），否则真机必报
        -- "ffi/zlib.lua:29: assertion failed!"。
        if DocxReader._inflate == nil then
            local ok, mod = pcall(require, "inflate")
            if ok and type(mod) == "table" and type(mod.raw) == "function" then
                DocxReader._inflate = mod
            else
                DocxReader._inflate = false
            end
        end
        if DocxReader._inflate == false then
            return nil, "缺少 inflate 解压模块（inflate.lua 未随插件一起安装）"
        end
        local ok, res, ierr = pcall(DocxReader._inflate.raw, comp, e.uncomp_size)
        if not ok then return nil, "解压失败：" .. tostring(res) end
        if not res then return nil, "解压失败：" .. tostring(ierr) end
        return res
    else
        return nil, "不支持的压缩方式：" .. tostring(e.method)
    end
end

------------------------------------------------------------------------
-- 对外：读取 .docx 文件
------------------------------------------------------------------------
function DocxReader.read(path)
    local f = io.open(path, "rb")
    if not f then return nil, "无法打开文件：" .. tostring(path) end
    local data = f:read("*a")
    f:close()
    if not data or #data == 0 then return nil, "文件为空" end

    local zip, err = parse_zip(data)
    if not zip then return nil, err end
    local self = { entries = zip.entries, data = zip.data }

    -- document.xml 必需
    local doc_xml, derr = read_entry(self, "word/document.xml")
    if not doc_xml then
        -- 某些文档路径大小写不同，做一次宽松匹配
        for nm in pairs(self.entries) do
            if nm:lower() == "word/document.xml" then
                doc_xml, derr = read_entry(self, nm)
                break
            end
        end
    end
    if not doc_xml then
        return nil, derr or "找不到 word/document.xml"
    end

    -- 书名（core.xml 可选）
    local title
    local core_xml = read_entry(self, "docProps/core.xml")
    if not core_xml then
        for nm in pairs(self.entries) do
            if nm:lower() == "docprops/core.xml" then core_xml = read_entry(self, nm); break end
        end
    end
    if core_xml then title = extract_core_title(core_xml) end

    local paragraphs = DocxReader.parse_document_xml(doc_xml)
    return { title = title, paragraphs = paragraphs }
end

return DocxReader
