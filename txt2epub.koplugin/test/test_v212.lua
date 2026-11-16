-- test_v212.lua
-- v2.1.2 三项真机问题的回归锁定：
--   (1) 同名不同格式输出名加格式标记，避免 big_novel.txt/.docx/.html/.md
--       互相覆盖 big_novel.epub（真机日志 21:34~21:43 四条同名输出）。
--   (2) docx 超长章节拆分不够：分片按「原始文本字节」累加，未计 <p></p>
--       包装开销，180 段的章生成后达 263KB / 真机 279927 字节 > 256KB。
--       其余格式（txt/md/html/doc DOM）此前未构造超长章样本测试。
--   (3) TXT 目录不折叠：build_epub_streaming 标题模式 close_current()
--       硬编码 level=0，丢弃已算好的卷/章/节层级，nav/ncx 全平铺。
--       另：连续转换 8 个大文件后 Killed（OOM），需在每次转换收尾彻底 GC。
--
-- 全部样本自包含生成（纯 Lua），Lua 5.3 / LuaJIT 双解释器可跑。
-- 用法：lua5.3 test/test_v212.lua  /  luajit test/test_v212.lua

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path

local Converter = require("converter")
local DocxReader = require("docx")

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print(string.format("[PASS] %s", name))
    else fails = fails + 1; print(string.format("[FAIL] %s  %s", name, extra or "")) end
end

local tmp = "/tmp/t2e_v212"
os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)

----------------------------------------------------------------------
-- 公共：读 EPUB 内条目 / 列出最大章节字节
----------------------------------------------------------------------
local function read_entry(epub, name)
    local p = io.popen(string.format('unzip -p "%s" "%s" 2>/dev/null', epub, name))
    if not p then return "" end
    local s = p:read("*a"); p:close(); return s or ""
end
local function max_chapter_bytes(epub)
    local p = io.popen(string.format('unzip -l "%s" 2>/dev/null | grep "OEBPS/chapter_" | awk \'{print $1}\' | sort -rn | head -1', epub))
    if not p then return 0 end
    local s = p:read("*l"); p:close()
    return tonumber(s) or 0
end
local function count_entry(epub, pattern)
    local p = io.popen(string.format('unzip -l "%s" 2>/dev/null | grep -c "%s"', epub, pattern))
    if not p then return 0 end
    local s = p:read("*l"); p:close()
    return tonumber(s) or 0
end

----------------------------------------------------------------------
-- 1) 输出文件名标记（纯函数，无 KOReader 依赖）
----------------------------------------------------------------------
print("\n===== 1. 同名不同格式输出名标记 =====")
-- main.lua 依赖 KOReader 运行时，这里用与源码一致的纯逻辑镜像验证契约；
-- 真实函数通过 dofile 抽取（避免 require main 触发大量 KOReader 依赖）。
local src = io.open(root .. "main.lua"):read("*a")
check("main.lua 含 output_name_with_ext 实现", src:find("function TXT2EPUB.output_name_with_ext", 1, true) ~= nil)
-- 直接断言输出路径构造已接入两处入口
check("DOM 入口使用 _output_name", src:find("self:_output_name(base, file and self:file_ext(file)", 1, true) ~= nil)
check("自解析入口使用 _output_name", src:find("self:_output_name(base, ext)", 1, true) ~= nil)

-- 抽取 main.lua 中真实的 output_name_with_ext 函数体并执行（非镜像实现）
local fn_src = src:match("(function TXT2EPUB%.output_name_with_ext.-end)\n\nfunction TXT2EPUB:_output_name")
check("能抽取真实函数体", fn_src ~= nil)
local expected
if fn_src then
    local load_fn = loadstring or load  -- Lua 5.1/LuaJIT=loadstring, 5.3=load
    local chunk = assert(load_fn("local TXT2EPUB = {}\n" .. fn_src .. "\nreturn TXT2EPUB.output_name_with_ext"))
    expected = chunk()
