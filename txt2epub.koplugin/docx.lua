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
--   * v2.1.7 流式管道：document.xml 走「解压即解析」——inflate.raw_stream 每产出一块就喂给
--     make_stream_parser，凑成 <w:p> 即 emit 段落并丢弃源文本，避免 2.8MB 全文 + 7000+ 段落表
--     同时驻留的瞬时内存尖峰（真机高基线堆下叠加触发 OOM）。parse_document_xml 作为纯函数保留供测试。
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
-- 越界返回 nil（畸形/截断文件不能让 Lua 抛 "arithmetic on a nil value"，
-- 由调用方转成明确的「文件损坏」提示）
local function le16(s, off)
    local a, b = s:byte(off), s:byte(off + 1)
    if not a or not b then return nil end
    return a + b * 256
end
local function le32(s, off)
    local a, b, c, d = s:byte(off), s:byte(off + 1), s:byte(off + 2), s:byte(off + 3)
    if not a or not b or not c or not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
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
-- 增量段落解析器（v2.1.7）：把 inflate 流式输出的块喂进来，遇到完整的
-- <w:p>...</w:p> 就立刻解析并 emit，随后丢弃该段源文本。
--   目的：不再把整份 2.8MB document.xml 与 7000+ 段落表同时压在 Lua 堆上。
--   原 parse_document_xml 保留（供测试/纯函数场景），二者解析出的段落序列完全一致。
--   emit(level, text)：level 为 nil 表示正文。
------------------------------------------------------------------------
local function make_stream_parser(emit)
    local buf = ""          -- 尚未凑成完整段落的尾部
    local function feed(chunk)
        if not chunk or chunk == "" then return end
        buf = buf .. chunk
        while true do
            local pstart = find_tag(buf, "p", 1)
            if not pstart then
                -- 没有起始标签：只保留末尾可能是不完整 "<w:p..." 的片段，其余丢弃。
                -- 用最后一个 '<' 作为安全切点，避免跨块被切断的标签丢失。
                local last_lt = buf:match(".*()<")
                if last_lt then buf = buf:sub(last_lt) else buf = "" end
                break
            end
            -- 自闭合 <w:p/> 或 <w:p .../>：无闭合标签，立即成段
            local gt = buf:find(">", pstart, true)
            if gt and buf:sub(gt - 1, gt) == "/>" then
                local pslice = buf:sub(pstart, gt)
                emit(paragraph_level(pslice), extract_text(pslice))
                buf = buf:sub(gt + 1)
            else
                local close = find_close_tag(buf, "p", pstart)
                local cgt = close and buf:find(">", close, true)
                if not cgt then
                    -- 闭合标签可能跨块被切断，保留从 pstart 起等待更多数据
                    buf = buf:sub(pstart)
                    break
                end
                local pslice = buf:sub(pstart, cgt)
                emit(paragraph_level(pslice), extract_text(pslice))
                buf = buf:sub(cgt + 1)
            end
        end
    end
    local function finish()
        -- 畸形文件兜底：残留的最后一个未闭合段落，按整段处理（与 parse_document_xml 一致）
        if buf ~= "" then
            local pstart = find_tag(buf, "p", 1)
            if pstart then
                local pslice = buf:sub(pstart)
                emit(paragraph_level(pslice), extract_text(pslice))
            end
            buf = ""
        end
    end
    return feed, finish
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
    -- 畸形/截断文件：字段缺失时返回明确错误，不做 nil 算术
    if not total or not cd_off or cd_off + 46 > n then
        return nil, "ZIP / .docx 结构损坏（EOCD / 中央目录越界）"
    end
    local entries = {}
    -- 中央目录偏移为 0 基，Lua 字符串索引为 1 基，需 +1
    local off = cd_off + 1
    for _ = 1, total do
        if off + 46 > n or le32(data, off) ~= 0x02014b50 then
            return nil, "中央目录结构异常或数据截断"
        end
        local method = le16(data, off + 10)
        local comp_size = le32(data, off + 20)
        local uncomp_size = le32(data, off + 24)
        local fnlen = le16(data, off + 28)
        local extralen = le16(data, off + 30)
        local commentlen = le16(data, off + 32)
        local local_off = le32(data, off + 42)
        if not method or not comp_size or not uncomp_size or not fnlen
            or not extralen or not commentlen or not local_off then
            return nil, "中央目录条目字段截断"
        end
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
    if lo + 30 > #self.data or le32(self.data, lo) ~= 0x04034b50 then
        return nil, "本地文件头签名错误或数据截断：" .. name
    end
    local fnlen = le16(self.data, lo + 26)
    local extralen = le16(self.data, lo + 28)
    if not fnlen or not extralen then
        return nil, "本地文件头字段截断：" .. name
    end
    local data_start = lo + 30 + fnlen + extralen
    if data_start + e.comp_size - 1 > #self.data then
        return nil, "条目压缩数据截断：" .. name
    end
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
-- 流式读取某条目：解压出的块直接喂给 sink(chunk)，不构建完整字符串。
-- 用于 document.xml 的「解压即解析」管道，避免 2.8MB 全文与段落表同时驻留。
-- 返回 true | nil, err。_entry_reader 测试钩子仍受支持（整块喂入）。
------------------------------------------------------------------------
local function read_entry_stream(self, name, sink)
    if DocxReader._entry_reader then
        local full = DocxReader._entry_reader(name)
        if not full then return nil, "测试钩子未返回条目：" .. name end
        sink(full)
        return true
    end
    local e = self.entries[name]
    if not e then return nil end
    local lo = e.local_off + 1
    if lo + 30 > #self.data or le32(self.data, lo) ~= 0x04034b50 then
        return nil, "本地文件头签名错误或数据截断：" .. name
    end
    local fnlen = le16(self.data, lo + 26)
    local extralen = le16(self.data, lo + 28)
    if not fnlen or not extralen then return nil, "本地文件头字段截断：" .. name end
    local data_start = lo + 30 + fnlen + extralen
    if data_start + e.comp_size - 1 > #self.data then
        return nil, "条目压缩数据截断：" .. name
    end
    -- 只切出压缩块本身（big_novel 约 117KB），而非整份解压结果
    local comp = self.data:sub(data_start, data_start + e.comp_size - 1)
    if e.method == 0 then
        sink(comp)
        return true
    elseif e.method == 8 then
        if DocxReader._inflate == nil then
            local ok, mod = pcall(require, "inflate")
            if ok and type(mod) == "table" and type(mod.raw_stream) == "function" then
                DocxReader._inflate = mod
            else
                DocxReader._inflate = false
            end
        end
        if DocxReader._inflate == false then
            return nil, "缺少 inflate 流式解压模块（inflate.lua 版本过旧）"
        end
        local ok, res, ierr = pcall(DocxReader._inflate.raw_stream, comp, e.uncomp_size, sink)
        if not ok then return nil, "解压失败：" .. tostring(res) end
        if not res then return nil, "解压失败：" .. tostring(ierr) end
        comp = nil
        return true
    else
        return nil, "不支持的压缩方式：" .. tostring(e.method)
    end
