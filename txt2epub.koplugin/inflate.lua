-- inflate.lua
-- 纯 Lua 的 raw DEFLATE (RFC 1951) 解压器 —— 零依赖。
--
-- 为什么需要它：
--   .docx 是 ZIP 容器，其中 method=8 的条目存的是「裸 deflate 流」(raw deflate)，
--   既没有 zlib 的 2 字节头 (0x78 0x9C)，也没有尾部 4 字节 adler32 校验。
--   而 KOReader 自带的 ffi/zlib.zlib_uncompress() 内部调用的是 zlib 的 uncompress()，
--   后者只接受完整的 zlib 流，喂 raw deflate 会返回 Z_DATA_ERROR 并触发
--   `assert(res == 0)` -> "ffi/zlib.lua:29: assertion failed!"。
--   KOReader 的 ffi/zlib_h.cdef 也并未声明 inflateInit2_/inflate/z_stream 等
--   raw-inflate 接口，无法借它解 ZIP 条目。
--
-- 因此本模块用纯 Lua 直接实现 RFC 1951 解码：
--   * 不依赖 ffi / libz / bit 库 / 外部进程，任何 Lua 5.1 / 5.3 / LuaJIT 均可运行；
--     （所有位运算用算术代替，保证跨平台与跨解释器一致）
--   * 内存有界：输出采用「分块冻结 + 32KB 回溯窗口」，不会随文档体积线性膨胀成
--     百万级 Lua table 元素，避免 Kindle 等低内存设备 OOM；
--   * 不改动 STORED (method=0) 路径，两者共用上层 ZipWriter。
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
--   返回 bits(k)、align() 两个闭包
------------------------------------------------------------------------
local function new_bitreader(data)
    local pos = 1
    local n = #data
    local buf = 0       -- 位缓冲，最低位为下一个待消费位
    local cnt = 0       -- 缓冲中有效位数（每次 bits() 返回后恒 < 8）

    -- 读取 k 位（k <= 16）并返回整数；数据耗尽返回 nil
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

    -- 丢弃当前字节内未消费的高位，对齐到下一字节边界（stored block 用）
    local function align()
        buf = 0
        cnt = 0
    end

    return bits, align
end

------------------------------------------------------------------------
-- canonical Huffman 解码表构造（puff.c construct）
--   lengths : 1-based 数组，lengths[i] 为符号 (i-1) 的码长（0 表示未使用）
--   返回 { count=..., symbol=... }；over-subscribed 时返回 nil
------------------------------------------------------------------------
local function construct(lengths, n)
    local count = {}
    for i = 0, MAXBITS do count[i] = 0 end
    for i = 1, n do
        local l = lengths[i] or 0
        if l < 0 or l > MAXBITS then return nil end
        count[l] = count[l] + 1
    end
    count[0] = 0  -- 长度为 0 的符号不参与编码

    -- 检查是否过度订阅（码长组合不可能构成前缀码）
    local left = 1
    for len = 1, MAXBITS do
        left = left * 2 - count[len]
        if left < 0 then return nil end
    end

    -- offs[len] = 码长为 len 的第一个符号在 symbol 表中的 0-based 位置
    local offs = { [1] = 0 }
    for len = 1, MAXBITS - 1 do
        offs[len + 1] = offs[len] + count[len]
    end
    local symbol = {}
    for i = 1, n do
        local l = lengths[i] or 0
        if l ~= 0 then
            symbol[offs[l] + 1] = i - 1   -- 存 0-based 符号值
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
        code = code + b                       -- 等价于 code |= b（低位此刻必为 0）
        local count = h.count[len]
        if code - count < first then          -- code < first + count
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
    for i = 1, 144 do l[i] = 8 end       -- 符号   0..143
    for i = 145, 256 do l[i] = 9 end    -- 符号 144..255
    for i = 257, 280 do l[i] = 7 end    -- 符号 256..279
    for i = 281, 288 do l[i] = 8 end    -- 符号 280..287
    fixed_lit = construct(l, 288)
    local d = {}
    for i = 1, 32 do d[i] = 5 end        -- 32 个距离码，均为 5 位
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

    -- 码长码的码长表（19 个符号）
    local cll = {}
    for i = 1, 19 do cll[i] = 0 end
    for i = 1, hclen do
        v = bits(3); if not v then return nil end
        cll[CLORDER[i] + 1] = v
    end
    local clh = construct(cll, 19)
    if not clh then return nil end

    -- 解出 hlit + hdist 个码长（含 16/17/18 游程）
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
-- 主入口：解压一段裸 deflate 流
------------------------------------------------------------------------
function inflate.raw(data, expected_size)
    if type(data) ~= "string" then
        return nil, "deflate 数据不是字符串"
    end
    if data == "" then
        if expected_size == 0 then return "" end
        return nil, "deflate 数据为空"
    end

    local bits, align = new_bitreader(data)

    -- 有界输出：chunks 保存已冻结的块；buf 保留最近 ≤ WINDOW+FLUSH 字节供 LZ77 回溯
    local WINDOW, FLUSH = 32768, 4096
    local chunks, nchunks = {}, 0
    local buf, nbuf = {}, 0
    local total = 0

    local function freeze_old()
        local t = {}
        for i = 1, FLUSH do t[i] = buf[i] end
        nchunks = nchunks + 1
        chunks[nchunks] = table.concat(t)
        local nb = {}
        for i = FLUSH + 1, nbuf do nb[i - FLUSH] = buf[i] end
        buf = nb
        nbuf = nbuf - FLUSH
    end

    local function put(ch)
        nbuf = nbuf + 1
        buf[nbuf] = ch
        total = total + 1
        if nbuf > WINDOW + FLUSH then freeze_old() end
    end

    local function finish()
        local t = {}
        for i = 1, nbuf do t[i] = buf[i] end
        nchunks = nchunks + 1
        chunks[nchunks] = table.concat(t)
        return table.concat(chunks)
    end

    --------------------------------------------------------------------
    -- 逐 block 解码
    --------------------------------------------------------------------
    while true do
        local final = bits(1)
        if not final then return nil, "数据意外结束（块头 BFINAL）" end
        local btype = bits(2)
        if not btype then return nil, "数据意外结束（块类型 BTYPE）" end

        if btype == 0 then
            -- STORED：对齐到字节，LEN / NLEN / 原始数据
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
                put(string.char(b))
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
                    put(string.char(sym))
                elseif sym == 256 then
                    break  -- 块结束
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
                    if dist > total or dist > nbuf then
                        return nil, "回溯距离超出已输出数据/窗口"
                    end

                    -- LZ77 重叠复制：源位置随写入向前滑动
                    for _ = 1, length do
                        local src = buf[nbuf - dist + 1]
                        put(src)
                    end
                end
            end
        else
            return nil, "保留的块类型 BTYPE=3"
        end

        if final == 1 then break end
    end

    local result = finish()
    if expected_size and expected_size >= 0 and #result ~= expected_size then
        return nil, string.format("解压大小不符：得到 %d 字节，预期 %d 字节", #result, expected_size)
    end
    return result
end

return inflate
