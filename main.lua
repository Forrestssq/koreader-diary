--[[--
日记插件（diary.koplugin）

功能：
  1. 写日记：弹出全屏多行输入框，保存时把正文按秒级时间戳追加写入当天
     的 Markdown 文件（双指下滑可直接退出输入框，不保存）。
  2. 回顾日记：全屏列表按时间倒序逐条列出全部日记（带多行摘要），长按一条
     可选「编辑」或「生成二维码」；点开后进入全屏分页浏览器，一天一页，
     可一直往前/往后翻。
  3. 日历查看：按月份的日历网格浏览，有日记的日子可点开查看。
  4. 连续记日记天数：统计当前连续天数、历史最长与累计天数。
  5. 每日提醒：可开关，可设多个时间点，到点弹窗提醒写日记（弹窗内直接带写
     入口）。若到点时 KOReader 没开着，下次打开时补弹；每个时间点一天只弹
     一次，另可选「今天已写过则不提醒」「一天最多提醒一次」。

面向 KOReader v2026.03，Lua 5.1（LuaJIT）。仅依赖 KOReader 自带模块。
所有接口均按 v2026.03 源码实际签名编写：
  - dispatcher:registerAction(name, {category="none", event=..., title=..., <section>=true})
  - ui/widget/inputdialog        fullscreen/allow_newline/buttons/getInputText/onShowKeyboard
  - ui/widget/textviewer         {title=, text=, width=, height=, buttons_table=,
                                  add_default_buttons=, page_turn_callback_prev/next=}
                                 注意：TextViewer 没有 fullscreen 选项，不传宽高时
                                 默认是「屏幕 - 30px」的内缩窗口，要全屏须显式传屏幕宽高；
                                 且它会就地把默认按钮行 table.insert 进 buttons_table，
                                 所以每次都得新建一张按钮表。
  - ui/widget/menu               {covers_fullscreen=, multilines_show_more_text=,
                                  items_per_page=, onMenuSelect=, switchItemTable=}
  - ui/widget/buttondialog       {title=, buttons=（按钮网格）, dismissable, rows_per_page}
  - ui/widget/confirmbox         {text=, ok_text=, ok_callback=, cancel_text=}
  - ui/widget/datetimewidget     只传 hour/min 即为时分选择器；OK 回调收到 widget 本身
  - ui/widget/infomessage        {text=, timeout=}
  - ui/widget/qrmessage          {text=, width=, height=}；自带点击/按键关闭
  - ui/widget/container/widgetcontainer  :extend{}
  - libs/libkoreader-lfs         lfs.attributes / lfs.mkdir / lfs.dir
  - apps/filemanager/filemanagerutil     getDefaultDir()
  - luasettings / datastorage    插件自己的设置文件 settings/diary.lua
  - two_finger_swipe 手势 ges.direction == "south"（见 device/gesturedetector.lua）

@module koplugin.Diary
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local QRMessage = require("ui/widget/qrmessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

-- 星期表头（周日起，与 os.date("*t").wday 的 1=周日 对齐）
local WEEKDAY_LABELS = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

-- 回顾列表里每项摘要的行数与单行字数上限
local SUMMARY_MAX_LINES = 4
local SUMMARY_MAX_CHARS = 60
-- 「改哪一条？」列表里每行摘要的字数上限（按钮是单行的，得短一些）
local PICKER_MAX_CHARS = 14
-- 补弹提醒的延时：启动瞬间界面还在铺，稍等一下再弹
local CATCHUP_DELAY = 3
-- QR 码 8-bit 模式的容量上限是 2953 字节，留一点余量。
local QR_MAX_BYTES = 2900

-------------------------------------------------------------------------------
-- 设置（模块级单例：插件在 FileManager ↔ ReaderUI 之间会被重新实例化）
-------------------------------------------------------------------------------

local DEFAULTS = {
    reminder_enabled = false,
    -- reminder_hour / reminder_min：1.3 及以前的单个提醒时间，只用于迁移
    reminder_hour = 21,
    reminder_min = 0,
    -- reminder_times：{ {hour=,min=}, ... }，升序去重；由 getReminderTimes 负责迁移
    reminder_skip_if_written = true, -- 今天已写过则静默跳过
    reminder_once_per_day = false,   -- 一天弹过一次之后，剩下的时间点都不再弹
    -- reminder_last：{ ["21:00"] = "YYYY-MM-DD" }，每个时间点各记各的
    export_range = "all",       -- all / 7d / 30d / month / custom
    -- export_from / export_to：字符串 "YYYY-MM-DD"，仅 custom 用
}

-- 导出范围的可选项（顺序即菜单顺序）
local EXPORT_RANGES = {
    { id = "all",    label = _("全部") },
    { id = "7d",     label = _("最近 7 天") },
    { id = "30d",    label = _("最近 30 天") },
    { id = "month",  label = _("本月") },
    { id = "custom", label = _("自定义日期") },
}

local diary_store

local function getStore()
    if not diary_store then
        diary_store = LuaSettings:open(DataStorage:getSettingsDir() .. "/diary.lua")
    end
    return diary_store
end

local function getSetting(key)
    local v = getStore():readSetting(key)
    if v == nil then
        return DEFAULTS[key]
    end
    return v
end

local function setSetting(key, value)
    getStore():saveSetting(key, value)
    getStore():flush()
end

-------------------------------------------------------------------------------
-- 日期时间选择器
--
-- VirtualKeyboard 是 modal 的，DateTimeWidget 默认不是。UIManager:show 的窗口栈
-- 规则是「非 modal 的一律插到 modal 之下」，所以在输入框里弹选择器时，它会被压
-- 在键盘底下——既看不见，事件也拿不到（sendEvent 只发给栈顶那个非 toast 窗口），
-- 于是整个界面像卡住一样。两手一起解决：
--   1) modal = true，进到键盘上面那一层。ConfirmBox / InfoMessage 本来就是
--      modal，所以删除确认之类一直是好的。
--   2) 弹出前收起键盘、关掉后再放回来。光有 modal 的话键盘还杵在后面，很乱。
--      收放键盘不重建对话框，比 InputDialog:toggleKeyboard 轻得多——后者会
--      onClose + free + init 整个重来，而且硬依赖一个 id="keyboard" 的按钮。
-------------------------------------------------------------------------------

local DiaryDateTime = DateTimeWidget:extend{
    modal = true,
}

function DiaryDateTime:onCloseWidget()
    -- 「确定」「取消」、点窗外、按返回键都会走到这里，键盘一定放得回来
    if self.on_dismiss then
        self.on_dismiss()
    end
    return DateTimeWidget.onCloseWidget(self)
end

-------------------------------------------------------------------------------
-- 带「双指下滑退出」的全屏输入框
-------------------------------------------------------------------------------

local DiaryInput = InputDialog:extend{}

function DiaryInput:init()
    InputDialog.init(self)
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.DiaryTwoFingerSwipe = {
            GestureRange:new{
                ges = "two_finger_swipe",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                },
            },
        }
    end
end

function DiaryInput:onDiaryTwoFingerSwipe(_, ges)
    -- 仅双指“下滑”退出（不保存）。
    if ges and ges.direction == "south" then
        if self.close_callback then
            self.close_callback()
        else
            UIManager:close(self)
        end
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- 纯函数工具（不依赖插件实例）
-------------------------------------------------------------------------------

