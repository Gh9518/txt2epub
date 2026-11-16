-- inflate.lua
-- 纯 Lua 的 raw DEFLATE (RFC 1951) 解压器 —— 零强制依赖。
--
-- 为什么需要它：
--   .docx 是 ZIP 容器，其中 method=8 的条目存的是「裸 deflate 流」(raw deflate)，
--   既没有 zlib 的 2 字节头 (0x78 0x9C)，也没有尾部 4 字节 adler32 校验。
--   KOReader 自带的 ffi/zlib.zlib_uncompress() 只接受完整 zlib 流，喂 raw deflate 会失败。
--
-- 双路径设计（v2.1.5）：
--   1) 快速路径：若运行环境提供 ffi + libz，直接调用 zlib 的 inflateInit2_(windowBits=-15)
--      做 raw inflate —— C 级速度、内存峰值极小，彻底避免低性能设备（Kindle）上
--      纯 Lua 逐字节解压大 XML 造成的 CPU 卡死与 OOM（真机 Killed）。
--      zlib 的所有声明都包在 pcall 里，任何一步不可用都会静默回退。
--   2) 回退路径：优化的纯 Lua 实现，输出采用「分块冻结 + 32KB 窗口 + 批量串拷贝」，
--      兼容 Lua 5.1 / 5.3 / LuaJIT，零 C 库依赖。
--
-- 对外 API：
--   inflate.raw(data [, expected_size]) -> string | nil, err
--     data           : 裸 deflate 字节流（ZIP 条目的压缩数据区）
--     expected_size  : 可选，ZIP 中央目录记录的解压后大小；给定时做严格长度校验
--
-- 参考：RFC 1951、zlib contrib/puff.c（Mark Adler）的 canonical Huffman 构造/解码算法。

local inflate = {}

local MAXBITS = 15

-- 2 的幂查表（用查表 + 算术代替位运算，兼容 Lua 5.1 / 5.3 / LuaJIT）
local POW2 = {}
do
    local v = 1
    for k = 0, 32 do
        POW2[k] = v
        v = v * 2
    end
end

-- 长度码 257..285 的基值与附加位
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT  = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
-- 距离码 0..29 的基值与附加位
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                8193, 12289, 16385, 24577 }
local DEXT  = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- 动态 Huffman 头中「码长码」的长度排列顺序（符号值 0..18）
local CLORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

------------------------------------------------------------------------
-- 位读取器：DEFLATE 位流为 LSB-first（字节内低位先出）
------------------------------------------------------------------------
local function new_bitreader(data)
    local pos = 1
    local n = #data
    local buf = 0
    local cnt = 0

    local function bits(k)
        while cnt < k do
            if pos > n then return nil end
            buf = buf + data:byte(pos) * POW2[cnt]
            cnt = cnt + 8
            pos = pos + 1
        end
        local p = POW2[k]
        local v = buf % p
        buf = math.floor(buf / p)
        cnt = cnt - k
        return v
    end

    local function align()
        buf = 0
        cnt = 0
    end

    return bits, align
end

------------------------------------------------------------------------
-- canonical Huffman 解码表构造（puff.c construct）
------------------------------------------------------------------------
local function construct(lengths, n)
    local count = {}
    for i = 0, MAXBITS do count[i] = 0 end
    for i = 1, n do
        local l = lengths[i] or 0
        if l < 0 or l > MAXBITS then return nil end
        count[l] = count[l] + 1
    end
    count[0] = 0

    local left = 1
    for len = 1, MAXBITS do
        left = left * 2 - count[len]
        if left < 0 then return nil end
    end

    local offs = { [1] = 0 }
    for len = 1, MAXBITS - 1 do
        offs[len + 1] = offs[len] + count[len]
    end
    local symbol = {}
    for i = 1, n do
        local l = lengths[i] or 0
        if l ~= 0 then
            symbol[offs[l] + 1] = i - 1
            offs[l] = offs[l] + 1
        end
    end
    return { count = count, symbol = symbol }
end

