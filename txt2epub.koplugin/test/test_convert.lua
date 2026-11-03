-- test/test_convert.lua
-- 直接 require converter（纯 Lua，无 KOReader UI 依赖）进行单元验证。
-- 运行：lua5.3 test/test_convert.lua   （在插件根目录执行）
--
-- 覆盖 3 个用例：
--   1) 含 3 个中文章节的 TXT -> 章节数与目录层级
--   2) 无章节标题的 TXT    -> “整本书作为一个章节”的回退逻辑
--   3) GBK 编码的中文 TXT  -> 编码自动识别与转换

-- 让 require 能找到同目录的 converter.lua
local plugin_dir = arg and arg[0] and arg[0]:match("(.*/)") or "./"
if plugin_dir == "" then plugin_dir = "./" end
package.path = package.path .. ";" .. plugin_dir .. "?.lua" .. ";" .. plugin_dir .. "../?.lua"
package.path = package.path .. ";./?.lua"

local Converter = require("converter")

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed = passed + 1
        print(string.format("[PASS] %s", name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s  %s", name, extra or ""))
    end
end

------------------------------------------------------------------------
-- 用例 1：3 个中文章节
------------------------------------------------------------------------
local sample_cn = [[
书名：测试小说

第一回 风起青萍

这是第一回的正文第一段。
这是第一回的正文第二段。

第一段结束后的空行隔开第二段。

第二章 江湖路远

第二回的内容，包含若干自然段。
每一段都会被包进 <p> 标签里。

第三章 落幕

第三回的结尾文字。
]]

local chs = Converter.split_chapters(sample_cn)
check("用例1 章节数量 == 3", #chs == 3, "实际=" .. #chs)
if #chs >= 1 then
    check("用例1 第1章标题", chs[1].title == "第一回 风起青萍", "实际=" .. tostring(chs[1].title))
end
if #chs >= 2 then
    check("用例1 第2章标题", chs[2].title == "第二章 江湖路远", "实际=" .. tostring(chs[2].title))
end
if #chs >= 3 then
    check("用例1 第3章标题", chs[3].title == "第三章 落幕", "实际=" .. tostring(chs[3].title))
end
-- 目录层级：每个章节应至少有 1 个段落
local all_have_para = true
for _, c in ipairs(chs) do
    if #c.paras == 0 then all_have_para = false end
end
check("用例1 每章均有正文段落", all_have_para)

-- 英文标题也应被识别
local sample_en = "Chapter 1\nHello world.\n\nChapter One\nSecond chapter.\n"
local chs_en = Converter.split_chapters(sample_en)
check("用例1 英文标题 Chapter 1 / Chapter One 被识别", #chs_en == 2, "实际=" .. #chs_en)

------------------------------------------------------------------------
-- 用例 2：无章节标题 -> 回退为单章
------------------------------------------------------------------------
local sample_plain = "这是一段没有任何章节标题的正文。\n\n这是第二段。\n还是没有标题。\n"
check("用例2 has_title_text 应为 false", Converter.has_title_text(sample_plain) == false)
local single = Converter.wrap_single_chapter(sample_plain, "无标题书")
check("用例2 回退为单章", #single == 1 and #single[1].paras >= 1, "实际章数=" .. #single)

------------------------------------------------------------------------
-- 用例 3：GBK 编码文件
------------------------------------------------------------------------
local utf8_text = "第一章 测试GBK编码转换是否正常"
-- 用 iconv 把 UTF-8 内容写成 GBK 文件
local tmp_utf8 = os.tmpname()
local tmp_gbk = os.tmpname()
do
    local f = io.open(tmp_utf8, "wb")
    f:write(utf8_text)
    f:close()
end
local iconv_rc = os.execute(string.format('iconv -f UTF-8 -t GBK "%s" > "%s" 2>/dev/null', tmp_utf8, tmp_gbk))
local iconv_ok = (iconv_rc == 0 or iconv_rc == true)
if iconv_ok then
    local decoded = Converter.read_all(tmp_gbk)
    check("用例3 GBK 解码后与原文一致", decoded == utf8_text,
        string.format("解码=%q 原文=%q", decoded, utf8_text))
else
    check("用例3 环境缺少 iconv，跳过", true, "（仅在本机无 iconv 时跳过）")
end

------------------------------------------------------------------------
-- 用例 4：空格缩进层级（无“第X章”标题，用缩进表达目录树）
------------------------------------------------------------------------
local sample_indent = [[
第1章 风起
    1.1 少年
        1.1.1 出身
        1.1.2 偶遇
    1.2 成长
第2章 云涌
    2.1 转折
]]

-- 内存行迭代器
local function iter_of(text)
    local pos = 1
    return function()
        if not pos then return nil end
        local nl = string.find(text, "\n", pos)
        local line
        if nl then line = string.sub(text, pos, nl - 1); pos = nl + 1
        else line = string.sub(text, pos); pos = nil end
        if line and string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
        return line
    end
end

local forest, cnt = Converter.build_chapters_indent(iter_of(sample_indent), 4, "缩进测试")
check("用例4 顶层章节 == 2", #forest == 2, "实际=" .. #forest)
check("用例4 总目录条目 == 7", cnt == 7, "实际=" .. cnt)
if #forest >= 1 then
    check("用例4 第1章标题", forest[1].title == "第1章 风起", "实际=" .. tostring(forest[1].title))
    check("用例4 第1章有 2 个子项", #forest[1].children == 2, "实际=" .. #forest[1].children)
    if #forest[1].children >= 1 then
        check("用例4 1.1 标题", forest[1].children[1].title == "1.1 少年", "实际=" .. tostring(forest[1].children[1].title))
        check("用例4 1.1 有 2 个孙项", #forest[1].children[1].children == 2, "实际=" .. #forest[1].children[1].children)
        if #forest[1].children[1].children >= 1 then
            local g = forest[1].children[1].children[1]
            check("用例4 1.1.1 标题", g.title == "1.1.1 出身", "实际=" .. tostring(g.title))
            check("用例4 1.1.1 层级 == 2", g.level == 2, "实际=" .. tostring(g.level))
        end
    end
end

-- 自定义步长：每行 2 空格 = 1 级（验证可配置）
local forest2 = Converter.build_chapters_indent(iter_of("A\n  B\n    C\n"), 2, "step2")
check("用例4 自定义步长2：顶层1/二级1/三级1",
    #forest2 == 1 and #forest2[1].children == 1 and #forest2[1].children[1].children == 1,
    "结构异常")

------------------------------------------------------------------------
-- 端到端：缩进模式生成一个真实 EPUB，校验嵌套目录
------------------------------------------------------------------------
local epub2 = (os.tmpname()):gsub("%..*$", "") .. ".epub"
local ok2, count2 = Converter.build_epub(forest, epub2, {
    book_title = "缩进测试",
    uid = "urn:uuid:00000000-0000-0000-0000-000000000002",
})
check("用例4 生成 EPUB 成功", ok2 == true)
check("用例4 扁平化节点数 == 7", count2 == 7, "实际=" .. count2)

local function extract_member(epub, name)
    local p = io.popen(string.format('unzip -p "%s" "%s" 2>/dev/null', epub, name), "r")
    if not p then return "" end
    local data = p:read("*a") or ""
    p:close()
    return data
end
local function count_sub(s, sub)
    local n, i = 0, 1
    while true do
        local f = string.find(s, sub, i, true)
        if not f then break end
        n = n + 1
        i = f + #sub
    end
    return n
end

local nav4 = extract_member(epub2, "OEBPS/nav.xhtml")
check("用例4 nav.xhtml 至少两层嵌套 <ol>", count_sub(nav4, "<ol>") >= 2, "实际 <ol> 数=" .. count_sub(nav4, "<ol>"))
local ncx4 = extract_member(epub2, "OEBPS/toc.ncx")
check("用例4 toc.ncx 含嵌套 navPoint", string.find(ncx4, "<navPoint[^>]*>.-<navPoint") ~= nil, "未检测到嵌套 navPoint")

------------------------------------------------------------------------
-- 端到端：生成一个真实 EPUB 并用纯 Lua 校验结构
------------------------------------------------------------------------
local epub_path = (os.tmpname()):gsub("%..*$", "") .. ".epub"
-- 用用例1的内容构建
local full_text = sample_cn
local chapters = Converter.split_chapters(full_text)
local ok, count = Converter.build_epub(chapters, epub_path, {
    book_title = "测试小说",
    uid = "urn:uuid:00000000-0000-0000-0000-000000000001",
})
check("端到端 生成 EPUB 成功", ok == true)
check("端到端 章节数 == 3", count == 3, "实际=" .. tostring(count))

-- 校验 ZIP：第一个条目必须是 mimetype 且 Stored（不压缩）
do
    local f = io.open(epub_path, "rb")
    local hdr = f:read(30) -- 本地文件头固定 30 字节
    local sig = hdr:sub(1, 4)
    check("端到端 ZIP 本地文件头签名正确", sig == "PK\3\4", "实际=" .. tostring(sig))
    -- 压缩方式位于第 9-10 字节；0 = Store
    local method = hdr:byte(9) + hdr:byte(10) * 256
    check("端到端 mimetype 使用 Stored(0) 方式", method == 0, "实际method=" .. method)
    -- 文件名长度位于第 27-28 字节
    local nlen = hdr:byte(27) + hdr:byte(28) * 256
    local name = f:read(nlen)
    check("端到端 首个条目名为 mimetype", name == "mimetype", "实际=" .. tostring(name))
    f:close()
end

-- 清理临时文件
os.remove(tmp_utf8)
os.remove(tmp_gbk)
os.remove(epub_path)
os.remove(epub2)

------------------------------------------------------------------------
print(string.format("\n==== 结果：%d 通过, %d 失败 ====", passed, failed))
if failed > 0 then os.exit(1) end