-- 逐级创建目录（等价 mkdir -p），只用 lfs.mkdir。
local function makeDirRecursive(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    local accum = path:sub(1, 1) == "/" and "/" or ""
    for component in path:gmatch("([^/]+)") do
        accum = accum .. component .. "/"
        if lfs.attributes(accum, "mode") == nil then
            local ok, err = lfs.mkdir(accum)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

-- UTF-8 安全的截断（用 util.splitToChars，不用 string.sub 切字节）。
local function truncateChars(text, max_chars)
    local chars = util.splitToChars(text)
    if #chars <= max_chars then
        return text
    end
    local kept = {}
    for i = 1, max_chars do
        kept[i] = chars[i]
    end
    return table.concat(kept) .. "…"
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitLines(text)
    local lines = {}
    -- 补一个换行，保证最后一行也能被取到
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- Markdown 里单个换行会被渲染器当成空格（软换行），正文里手打的换行要想
-- 保住，行尾得留两个空格 —— 这是 Markdown 的「强制换行」写法。
-- 空行本身就是段落分隔，不用补；段落最后一行也不用。
local function addHardBreaks(text)
    local lines = splitLines(text)
    for i = 1, #lines do
        local stripped = lines[i]:gsub("[ \t]+$", "")
        local next_line = lines[i + 1]
        if stripped ~= "" and next_line and trim(next_line) ~= "" then
            lines[i] = stripped .. "  "
        else
            lines[i] = stripped
        end
    end
    return table.concat(lines, "\n")
end

-- 读回来时把行尾空格去掉，编辑器和阅读界面拿到的都是干净文本。
local function stripHardBreaks(text)
    local lines = splitLines(text)
    for i = 1, #lines do
        lines[i] = lines[i]:gsub("[ \t]+$", "")
    end
    return table.concat(lines, "\n")
end

-- 先写临时文件再 rename。同一目录下 rename 是原子的，中途掉电不会留下半截文件。
local function writeFileAtomic(path, content)
    local tmp_path = path .. ".tmp"
    local f, ferr = io.open(tmp_path, "w")
    if not f then
        return false, ferr
    end
    f:write(content)
    f:close()

    local ok, rerr = os.rename(tmp_path, path)
    if not ok then
        os.remove(tmp_path)
        return false, rerr
    end
    return true, path
end

-- 一天之内的记录必须按时间正序存放：显示顺序和 rec_index 都依赖这个顺序。
local function insertSorted(records, rec)
    local pos = #records + 1
    for i = 1, #records do
        if (records[i].time or "") > (rec.time or "") then
            pos = i
            break
        end
    end
    table.insert(records, pos, rec)
    return pos
end

-- 把某天转成“连续天数比较”用的整数日序（正午取时刻以避开 DST 边界）。
local function dayIndex(year, month, day)
    return math.floor(os.time({ year = year, month = month, day = day, hour = 12 }) / 86400)
end

-------------------------------------------------------------------------------
-- 插件主体
-------------------------------------------------------------------------------

local Diary = WidgetContainer:extend{
    name = "diary",
    is_doc_only = false, -- 在 FileManager 和 ReaderUI 两侧都加载
}

function Diary:getHomeDir()
    local home = G_reader_settings:readSetting("home_dir")
    if not home then
        home = filemanagerutil.getDefaultDir()
    end
    return home
end

-- diary 目录：home directory 下的 diary 子目录。
function Diary:getDiaryDir()
    return self:getHomeDir() .. "/diary"
end

function Diary:getEntryPath(date_str)
    return self:getDiaryDir() .. "/" .. date_str .. ".md"
end

-- 扫描目录，收集所有 YYYY-MM-DD.md 文件。
-- 返回：list（{str,y,m,d}，按日期倒序）、set（set["YYYY-MM-DD"]=true）。
function Diary:collectEntries()
    local dir = self:getDiaryDir()
    local list, set = {}, {}
    if lfs.attributes(dir, "mode") ~= "directory" then
        return list, set
    end
    for name in lfs.dir(dir) do
        local y, m, d = name:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%.md$")
        if y then
            local date_str = y .. "-" .. m .. "-" .. d
            table.insert(list, {
                str = date_str,
                y = tonumber(y), m = tonumber(m), d = tonumber(d),
            })
            set[date_str] = true
        end
    end
    -- ISO 日期字符串按字典序即为时间序；倒序 = 最新在前。
    table.sort(list, function(a, b) return a.str > b.str end)
    return list, set
end

-------------------------------------------------------------------------------
-- 1) 写日记
-------------------------------------------------------------------------------

-- 当前时刻，作为「写新条目」和「改成现在」的默认时间戳。
-- 按系统本地时间的自然日划分，不做凌晨偏移。
local function nowStamp()
    local t = os.date("*t")
    return {
        year = t.year, month = t.month, day = t.day,
        hour = t.hour, min = t.min, sec = t.sec,
    }
end

local function stampDate(stamp)
    return string.format("%04d-%02d-%02d", stamp.year, stamp.month, stamp.day)
end

local function stampTime(stamp)
    return string.format("%02d:%02d:%02d", stamp.hour, stamp.min, stamp.sec or 0)
end

-- 菜单/按钮上给人看的写法，秒没意义就不显示了
local function stampLabel(stamp)
    return string.format("%s %02d:%02d", stampDate(stamp), stamp.hour, stamp.min)
end

-- 把一条记录放到指定的日期+时间。给了 old_date/old_rec_index 就先把原处那条
-- 摘掉，于是「改时间戳」和「改日期」都变成同一个操作：搬家。
-- 成功返回 true, date_str；失败返回 false, err。
function Diary:placeRecord(text, date_str, time_str, old_date, old_rec_index)
    text = trim(text)
    local rec = { time = time_str, text = text }

    if old_date and old_date == date_str then
        -- 同一天内挪动：一次读改写就够了
        local records = self:parseDayRecords(date_str)
        if not records or not records[old_rec_index] then
            return false, _("这条日记已经不在了。")
        end
        table.remove(records, old_rec_index)
        insertSorted(records, rec)
        local ok, err = self:writeDayRecords(date_str, records)
        return ok, ok and date_str or err
    end

    if old_date then
        -- 跨天搬家：先从原来那天摘掉（摘空了那天的文件也会被删掉）
        local old_records = self:parseDayRecords(old_date)
        if not old_records or not old_records[old_rec_index] then
            return false, _("这条日记已经不在了。")
        end
        table.remove(old_records, old_rec_index)
        local ok, err = self:writeDayRecords(old_date, old_records)
        if not ok then
            return false, err
        end
    end

    local records = self:parseDayRecords(date_str) or {}
    insertSorted(records, rec)
    local ok, err = self:writeDayRecords(date_str, records)
    return ok, ok and date_str or err
end

