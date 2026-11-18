-- inflate.lua
-- 纯 Lua 的 raw DEFLATE (RFC 1951) 解压器 —— 零依赖、内存有界、跨设备一致。
--
-- 为什么需要它：
--   .docx 是 ZIP 容器，其中 method=8 的条目存的是「裸 deflate 流」(raw deflate)，
--   既没有 zlib 的 2 字节头 (0x78 0x9C)，也没有尾部 4 字节 adler32 校验。
--   KOReader 自带的 ffi/zlib.zlib_uncompress() 只接受完整 zlib 流，喂 raw deflate 会失败。
--
-- 【版本沿革 / 崩溃根因订正】
--   v2.1.5 曾加入 ffi+libz 快路径。v2.1.6 依据当时 crash.log 的 "ffi.load: z"→"Killed"
--   判定为 FFI ABI 冲突并移除之，加「熔断」保护（输出总量/迭代越界即报错，绝不无限 append）。
--   v2.1.7 真机第五轮反馈证明：移除 FFI 后新日志里已无 ffi.load:z，但 big_novel.docx /
--   long_chapter.docx 仍被 Killed —— FFI 并非根因。真正原因是「先把整份 document.xml
--   解压成 2.8MB 字符串、再解析成 7000+ 段落表」的瞬时内存尖峰（GC 前 ~18MB RSS），
--   叠加真机已渲染 DOM 的 28-30MB 基线堆触发 OOM。为此 v2.1.7 新增 raw_stream，
--   让 docx「解压即解析」，把最大单次分配从 2.8MB 降到 32KB。
--   v2.1.6 的纯 Lua 回归 + 熔断作为安全加固予以保留。
--   效率权衡：纯 Lua 在本机解压 2.8MB XML 约 0.4 秒，真机约数秒，稳定远重于微小速度差。
--
-- 对外 API：
--   inflate.raw(data [, expected_size]) -> string | nil, err
--     data           : 裸 deflate 字节流（ZIP 条目的压缩数据区）
--     expected_size  : 可选，ZIP 中央目录记录的解压后大小；给定时做严格长度校验 + 熔断上界
--   inflate.raw_stream(data [, expected_size], sink) -> true | nil, err   (v2.1.7)
--     同 raw，但每产出一块就调用 sink(chunk_string)，不构建完整结果字符串。
--     用于 docx 的「解压即解析」流式管道：避免 2.8MB 全文与 7000+ 段落表同时驻留
--     造成瞬时内存尖峰（真机高基线堆下叠加触发 OOM Killed 的根因）。
--     sink 返回 false 可提前中止（返回 nil, "输出被消费者中止"）。
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
-- 熔断参数：防止损坏数据 / ABI 异常导致无限 append 而 OOM。
--   hard_cap  : 输出字节硬上限（有 expected_size 时=其+1KB；否则 128MB 兜底）
--   max_iter  : 解码符号迭代上限（2.8MB 输出约需 < 100 万次，留 12 倍余量）
--   任一路越界立即返回明确错误，调用方转成友好提示，绝不 Killed 整个进程。
------------------------------------------------------------------------
local DEFAULT_HARD_CAP = 128 * 1024 * 1024
local DEFAULT_MAX_ITER = 12 * 1024 * 1024

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
-- 主入口：解压一段裸 deflate 流（纯 Lua，分块冻结 + 32KB 窗口 + 批量串拷贝）
--   out      : 已冻结输出块（字符串）
--   cur      : 尚未冻结的字面量字节表
--   hist     : 最近 ≤ WINDOW 字节的回溯窗口（字符串，供 LZ77 批量复制）
--   全程带熔断：输出总量/迭代次数越界立即返回错误，绝不无限 append。
------------------------------------------------------------------------
-- 内部核心：emit(chunk) 每产出一块调用一次；emit 返回 false 表示消费者中止。
-- 返回 true | nil, err；size 校验用累计 total（流式模式无需完整结果串）。
local function core(data, expected_size, emit)
    if type(data) ~= "string" then
        return nil, "deflate 数据不是字符串"
    end
    if data == "" then
        if expected_size == 0 then return true end
        return nil, "deflate 数据为空"
    end

    local hard_cap = (expected_size and expected_size >= 0)
        and (expected_size + 1024) or DEFAULT_HARD_CAP
    local max_iter = DEFAULT_MAX_ITER
    local iter = 0
    local function tick()
        iter = iter + 1
        if iter > max_iter then return false end
        return true
    end

    local bits, align = new_bitreader(data)
    local WINDOW, FLUSH = 32768, 8192
    local cur, ncur = {}, 0
    local hist = ""
    local total = 0

    local emit_aborted = false
    local function flush_cur()
        if ncur == 0 then return true end
        local s = table.concat(cur, "", 1, ncur)
        if emit(s) == false then emit_aborted = true; return false end
        local hl = #hist
        if hl + ncur <= WINDOW then
            hist = hist .. s
        else
            local keep = WINDOW - ncur
            if keep > 0 then hist = hist:sub(hl - keep + 1) .. s
            else hist = s:sub(-WINDOW) end
        end
        cur, ncur = {}, 0
        return true
    end

    local function put(b)
        ncur = ncur + 1; cur[ncur] = string.char(b)
        total = total + 1
        if total > hard_cap then return false end
        if ncur >= FLUSH then return flush_cur() end
        return true
    end

    -- LZ77 重叠复制：用 string.rep 一次性生成，避免逐字节循环
    local function copy_match(dist, len)
        if not flush_cur() then return false end
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
        if emit(rep) == false then emit_aborted = true; return false end
        local nl = #rep
        if hl + nl <= WINDOW then
            hist = hist .. rep
        else
            local keep = WINDOW - nl
            if keep > 0 then hist = hist:sub(hl - keep + 1) .. rep
            else hist = rep:sub(-WINDOW) end
        end
        total = total + len
        if total > hard_cap then return false end
        return true
    end

    while true do
        if not tick() then return nil, "解压迭代超限（数据可能损坏）" end
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
                if not tick() then return nil, "解压迭代超限（STORED 块）" end
                local b = bits(8)
                if not b then return nil, "数据意外结束（STORED 数据）" end
                if not put(b) then return nil, "解压输出超限（数据可能损坏）" end
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
                if not tick() then return nil, "解压迭代超限（Huffman 块）" end
                local sym = decode(lh, bits)
                if not sym then return nil, "字面/长度码解码失败" end
                if sym < 256 then
                    if not put(sym) then return nil, "解压输出超限（数据可能损坏）" end
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
                        return nil, "回溯距离超出窗口或输出超限"
                    end
                end
            end
        else
            return nil, "保留的块类型 BTYPE=3"
        end

        if final == 1 then break end
    end

    if not flush_cur() then
        if emit_aborted then return nil, "输出被消费者中止" end
        return nil, "解压输出超限（收尾）"
    end
    if expected_size and expected_size >= 0 and total ~= expected_size then
        return nil, string.format("解压大小不符：得到 %d 字节，预期 %d 字节", total, expected_size)
    end
    return true
end

-- 一次性解压为字符串（保持原有 API 语义）
function inflate.raw(data, expected_size)
    local out, nout = {}, 0
    local ok, err = core(data, expected_size, function(s)
        nout = nout + 1; out[nout] = s
        return true
    end)
    if not ok then return nil, err end
    return table.concat(out, "", 1, nout)
end

-- 流式解压：每产出一块调用 sink(chunk)，不构建完整结果串。
-- 消费者可就地增量处理（如边解压边解析 XML 段落），把内存峰值从「整份解压结果」
-- 降为「一块 + 消费者状态」。sink 返回 false 可提前中止。
function inflate.raw_stream(data, expected_size, sink)
    if type(sink) ~= "function" then return nil, "sink 不是函数" end
    return core(data, expected_size, sink)
end

return inflate
