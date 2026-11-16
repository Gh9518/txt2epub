-- 回归：TXT 标题模式下「无标题 + 末尾无空行」正文不得被静默丢弃。
-- 历史缺陷：leading 只在遇到空行时 flush_into()，循环结束缺收尾 flush，
-- 整本是一行 744KB 纯正文的样本只产出 358 字节空章（目录/zip 校验却全过）。
-- 本测试用「正文字符守恒 + 特征短语」验证，不依赖目录条数。
package.path = "/workspace/txt2epub.koplugin/?.lua;" .. package.path
local C = require("converter")

local TMP = "/tmp/t2e_notitle_flush"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP)
local pass, fail = 0, 0
local function ck(name, cond, extra)
    if cond then
        pass = pass + 1
        print("[PASS] " .. name)
    else
        fail = fail + 1
        print("[FAIL] " .. name .. (extra and ("  " .. tostring(extra)) or ""))
    end
end
local function sh(cmd)
    local p = io.popen(cmd)
    local s = p and p:read("*a") or ""
    if p then p:close() end
    return (s:gsub("%s+$", ""))
end
local function write(path, s)
    local f = assert(io.open(path, "wb")); f:write(s); f:close()
end
-- 拼接所有章节 XHTML 的纯文本（测试正文均为纯中文，无 XML 实体干扰）
local function epub_body(out)
    local p = io.popen("unzip -p '" .. out .. "' 'OEBPS/chapter_*.xhtml' 2>/dev/null")
    local s = p and p:read("*a") or ""
    if p then p:close() end
    return (s:gsub("<[^>]+>", ""))
end
local function max_chapter(out)
    return tonumber(sh("unzip -l '" .. out .. "' 2>/dev/null | grep OEBPS/chapter_ | awk '{print $1}' | sort -rn | head -1")) or 0
end
local function zipok(out)
    return sh("unzip -t '" .. out .. "' >/dev/null 2>&1; echo $?") == "0"
end
local function convert(name, content, book)
    local src = TMP .. "/" .. name .. ".txt"
    local out = TMP .. "/" .. name .. ".epub"
    write(src, content)
    os.remove(out)
    local ok, cnt = C.build_epub_streaming(C.lines(src), "title", nil,
        book or name, out, { indent = "2em" })
    C.release_lines(src)
    return ok, cnt, out
end

----------------------------------------------------------------------
print("== 1. 单行超长无标题（整本一行、末尾无换行）==")
local BIG = string.rep("这是没有任何章节标题的纯正文用于验证收尾刷新是否正确。", 8000)
local ok1, cnt1, out1 = convert("single_line_big", BIG)
ck("转换返回 true", ok1 == true)
ck("EPUB zip 合法", zipok(out1))
ck("分片数 > 1（触发 256KB 切分）", cnt1 ~= nil and cnt1 > 1, "chapters=" .. tostring(cnt1))
local body1 = epub_body(out1)
local cn1 = 0
for _ in body1:gmatch("[\228-\233][\128-\191][\128-\191]") do cn1 = cn1 + 1 end
-- 源中文字符数：模板 27 字 × 8000
local src_cn = 0
for _ in BIG:gmatch("[\228-\233][\128-\191][\128-\191]") do src_cn = src_cn + 1 end
ck("正文中文字符守恒（零丢失）", cn1 >= src_cn,
   "源=" .. src_cn .. " 输出=" .. cn1)
ck("特征短语存在", body1:find("用于验证收尾刷新是否正确", 1, true) ~= nil)
ck("单章 XHTML < 256KB", max_chapter(out1) < 256 * 1024,
   "最大=" .. max_chapter(out1) .. " 字节")

----------------------------------------------------------------------
print("== 2. 多行无标题、末尾无空行 ==")
local ok2, _, out2 = convert("multi_no_trailing_blank",
    "第一段纯正文甲。\n第二段纯正文乙。\n第三段纯正文丙。")
ck("转换返回 true", ok2 == true)
local body2 = epub_body(out2)
ck("三段正文全部保留",
   body2:find("第一段纯正文甲", 1, true) ~= nil and
   body2:find("第二段纯正文乙", 1, true) ~= nil and
   body2:find("第三段纯正文丙", 1, true) ~= nil,
   body2:sub(1, 120))

----------------------------------------------------------------------
print("== 3. 多行无标题、末尾有空行（旧路径护栏）==")
local ok3, _, out3 = convert("multi_with_blank",
    "起首段落甲。\n中间段落乙。\n末尾段落丙。\n\n")
ck("转换返回 true", ok3 == true)
local body3 = epub_body(out3)
ck("末尾段落仍保留",
   body3:find("起首段落甲", 1, true) ~= nil and
   body3:find("末尾段落丙", 1, true) ~= nil)

----------------------------------------------------------------------
print("== 4. 有标题、末尾无空行（确认未受影响）==")
local ok4, cnt4, out4 = convert("titled_no_blank",
    "第一章　开端\n这是第一章的正文段落甲。\n这是第一章的正文段落乙。\n第二章　收尾\n这是第二章的正文段落丙。")
ck("转换返回 true", ok4 == true)
ck("章节数 = 2", cnt4 == 2, "chapters=" .. tostring(cnt4))
local body4 = epub_body(out4)
ck("两章正文均保留（末章末尾无空行）",
   body4:find("这是第一章的正文段落乙", 1, true) ~= nil and
   body4:find("这是第二章的正文段落丙", 1, true) ~= nil,
   body4:sub(1, 160))

----------------------------------------------------------------------
print("== 5. 空文件 / 纯空行不崩溃 ==")
local ok5, cnt5, out5 = convert("empty", "")
ck("空文件返回 true 且生成 1 章", ok5 == true and cnt5 == 1,
   "ok=" .. tostring(ok5) .. " chapters=" .. tostring(cnt5))
ck("空文件 EPUB zip 合法", zipok(out5))
local ok6, cnt6, out6 = convert("only_blank", "\n\n\n")
ck("纯空行文件返回 true", ok6 == true, "chapters=" .. tostring(cnt6))
ck("纯空行 EPUB zip 合法", zipok(out6))

----------------------------------------------------------------------
print("== 6. 无解码临时文件残留 ==")
ck("release_lines 后临时文件已清理",
   io.open(TMP .. "/.txt2epub_decode.tmp", "rb") == nil)

----------------------------------------------------------------------
print(string.format("\n===== 无标题正文收尾刷新回归：%d 通过 / %d 失败 =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