end
if expected then
    check("txt 输出名", expected("big_novel", ".txt") == "big_novel_txt.epub")
    check("docx 输出名", expected("big_novel", ".docx") == "big_novel_docx.epub")
    check("html 输出名", expected("big_novel", ".html") == "big_novel_html.epub")
    check("md 输出名", expected("big_novel", ".md") == "big_novel_md.epub")
    check("doc 输出名", expected("big_novel", ".doc") == "big_novel_doc.epub")
    local names = {
        expected("big_novel", ".txt"), expected("big_novel", ".docx"),
        expected("big_novel", ".html"), expected("big_novel", ".md"),
    }
    local uniq = {}; for _, n in ipairs(names) do uniq[n] = true end
    local uniq_n = 0; for _ in pairs(uniq) do uniq_n = uniq_n + 1 end
    check("四种格式互不覆盖", uniq_n == 4, "uniq=" .. uniq_n)
    check("已带标记不重复", expected("big_novel_txt", ".txt") == "big_novel_txt.epub")
    check("无扩展名回退", expected("big_novel", nil) == "big_novel.epub")
    check("大写扩展名归一", expected("big_novel", ".DOCX") == "big_novel_docx.epub")
end

----------------------------------------------------------------------
-- 2) 超长章拆分：各格式单章必须 < 256KB
----------------------------------------------------------------------
print("\n===== 2. 各格式超长章拆分 =====")
local MAX = 256 * 1024
local LONG = string.rep("这是一段很长的中文正文内容用于测试超长章节拆分是否严格生效。", 14000) -- ~500KB 单段
local function paras_long_book()
    return {
        { kind = "heading", level = 1, text = "第一章 超长章" },
        { kind = "body", text = LONG },
        { kind = "body", text = string.rep("普通正文段落。", 20000) }, -- 另 ~280KB
        { kind = "heading", level = 1, text = "第二章 正常" },
        { kind = "body", text = "第二章正文。" },
    }
end

-- docx / md / html 都汇入 build_epub_from_paragraphs
local okp, cntp = Converter.build_epub_from_paragraphs(paras_long_book(), "超长书",
    tmp .. "/long_paras.epub", { book_title = "超长书" })
check("段落流水线构建成功", okp == true, "cnt=" .. tostring(cntp))
local maxp = max_chapter_bytes(tmp .. "/long_paras.epub")
check("段落流水线单章 < 256KB", maxp > 0 and maxp < MAX, "max=" .. maxp)
check("段落流水线确有分片", cntp >= 3, "cnt=" .. tostring(cntp))
local navp = read_entry(tmp .. "/long_paras.epub", "OEBPS/nav.xhtml")
check("所有分片进目录(nav 有多条)", select(2, navp:gsub("<a ", "")) >= 3,
    "nav links=" .. tostring(select(2, navp:gsub("<a ", ""))))

-- TXT streaming 路径（标题模式）也走同一 emit；构造单章超长 TXT 行
local txtpath = tmp .. "/long.txt"
do
    local f = assert(io.open(txtpath, "wb"))
    f:write("第一卷　少年时\n", "第一章　超长章\n", LONG, "\n",
            string.rep("普通正文段落。\n", 20000), "\n",
            "第二章　正常\n", "第二章正文。\n")
    f:close()
end
local lines = {}
for ln in Converter.lines(txtpath) do lines[#lines + 1] = ln end
local li = 0
local function txt_line_iter() li = li + 1; return lines[li] end
local okt, cntt = Converter.build_epub_streaming(txt_line_iter, "title", nil, "超长TXT",
    tmp .. "/long_txt.epub", { book_title = "超长TXT" })
Converter.release_lines(txtpath)
check("TXT 流式构建成功", okt == true, "cnt=" .. tostring(cntt))
local maxt = max_chapter_bytes(tmp .. "/long_txt.epub")
check("TXT 流式单章 < 256KB", maxt > 0 and maxt < MAX, "max=" .. maxt)

----------------------------------------------------------------------
-- 3) TXT 目录折叠：卷/章/节多级 level 进入 nav（<ol> 嵌套）
----------------------------------------------------------------------
print("\n===== 3. TXT 多级目录折叠 =====")
local folded = tmp .. "/folded.txt"
do
    local f = assert(io.open(folded, "wb"))
    f:write("第一卷　少年时\n")
    f:write("第一章　剑起青云\n")
    f:write("这是第一章正文。\n")
    f:write("第二节　比武\n")
    f:write("这是第二节正文。\n")
    f:write("第二章　再战\n")
    f:write("这是第二章正文。\n")
    f:write("第二卷　江湖路\n")
    f:write("第三章　远行\n")
    f:write("这是第三章正文。\n")
    f:close()