-- 逐位解出一个 Huffman 符号（puff.c decode）；失败返回 nil
local function decode(h, bits)
    local code, first, index = 0, 0, 0
    for len = 1, MAXBITS do
        local b = bits(1)
        if not b then return nil end
        code = code + b
        local count = h.count[len]
        if code - count < first then
            return h.symbol[index + (code - first) + 1]
        end
        index = index + count
        first = (first + count) * 2
        code = code * 2
    end
    return nil
end

------------------------------------------------------------------------
-- 固定 Huffman 表（BTYPE=01），惰性构造一次
------------------------------------------------------------------------
local fixed_lit, fixed_dist
local function init_fixed()
    if fixed_lit then return end
    local l = {}
    for i = 1, 144 do l[i] = 8 end
    for i = 145, 256 do l[i] = 9 end
    for i = 257, 280 do l[i] = 7 end
    for i = 281, 288 do l[i] = 8 end
    fixed_lit = construct(l, 288)
    local d = {}
    for i = 1, 32 do d[i] = 5 end
    fixed_dist = construct(d, 32)
end

------------------------------------------------------------------------
-- 动态 Huffman 表（BTYPE=10）
------------------------------------------------------------------------
local function dynamic_tables(bits)
    local v
    v = bits(5); if not v then return nil end
    local hlit = v + 257
    v = bits(5); if not v then return nil end
    local hdist = v + 1
    v = bits(4); if not v then return nil end
    local hclen = v + 4

    local cll = {}
    for i = 1, 19 do cll[i] = 0 end
    for i = 1, hclen do
        v = bits(3); if not v then return nil end
        cll[CLORDER[i] + 1] = v
    end
    local clh = construct(cll, 19)
    if not clh then return nil end

    local lengths = {}
    local total = hlit + hdist
    local i = 1
    while i <= total do
        local sym = decode(clh, bits)
        if not sym then return nil end
        if sym <= 15 then
            lengths[i] = sym; i = i + 1
        elseif sym == 16 then
            if i == 1 then return nil end
            v = bits(2); if not v then return nil end
            local rep = v + 3
            local prev = lengths[i - 1]
            for _ = 1, rep do
                if i > total then return nil end
                lengths[i] = prev; i = i + 1
            end
        elseif sym == 17 then
            v = bits(3); if not v then return nil end
            local rep = v + 3
            for _ = 1, rep do
                if i > total then return nil end
                lengths[i] = 0; i = i + 1
            end
        elseif sym == 18 then
            v = bits(7); if not v then return nil end
            local rep = v + 11
            for _ = 1, rep do
                if i > total then return nil end
                lengths[i] = 0; i = i + 1
            end
        else
            return nil
        end
    end

    local litl, distl = {}, {}
    for j = 1, hlit do litl[j] = lengths[j] end
    for j = 1, hdist do distl[j] = lengths[hlit + j] end
    local lh = construct(litl, hlit)
    local dh = construct(distl, hdist)
    if not lh or not dh then return nil end
    return lh, dh
end

------------------------------------------------------------------------
-- 快速路径：ffi + libz 的 raw inflate（windowBits = -15）
-- 任何环节不可用 / 报错都返回 nil，由调用方回退纯 Lua。
------------------------------------------------------------------------
local ffi_zlib -- 缓存已成功初始化的 {z, version, cdef_size}
local ffi_zlib_tried = false

