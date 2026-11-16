-- 征集测试样本端到端验证：逐文件调用插件自解析路径生成 EPUB。
-- 用法：lua5.3 test/fixtures/verify_testfiles.lua
-- 输出：/tmp/t2e_verify_result.tsv 与 /tmp/t2e_verify_epub/<n>.epub
-- 之后由 build_test_list.py 回填 TEST_LIST.csv。
package.path = "/workspace/txt2epub.koplugin/?.lua;" .. package.path

local C = require("converter")
local ROOT = "/workspace/txt2epub_testfiles_v2.1.0"
local OUTDIR = "/tmp/t2e_verify_epub"
local RESULT = "/tmp/t2e_verify_result.tsv"

os.execute("rm -rf " .. OUTDIR .. " && mkdir -p " .. OUTDIR)

local function tsv(line)
    local t = {}
    for p in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = p end
    return t
end

local mf = assert(io.open(ROOT .. "/manifest.tsv", "r"), "manifest.tsv 缺失")
mf:read("*l") -- header
local rf = assert(io.open(RESULT, "w"), "无法写结果文件")
rf:write("rel\tfmt\tstatus\tchapters\terr\tepub\n")

local idx = 0
local tally = { OK = 0, FAIL = 0, DOM = 0 }
for line in mf:lines() do
    if line ~= "" then
        local t = tsv(line)
        local rel, fmt = t[1], t[3]
        idx = idx + 1
        local path = ROOT .. "/" .. rel
        local out = OUTDIR .. "/" .. idx .. ".epub"
        local book = (rel:match("([^/]+)$") or "sample"):gsub("%.[^%.]+$", "")
        local status, chapters, err, epub = "DOM", "0", "", ""

        if fmt == "txt" then
            local ok, a, b = pcall(function()
                local it = C.lines(path)
                return C.build_epub_streaming(it, "title", nil, book, out, { indent = "2em" })
            end)
            if ok then
                status = (a == true) and "OK" or "FAIL"
                chapters = tostring(b or 0)
                if a ~= true then err = tostring(b):gsub("[\r\n]", " "):sub(1, 120) end
            else
                status, err = "FAIL", tostring(a):gsub("[\r\n]", " "):sub(1, 160)
            end
        elseif fmt == "md" or fmt == "markdown" or fmt == "html" or fmt == "htm" then
            local ok, a, b = pcall(C.build_epub_from_markup, path, out, { book_title = book })
            if ok then
                status = (a == true) and "OK" or "FAIL"
                chapters = tostring(b or 0)
                if a ~= true then err = tostring(b):gsub("[\r\n]", " "):sub(1, 120) end
            else
                status, err = "FAIL", tostring(a):gsub("[\r\n]", " "):sub(1, 160)
            end
        elseif fmt == "docx-DEFLATE" or fmt == "docx-STORED" then
            local ok, a, b = pcall(C.build_epub_from_docx, path, out, { book_title = book })
            if ok then
                status = (a == true) and "OK" or "FAIL"
                chapters = tostring(b or 0)
                if a ~= true then err = tostring(b):gsub("[\r\n]", " "):sub(1, 120) end
            else
                status, err = "FAIL", tostring(a):gsub("[\r\n]", " "):sub(1, 160)
            end
        elseif fmt == "docx-broken" then
            -- 畸形 docx：要求 DocxReader.read 返回明确错误而不是抛未捕获异常
            local okR, D = pcall(require, "docx")
            if okR and D then
                local ok, doc, msg = pcall(D.read, path)
                if ok and doc == nil then
                    status, err = "OK", "明确报错：" .. tostring(msg):gsub("[\r\n]", " "):sub(1, 100)
                elseif ok then
                    status, err = "FAIL", "畸形文件竟被当作有效 docx 读入"
                else
                    status, err = "FAIL", "未捕获异常：" .. tostring(doc):gsub("[\r\n]", " "):sub(1, 120)
                end
            else
                status, err = "FAIL", "docx 模块加载失败"
            end
        end

        if status ~= "DOM" then
            local f = io.open(out, "rb")
            if f then
                local sz = f:seek("end")
                f:close()
                if sz and sz > 0 then epub = out end
            end
        end
        tally[status] = (tally[status] or 0) + 1
        rf:write(string.format("%s\t%s\t%s\t%s\t%s\t%s\n",
            rel, fmt, status, chapters, err, epub))
        io.write(string.format("[%s] %-46s %-14s chapters=%s %s\n",
            status, rel, fmt, chapters, err ~= "" and ("| " .. err) or ""))
    end
end
rf:close()
mf:close()
print(string.format("\n=== 合计 %d 个文件：OK %d / FAIL %d / DOM(仅真机) %d ===",
    idx, tally.OK or 0, tally.FAIL or 0, tally.DOM or 0))