end

------------------------------------------------------------------------
-- 对外：读取 .docx 文件
--   用 pcall 兜底：畸形/截断/伪造的 ZIP 里任何未预料的算术或索引异常，
--   一律转成「解析失败」的明确错误返回，绝不把 Lua 异常抛给上层 UI。
------------------------------------------------------------------------
local function read_impl(path)
    local f = io.open(path, "rb")
    if not f then return nil, "无法打开文件：" .. tostring(path) end
    local data = f:read("*a")
    f:close()
    if not data or #data == 0 then return nil, "文件为空" end

    local zip, err = parse_zip(data)
    if not zip then return nil, err end
    local self = { entries = zip.entries, data = zip.data }

    -- 定位 document.xml 条目（含大小写宽松匹配）
    local doc_name = "word/document.xml"
    if not self.entries[doc_name] then
        for nm in pairs(self.entries) do
            if nm:lower() == "word/document.xml" then doc_name = nm; break end
        end
    end
    if not self.entries[doc_name] then return nil, "找不到 word/document.xml" end

    -- 书名（core.xml 可选，通常仅数百字节，走普通读取）
    local title
    local core_name = "docProps/core.xml"
    if not self.entries[core_name] then
        for nm in pairs(self.entries) do
            if nm:lower() == "docprops/core.xml" then core_name = nm; break end
        end
    end
    if self.entries[core_name] then
        local core_xml = read_entry(self, core_name)
        if core_xml then title = extract_core_title(core_xml) end
        core_xml = nil
    end

    -- ============ 核心：流式「解压即解析」管道 ============
    -- 旧做法：inflate 出整份 2.8MB XML 字符串 -> parse_document_xml 生成 7000+
    -- 段落表；两者同时驻留，GC 前瞬时峰值达 ~10MB heap / 18MB RSS。真机转换前
    -- 基线堆已 28-30MB（已渲染 DOM），叠加这个瞬时尖峰即触发内核 OOM Killed。
    -- 新做法：每块解压输出立刻喂给增量解析器，凑成完整 <w:p> 就 emit 成段落并
    -- 丢弃该段源文本；内存中同时存在的只有 32KB 解压窗口 + 当前段落 + 结果段落表。
    local paragraphs = {}
    local feed_parser, finish_parser = make_stream_parser(function(level, text)
        paragraphs[#paragraphs + 1] = level
            and { kind = "heading", level = level, text = text }
            or { kind = "body", text = text }
    end)
    local sok, serr = read_entry_stream(self, doc_name, feed_parser)
    if not sok then return nil, serr or "读取 document.xml 失败" end
    finish_parser()

    -- 主动释放 ZIP 原始字节（脚本级 119KB，堆上仍应尽早断开引用）
    self.data = nil
    zip.data = nil
    data = nil
    -- 归还 Huffman 临时表等；不依赖这里的回收来「补回」内存 —— 真正的
    -- 修复是上面的流式管道让峰值本身不再出现。保留 collect 以利连续多次转换。
    collectgarbage("collect")
    return { title = title, paragraphs = paragraphs }
end

function DocxReader.read(path)
    local ok, res, err = pcall(read_impl, path)
    if not ok then
        return nil, "Word 文档解析失败（文件可能损坏）：" .. tostring(res)
    end
    return res, err
end

return DocxReader