local function try_ffi_inflate(data, expected_size)
    if ffi_zlib_tried and not ffi_zlib then return nil end
    local ok = pcall(function()
        if not ffi_zlib then
            local ffi = require("ffi")
            -- 分块声明：即使 KOReader 已声明过部分符号也不会整体回退。
            -- 类型/函数均加 inflate_ 独特前缀，避免与 ffi/zlib.lua 的 z_stream 等冲突。
            pcall(ffi.cdef, [[
                typedef unsigned char inflate_byte;
                typedef unsigned int  inflate_uint;
                typedef unsigned long inflate_ulong;
                typedef void* (*inflate_alloc)(void*, inflate_uint, inflate_uint);
                typedef void  (*inflate_free)(void*, void*);
                typedef struct inflate_z_stream_s {
                    inflate_byte* next_in;
                    inflate_uint  avail_in;
                    inflate_ulong total_in;
                    inflate_byte* next_out;
                    inflate_uint  avail_out;
                    inflate_ulong total_out;
                    char*         msg;
                    void*         state;
                    inflate_alloc zalloc;
                    inflate_free  zfree;
                    void*         opaque;
                    int           data_type;
                    inflate_ulong adler;
                    inflate_ulong reserved;
                } inflate_z_stream;
            ]])
            pcall(ffi.cdef, "int inflateInit2_(inflate_z_stream*, int, const char*, int);")
            pcall(ffi.cdef, "int inflate(inflate_z_stream*, int);")
            pcall(ffi.cdef, "int inflateEnd(inflate_z_stream*);")
            local z = ffi.load("z")
            -- 版本字符串：优先调用 zlibVersion（KOReader 可能已声明），失败则用通用值。
            -- inflateInit2_ 只按主/次版本宽松校验，1.2.11 可匹配绝大多数 zlib 1.2.x。
            pcall(ffi.cdef, "const char* zlibVersion(void);")
            local version = "1.2.11"
            pcall(function()
                local v = ffi.string(z.zlibVersion())
                if v and v ~= "" then version = v end
            end)
            ffi_zlib = { ffi = ffi, z = z, version = version }
        end
    end)
    ffi_zlib_tried = true
    if not ok or not ffi_zlib then return nil end

    local ffi, z, version = ffi_zlib.ffi, ffi_zlib.z, ffi_zlib.version
    local result, ok2 = nil, pcall(function()
        local strm = ffi.new("inflate_z_stream")
        local nin = #data
        local cin = ffi.new("inflate_byte[?]", nin)
        ffi.copy(cin, data, nin)
        strm.next_in = ffi.cast("inflate_byte*", cin)
        strm.avail_in = nin
        -- windowBits = -15 : raw deflate（无 zlib 头、无 adler32 尾）
        local ret = z.inflateInit2_(strm, -15, version, ffi.sizeof("inflate_z_stream"))
        if ret ~= 0 then error("inflateInit2_ failed: " .. tostring(ret)) end
        local CHUNK = 65536
        local cout = ffi.new("inflate_byte[?]", CHUNK)
        local parts, nparts = {}, 0
        while true do
            strm.next_out = ffi.cast("inflate_byte*", cout)
            strm.avail_out = CHUNK
            ret = z.inflate(strm, 4)  -- Z_FINISH
            local produced = CHUNK - strm.avail_out
            if produced > 0 then
                nparts = nparts + 1
                parts[nparts] = ffi.string(cout, produced)
            end
            if ret == 1 then break end       -- Z_STREAM_END
            if ret ~= 0 then
                z.inflateEnd(strm)
                error("inflate failed: " .. tostring(ret))
            end
        end
        z.inflateEnd(strm)
        result = table.concat(parts, "", 1, nparts)
        parts = nil
    end)
    if not ok2 or not result then return nil end
    if expected_size and expected_size >= 0 and #result ~= expected_size then
        return nil  -- 长度不符：不信任 ffi 结果，回退纯 Lua 复核
    end
    return result
end