-- 把整理好的 records 数组写回当天文件。records 为空则连文件一起删掉。
-- 先写临时文件再 rename（同一目录下 rename 是原子的），中途掉电不会留下半截文件。
function Diary:writeDayRecords(date_str, records)
    local ok_dir, mkerr = makeDirRecursive(self:getDiaryDir())
    if not ok_dir then
        return false, mkerr
    end
    local path = self:getEntryPath(date_str)

    if #records == 0 then
        local ok, err = os.remove(path)
        if not ok and lfs.attributes(path, "mode") ~= nil then
            return false, err
        end
        return true, path
    end

    local parts = { "# " .. date_str .. "\n\n" }
    for idx = 1, #records do
        local rec = records[idx]
        -- 手工编辑出来的、本来就没有时间戳的记录，写回时也不硬加时间戳。
        if rec.time then
            parts[#parts + 1] = "## " .. rec.time .. "\n\n"
        end
        -- 行尾补两个空格，Markdown 渲染时才会真的换行而不是拼成一段
        parts[#parts + 1] = addHardBreaks(rec.text) .. "\n\n"
    end

    return writeFileAtomic(path, table.concat(parts))
end

-- 删除某天第 rec_index 条记录；删完当天没有记录了就把文件也删掉。
function Diary:deleteRecord(date_str, rec_index)
    local records = self:parseDayRecords(date_str)
    if not records or not records[rec_index] then
        return false, _("这条日记已经不在了。")
    end
    table.remove(records, rec_index)
    return self:writeDayRecords(date_str, records)
end

-- 输入框是「写今天的新条目」还是「改某条旧记录」，由 self.edit_index 决定：
--   0        → 新条目（写入今天）
--   1..#N    → 正在改 self.edit_units[edit_index] 这条
-- edit_units 是 record 粒度、严格时间倒序的，所以 ◀ 是往更早翻，▶ 是往更新翻。

function Diary:saveCurrentInput()
    if not self.diary_input then
        return
    end
    local content = self.diary_input:getInputText()
    if content == nil or trim(content) == "" then
        -- 空内容不写入，保留输入框。改旧记录时想清空，请用「删除」。
        UIManager:show(InfoMessage:new{
            text = self.edit_index > 0
                and _("内容为空，未保存。想删掉这条请用「删除」。")
                or _("内容为空，未保存。"),
            timeout = 2,
        })
        return
    end

    -- 时间戳怎么定：
    --   * 自己动过日期时间选择器 → 就按选的来，不再多问
    --   * 没动过、但正文改了     → 问一句要不要改成现在
    --   * 都没有                 → 原样保留
    if self.edit_index == 0 or self.edit_stamp_set then
        self:commitEntry(content, self.edit_stamp)
        return
    end

    if self.diary_input:isTextEdited() then
        local unit = self.edit_units[self.edit_index]
        UIManager:show(ConfirmBox:new{
            text = string.format(
                _("这条日记改过了。时间戳要改成现在吗？\n\n原时间：%s\n现在：%s"),
                unit.title, stampLabel(nowStamp())),
            ok_text = _("改成现在"),
            ok_callback = function()
                self:commitEntry(content, nowStamp())
            end,
            cancel_text = _("保持原样"),
            cancel_callback = function()
                self:commitEntry(content, self.edit_stamp)
            end,
        })
        return
    end

    self:commitEntry(content, self.edit_stamp)
end

-- 真正落盘。stamp 决定这条记录最终待在哪一天、什么时间。
function Diary:commitEntry(content, stamp)
    local date_str, time_str = stampDate(stamp), stampTime(stamp)
    local old_date, old_rec_index
    if self.edit_index > 0 then
        local unit = self.edit_units[self.edit_index]
        old_date, old_rec_index = unit.date, unit.rec_index
    end

    local ok, result = self:placeRecord(content, date_str, time_str, old_date, old_rec_index)
    if not ok then
        -- 写入失败：报错并保留输入框内容不关闭（不设 timeout，等用户点掉）。
        UIManager:show(InfoMessage:new{
            text = _("保存失败：") .. tostring(result or _("未知错误")),
        })
        return
    end

    self.diary_changed = true
    if self.edit_index == 0 then
        self:closeEntryDialog()
        UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 1 })
        return
    end

    -- 改完留在这一条上。可能换了日期、也可能在同一天里挪了位置，
    -- rec_index 全乱了，只能重建列表再按 日期+时间 找回来。
    self.edit_units = self:getRecordUnits()
    -- 找不回来（理论上不该发生）就退而停在附近，别把用户甩回「写新条目」
    local found = math.min(self.edit_index, #self.edit_units)
    for idx = 1, #self.edit_units do
        local u = self.edit_units[idx]
        if u.date == date_str and u.time == time_str then
            found = idx
            break
        end
    end
    UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 1 })
    self:applyEntryState(found)
end

function Diary:closeEntryDialog()
    if self.diary_input then
        UIManager:close(self.diary_input)
        self.diary_input = nil
    end
    if self.diary_changed then
        self.diary_changed = nil
        self:refreshOpenViews()
    end
end

-- 有未保存改动时先确认，再执行 action。
function Diary:confirmDiscard(action)
    if self.diary_input and self.diary_input:isTextEdited() then
        UIManager:show(ConfirmBox:new{
            text = _("当前修改还没保存，确定放弃吗？"),
            ok_text = _("放弃"),
            ok_callback = action,
            cancel_text = _("继续编辑"),
        })
        return
    end
    action()
end

