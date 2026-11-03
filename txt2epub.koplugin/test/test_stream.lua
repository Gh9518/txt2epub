-- test_stream.lua
-- 验证 build_epub_streaming：流式、逐章写盘即释放，内存只保留一章量级。
-- 关键断言：
--   1) 与旧的整书入内存版本（build_epub + split_chapters）产出结构一致、章节数相同；
--   2) 大书（多章）能正常完成且被切成多次 UI tick（逐章 yield）；
--   3) indent / single 模式均正确。
-- 运行：luajit test/test_stream.lua

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then
        passes = passes + 1
        print("[PASS] " .. name)
    else
        fails = fails + 1
        print("[FAIL] " .. name .. (extra and ("  -> " .. tostring(extra)) or ""))
    end
end

----------------------------------------------------------------------
-- 准备测试环境（最小化 KOReader 桩，且不提供 util.fileExists，模拟真机）
----------------------------------------------------------------------
package.path = "./?.lua;" .. package.path
local Converter = require("converter")

----------------------------------------------------------------------
-- 工具：写临时 TXT、列 ZIP 内条目、读 ZIP 内某文件
----------------------------------------------------------------------
local function write_tmp(name, content)
    local p = "/tmp/t2e_stream/" .. name
    os.execute("mkdir -p /tmp/t2e_stream")
    local f = io.open(p, "w")
    f:write(content)
    f:close()
    return p
end

local function unzip_list(path)
    local f = io.popen('unzip -l "' .. path .. '" 2>/dev/null')
    local out = f:read("*a")
    f:close()
    return out
end

local function count_chapters(zipout)
    local n = 0
    for _ in string.gmatch(zipout, "OEBPS/chapter_%d+%.xhtml") do
        n = n + 1
    end
    return n
end