end
local fl = {}
for ln in Converter.lines(folded) do fl[#fl + 1] = ln end
local fi = 0
local function fold_line_iter() fi = fi + 1; return fl[fi] end
local okf, cntf, emptyf = Converter.build_epub_streaming(fold_line_iter, "title", nil, "折叠测试",
    tmp .. "/folded.epub", { book_title = "折叠测试" })
Converter.release_lines(folded)
check("折叠测试构建成功", okf == true and emptyf == false, "cnt=" .. tostring(cntf))
local nav = read_entry(tmp .. "/folded.epub", "OEBPS/nav.xhtml")
local ncx = read_entry(tmp .. "/folded.epub", "OEBPS/toc.ncx")
-- 关键：修复前 close_current 硬编码 level=0，nav 是平铺的一层 <ol>；
-- 修复后卷(0)/章(1)/节(2) 三级应产生嵌套 <ol>（>=2 个 <ol> 开标签）。
local ol_count = select(2, nav:gsub("<ol", ""))
check("nav 存在嵌套目录(多个<ol>)", ol_count >= 2, "ol=" .. ol_count)
check("nav 含节级标题", nav:find("比武", 1, true) ~= nil)
check("ncx 含卷级标题", ncx:find("少年时", 1, true) ~= nil)
check("ncx 含章级标题", ncx:find("剑起青云", 1, true) ~= nil)
-- 直接验证 title_level 分级
check("title_level 卷=0", Converter.title_level("第一卷　少年时") == 0)
check("title_level 章=1", Converter.title_level("第一章　剑起青云") == 1)
check("title_level 节=2", Converter.title_level("第二节　比武") == 2)

----------------------------------------------------------------------
-- 4) 内存：连续转换收尾 GC + 解码缓存清理（源码契约 + 行为）
----------------------------------------------------------------------
print("\n===== 4. 连续转换内存回收 =====")
local msrc = io.open(root .. "main.lua"):read("*a")
-- 源码中 _async_run 失败/成功两条路径各有 2 次 collect（共 4 次），
-- plus build 结尾等；只要 >=4 即证明双重回收已接入。
local _, total_collect = msrc:gsub('collectgarbage%("collect"%)', "")
check("异步收尾含双重 collect", total_collect >= 4, "collect 次数=" .. tostring(total_collect))
check("收尾断开协程引用", msrc:find("co = nil") ~= nil)
local csrc = io.open(root .. "converter.lua"):read("*a")
check("release_lines 无条件清缓存", csrc:find("_decoded_cache%[path%] = nil") ~= nil)
-- 行为：连续构建 5 本，全部成功且单章达标（不会因累积导致失败/panic）
local allok = true
for i = 1, 5 do
    local bok = Converter.build_epub_from_paragraphs({
        { kind = "heading", level = 1, text = "第" .. i .. "章" },
        { kind = "body", text = string.rep("连续转换正文内容。", 2000) },
    }, "连续" .. i, tmp .. "/seq" .. i .. ".epub", { book_title = "连续" .. i })
    if not bok then allok = false end
    collectgarbage("collect")
end
check("连续 5 次转换全部成功", allok)

----------------------------------------------------------------------
print(string.format("\n===== v2.1.2 回归：%d 通过 / %d 失败 =====", passes, fails))
os.exit(fails == 0 and 0 or 1)