-- 把输入框切换到第 index 条（0 = 写今天的新条目），原地换内容和标题，
-- 不重建对话框，免得键盘一闪一闪。
function Diary:applyEntryState(index)
    local dialog = self.diary_input
    if not dialog then return end
    self.edit_index = index

    local unit = index > 0 and self.edit_units[index] or nil
    dialog.title_bar:setTitle(unit and unit.title or _("写日记"))
    -- setInputText 会把「已修改」标记清掉，正是切换后想要的
    dialog:setInputText(unit and unit.text or "")

    -- 换条目就重置目标时间戳：旧记录用它自己的，新条目用现在。
    self.edit_stamp = unit and self:unitStamp(unit) or nowStamp()
    self.edit_stamp_set = false
    self:updateStampButton()

    local function setEnabled(id, enabled)
        local btn = dialog.button_table:getButtonById(id)
        if btn then btn:enableDisable(enabled) end
    end
    setEnabled("diary_prev", index < #self.edit_units)
    setEnabled("diary_next", index > 0)
    setEnabled("diary_today", index > 0)
    setEnabled("diary_delete", index > 0)
    dialog:refreshButtons()
end

-- 从「YYYY-MM-DD」+「HH:MM:SS」还原成 stamp 表。
-- 没有时间戳的记录（手工编辑出来的）补成当天 00:00:00。
function Diary:unitStamp(unit)
    local y, m, d = unit.date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local hh, mm, ss = (unit.time or ""):match("^(%d%d):(%d%d):(%d%d)$")
    return {
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(hh) or 0, min = tonumber(mm) or 0, sec = tonumber(ss) or 0,
    }
end

function Diary:updateStampButton()
    local dialog = self.diary_input
    if not dialog then return end
    local btn = dialog.button_table:getButtonById("diary_stamp")
    if btn then
        -- 传回原宽度，Button 就只换文字不重建整个框
        btn:setText(string.format(_("日期时间：%s"), stampLabel(self.edit_stamp)), btn.width)
    end
end

function Diary:showStampDialog()
    local stamp = self.edit_stamp
    local dialog = self.diary_input

    -- 先把键盘收起来，别让它挡着选择器（详见 DiaryDateTime 上面那段说明）
    local restore_keyboard = dialog and dialog:isKeyboardVisible()
    if restore_keyboard then
        dialog:onCloseKeyboard()
    end

    UIManager:show(DiaryDateTime:new{
        year = stamp.year,
        month = stamp.month,
        day = stamp.day,
        hour = stamp.hour,
        min = stamp.min,
        ok_text = _("确定"),
        -- 不给的话 DateTimeWidget 会用它自带的英文 "Close"
        cancel_text = _("取消"),
        title_text = _("这条日记的日期时间"),
        info_text = _("改了之后，这条日记会被挪到所选的日期。"),
        -- OK 时 DateTimeWidget 是以 self:callback(self) 调用的，读 w.year / w.month / …
        callback = function(w)
            self.edit_stamp = {
                year = w.year, month = w.month, day = w.day,
                hour = w.hour, min = w.min, sec = 0,
            }
            self.edit_stamp_set = true
            self:updateStampButton()
            if self.diary_input then
                self.diary_input:refreshButtons()
            end
        end,
        on_dismiss = function()
            if not restore_keyboard then return end
            -- 等这个窗口真的从栈上摘掉了再放键盘，免得两边同时改窗口栈
            UIManager:nextTick(function()
                if self.diary_input then
                    self.diary_input:onShowKeyboard()
                end
            end)
        end,
    })
end

function Diary:gotoEntry(index)
    if index < 0 or index > #self.edit_units then
        return
    end
    self:confirmDiscard(function()
        self:applyEntryState(index)
    end)
end

function Diary:deleteCurrentEntry()
    if self.edit_index == 0 then return end
    local unit = self.edit_units[self.edit_index]
    UIManager:show(ConfirmBox:new{
        text = string.format(_("确定删除这条日记吗？\n\n%s"), unit.title),
        ok_text = _("删除"),
        ok_callback = function()
            local ok, err = self:deleteRecord(unit.date, unit.rec_index)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = _("删除失败：") .. tostring(err or _("未知错误")),
                })
                return
            end
            self.diary_changed = true
            -- 记录数变了，rec_index 会整体前移，必须重建列表
            local was = self.edit_index
            self.edit_units = self:getRecordUnits()
            UIManager:show(InfoMessage:new{ text = _("已删除"), timeout = 1 })
            -- 停在原位（原位没有了就停在最后一条，一条不剩就回到新条目）
            self:applyEntryState(math.min(was, #self.edit_units))
        end,
        cancel_text = _("取消"),
    })
end

-- start_index：0 或 nil = 写今天的新条目；>0 = 直接编辑第 N 条记录
function Diary:showEntryDialog(start_index)
    self.edit_units = self:getRecordUnits()
    self.edit_index = start_index or 0
    if self.edit_index > #self.edit_units then
        self.edit_index = 0
    end
    local unit = self.edit_index > 0 and self.edit_units[self.edit_index] or nil
    self.edit_stamp = unit and self:unitStamp(unit) or nowStamp()
    self.edit_stamp_set = false

    self.diary_input = DiaryInput:new{
        title = unit and unit.title or _("写日记"),
        input = unit and unit.text or "",
        input_hint = _("写点什么…（双指下滑退出，不保存）"),
        fullscreen = true,     -- 全屏，无需指定宽高
        condensed = true,      -- 全屏编辑器推荐布局
        allow_newline = true,  -- 允许换行（多行输入）
        cursor_at_end = false,
        close_callback = function()
            self:confirmDiscard(function() self:closeEntryDialog() end)
        end,
        buttons = {
            -- 第一行：往回翻看 / 回到今天 / 往回翻
            {
                {
                    text = "◀",
                    id = "diary_prev",
                    enabled = self.edit_index < #self.edit_units,
                    callback = function() self:gotoEntry(self.edit_index + 1) end,
                },
                {
                    text = _("今天"),
                    id = "diary_today",
                    enabled = self.edit_index > 0,
                    callback = function() self:gotoEntry(0) end,
                },
                {
                    text = "▶",
                    id = "diary_next",
                    enabled = self.edit_index > 0,
                    callback = function() self:gotoEntry(self.edit_index - 1) end,
                },
            },
            -- 第二行：这条日记算哪天几点，点开可改
            {
                {
                    text = string.format(_("日期时间：%s"), stampLabel(self.edit_stamp)),
                    id = "diary_stamp",
                    callback = function() self:showStampDialog() end,
                },
            },
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        self:confirmDiscard(function() self:closeEntryDialog() end)
                    end,
                },
                {
                    text = _("删除"),
                    id = "diary_delete",
                    enabled = self.edit_index > 0,
                    callback = function() self:deleteCurrentEntry() end,
                },
                {
                    text = _("保存"),
                    id = "diary_save",
                    callback = function() self:saveCurrentInput() end,
                },
            },
        },
    }
    UIManager:show(self.diary_input)
    self.diary_input:onShowKeyboard()
end

-------------------------------------------------------------------------------
-- 查看某天全文
-------------------------------------------------------------------------------

function Diary:readEntryFile(date_str)
    local path = self:getEntryPath(date_str)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

