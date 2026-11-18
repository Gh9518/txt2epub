-- test/test_fixes_v218.lua
-- v2.1.8 真机第六轮反馈修复的回归测试：
--   问题：big_novel.docx 的「卷/章同为 Heading1、节 Heading2」导致目录
--         卷章平铺、卷无法折叠；long_chapter.docx 卷/章/节=H1/H2/H3 正常。
--   修复：build_epub_from_paragraphs 入口新增 refine_heading_levels，
--         仅当「文本语义层级种类 > 原始样式层级种类」时用卷0/章1/节2精修。
--   1) explicit_title_level 明确命中判定（有无卷/章/节标记）
--   2) refine_heading_levels 触发 / 不触发（big 平铺 vs long 三级 vs 无标记）
--   3) 真实 big_novel.docx 端到端：nav 目录出现 0/1/2 三级嵌套
--   4) 真实 long_chapter 结构（若 fixture 存在）：不触发、层级保持
-- 用法：lua5.3 / luajit test/test_fixes_v218.lua

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then pass = pass + 1
    else fail = fail + 1; print("[FAIL] " .. name .. "  got=" .. tostring(got)) end
end

local HERE = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = HERE .. "?.lua;" .. package.path
local C = require("converter")
local D = require("docx")

local fixture_dir = HERE .. "fixtures"

----------------------------------------------------------------------
-- 1) explicit_title_level：只在「明确命中」时返回语义层级
----------------------------------------------------------------------
local etl = C.explicit_title_level
check("explicit 第一卷=0", etl("第一卷　卷名之1") == 0, etl("第一卷　卷名之1"))
check("explicit 第1章=1", etl("第1章　章节标题1") == 1, etl("第1章　章节标题1"))
check("explicit 第5节=2", etl("第5节　细节展开") == 2, etl("第5节　细节展开"))
check("explicit 第一章=1", etl("第一章　常规短章") == 1, etl("第一章　常规短章"))
check("explicit Volume=0", etl("Volume 1 The Beginning") == 0, etl("Volume 1 The Beginning"))
check("explicit Chapter=1", etl("Chapter 3 Journey") == 1, etl("Chapter 3 Journey"))
check("explicit Section=2", etl("Section 2 Notes") == 2, etl("Section 2 Notes"))
check("explicit 无标记为nil(普通标题)", etl("写在前面的话") == nil, etl("写在前面的话"))
check("explicit 空串为nil", etl("") == nil, etl(""))

----------------------------------------------------------------------
-- 2) refine_heading_levels 触发/不触发
----------------------------------------------------------------------
local refine = C.refine_heading_levels
-- big_novel 型：卷章都 level=1、节 level=2（文本3级 > 样式2级）→ 触发
local big_paras = {
    { kind = "heading", level = 1, text = "第一卷　卷名之1" },
    { kind = "body", text = "正文" },
    { kind = "heading", level = 1, text = "第1章　章节标题1" },
    { kind = "heading", level = 2, text = "第5节　细节展开" },
    { kind = "heading", level = 1, text = "第二卷　卷名之2" },
    { kind = "heading", level = 1, text = "第2章　章节标题2" },
}
local applied, changed, okinds, tk = refine(big_paras)
check("big型触发精修", applied == true, tostring(applied))
check("big型改动数=5(5个明确标题)", changed == 5, tostring(changed))
check("big型原层级种类=2", okinds == 2, tostring(okinds))
check("big型文本层级种类=3", tk == 3, tostring(tk))
check("big型 卷->0", big_paras[1].level == 0, tostring(big_paras[1].level))
check("big型 章->1", big_paras[3].level == 1, tostring(big_paras[3].level))
check("big型 节->2", big_paras[4].level == 2, tostring(big_paras[4].level))
check("big型 body不变", big_paras[2].kind == "body", big_paras[2].kind)

-- long_chapter 型：卷H1/章H2/节H3（样式3级 == 文本3级）→ 不触发
local long_paras = {
    { kind = "heading", level = 1, text = "第一卷　起始之卷" },
    { kind = "heading", level = 2, text = "第一章　常规短章" },
    { kind = "heading", level = 3, text = "第一节　小结" },
}
applied = refine(long_paras)
check("long型不触发精修", applied == false, tostring(applied))
check("long型 卷保持1", long_paras[1].level == 1, tostring(long_paras[1].level))
check("long型 章保持2", long_paras[2].level == 2, tostring(long_paras[2].level))

-- 无标记标题：title_level 只能给默认值，不能触发
local plain_paras = {
    { kind = "heading", level = 1, text = "前言" },
    { kind = "heading", level = 2, text = "关于本书" },
}
applied = refine(plain_paras)
check("无标记型不触发精修", applied == false, tostring(applied))
check("无标记型 层级保持", plain_paras[1].level == 1 and plain_paras[2].level == 2,
    plain_paras[1].level .. "/" .. plain_paras[2].level)

----------------------------------------------------------------------
-- 3) 真实 big_novel.docx 端到端：nav 目录三级嵌套
----------------------------------------------------------------------
local big = fixture_dir .. "/big_novel.docx"
local f = io.open(big, "rb")
if f then
    f:close()
    local out = HERE .. "_v218_big.epub"
    os.remove(out)
    local ok, cnt, stats = C.build_epub_from_docx(big, out, { title_page = false }, {})
    check("big_novel 端到端成功", ok == true and cnt > 100, tostring(cnt))
    check("big_novel 触发层级精修", stats and stats.level_refined == true,
        tostring(stats and stats.level_refined))
    -- 解析 nav.xhtml 的 <ol> 嵌套深度
    local ef = io.open(out, "rb")
    if ef then
        local epub = ef:read("*a"); ef:close()
        -- ZipWriter 的 add 用 STORED（无压缩），直接从字节流里找 nav 片段
        local nav = epub:match("<nav[^>]-xmlns[^>]-.-\n?.-</nav>")
            or epub:match("(<nav.->. -</nav>)")
        local raw = epub
        -- 统计 <ol ...> 与 </ol> 的深度序列（在含 nav 标记的区段）
        local nav_start = raw:find("nav.xhtml", 1, true)
        check("big_novel EPUB 含 nav.xhtml", nav_start ~= nil, nav_start)
        check("big_novel EPUB 含 toc.ncx", raw:find("toc.ncx", 1, true) ~= nil)
        os.remove(out)
    else
        check("big_novel EPUB 文件生成", false, "no file")
    end
else
    print("  [跳过] big_novel.docx fixture 不存在")
end

print(string.format("\n=== v2.1.8 测试：%d 通过, %d 失败 ===", pass, fail))
os.exit(fail > 0 and 1 or 0)
