-- test_regress.lua
-- 本轮「根据测试查找 bug」的回归锁定，覆盖 3 个此前测试全绿却真机/大文件翻车的问题：
--   1) docx.lua 数字字符实体解码用了 Lua 5.3 才有的 utf8.char，
--      KOReader 真机是 LuaJIT（无 utf8 库）-> 含 &#20013; 的 Word 文档转换直接抛错；
--      且超范围码点在 Lua 5.3 上也抛 "value out of range"。
--   2) 单个超长段落（Word 里一整章不分段）绕过 256KB 切分，产出 500KB+ 单章 XHTML。
--   3) DOM 兜底路径无 </p> 边界时 split_html_at_p 切分失效。
--
-- 全部样本自包含生成（纯 Lua 写 STORED 版 docx，无需外部 fixture / 无需 zlib），
-- 因此 Lua 5.3 与 LuaJIT（真机解释器）都能完整跑通。
-- 用法：lua5.3 test/test_regress.lua   /   luajit test/test_regress.lua

local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path

local DocxReader = require("docx")
local Converter = require("converter")

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print(string.format("[PASS] %s", name))
    else fails = fails + 1; print(string.format("[FAIL] %s  %s", name, extra or "")) end
end

----------------------------------------------------------------------
-- 纯 Lua 生成 STORED 版 .docx（ZIP 容器，method=0；DocxReader 不校验 CRC）
----------------------------------------------------------------------
local function le16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function make_stored_docx(path, xml)
    local name = "word/document.xml"
    local data = xml
    local lfh = string.char(0x50, 0x4b, 0x03, 0x04)   -- local file header
        .. le16(20) .. le16(0) .. le16(0)               -- version, flags, method(0=STORED)
        .. le16(0) .. le16(0)                           -- modtime, moddate
        .. le32(0) .. le32(#data) .. le32(#data)        -- crc(不校验), comp, uncomp
        .. le16(#name) .. le16(0) .. name .. data
    local cd = string.char(0x50, 0x4b, 0x01, 0x02)     -- central directory
        .. le16(20) .. le16(20) .. le16(0) .. le16(0)
        .. le16(0) .. le16(0)
        .. le32(0) .. le32(#data) .. le32(#data)
        .. le16(#name) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
        .. le32(0) .. le32(0) .. name
    local eocd = string.char(0x50, 0x4b, 0x05, 0x06)
        .. le16(0) .. le16(0) .. le16(1) .. le16(1)
        .. le32(#cd) .. le32(#lfh) .. le16(0)
    local f = assert(io.open(path, "wb")); f:write(lfh, cd, eocd); f:close()
end

----------------------------------------------------------------------
-- 1) 数字字符实体（真机 LuaJIT 无 utf8 库）
----------------------------------------------------------------------
print("\n---- [1] 数字字符实体解码 ----")
local entity_xml = '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'
    .. '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>&#x7B2C;&#19968;&#31456;</w:t></w:r></w:p>'
    .. '<w:p><w:r><w:t>&#20013;&#25991; &#65; &#x1F600; &#x110000; &#99999999999;</w:t></w:r></w:p>'
    .. '<w:p><w:r><w:t>&amp; &lt; &gt; &quot; &apos;</w:t></w:r></w:p>'
    .. '</w:body></w:document>'
local eok, eps = pcall(DocxReader.parse_document_xml, entity_xml)
check("含数字实体的 XML 解析不抛错（关键：LuaJIT 下）", eok, tostring(eps))
if eok then
    check("十进制/十六进制实体正确解码为「第一章」", eps[1].text == "第一章", tostring(eps[1].text))
    check("中文/ASCII/4 字节 emoji 均正确", eps[2].text:find("中文 A", 1, true) ~= nil
        and eps[2].text:find("\240\159\152\128", 1, true) ~= nil, tostring(eps[2].text))
    check("超范围(0x110000)/巨大值(99999999999) 安全降级为 U+FFFD",
        eps[2].text:find("\239\191\189", 1, true) ~= nil, tostring(eps[2].text))
    check("命名实体仍正确解码", eps[3].text == '& < > " \'', tostring(eps[3].text))
    check("标题层级不受实体影响", eps[1].kind == "heading" and eps[1].level == 1)
end

-- 端到端：把含数字实体的 XML 装成真 docx 再转换，确保整条链路在 LuaJIT 下也通
local ent_path = "/tmp/test_regress_entity.docx"
make_stored_docx(ent_path, entity_xml)
local edok, ederr = DocxReader.read(ent_path)
check("端到端读取含数字实体的 docx 不抛错", edok ~= nil, tostring(ederr))
if edok then
    check("读出的段落文本已正确解码", edok.paragraphs[1].text == "第一章", tostring(edok.paragraphs[1].text))
    local eout = "/tmp/test_regress_entity.epub"; os.remove(eout)
    local ebok, ebres = pcall(Converter.build_epub_from_docx, ent_path, eout, { book_title = "实体测试" })
    check("端到端生成 EPUB 成功", ebok and ebres ~= false, tostring(ebres))
end
os.remove(ent_path); os.remove("/tmp/test_regress_entity.epub")

----------------------------------------------------------------------
-- 2) 单个超长段落 -> 必须被切分成多个 <300KB 的 XHTML
----------------------------------------------------------------------
print("\n---- [2] 单段超长切分（Kindle OOM/重启诱因）----")
local big = string.rep("这是没有分段的超长正文内容，用于验证单段超大时章节切分是否生效。", 6000)
local single_xml = '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'
    .. '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>单段测试书</w:t></w:r></w:p>'
    .. '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章 全部内容</w:t></w:r></w:p>'
    .. '<w:p><w:r><w:t>' .. big .. '</w:t></w:r></w:p>'
    .. '</w:body></w:document>'
local sp_path = "/tmp/test_regress_single.docx"
make_stored_docx(sp_path, single_xml)
local sdok, sderr = DocxReader.read(sp_path)
check("单段超长 docx 可读取", sdok ~= nil, tostring(sderr))
if sdok then
    local max_para = 0
    for _, p in ipairs(sdok.paragraphs) do if #p.text > max_para then max_para = #p.text end end
    check("样本确含 >256KB 的单段", max_para > 256 * 1024, tostring(max_para))
end
local sout = "/tmp/test_regress_single.epub"; os.remove(sout)
local sbok, sres, scnt = pcall(Converter.build_epub_from_docx, sp_path, sout, { book_title = "单段测试书" })
check("单段超长转换不 panic", sbok and sres ~= false, tostring(sres))
if sbok and sres ~= false then
    check("章节文件数 > 1（切分生效）", (scnt or 0) > 1, tostring(scnt))
    local tmp = "/tmp/test_regress_single_unzip"
    os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
    os.execute("cd " .. tmp .. " && unzip -o -q " .. sout .. " >/dev/null 2>&1")
    local p = io.popen("ls -l " .. tmp .. "/OEBPS/chapter_*.xhtml 2>/dev/null | awk '{print $5}' | sort -rn | head -1")
    local maxsz = tonumber(p:read("*a"):match("%d+") or "0"); p:close()
    print(string.format("    最大章节文件 %d 字节", maxsz))
    check("单章 XHTML < 300KB（不再产出 500KB+ 单文件）", maxsz > 0 and maxsz < 300 * 1024, tostring(maxsz))
    -- 正文完整性：切分不能丢内容
    local g = io.popen("cat " .. tmp .. "/OEBPS/chapter_*.xhtml | grep -o '这是没有分段的超长正文内容' | wc -l")
    local hits = tonumber(g:read("*a"):match("%d+") or "0"); g:close()
    print(string.format("    正文片段命中 %d 次", hits))
    check("超长正文完整保留（未丢失）", hits >= 5900, tostring(hits))
    -- 所有分片 UTF-8 合法（不切在汉字中间）：用 iconv 校验
    local ic = os.execute("cat " .. tmp .. "/OEBPS/chapter_*.xhtml | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1")
    check("切分点未破坏 UTF-8（所有分片合法）", ic == 0 or ic == true, tostring(ic))
    os.execute("rm -rf " .. tmp)
end
os.remove(sp_path); os.remove(sout)

----------------------------------------------------------------------
-- 3) DOM 兜底：无 </p> 边界的超长 raw_html 也要被切分
----------------------------------------------------------------------
print("\n---- [3] DOM 路径无 </p> 边界时的二次切分 ----")
local no_p_html = "<div>" .. string.rep("没有p边界的长文本内容ABC", 30000) .. "</div>"  -- ~1MB，无 </p>
local dom_api = {
    title = "无边界测试",
    toc = { { text = "唯一一章", depth = 1, pos0 = "XP0", pos1 = "XPEND" } },
    get_html = function() return no_p_html end,
}
local dout = "/tmp/test_regress_dom.epub"; os.remove(dout)
local dbok, dres, dcnt = pcall(Converter.build_epub_from_document, dom_api, dout, { book_title = "无边界测试" })
check("无 </p> 边界的大 HTML 转换不 panic", dbok and dres ~= false, tostring(dres))
if dbok and dres ~= false then
    check("无 </p> 边界时也被切成多个分片", (dcnt or 0) > 1, tostring(dcnt))
    local tmp = "/tmp/test_regress_dom_unzip"
    os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
    os.execute("cd " .. tmp .. " && unzip -o -q " .. dout .. " >/dev/null 2>&1")
    local p = io.popen("ls -l " .. tmp .. "/OEBPS/chapter_*.xhtml 2>/dev/null | awk '{print $5}' | sort -rn | head -1")
    local maxsz = tonumber(p:read("*a"):match("%d+") or "0"); p:close()
    print(string.format("    DOM 路径最大章节文件 %d 字节", maxsz))
    check("DOM 路径单章 < 300KB", maxsz > 0 and maxsz < 300 * 1024, tostring(maxsz))
    os.execute("rm -rf " .. tmp)
end
os.remove(dout)

----------------------------------------------------------------------
-- 4) 畸形 / 截断 .docx：必须返回明确错误，不得抛 Lua 异常
----------------------------------------------------------------------
print("\n---- [4] 畸形 / 截断 docx 的健壮性 ----")
local function write_raw(path, s) local f = io.open(path, "wb"); f:write(s); f:close() end
local malformed = {
    { name = "空文件", data = "" },
    { name = "随机字节", data = "\1\2\3\4not a zip\5\6\7" },
    { name = "只有 EOCD 签名", data = string.char(0x50, 0x4b, 0x05, 0x06) },
    { name = "EOCD 后面字段全截断", data = string.char(0x50, 0x4b, 0x05, 0x06) .. string.rep("\0", 10) },
    { name = "EOCD 声称大量条目", data = string.char(0x50, 0x4b, 0x05, 0x06)
        .. string.rep("\0", 8) .. le16(500) .. le32(1000) .. le32(0) .. le32(0) .. le16(0) },
}
for _, m in ipairs(malformed) do
    local p = "/tmp/test_regress_bad.docx"
    write_raw(p, m.data)
    local ok, res, err = pcall(DocxReader.read, p)
    check("畸形文件不抛异常：" .. m.name, ok, tostring(res))
    if ok then
        check("畸形文件返回 (nil, 明确错误)：" .. m.name, res == nil and type(err) == "string",
            "res=" .. tostring(res) .. " err=" .. tostring(err))
    end
end
os.remove("/tmp/test_regress_bad.docx")
-- 正常文件不受影响（回归）
local normal = "/tmp/test_regress_normal.docx"
make_stored_docx(normal, '<w:document xmlns:w="x"><w:body><w:p><w:r><w:t>正文</w:t></w:r></w:p></w:body></w:document>')
local nres, nerr = DocxReader.read(normal)
check("合法 docx 仍正常读取（健壮性改动无回归）", type(nres) == "table"
    and nres.paragraphs[1].text == "正文", tostring(nerr))
os.remove(normal)

print(string.format("\n=== test_regress：%d 通过, %d 失败 ===", passes, fails))
os.exit(fails == 0 and 0 or 1)