-- 把某天的文件解析成若干条记录：{ {time="HH:MM:SS", text="正文"}, ... }。
-- 文件不存在返回 nil。要容忍用户手工编辑过的文件：
--   * "## HH:MM:SS" 开一条新记录；
--   * 首条记录出现之前的 "# ..."（文件标题行）跳过；
--   * 正文行出现在任何时间戳之前 → 归入一条 time=nil 的记录；
--   * 正文为空的记录直接丢弃（标题行后面那个空行、以及只有时间戳没内容的条目）。
function Diary:parseDayRecords(date_str)
    local content = self:readEntryFile(date_str)
    if not content then
        return nil
    end
    local parsed = {}
    local cur
    -- 补一个换行，保证 gmatch 能取到最后一行
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local ts = line:match("^##%s+(%d%d:%d%d:%d%d)%s*$")
        if ts then
            cur = { time = ts, lines = {} }
            parsed[#parsed + 1] = cur
        elseif not cur and line:match("^#[^#]") then
            -- 文件标题行 "# YYYY-MM-DD"，跳过
        else
            if not cur then
                cur = { time = nil, lines = {} }
                parsed[#parsed + 1] = cur
            end
            cur.lines[#cur.lines + 1] = line
        end
    end
    local records = {}
    for _idx = 1, #parsed do
        local rec = parsed[_idx]
        -- 存进去的强制换行标记（行尾两个空格）在这里剥掉，上层拿到的是干净文本
        local text = trim(stripHardBreaks(table.concat(rec.lines, "\n")))
        if text ~= "" then
            records[#records + 1] = { time = rec.time, text = text }
        end
    end
    return records
end

-- 把一天的多条记录渲染成一整块正文（每条前带时间行）。
local function renderRecords(records)
    local parts = {}
    for _idx = 1, #records do
        local rec = records[_idx]
        if rec.text ~= "" then
            parts[#parts + 1] = (rec.time and (rec.time .. "\n") or "") .. rec.text
        end
    end
    return table.concat(parts, "\n\n")
end

-- 回顾列表用的多行摘要：取前若干非空行，每行再截短。
local function summarizeText(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local t = trim(line)
        if t ~= "" then
            lines[#lines + 1] = truncateChars(t, SUMMARY_MAX_CHARS)
            if #lines >= SUMMARY_MAX_LINES then
                break
            end
        end
    end
    return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- 2) 回顾日记：全屏列表（多行摘要） → 全屏分页浏览器
-------------------------------------------------------------------------------

-- record 粒度的单元数组，严格按时间倒序（同一天内也是最新的在前）。
-- 回顾列表和编辑器都以它为准：列表里一项就是这里的一个单元，下标直接通用；
-- 编辑器的 ◀ 往下标大的走，也就是一路往更早翻。
-- rec_index 是它在 parseDayRecords 结果里的下标（那边是正序的），改写/删除要用。
function Diary:getRecordUnits(list)
    list = list or self:collectEntries()
    local units = {}
    for _idx = 1, #list do
        local date_str = list[_idx].str
        local records = self:parseDayRecords(date_str) or {}
        for r = #records, 1, -1 do
            units[#units + 1] = {
                date = date_str,
                rec_index = r,
                time = records[r].time,
                title = records[r].time and (date_str .. " " .. records[r].time) or date_str,
                text = records[r].text,
            }
        end
    end
    return units
end

-- 分页浏览器用的单元数组：一天一则（日期倒序）。
function Diary:getUnits()
    local list = self:collectEntries()
    local units = {}
    for _idx = 1, #list do
        local date_str = list[_idx].str
        units[#units + 1] = { date = date_str, title = date_str }
    end
    return units
end

-- 惰性取一天的正文（第一次访问时才读文件）。
function Diary:unitText(unit)
    if not unit.text then
        unit.text = renderRecords(self:parseDayRecords(unit.date) or {})
    end
    return unit.text
end

-- 一条记录一项。units 就是 getRecordUnits() 的结果，item.unit_index 与之对应，
-- 编辑时可以原样传给 showEntryDialog。
function Diary:buildReviewItems(units)
    local item_table = {}
    for idx = 1, #units do
        local unit = units[idx]
        local summary = summarizeText(unit.text)
        -- Menu 会把条目文本里的 \n 换成空格（menu.lua:211），所以摘要在这里
        -- 是一整段回流的文字；标题后面加个 · 把它和正文分开。
        item_table[#item_table + 1] = {
            text = summary ~= "" and (unit.title .. "  ·  " .. summary) or unit.title,
            date = unit.date,
            unit_index = idx,
        }
    end
    return item_table
end

function Diary:showReview()
    local units = self:getRecordUnits()
    if #units == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有任何日记。"),
        })
        return
    end
    self.review_units = units
    local item_table = self:buildReviewItems(units)

    self.review_menu = Menu:new{
        name = "diary_review",
        title = string.format(_("回顾日记（共 %d 条）"), #units),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        -- 关键：多行摘要。Menu 会自动二分收缩字号，超长自动加省略号。
        multilines_show_more_text = true,
        items_per_page = 6,
        -- 摘要要占宽度，别让快捷键方框吃掉左边一大块
        is_enable_shortcut = false,
        onMenuSelect = function(_menu, item)
            if item.date then
                self:closeReview()
                self:showPager(item.date)
            end
            return true
        end,
        -- 长按某一条 → 问是编辑还是生成二维码
        onMenuHold = function(_menu, item)
            self:showRecordActions(item)
            return true
        end,
    }
    self.review_menu.close_callback = function()
        self:closeReview()
    end
    UIManager:show(self.review_menu)
end

function Diary:closeReview()
    if self.review_menu then
        UIManager:close(self.review_menu)
        self.review_menu = nil
        self.review_units = nil
    end
end

-- 回顾列表长按一条：编辑，还是把它变成二维码带走。
function Diary:showRecordActions(item)
    local units = self.review_units
    local unit = units and item.unit_index and units[item.unit_index]
    if not unit then
        return
    end

    local function close()
        if self.record_action_dialog then
            UIManager:close(self.record_action_dialog)
            self.record_action_dialog = nil
        end
    end

    self.record_action_dialog = ButtonDialog:new{
        title = unit.title,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("编辑"),
                    callback = function()
                        close()
                        -- showEntryDialog 会自己重建 edit_units，下标与列表一致
                        self:showEntryDialog(item.unit_index)
                    end,
                },
            },
            {
                {
                    text = _("生成二维码"),
                    callback = function()
                        close()
                        self:showRecordQR(unit)
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = close,
                },
            },
        },
    }
    UIManager:show(self.record_action_dialog)
end

-- 只编码正文。QRWidget 自己也会截断，但它是按字节切的，中文会切出半个字符，
-- 所以这里先按字符截到容量以内。
function Diary:showRecordQR(unit)
    local text = unit.text or ""
    if #text > QR_MAX_BYTES then
        local chars = util.splitToChars(text)
        local kept, bytes = {}, 0
        for i = 1, #chars do
            bytes = bytes + #chars[i]
            if bytes > QR_MAX_BYTES then
                break
            end
            kept[i] = chars[i]
        end
        text = table.concat(kept)
        UIManager:show(InfoMessage:new{
            text = string.format(_("内容过长，二维码只包含前 %d 字。"), #kept),
            timeout = 3,
        })
    end
    UIManager:show(QRMessage:new{
        text = text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

-------------------------------------------------------------------------------
-- 全屏分页浏览器
-------------------------------------------------------------------------------

-- start_date 为 nil 时从最新的一则开始。
function Diary:showPager(start_date)
    local units = self:getUnits()
    if #units == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有任何日记。"),
        })
        return
    end

    local start_index = 1
    if start_date then
        for idx = 1, #units do
            if units[idx].date == start_date then
                start_index = idx
                break
            end
        end
    end

    self.pager_units = units
    self.pager_total_pages = #units
    self:showPagerPage(start_index)
end

-- 一天一页：第 page 页就是 pager_units[page] 那一天的全部记录。
function Diary:showPagerPage(page)
    local unit = self.pager_units[page]
    local total_pages = self.pager_total_pages
    self.pager_page = page

    -- 页码放标题里，把中间那个按钮位让给「编辑」
    local title = string.format("%s  (%d/%d)", unit.title, page, total_pages)

    -- TextViewer 会就地把默认按钮行 insert 进 buttons_table，所以每页都要新建一张表。
    local buttons_table = {
        {
            {
                text = _("◀ 上一页"),
                enabled = page > 1,
                callback = function() self:pagerGoto(page - 1) end,
            },
            {
                text = _("编辑"),
                callback = function() self:editRecordsOfDay(unit.date) end,
            },
            {
                text = _("下一页 ▶"),
                enabled = page < total_pages,
                callback = function() self:pagerGoto(page + 1) end,
            },
        },
    }

    self.pager = TextViewer:new{
        title = title,
        title_shrink_font_to_fit = true,
        text = self:unitText(unit),
        -- 真·全屏：不传宽高的话 TextViewer 默认是「屏幕 - 30px」的内缩窗口。
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        buttons_table = buttons_table,
        add_default_buttons = true, -- 保留 查找 / ⇱ / ⇲ / 关闭
        -- 实体翻页键：本页滚到底/顶之后再按，自动跳到下/上一页。
        page_turn_callback_prev = function() self:pagerGoto(page - 1) end,
        page_turn_callback_next = function() self:pagerGoto(page + 1) end,
        close_callback = function()
            self.pager = nil
            self.pager_units = nil
        end,
    }
    UIManager:show(self.pager)
end

function Diary:pagerGoto(page)
    if page < 1 or page > self.pager_total_pages then
        return
    end
    self:closePager()
    self:showPagerPage(page)
end

function Diary:closePager()
    if self.pager then
        -- 重建（而非改内容）：顺带把滚动位置重置到页首，正是翻页想要的。
        local viewer = self.pager
        self.pager = nil
        viewer.close_callback = nil
        UIManager:close(viewer)
    end
end

-------------------------------------------------------------------------------
-- 修改 / 删除的入口
-------------------------------------------------------------------------------

-- 编辑总是 record 粒度，所以先把「屏幕上这些单元」映射回一条条记录。
-- 一条就直接进编辑器，多条就先弹个列表让用户挑。
function Diary:pickRecordToEdit(matches)
    if #matches == 0 then
        UIManager:show(InfoMessage:new{ text = _("这里没有可编辑的日记。") })
        return
    end
    if #matches == 1 then
        self:showEntryDialog(matches[1])
        return
    end

    local record_units = self.edit_pick_units

    -- 全是同一天的话，每行就不用再重复日期了
    local one_day = true
    for idx = 2, #matches do
        if record_units[matches[idx]].date ~= record_units[matches[1]].date then
            one_day = false
            break
        end
    end

    local buttons = {}
    for idx = 1, #matches do
        local unit = record_units[matches[idx]]
        local pick = matches[idx]
        local prefix = one_day and (unit.time or unit.date) or unit.title
        buttons[#buttons + 1] = {
            {
                -- 按钮是单行的：摘要压成一行并截短，各行长度接近才不会字号不一
                text = prefix .. "  " .. truncateChars(
                    (unit.text:gsub("%s+", " ")), PICKER_MAX_CHARS),
                align = "left",
                callback = function()
                    UIManager:close(self.pick_dialog)
                    self.pick_dialog = nil
                    self:showEntryDialog(pick)
                end,
            },
        }
    end
    self.pick_dialog = ButtonDialog:new{
        title = _("改哪一条？"),
        title_align = "center",
        buttons = buttons,
        rows_per_page = 8,
    }
    UIManager:show(self.pick_dialog)
end

-- 分页浏览器的「编辑」：这一页就是一天，落到这天的记录上。
function Diary:editRecordsOfDay(date_str)
    local record_units = self:getRecordUnits()
    self.edit_pick_units = record_units
    local matches = {}
    for idx = 1, #record_units do
        if record_units[idx].date == date_str then
            matches[#matches + 1] = idx
        end
    end
    self:pickRecordToEdit(matches)
end

-- 改过 / 删过之后，把还开着的回顾列表和分页浏览器刷新一遍，免得看到旧内容。
function Diary:refreshOpenViews()
    if self.review_menu then
        local units = self:getRecordUnits()
        self.review_units = units
        local item_table = self:buildReviewItems(units)
        self.review_menu:switchItemTable(
            string.format(_("回顾日记（共 %d 条）"), #units), item_table, -1)
    end
    if self.pager then
        local page = self.pager_page or 1
        self.pager_units = self:getUnits()
        if #self.pager_units == 0 then
            self:closePager()
            self.pager_units = nil
            UIManager:show(InfoMessage:new{ text = _("已经没有日记了。") })
            return
        end
        self.pager_total_pages = #self.pager_units
        self:closePager()
        self:showPagerPage(math.min(page, self.pager_total_pages))
    end
end

-------------------------------------------------------------------------------
-- 3) 日历查看（按月网格）
-------------------------------------------------------------------------------

function Diary:showCalendarToday()
    local now = os.date("*t")
    self:showCalendar(now.year, now.month)
end

function Diary:showCalendar(year, month)
    -- 归一化月份（允许 0 或 13 溢出）
    while month < 1 do
        month = month + 12
        year = year - 1
    end
    while month > 12 do
        month = month - 12
        year = year + 1
    end

    local _list, set = self:collectEntries()

    -- 当月天数与 1 号是星期几
    local days_in_month = tonumber(os.date("%d",
        os.time({ year = year, month = month + 1, day = 0, hour = 12 })))
    local first_wday = os.date("*t",
        os.time({ year = year, month = month, day = 1, hour = 12 })).wday -- 1=周日

    local buttons = {}

    -- 星期表头
    local header_row = {}
    for i = 1, 7 do
        table.insert(header_row, { text = WEEKDAY_LABELS[i], enabled = false })
    end
    table.insert(buttons, header_row)

    -- 日期网格
    local cell = 1 - (first_wday - 1) -- 使 1 号落在正确的星期列
    local total_cells = math.ceil((first_wday - 1 + days_in_month) / 7) * 7
    for _ = 1, total_cells / 7 do
        local row = {}
        for _ = 1, 7 do
            if cell < 1 or cell > days_in_month then
                table.insert(row, { text = " ", enabled = false })
            else
                local day = cell
                local date_str = string.format("%04d-%02d-%02d", year, month, day)
                local has_entry = set[date_str] == true
                row[#row + 1] = {
                    text = tostring(day),
                    -- 有日记的日子可点（显示为深色），无日记的日子置灰不可点。
                    enabled = has_entry,
                    -- 与「回顾日记」同一个全屏分页浏览器，定位到这一天。
                    callback = has_entry and function()
                        self:showPager(date_str)
                    end or nil,
                }
            end
            cell = cell + 1
        end
        table.insert(buttons, row)
    end

    -- 导航行
    table.insert(buttons, {
        {
            text = _("◀ 上月"),
            callback = function()
                UIManager:close(self.calendar_dialog)
                self:showCalendar(year, month - 1)
            end,
        },
        {
            text = _("今天"),
            callback = function()
                UIManager:close(self.calendar_dialog)
                self:showCalendarToday()
            end,
        },
        {
            text = _("下月 ▶"),
            callback = function()
                UIManager:close(self.calendar_dialog)
                self:showCalendar(year, month + 1)
            end,
        },
    })

    self.calendar_dialog = ButtonDialog:new{
        title = string.format(_("%d 年 %d 月"), year, month),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.calendar_dialog)
end

-------------------------------------------------------------------------------
-- 4) 连续记日记天数
-------------------------------------------------------------------------------

function Diary:showStreak()
    local list = self:collectEntries()
    if #list == 0 then
        UIManager:show(InfoMessage:new{
            text = _("还没有任何日记。"),
        })
        return
    end

    -- 全部日序集合
    local index_set = {}
    for _, item in ipairs(list) do
        index_set[dayIndex(item.y, item.m, item.d)] = true
    end

    local now = os.date("*t")
    local today = dayIndex(now.year, now.month, now.day)

    -- 当前连续天数：以今天为终点；今天没写则允许以昨天为终点。
    local current = 0
    local cursor = nil
    if index_set[today] then
        cursor = today
    elseif index_set[today - 1] then
        cursor = today - 1
    end
    while cursor and index_set[cursor] do
        current = current + 1
        cursor = cursor - 1
    end

    -- 历史最长连续天数
    local longest = 0
    for _, item in ipairs(list) do
        local idx = dayIndex(item.y, item.m, item.d)
        if not index_set[idx - 1] then -- 连续段起点
            local run, c = 0, idx
            while index_set[c] do
                run = run + 1
                c = c + 1
            end
            if run > longest then
                longest = run
            end
        end
    end

    local text = string.format(
        _("当前连续记日记：%d 天\n历史最长连续：%d 天\n累计记录天数：%d 天"),
        current, longest, #list)
    UIManager:show(InfoMessage:new{ text = text })
end

-------------------------------------------------------------------------------
-- 6) 导出为一个大 Markdown 文件
-------------------------------------------------------------------------------

-- 把某天往前/往后推 n 天（正午取时刻，避开 DST 边界）。
local function shiftDate(date_str, days)
    local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local t = os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12,
    }) + days * 86400
    return os.date("%Y-%m-%d", t)
end

local function todayDate()
    return os.date("%Y-%m-%d")
end

-- 当前设置对应的日期区间。返回 from, to（nil 表示这一头不限）。
function Diary:getExportRange()
    local mode = getSetting("export_range")
    local today = todayDate()
    if mode == "7d" then
        return shiftDate(today, -6), today
    elseif mode == "30d" then
        return shiftDate(today, -29), today
    elseif mode == "month" then
        return today:sub(1, 8) .. "01", today
    elseif mode == "custom" then
        local from, to = getSetting("export_from"), getSetting("export_to")
        -- 顺手兜一下反着填的情况
        if from and to and from > to then
            from, to = to, from
        end
        return from, to
    end
    return nil, nil -- 全部
end

-- 落在区间里的日期，按时间正序（导出的文件是拿来从头读的）。
-- ISO 日期字符串按字典序比较即是按时间比较。
function Diary:collectEntriesInRange(from, to)
    local list = self:collectEntries()
    local out = {}
    for idx = #list, 1, -1 do -- collectEntries 是倒序，反着走就是正序
        local date_str = list[idx].str
        if (not from or date_str >= from) and (not to or date_str <= to) then
            out[#out + 1] = date_str
        end
    end
    return out
end

function Diary:exportRangeLabel()
    local mode = getSetting("export_range")
    for _idx = 1, #EXPORT_RANGES do
        if EXPORT_RANGES[_idx].id == mode then
            return EXPORT_RANGES[_idx].label
        end
    end
    return _("全部")
end

-- 自定义区间第一次用时给个像样的默认值：从最早一篇到今天。
function Diary:ensureCustomRange()
    if not getSetting("export_from") then
        local list = self:collectEntries()
        -- list 是倒序，最后一个是最早的
        setSetting("export_from", #list > 0 and list[#list].str or todayDate())
    end
    if not getSetting("export_to") then
        setSetting("export_to", todayDate())
    end
end

function Diary:doExport()
    -- 自定义模式下起止一定要有值，否则 getExportRange 会退化成「全部」，
    -- 用户按了「现在导出」却导出了一切，很意外。
    if getSetting("export_range") == "custom" then
        self:ensureCustomRange()
    end
    local from, to = self:getExportRange()
    local dates = self:collectEntriesInRange(from, to)
    if #dates == 0 then
        UIManager:show(InfoMessage:new{ text = _("所选范围内没有日记。") })
        return
    end

    local parts = {
        "# " .. _("日记导出") .. "\n\n",
        string.format(_("范围：%s ~ %s\n"), dates[1], dates[#dates]),
    }
    local range_line_idx = #parts + 1
    parts[range_line_idx] = "" -- 占位，条数统计完再填
    parts[#parts + 1] = string.format(_("导出时间：%s\n\n"), stampLabel(nowStamp()))

    local total_records = 0
    for _idx = 1, #dates do
        local date_str = dates[_idx]
        local records = self:parseDayRecords(date_str) or {}
        parts[#parts + 1] = "---\n\n## " .. date_str .. "\n\n"
        for r = 1, #records do
            local rec = records[r]
            total_records = total_records + 1
            if rec.time then
                parts[#parts + 1] = "### " .. rec.time .. "\n\n"
            end
            -- 和存储一样补上强制换行，否则导出的文件渲染时会把换行拼成一段
            parts[#parts + 1] = addHardBreaks(rec.text) .. "\n\n"
        end
    end
    parts[range_line_idx] = string.format(_("共 %d 天 / %d 条\n"), #dates, total_records)

    local path = string.format("%s/diary-export-%s_%s.md",
        self:getHomeDir(), dates[1], dates[#dates])
    local ok, err = writeFileAtomic(path, table.concat(parts))
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("导出失败：") .. tostring(err or _("未知错误")),
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("已导出 %d 天 / %d 条到：\n%s"), #dates, total_records, path),
    })
end

function Diary:showExportDatePicker(key, title, touchmenu_instance)
    self:ensureCustomRange()
    local cur = getSetting(key)
    local y, m, d = cur:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    UIManager:show(DiaryDateTime:new{
        year = tonumber(y),
        month = tonumber(m),
        day = tonumber(d),
        ok_text = _("确定"),
        cancel_text = _("取消"),
        title_text = title,
        callback = function(w)
            setSetting(key, string.format("%04d-%02d-%02d", w.year, w.month, w.day))
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })
end

function Diary:getExportMenu()
    local range_items = {}
    for _idx = 1, #EXPORT_RANGES do
        local r = EXPORT_RANGES[_idx]
        range_items[#range_items + 1] = {
            text = r.label,
            radio = true,
            checked_func = function() return getSetting("export_range") == r.id end,
            keep_menu_open = true,
            callback = function()
                setSetting("export_range", r.id)
                if r.id == "custom" then
                    self:ensureCustomRange()
                end
            end,
        }
    end

    local function isCustom() return getSetting("export_range") == "custom" end

    return {
        {
            text_func = function()
                return string.format(_("导出范围：%s"), self:exportRangeLabel())
            end,
            sub_item_table = range_items,
        },
        {
            text_func = function()
                return string.format(_("起始日期：%s"), getSetting("export_from") or _("未设置"))
            end,
            enabled_func = isCustom,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showExportDatePicker("export_from", _("起始日期"), touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return string.format(_("结束日期：%s"), getSetting("export_to") or _("未设置"))
            end,
            enabled_func = isCustom,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                self:showExportDatePicker("export_to", _("结束日期"), touchmenu_instance)
            end,
        },
        {
            text_func = function()
                local from, to = self:getExportRange()
                return string.format(_("现在导出（%d 天）"),
                    #self:collectEntriesInRange(from, to))
            end,
            keep_menu_open = true,
            callback = function()
                self:doExport()
            end,
        },
    }
end

-------------------------------------------------------------------------------
-- 5) 每日提醒
-------------------------------------------------------------------------------

local function slotKey(slot)
    return string.format("%02d:%02d", slot.hour, slot.min)
end

-- 时间点排序 + 去重后落盘。存进去的永远是升序的，取用的地方就不必再排。
local function setReminderTimes(times)
    table.sort(times, function(a, b)
        if a.hour ~= b.hour then return a.hour < b.hour end
        return a.min < b.min
    end)
    local out, seen = {}, {}
    for idx = 1, #times do
        local key = slotKey(times[idx])
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = { hour = times[idx].hour, min = times[idx].min }
        end
    end
    setSetting("reminder_times", out)
    return out
end

-- 1.3 及以前只有一个提醒时间，第一次读到时就地迁移成列表并落盘，
-- 老用户升级后原来那个时间点照旧生效。
local function getReminderTimes()
    local times = getStore():readSetting("reminder_times")
    if type(times) ~= "table" then
        return setReminderTimes({
            { hour = getSetting("reminder_hour"), min = getSetting("reminder_min") },
        })
    end
    return times
end

local function reminderTimesLabel()
    local times = getReminderTimes()
    if #times == 0 then
        return _("未设置")
    end
    local parts = {}
    for idx = 1, #times do
        parts[idx] = slotKey(times[idx])
    end
    return table.concat(parts, "、")
end

-- 某个时间点在「now 所在那一天」的绝对时刻。
local function slotTarget(slot, now)
    local t = os.date("*t", now)
    t.hour, t.min, t.sec = slot.hour, slot.min, 0
    return os.time(t)
end

-- 每个时间点各记各的「最后提醒日期」。
local function getReminderLast()
    return getStore():readSetting("reminder_last", {})
end

local function markReminded(keys, today)
    local last = getReminderLast()
    for idx = 1, #keys do
        last[keys[idx]] = today
    end
    -- readSetting 返回的就是存在设置表里的那张表，改完 flush 即落盘
    getStore():saveSetting("reminder_last", last)
    getStore():flush()
end

-- 重排下一次提醒。开关、时间、跳过策略任一改动后都要重调。
--
-- UIManager 的定时器跑在 CLOCK_MONOTONIC 上（休眠期间不走时），而提醒是墙钟
-- 语义，所以每次 onResume 都要按 os.time() 重算一遍（同 readtimer 插件）。
function Diary:scheduleReminder()
    UIManager:unschedule(self.reminder_cb)
    if not getSetting("reminder_enabled") then
        return
    end
    local times = getReminderTimes()
    if #times == 0 then
        return
    end

    local now = os.time()
    local today = os.date("%Y-%m-%d", now)
    local last = getReminderLast()

    local next_target
    for idx = 1, #times do
        local target = slotTarget(times[idx], now)
        if now >= target then
            if last[slotKey(times[idx])] ~= today then
                -- 到点时 KOReader 没开着 → 现在补弹一次。
                UIManager:scheduleIn(CATCHUP_DELAY, self.reminder_cb)
                return
            end
        elseif not next_target or target < next_target then
            next_target = target
        end
    end

    if not next_target then
        -- 今天的都过完了，排到明天最早的那个（day+1 交给 os.time 归一化跨月/跨年）。
        local t = os.date("*t", now)
        t.day = t.day + 1
        t.hour, t.min, t.sec = times[1].hour, times[1].min, 0
        next_target = os.time(t)
    end
    UIManager:scheduleIn(math.max(next_target - now, 1), self.reminder_cb)
end

function Diary:fireReminder()
    local now = os.time()
    local today = os.date("%Y-%m-%d", now)
    local last = getReminderLast()

    -- 打标记之前先看今天是不是已经弹过了——「一天最多提醒一次」要用它。
    local already_fired_today = false
    for _key, date_str in pairs(last) do
        if date_str == today then
            already_fired_today = true
            break
        end
    end

    local due = {}
    local times = getReminderTimes()
    for idx = 1, #times do
        local key = slotKey(times[idx])
        if now >= slotTarget(times[idx], now) and last[key] ~= today then
            due[#due + 1] = key
        end
    end
    -- 先落盘：这把锁同时保证「每个时间点一天只弹一次」「FM/Reader 两个实例不
    -- 重复弹」「补弹只补一次」。
    markReminded(due, today)

    local written = lfs.attributes(self:getEntryPath(today), "mode") ~= nil
    local muted = (getSetting("reminder_skip_if_written") and written)
        or (getSetting("reminder_once_per_day") and already_fired_today)
    if #due > 0 and not muted then
        UIManager:show(ConfirmBox:new{
            text = _("该写日记了。"),
            ok_text = _("现在写"),
            ok_callback = function()
                self:showEntryDialog()
            end,
            cancel_text = _("稍后"),
        })
    end

    self:scheduleReminder() -- 排下一个时间点 / 明天
end

-- 时分选择器。slot 为 nil 表示新增一个时间点；否则是改 slot_index 这一个。
function Diary:showReminderTimeDialog(touchmenu_instance, slot_index)
    local times = getReminderTimes()
    local slot = slot_index and times[slot_index]
    UIManager:show(DiaryDateTime:new{
        hour = slot and slot.hour or 21,
        min = slot and slot.min or 0,
        ok_text = _("设置"),
        cancel_text = _("取消"),
        title_text = slot and _("修改提醒时间") or _("添加提醒时间"),
        info_text = _("选择每天提醒写日记的时间。"),
        -- OK 时 DateTimeWidget 是以 self:callback(self) 调用的，读 w.hour / w.min。
        callback = function(w)
            local updated = getReminderTimes()
            if slot_index then
                updated[slot_index] = { hour = w.hour, min = w.min }
            else
                updated[#updated + 1] = { hour = w.hour, min = w.min }
            end
            setReminderTimes(updated)
            -- 刚设的时间若今天已经过了，别立刻弹；从明天开始。
            local now = os.time()
            local new_slot = { hour = w.hour, min = w.min }
            if now >= slotTarget(new_slot, now) then
                markReminded({ slotKey(new_slot) }, os.date("%Y-%m-%d", now))
            end
            self:scheduleReminder()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })
end

function Diary:getReminderTimesMenu()
    local times = getReminderTimes()
    local items = {}
    for idx = 1, #times do
        local slot_index = idx
        items[#items + 1] = {
            text = slotKey(times[idx]),
            mandatory = _("长按删除"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showReminderTimeDialog(touchmenu_instance, slot_index)
            end,
            hold_callback = function(touchmenu_instance)
                local current = getReminderTimes()
                local victim = current[slot_index]
                if not victim then return end
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("删除提醒时间 %s？"), slotKey(victim)),
                    ok_text = _("删除"),
                    ok_callback = function()
                        table.remove(current, slot_index)
                        setReminderTimes(current)
                        self:scheduleReminder()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                    cancel_text = _("取消"),
                })
            end,
        }
    end
    items[#items + 1] = {
        text = _("添加提醒时间"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showReminderTimeDialog(touchmenu_instance)
        end,
    }
    return items
end

-------------------------------------------------------------------------------
-- 入口注册
-------------------------------------------------------------------------------

function Diary:onDispatcherRegisterActions()
    -- 均可绑定到手势 / 实体按键。
    Dispatcher:registerAction("diary_new_entry",
        { category = "none", event = "DiaryNewEntry", title = _("新建日记条目"), general = true })
    Dispatcher:registerAction("diary_review",
        { category = "none", event = "DiaryReview", title = _("回顾日记"), general = true })
    Dispatcher:registerAction("diary_calendar",
        { category = "none", event = "DiaryCalendar", title = _("日记日历"), general = true })
    Dispatcher:registerAction("diary_streak",
        { category = "none", event = "DiaryStreak", title = _("连续记日记天数"), general = true })
end

function Diary:init()
    self:onDispatcherRegisterActions()
    -- 每实例闭包：UIManager:unschedule 只认函数身份，用 self.method 的话会把
    -- 别的实例的同名任务一起解掉（见 autosuspend 插件的注释）。
    self.reminder_cb = function()
        self:fireReminder()
    end
    self:scheduleReminder()
    self.ui.menu:registerToMainMenu(self)
end

function Diary:onResume()
    self:scheduleReminder()
end

function Diary:onCloseWidget()
    UIManager:unschedule(self.reminder_cb)
end

function Diary:getSettingsMenu()
    return {
        {
            text = _("每日提醒"),
            separator = true,
            sub_item_table = {
                {
                    text = _("启用提醒"),
                    checked_func = function() return getSetting("reminder_enabled") end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        setSetting("reminder_enabled", not getSetting("reminder_enabled"))
                        self:scheduleReminder()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text_func = function()
                        return string.format(_("提醒时间：%s"), reminderTimesLabel())
                    end,
                    enabled_func = function() return getSetting("reminder_enabled") end,
                    sub_item_table_func = function() return self:getReminderTimesMenu() end,
                },
                {
                    text = _("今天已写过则不提醒"),
                    enabled_func = function() return getSetting("reminder_enabled") end,
                    checked_func = function() return getSetting("reminder_skip_if_written") end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        setSetting("reminder_skip_if_written",
                            not getSetting("reminder_skip_if_written"))
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("一天最多提醒一次"),
                    enabled_func = function() return getSetting("reminder_enabled") end,
                    checked_func = function() return getSetting("reminder_once_per_day") end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        setSetting("reminder_once_per_day",
                            not getSetting("reminder_once_per_day"))
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
        {
            text = _("导出为一个 Markdown 文件"),
            sub_item_table_func = function() return self:getExportMenu() end,
        },
    }
end

-- 主菜单 tools 分类下的一个子菜单。
function Diary:addToMainMenu(menu_items)
    menu_items.diary = {
        text = _("日记"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("写日记"),
                callback = function() self:showEntryDialog() end,
            },
            {
                text = _("回顾日记"),
                callback = function() self:showReview() end,
            },
            {
                text = _("日历查看"),
                callback = function() self:showCalendarToday() end,
            },
            {
                text = _("连续记日记天数"),
                separator = true,
                callback = function() self:showStreak() end,
            },
            {
                text = _("设置"),
                keep_menu_open = true,
                sub_item_table = self:getSettingsMenu(),
            },
        },
    }
end

-- Dispatcher 动作 → 事件处理器
function Diary:onDiaryNewEntry()
    self:showEntryDialog()
    return true
end

function Diary:onDiaryReview()
    self:showReview()
    return true
end

function Diary:onDiaryCalendar()
    self:showCalendarToday()
    return true
end

function Diary:onDiaryStreak()
    self:showStreak()
    return true
end

return Diary