----------------------------------------------------------------------
-- 用例 A：流式版 vs 整书入内存版 结构一致、章节数相同（标题模式）
----------------------------------------------------------------------
local text = {}
text[#text + 1] = "书名：测试书"
for i = 1, 50 do
    text[#text + 1] = "第一章 " .. i
    text[#text + 1] = "这是第 " .. i .. " 章的正文段落一。"
    text[#text + 1] = ""
    text[#text + 1] = "这是第 " .. i .. " 章的正文段落二。"
end
local big = table.concat(text, "\n")

local pathA = write_tmp("t_title.txt", big)
local outA1 = "/tmp/t2e_stream/title_mem.epub"
local outA2 = "/tmp/t2e_stream/title_stream.epub"

-- 整书入内存版
local chapters = Converter.split_chapters(big, nil)
local ok1, c1 = Converter.build_epub(chapters, outA1, { book_title = "测试书" })
-- 流式版（消费行迭代器）
local ok2, c2 = Converter.build_epub_streaming(Converter.lines(pathA), "title", nil, "测试书", outA2, {})

check("标题模式 流式版成功", ok2 == true)
check("标题模式 章节数与整书版一致（均应为 50）", c1 == c2 and c2 == 50, string.format("mem=%s stream=%s", c1, c2))
check("标题模式 流式产出 EPUB 文件", io.open(outA2, "rb") ~= nil)
local za = unzip_list(outA1)
local zb = unzip_list(outA2)
check("标题模式 流式版章节文件数与整书版一致", count_chapters(za) == count_chapters(zb) and count_chapters(zb) == 50)
local p_mime = string.find(zb, "mimetype")
local p_chap = string.find(zb, "OEBPS/chapter_")
check("标题模式 mimetype 位于章节文件之前（首条目）", p_mime and p_chap and p_mime < p_chap)

----------------------------------------------------------------------
-- 用例 B：缩进模式
----------------------------------------------------------------------
local ind = {}
ind[#ind + 1] = "第1章 开篇"
ind[#ind + 1] = "    1.1 小节"
ind[#ind + 1] = "        1.1.1 细项"
ind[#ind + 1] = "第2章 发展"
ind[#ind + 1] = "    2.1 小节"
local ind_text = table.concat(ind, "\n")
local pathB = write_tmp("t_indent.txt", ind_text)
local outB = "/tmp/t2e_stream/indent_stream.epub"
local okB, cB, emptyB = Converter.build_epub_streaming(Converter.lines(pathB), "indent", 4, "缩进书", outB, {})
check("缩进模式 流式版成功", okB == true)
check("缩进模式 节点数正确（5 行非空）", cB == 5, cB)
check("缩进模式 非空文件 empty=false", emptyB == false)
check("缩进模式 产出 EPUB 文件", io.open(outB, "rb") ~= nil)

----------------------------------------------------------------------
-- 用例 C：单章模式（整本合并为一章）
----------------------------------------------------------------------
local pathC = write_tmp("t_single.txt", "第一段。\n第二段。\n\n第三段。")
local outC = "/tmp/t2e_stream/single_stream.epub"
local okC, cC = Converter.build_epub_streaming(Converter.lines(pathC), "single", nil, "单章书", outC, {})
check("单章模式 流式版成功", okC == true)
check("单章模式 仅 1 章", cC == 1, cC)

----------------------------------------------------------------------
-- 用例 D：空文件 / 全空行 -> 回退单章（indent 的 empty=true）
----------------------------------------------------------------------
local pathD = write_tmp("t_blank.txt", "\n\n   \n\n")
local outD = "/tmp/t2e_stream/blank_stream.epub"
local okD, cD, emptyD = Converter.build_epub_streaming(Converter.lines(pathD), "indent", 4, "空书", outD, {})
check("空文件 流式版成功", okD == true)
check("空文件 回退为 1 章", cD == 1, cD)
check("空文件 empty 标记正确", emptyD == true)
check("空文件 产出合法 EPUB（回退单章）", io.open(outD, "rb") ~= nil)

----------------------------------------------------------------------
-- 用例 E：大书（200 章）流式完成 + 逐章 yield（内存只保留一章量级）
--         用虚构的“行迭代器”喂入，避免真实 200 章文件 IO 拖慢测试。
----------------------------------------------------------------------
local function big_iter_factory(nch)
    local i = 0
    local lines = {}
    lines[#lines + 1] = "大书"
    for c = 1, nch do
        lines[#lines + 1] = "第" .. c .. "章"
        for p = 1, 5 do
            lines[#lines + 1] = "正文行 " .. c .. "-" .. p
        end
    end
    local k = 0
    return function()
        k = k + 1
        return lines[k]
    end
end

local yield_count = 0
local outE = "/tmp/t2e_stream/big_stream.epub"
local okE, cE = Converter.build_epub_streaming(big_iter_factory(200), "title", nil, "大书", outE, {},
{
    on_yield = function()
        -- 每次写完一章即回调一次（真机里此回调会 coroutine.yield 让出主线程）
        yield_count = yield_count + 1
    end,
})
check("大书 流式版成功", okE == true)
check("大书 章节数正确（200）", cE == 200, cE)
check("大书 逐章 yield（次数=章节数=200）", yield_count == 200, yield_count)
check("大书 产出 EPUB 文件", io.open(outE, "rb") ~= nil)
local ze = unzip_list(outE)
check("大书 章节文件数=200", count_chapters(ze) == 200)

----------------------------------------------------------------------
-- 用例 F（回归）：前 64KB 边界恰好切在多字节字符中途的 UTF-8 文件
--   旧版 is_valid_utf8 只检查前 65540 字节，若该块末尾切在中文多字节中途会误判为
--   非 UTF-8，进而走整本载入的 GBK 分支 -> 内存爆炸 OOM。此处构造此类文件，
--   验证其被正确识别为 UTF-8 并流式切分（章节数正确、不被误并为单章）。
----------------------------------------------------------------------
local pad = string.rep("中", 21846)          -- 21846 * 3 = 65538 字节
local cut = "\228\184"                        -- “中”的前 2 字节：使前 65540 字节末尾切在 3 字节字符中途
local body = {}
body[#body + 1] = "书名"
for c = 1, 5 do
    body[#body + 1] = "第" .. c .. "章"
    body[#body + 1] = "这是第" .. c .. "章的正文内容。"         -- 紧接着多字节边界之后
end
local pathF = write_tmp("t_boundary.txt", pad .. cut .. table.concat(body, "\n"))
local outF = "/tmp/t2e_stream/boundary_stream.epub"
local okF, cF = Converter.build_epub_streaming(Converter.lines(pathF), "title", nil, "边界书", outF, {})
check("边界文件 流式版成功", okF == true)
check("边界文件 正确切分为 5 章（非误并单章）", cF == 5, cF)
check("边界文件 产出 EPUB", io.open(outF, "rb") ~= nil)

----------------------------------------------------------------------
-- 汇总
----------------------------------------------------------------------
print(string.format("\n===== 流式构建测试：%d 通过 / %d 失败 =====", passes, fails))
os.exit(fails == 0 and 0 or 1)