------------------------------------------------------------------------
-- 主入口：解压一段裸 deflate 流
--   优先 ffi zlib（快、省内存）；不可用则回退优化的纯 Lua。
------------------------------------------------------------------------
function inflate.raw(data, expected_size)
    if type(data) ~= "string" then
        return nil, "deflate 数据不是字符串"
    end
    if data == "" then
        if expected_size == 0 then return "" end
        return nil, "deflate 数据为空"
    end

    -- 快速路径（Kindle 等低性能设备上至关重要）
    local fast = try_ffi_inflate(data, expected_size)
    if fast then return fast end

    --------------------------------------------------------------------
    -- 回退路径：纯 Lua，分块冻结 + 32KB 窗口 + 批量串拷贝
    --   out      : 已冻结输出块（字符串）
    --   cur      : 尚未冻结的字面量字节表
    --   hist     : 最近 ≤ WINDOW 字节的回溯窗口（字符串，供 LZ77 批量复制）
    --------------------------------------------------------------------
    local bits, align = new_bitreader(data)
    local WINDOW, FLUSH = 32768, 8192
    local out, nout = {}, 0
    local cur, ncur = {}, 0
    local hist = ""
    local total = 0

    local function flush_cur()
        if ncur == 0 then return end
        local s = table.concat(cur, "", 1, ncur)
        nout = nout + 1; out[nout] = s
        local hl = #hist
        if hl + ncur <= WINDOW then
            hist = hist .. s
        else
            local keep = WINDOW - ncur
            if keep > 0 then hist = hist:sub(hl - keep + 1) .. s
            else hist = s:sub(-WINDOW) end
        end
        cur, ncur = {}, 0
    end

    local function put(b)
        ncur = ncur + 1; cur[ncur] = string.char(b)
        total = total + 1
        if ncur >= FLUSH then flush_cur() end
    end

    -- LZ77 重叠复制：用 string.rep 一次性生成，避免逐字节循环
    local function copy_match(dist, len)
        flush_cur()
        local hl = #hist
        if dist > hl then return false end
        local pat = hist:sub(hl - dist + 1, hl)
        local pl = #pat
        local rep
        if len <= pl then
            rep = pat:sub(1, len)
        else
            rep = pat:rep(math.ceil(len / pl)):sub(1, len)
        end
        nout = nout + 1; out[nout] = rep
        local nl = #rep
        if hl + nl <= WINDOW then
            hist = hist .. rep
        else
            local keep = WINDOW - nl
            if keep > 0 then hist = hist:sub(hl - keep + 1) .. rep
            else hist = rep:sub(-WINDOW) end
        end
        total = total + len
        return true
    end

    while true do
        local final = bits(1)
        if not final then return nil, "数据意外结束（块头 BFINAL）" end
        local btype = bits(2)
        if not btype then return nil, "数据意外结束（块类型 BTYPE）" end

        if btype == 0 then
            align()
            local len = bits(16)
            if not len then return nil, "数据意外结束（STORED LEN）" end
            local nlen = bits(16)
            if not nlen then return nil, "数据意外结束（STORED NLEN）" end
            if len + nlen ~= 65535 then
                return nil, "STORED 块长度校验失败（NLEN 不匹配）"
            end
            for _ = 1, len do
                local b = bits(8)
                if not b then return nil, "数据意外结束（STORED 数据）" end
                put(b)
            end

        elseif btype == 1 or btype == 2 then
            local lh, dh
            if btype == 1 then
                init_fixed()
                lh, dh = fixed_lit, fixed_dist
            else
                lh, dh = dynamic_tables(bits)
                if not lh then return nil, "动态 Huffman 表无效或数据截断" end
            end
            if not lh or not dh then return nil, "Huffman 表构造失败" end

            while true do
                local sym = decode(lh, bits)
                if not sym then return nil, "字面/长度码解码失败" end
                if sym < 256 then
                    put(sym)
                elseif sym == 256 then
                    break
                else
                    local li = sym - 257 + 1
                    if li < 1 or li > 29 then
                        return nil, "无效长度码：" .. tostring(sym)
                    end
                    local lextra = bits(LEXT[li])
                    if not lextra then return nil, "数据意外结束（长度附加位）" end
                    local length = LBASE[li] + lextra

                    local dsym = decode(dh, bits)
                    if not dsym then return nil, "距离码解码失败" end
                    if dsym < 0 or dsym > 29 then
                        return nil, "无效距离码：" .. tostring(dsym)
                    end
                    local dextra = bits(DEXT[dsym + 1])
                    if not dextra then return nil, "数据意外结束（距离附加位）" end
                    local dist = DBASE[dsym + 1] + dextra
                    if dist > total then
                        return nil, "回溯距离超出已输出数据"
                    end
                    if not copy_match(dist, length) then
                        return nil, "回溯距离超出窗口"
                    end
                end
            end
        else
            return nil, "保留的块类型 BTYPE=3"
        end

        if final == 1 then break end
    end

    flush_cur()
    local result = table.concat(out, "", 1, nout)
    if expected_size and expected_size >= 0 and #result ~= expected_size then
        return nil, string.format("解压大小不符：得到 %d 字节，预期 %d 字节", #result, expected_size)
    end
    return result
end

return inflate
