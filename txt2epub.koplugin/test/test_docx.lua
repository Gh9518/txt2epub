-- test/test_docx.lua
-- Word(.docx) -> EPUB 转换的单元 + 集成测试。
-- 运行：lua5.3 test/test_docx.lua   （在插件根目录执行）
--
-- 覆盖：
--   1) 纯 XML 解析：parse_document_xml 正确识别 Title/Heading1/Heading2 层级与正文、解码实体
--   2) ZIP 读取（STORED 样本）：DocxReader.read 全流程，书名/段落正确
--   3) 端到端：build_epub_from_docx 生成合法 EPUB，含多级嵌套目录（Stored 样本，无需 zlib）
--   4) （仅设备上）DEFALTE 样本：若 ffi/zlib 可用则用真实解压；沙箱无 zlib 时跳过

local plugin_dir = arg and arg[0] and arg[0]:match("(.*/)") or "./"
if plugin_dir == "" then plugin_dir = "./" end
package.path = package.path .. ";" .. plugin_dir .. "?.lua" .. ";" .. plugin_dir .. "../?.lua"
package.path = package.path .. ";./?.lua"

local Converter = require("converter")
local DocxReader = require("docx")

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

local function fixture(name)
    return plugin_dir .. "fixtures/" .. name
end

------------------------------------------------------------------------
-- 用例 1：XML 解析（直接喂抽取出的 document.xml，绕开 ZIP，专注解析逻辑）
------------------------------------------------------------------------
local xml = io.open(fixture("sample_document.xml"), "r"):read("*a")
local paras = DocxReader.parse_document_xml(xml)
check("段落总数 = 12", #paras == 12, "got " .. #paras)

-- 第 1 段：Title -> level 1
check("第1段为标题且层级=1 (Title)", paras[1].kind == "heading" and paras[1].level == 1,
    tostring(paras[1].kind) .. "/" .. tostring(paras[1].level))
check("Title 文本=测试小说书名", paras[1].text == "测试小说书名", paras[1].text)
-- 第 2 段：Heading1 -> 1
check("第2段 Heading1 层级=1", paras[2].kind == "heading" and paras[2].level == 1, tostring(paras[2].level))
check("第2段文本=第一章 风起", paras[2].text == "第一章 风起", paras[2].text)
-- 第 3 段：正文
check("第3段为 body", paras[3].kind == "body", tostring(paras[3].kind))
check("正文含英文与数字", paras[3].text:find("ABC") and paras[3].text:find("123"), paras[3].text)
-- 第 7 段：Heading2 -> 2（第一节 细节，隶属第二章）
check("第7段 Heading2 层级=2", paras[7].kind == "heading" and paras[7].level == 2, tostring(paras[7].level))
-- 第 10 段：特殊字符转义
check("末章正文实体解码 & < >", paras[10].text:find("& 特殊字符 < 与 > 需要正确转义。") ~= nil, paras[10].text)

------------------------------------------------------------------------
-- 用例 2：STORED 样本全流程读取（不依赖 zlib，沙箱可跑）
------------------------------------------------------------------------
local doc, derr = DocxReader.read(fixture("sample_stored.docx"))
check("读取 STORED docx 成功", doc ~= nil, tostring(derr))
if doc then
    check("书名取自 core.xml = 测试小说书名", doc.title == "测试小说书名", tostring(doc.title))
    check("段落数 = 12", #doc.paragraphs == 12, tostring(#doc.paragraphs))
    check("首段为标题", doc.paragraphs[1].kind == "heading")
    check("Heading2 段存在", (function()
        for _, p in ipairs(doc.paragraphs) do
            if p.kind == "heading" and p.level == 2 then return true end
        end
        return false
    end)())
end

------------------------------------------------------------------------
-- 用例 3：端到端生成 EPUB（STORED 样本）
------------------------------------------------------------------------
local out = "/tmp/test_docx_out.epub"
os.remove(out)
    local ok, _, cnt = pcall(Converter.build_epub_from_docx, fixture("sample_stored.docx"), out, {
        indent = "2em", style = "standard", book_title = "测试小说书名",
    })
check("build_epub_from_docx 成功", ok, tostring(cnt))
if ok then
    check("章节文件数 = 5（Title 作为书名不单独成章）", cnt == 5, tostring(cnt))
    -- 校验 EPUB 结构
    local f = io.open(out, "rb")
    local head = f:read(4)
    f:close()
    check("输出是合法 ZIP（PK 头）", head == "PK\3\4", tostring(head))

    -- 抽取 nav.xhtml 验证多级嵌套（Heading1 下含 Heading2 子列表）
    local tmp = "/tmp/test_docx_unzip"
    os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
    os.execute("cd " .. tmp .. " && unzip -o -q " .. out .. " >/dev/null 2>&1")
    local nav = io.open(tmp .. "/OEBPS/nav.xhtml", "r")
    if nav then
        local navx = nav:read("*a"); nav:close()
        local h1 = select(2, navx:gsub("<li><a href=\"chapter_0001", ""))
        check("nav 含首章链接", h1 >= 1)
        -- 嵌套：Heading2（第一节）应在 Heading1（第二章）的 <ol> 内
        check("nav 出现嵌套 <ol>（多级目录）", navx:find("<ol>.-<ol>") ~= nil)
        check("nav 出现 Heading2 文本“第一节”", navx:find("第一节") ~= nil)
    else
        check("nav.xhtml 存在", false)
    end
end

------------------------------------------------------------------------
-- 用例 4：DEFALTE 样本（需 ffi/zlib；沙箱无 zlib 时跳过）
------------------------------------------------------------------------
local has_zlib = false
local okz, zlib = pcall(require, "ffi/zlib")
if okz and zlib and zlib.zlib_uncompress then has_zlib = true end
if has_zlib then
    local d2, e2 = DocxReader.read(fixture("sample.docx"))
    check("读取 DEFLATE docx 成功（真机 zlib）", d2 ~= nil, tostring(e2))
    if d2 then
        os.remove(out)
        local ok2, _, cnt2 = pcall(Converter.build_epub_from_docx, fixture("sample.docx"), out, {
            indent = "2em", style = "standard", book_title = "测试小说书名",
        })
        check("DEFLATE 端到端生成 EPUB", ok2, tostring(cnt2))
    end
else
    print("[SKIP] DEFLATE 样本：当前环境无 ffi/zlib（真机 KOReader 自带，发布后自动生效）")
end

------------------------------------------------------------------------
print(string.format("\n=== docx 测试：%d 通过, %d 失败 ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
