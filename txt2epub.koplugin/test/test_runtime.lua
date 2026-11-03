-- test_runtime.lua
-- 用最小 KOReader 运行桩，模拟"点击 开始转换"后从 main.lua 进入的真实执行路径：
--   convert() -> _check_title_and_run() -> _run() -> nextTick 回调 -> _do_convert() -> Converter.build_epub()
-- 目标：捕捉转换路径上任何运行时错误（非 panic 的 Lua error 或真正的 panic）。
--
-- 用法：lua5.3 test/test_runtime.lua

local passes, fails = 0, 0
local function check(name, cond, extra)
    if cond then
        passes = passes + 1
        print(string.format("[PASS] %s", name))
    else
        fails = fails + 1
        print(string.format("[FAIL] %s  %s", name, extra or ""))
    end
end

----------------------------------------------------------------------
-- 最小 KOReader 运行桩
----------------------------------------------------------------------
local captured = {}   -- 记录 UIManager:show 传入的 widget
local closed = {}     -- 记录 UIManager:close 传入的 widget（用于验证旧进度框被关闭、不残留）
local next_tick_queue = {}

-- gettext
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })

-- logger / dbg
package.loaded["logger"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["dbg"] = { dassert = function(c, m) assert(c, m) end }

-- device（reader_menu_order fixture 可能用到，这里不加载它）
package.loaded["device"] = setmetatable({}, { __index = function() return function() return false end end })

-- ffi/util
-- 注意：故意不提供 fileExists，以模拟真实 KOReader 环境中该函数不存在的情况，
-- 从而验证插件不再依赖 util.fileExists（历史版本曾因此 panic 崩溃）。
package.loaded["ffi/util"] = {
    basename = function(p) return (string.gsub(p, "^.*/", "")) end,
    dirname  = function(p) return (string.gsub(p, "/[^/]*$", "")) end,
    joinPath = function(a, b) return a .. "/" .. b end,
    -- 保留可能的其它引用
    orderedPairs = function(t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local i = 0
        return function() i = i + 1; if keys[i] ~= nil then return keys[i], t[keys[i]] end end
    end,
}

-- ui/widget/container/widgetcontainer
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(o)
        o = o or {}
        local cls = {}
        setmetatable(cls, { __index = o })
        cls.__index = cls
        cls.new = function(_, attr)
            local inst = {}
            if type(attr) == "table" then
                for k, v in pairs(attr) do
                    if inst[k] == nil then inst[k] = v end
                end
            end
            setmetatable(inst, { __index = cls })
            inst.__index = cls
            if inst.init then inst:init() end
            return inst
        end
        return cls
    end,
}

-- ui/uimanager：nextTick 改为入队（模拟真实 UI 节拍中“下一轮才执行”）；
-- 借助 drain_next_ticks 在测试里把队列跑完，从而完整执行协程版转换路径。
-- 若协程内或 nextTick 回调里发生 panic（真实环境会整体崩溃退出），这里会如实报错。
local next_tick_queue = {}
local next_tick_count = 0   -- 统计 nextTick 被入队次数（用于验证“逐章让出 UI”）
local UI = {
    show = function(_, w)
        captured[#captured + 1] = w
        return w
    end,
    close = function(_, w)
        if w ~= nil then closed[#closed + 1] = w end
    end,
    nextTick = function(_, fn)
        next_tick_count = next_tick_count + 1
        next_tick_queue[#next_tick_queue + 1] = fn
    end,
}
-- 模拟真实 UIManager 主循环：逐个取出 nextTick 任务执行（用 pcall 捕捉 panic）。
-- 协程版 _run 会在每写完一个章节后再次 nextTick(step)，故循环会持续推进直至协程结束。
local function drain_next_ticks()
    local guard = 0
    while #next_tick_queue > 0 do
        guard = guard + 1
        if guard > 1000000 then error("nextTick 队列未收敛（疑似死循环）") end
        local fn = table.remove(next_tick_queue, 1)
        local ok, err = pcall(fn)
        if not ok then
            error("nextTick 回调 panic（即真实环境会整体崩溃）: " .. tostring(err))
        end
    end
end

local InfoMessage = { new = function(_, o) o = o or {}; o._type = "InfoMessage"; return o end }
local ConfirmBox = {
    new = function(_, o)
        o = o or {}
        o._type = "ConfirmBox"
        o._run_ok = function() if o.ok_callback then o.ok_callback() end end
        o._run_cancel = function() if o.cancel_callback then o.cancel_callback() end end
        o._run_other = function(i) if o.other_buttons and o.other_buttons[i] then o.other_buttons[i].callback() end end
        return o
    end,
}
local InputDialog = {
    new = function(_, o)
        o = o or {}
        o._type = "InputDialog"
        o.getInputValue = function() return o._value or o.input or "" end
        return o
    end,
}
package.loaded["ui/uimanager"] = UI
package.loaded["ui/widget/infomessage"] = InfoMessage
package.loaded["ui/widget/confirmbox"] = ConfirmBox
package.loaded["ui/widget/inputdialog"] = InputDialog

-- G_reader_settings（桩：独立存储表，避免 upvalue / self 歧义）
local __store = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return __store[k] end,
    saveSetting = function(_, k, v) __store[k] = v end,
}

----------------------------------------------------------------------
-- 加载插件（与插件目录同级的 converter.lua）
----------------------------------------------------------------------
local here = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local root = here:gsub("test/", "")
package.path = root .. "?.lua;" .. package.path

local ok_load, TXT2EPUB = pcall(require, "main")
check("main.lua 可被加载（无加载期错误）", ok_load, tostring(TXT2EPUB))

----------------------------------------------------------------------
-- 构造实例 + 测试文件
----------------------------------------------------------------------
local inst = TXT2EPUB:new({ ui = { menu = { registerToMainMenu = function() end }, document = { file = "/x/书.txt" } } })

-- 准备测试 TXT（标题模式 + 缩进模式）
local tmpdir = os.tmpname():gsub("[^/]*$", "")
os.execute('mkdir -p /tmp/t2e_test')
local title_txt = "/tmp/t2e_test/标题小说.txt"
local indent_txt = "/tmp/t2e_test/缩进大纲.txt"
local fh = io.open(title_txt, "w")
fh:write("书名：江湖夜雨\n\n第一章 风起\n\n第一段正文。\n第二段。\n\n第二章 云涌\n\n第三章内容。\n")
fh:close()
local fh2 = io.open(indent_txt, "w")
fh2:write("第3章 剑客\n    3.1 初入江湖\n        3.1.1 少年离家\n    3.2 学艺\n第4章 风波\n    4.1 比武\n")
fh2:close()

----------------------------------------------------------------------
-- 用例 A：标题模式 —— 直接走 _do_convert（绕过 UI 弹窗）
----------------------------------------------------------------------
inst.ui.document.file = title_txt
local out_a = "/tmp/t2e_test/标题小说.epub"
captured = {}
local ok_a, res_a = pcall(function()
    return inst:_do_convert(title_txt, out_a, "江湖夜雨", false)
end)
check("标题模式 _do_convert 不抛错", ok_a, tostring(res_a))
check("标题模式 返回章节数 > 0", ok_a and res_a and res_a.count and res_a.count > 0,
    ok_a and ("count=" .. tostring(res_a.count)) or "")
check("标题模式 生成 EPUB 文件存在", ok_a and io.open(out_a, "rb") ~= nil)
if ok_a and io.open(out_a, "rb") then
    -- 校验 zip 合法 + mimetype 首项
    local f = io.popen(string.format("unzip -l '%s' 2>/dev/null | head -5", out_a))
    local head = f:read("*a"); f:close()
    check("标题模式 EPUB 是合法 zip（unzip 可读）", head:find("mimetype") ~= nil, head:sub(1, 80))
end

----------------------------------------------------------------------
-- 用例 B：缩进模式 —— _do_convert_indent
----------------------------------------------------------------------
inst.ui.document.file = indent_txt
local out_b = "/tmp/t2e_test/缩进大纲.epub"
captured = {}
local ok_b, res_b = pcall(function()
    return inst:_do_convert_indent(indent_txt, out_b, "剑客录")
end)
check("缩进模式 _do_convert_indent 不抛错", ok_b, tostring(res_b))
check("缩进模式 返回条目数 > 0", ok_b and res_b and res_b.count and res_b.count > 0,
    ok_b and ("count=" .. tostring(res_b.count)) or "")
check("缩进模式 生成 EPUB 文件存在", ok_b and io.open(out_b, "rb") ~= nil)

----------------------------------------------------------------------
-- 用例 C：完整点击流程（convert -> 有标题 -> _run -> 协程 nextTick 执行）
-- convert() 只负责入队 nextTick(step)；随后用 drain_next_ticks 把协程跑完，
-- 完整复现真实 UI 节拍中“每章 yield 一次”的执行路径，并捕获任何 panic。
----------------------------------------------------------------------
-- 先删除用例 A 生成的同名输出，避免触发“覆盖确认”弹窗（弹窗会等待点击，不会立即转换）
os.remove("/tmp/t2e_test/标题小说.epub")
inst.ui.document.file = title_txt
local out_c = "/tmp/t2e_test/标题小说.epub"  -- convert() 内部依此文件名推导输出
captured = {}
local ok_c = pcall(function()
    inst:convert()   -- 内部 show(InfoMessage) 然后 nextTick 入队 step（协程）
end)
check("完整 convert() 入口不 panic", ok_c, tostring(ok_c))
local ok_c_drain = pcall(drain_next_ticks)  -- 跑完协程版转换
check("完整流程 协程执行（逐章 yield）不 panic", ok_c_drain, tostring(ok_c_drain))
check("完整流程 生成 EPUB", io.open(out_c, "rb") ~= nil)

-- 进度框不残留回归（有标题场景）：_check_title_and_run 打开「正在识别章节」scan 常驻框后，
-- 进入 build 阶段时 _open_progress 必须先 close 旧 scan 框；否则该常驻框（dismissable=false）
-- 残留屏幕栈底，转换完成提示（timeout=5）消失后重新露出、且无法点击关闭 → 「卡在正在识别章节」。
do
    local scan_shown, scan_closed = 0, 0
    for _, w in ipairs(captured) do
        if w._type == "InfoMessage" and w.text and tostring(w.text):find("正在识别章节") then
            scan_shown = scan_shown + 1
        end
    end
    for _, w in ipairs(closed) do
        if w._type == "InfoMessage" and w.text and tostring(w.text):find("正在识别章节") then
            scan_closed = scan_closed + 1
        end
    end
    check("「正在识别章节」框已被关闭、不残留（防“转换完成后卡住”）",
        scan_shown > 0 and scan_closed >= scan_shown,
        string.format("shown=%d closed=%d", scan_shown, scan_closed))
end

----------------------------------------------------------------------
-- 用例 D：无标题 TXT -> ConfirmBox -> 选择“按缩进切分”
----------------------------------------------------------------------
local no_title_txt = "/tmp/t2e_test/无标题.txt"
local fh3 = io.open(no_title_txt, "w")
fh3:write("这是一段普通散文。\n没有章节标题。\n    3.1 小标题（靠缩进）\n")
fh3:close()
inst.ui.document.file = no_title_txt
local out_d = "/tmp/t2e_test/无标题.epub"
os.remove(out_d)
captured = {}
local ok_d = pcall(function()
    inst:convert()   -- 无标题 -> 弹 ConfirmBox（不入队 nextTick）
end)
check("无标题 convert() 自身不 panic", ok_d, tostring(ok_d))
-- 找到最后一个 ConfirmBox，模拟点击“按缩进切分”（ok_callback）
local cb
for _, w in ipairs(captured) do if w._type == "ConfirmBox" then cb = w end end
check("无标题场景弹出了 ConfirmBox", cb ~= nil)
if cb then
    local ok_d2 = pcall(function()
        cb._run_ok()          -- 触发 _run_indent -> nextTick 入队 step（协程）
        drain_next_ticks()    -- 跑完协程版缩进转换
    end)
    check("无标题 ConfirmBox 选“按缩进切分”后协程执行不 panic", ok_d2, tostring(ok_d2))
    check("无标题缩进转换生成 EPUB", io.open(out_d, "rb") ~= nil)
end

----------------------------------------------------------------------
-- 用例 E：多章节大书 —— 验证“逐章 yield，分多次 UI tick 完成”而非一次性阻塞
-- 直接统计本用例消耗的 nextTick 次数：章节越多，tick 越多（证明主线程被分片，
-- 不会因长时间阻塞被看门狗 / ANR 杀掉）。
----------------------------------------------------------------------
local big_txt = "/tmp/t2e_test/大书.txt"
os.remove(big_txt)
local bf = io.open(big_txt, "w")
bf:write("大书\n\n")
for i = 1, 120 do
    bf:write(string.format("第%d章 篇章%d\n\n", i, i))
    bf:write("第一段正文内容。\n第二段正文内容。\n\n")
end
bf:close()
inst.ui.document.file = big_txt
local out_e = "/tmp/t2e_test/大书.epub"
os.remove(out_e)
captured = {}
next_tick_count = 0
local ok_e = pcall(function()
    inst:convert()
    drain_next_ticks()
end)
check("大书(120章) 协程转换不 panic", ok_e, tostring(ok_e))
check("大书 生成 EPUB", io.open(out_e, "rb") ~= nil)
-- 120 个章节 + 收尾，至少应分成多次 nextTick（而非 1 次阻塞）
check("大书 分多次 UI tick 完成（nextTick 次数 > 1，证明逐章让出主线程）",
    next_tick_count > 1, "next_tick_count=" .. tostring(next_tick_count))

-- 进度框创建回归：旧 bug —— _open_progress 先把 _progress 置 nil 再调 _set_progress，
-- 而 _set_progress 首行 `if not self._progress then return end` 导致进度框从始至终
-- 从未被创建，转换过程屏幕无任何提示（“页面卡住、毫无反馈”）。
-- 验证：convert() 全流程中 captured 里必须出现「常驻进度框」与「完成提示」。
local has_progress_box, has_done_box = false, false
for _, w in ipairs(captured) do
    if w._type == "InfoMessage" then
        if w.dismissable == false and w.timeout == nil then
            has_progress_box = true
        end
        if w.timeout and w.timeout >= 5 then
            has_done_box = true
        end
    end
end
check("转换过程创建了常驻进度框（防“无提示”）", has_progress_box)
check("转换结束弹出了完成提示（timeout≥5）", has_done_box)

----------------------------------------------------------------------
-- 汇总
----------------------------------------------------------------------
print(string.format("\n===== 运行时测试：%d 通过 / %d 失败 =====", passes, fails))
os.exit(fails == 0 and 0 or 1)
