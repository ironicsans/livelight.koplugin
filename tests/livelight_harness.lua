-- Off-device simulation for livelight.koplugin: a fake screen, a fake light
-- that records every change, a fake clock, and a finger that produces the
-- same pan / pan_release / swipe events KOReader's gesture detector does.
local js = require("js")
local PLUGIN = js.global.PLUGIN_DIR

local W, H = 1072, 1448 -- Clara BW
local PAN_THRESHOLD = 66 -- how far a finger moves before KOReader calls it a pan

local now = 0
local tasks, shown, dirty, light_log = {}, {}, {}, {}
local settings = {}
G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
}

local has_warmth = true
local powerd = {
    fl_min = 0, fl_max = 100, fl_intensity = 40, is_fl_on = true,
    fl_warmth_min = 0, fl_warmth_max = 10, fl_warmth = 50, warmth_scale = 10,
}
function powerd:frontlightIntensity() if not self.is_fl_on then return 0 end return self.fl_intensity end
function powerd:setIntensity(n)
    if n == self:frontlightIntensity() then return false end
    self.fl_intensity = n; self.is_fl_on = true
    light_log[#light_log + 1] = "b" .. n
    return true
end
function powerd:turnOffFrontlight()
    if not self.is_fl_on then return false end
    self.is_fl_on = false
    light_log[#light_log + 1] = "off"
    return true
end
function powerd:frontlightWarmth() return self.fl_warmth end
function powerd:toNativeWarmth(w) return math.floor(w / self.warmth_scale + 0.5) end
function powerd:fromNativeWarmth(n) return math.floor(n * self.warmth_scale + 0.5) end
function powerd:setWarmth(w)
    if w == self.fl_warmth then return false end
    self.fl_warmth = w
    light_log[#light_log + 1] = "w" .. self:toNativeWarmth(w)
    return true
end
function powerd:updateResumeFrontlightState() light_log[#light_log + 1] = "resume-state" end

local function widgetClass()
    local cls = {}
    cls.extend = function(base, o) o = o or {}; setmetatable(o, { __index = base }); return o end
    cls.new = function(base, o) o = o or {}; setmetatable(o, { __index = base }); o.dimen = o.dimen or {}; if o.init then o:init() end; return o end
    cls.getSize = function() return { w = 200, h = 40 } end
    cls.setText = function(self, text) self.text = text end
    cls.free = function() end
    return cls
end
-- KOReader's list widget, as far as gestures go: it swallows every pan, and a
-- downward swipe closes it.
local menu_log = {}
local MenuStub = {}
function MenuStub:onPan(arg, ges) menu_log[#menu_log + 1] = ges.mousewheel_direction and "wheel" or "pan"; return true end
function MenuStub:onSwipe(arg, ges) menu_log[#menu_log + 1] = ges.direction == "south" and "closed" or "swipe" end
function MenuStub:onMultiSwipe(arg, ges) menu_log[#menu_log + 1] = "closed"; return true end
local stubs = {
    ["ui/widget/menu"] = MenuStub,
    ["ui/gesturerange"] = { new = function(_, o) return o end },
    ["gettext"] = function(s) return s end,
    ["ffi/blitbuffer"] = { COLOR_WHITE = 1 },
    ["ffi/util"] = { template = function(str, ...)
        local params = { ... }
        return (str:gsub("%%([1-9][0-9]?)", function(i) return tostring(params[tonumber(i)]) end))
    end },
    ["optmath"] = { round = function(n) return math.floor(n + 0.5) end },
    ["device"] = {
        screen = { getWidth = function() return W end, getHeight = function() return H end },
        hasFrontlight = function() return true end,
        isTouchDevice = function() return true end,
        hasNaturalLight = function() return has_warmth end,
        getPowerDevice = function() return powerd end,
    },
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/geometry"] = { new = function(_, o) return o end },
    ["ui/size"] = { border = { window = 2 }, radius = { window = 7 }, padding = { large = 10 }, span = { horizontal_default = 10 } },
    ["ui/widget/horizontalgroup"] = widgetClass(),
    ["ui/widget/container/leftcontainer"] = widgetClass(),
    ["ui/widget/horizontalspan"] = widgetClass(),
    ["ui/widget/container/centercontainer"] = widgetClass(),
    ["ui/widget/container/framecontainer"] = widgetClass(),
    ["ui/widget/container/widgetcontainer"] = widgetClass(),
    ["ui/widget/textwidget"] = widgetClass(),
    ["ui/widget/verticalgroup"] = widgetClass(),
    ["ui/widget/verticalspan"] = widgetClass(),
    ["ui/uimanager"] = {
        scheduleIn = function(_, delay, fn) tasks[#tasks + 1] = { at = now + delay, fn = fn } end,
        unschedule = function(_, fn) for i = #tasks, 1, -1 do if tasks[i].fn == fn then table.remove(tasks, i) end end end,
        show = function(_, w) shown[#shown + 1] = w; w.visible = true; if w.onShow then w:onShow() end end,
        close = function(_, w) w.visible = false; if w.onCloseWidget then w:onCloseWidget() end end,
        -- Record what would be redrawn: the text on screen and the e-ink mode.
        setDirty = function(_, w, fn)
            local mode, region = fn()
            dirty[#dirty + 1] = {
                text = w and (w.name .. " " .. w.number.text), mode = mode, at = now,
                -- which part of the screen: just the number, or the whole box
                part = w and (region == w.number_slot.dimen and "number" or region == w.word_slot.dimen and "word" or region == w.frame.dimen and "box" or "?") or "page",
                word = w and w.word.text,
            }
        end,
    },
}
local real_require = require
function require(name) if stubs[name] ~= nil then return stubs[name] end return real_require(name) end

local function advance(seconds)
    local target = now + seconds
    while true do
        local due
        for i, t in ipairs(tasks) do if t.at <= target and (not due or t.at < tasks[due].at) then due = i end end
        if not due then break end
        local t = table.remove(tasks, due)
        now = math.max(now, t.at)
        t.fn()
    end
    now = target
end

local L = dofile(PLUGIN .. "/main.lua")

-- The plugin's zones, as registered on a fake reader.
local zones, zone_order = {}, {}
local function newPlugin(document)
    zones, zone_order = {}, {}
    return L:new{ ui = {
        document = document,
        menu = { registerToMainMenu = function() end },
        registerTouchZones = function(_, list)
            for _, z in ipairs(list) do zones[z.ges] = z; zone_order[#zone_order + 1] = z.id end
        end,
    } }
end

-- A finger. down() then to() any number of times then lift() or flick().
-- Each call returns whether the plugin kept the event (true) or passed it on.
local finger = {}
local function down(x, y) finger = { x0 = x, y0 = y, x = x, y = y, panning = false } end
local function to(x, y)
    finger.x, finger.y = x, y
    if not finger.panning then
        if math.abs(x - finger.x0) < PAN_THRESHOLD and math.abs(y - finger.y0) < PAN_THRESHOLD then return nil end
        finger.panning = true
    end
    return zones.pan.handler({
        ges = "pan",
        start_pos = { x = finger.x0, y = finger.y0 },
        pos = { x = x, y = y },
        relative = { x = x - finger.x0, y = y - finger.y0 },
    })
end
-- Slide in small steps, as a real finger does, pausing between events.
local function slide(x, y, pause)
    local kept
    local steps = math.max(1, math.floor(math.max(math.abs(y - finger.y), math.abs(x - finger.x)) / 10))
    local fx, fy = finger.x, finger.y
    for i = 1, steps do
        local r = to(fx + (x - fx) * i / steps, fy + (y - fy) * i / steps)
        if r ~= nil then kept = r end
        advance(pause or 0.01)
    end
    return kept
end
local function lift() return zones.pan_release.handler({ ges = "pan_release", pos = { x = finger.x, y = finger.y } }) end
local function direction()
    local dx, dy = finger.x - finger.x0, finger.y - finger.y0
    if math.abs(dy) >= math.abs(dx) then return dy < 0 and "north" or "south" end
    return dx < 0 and "west" or "east"
end
local function flick(kind)
    kind = kind or "swipe"
    return zones[kind].handler({
        ges = kind,
        pos = { x = finger.x0, y = finger.y0 },
        end_pos = { x = finger.x, y = finger.y },
        direction = direction(),
    })
end

local failures = 0
local function check(label, cond, extra)
    if cond then print("  ok    " .. label) else failures = failures + 1; print("  FAIL  " .. label .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function log() return table.concat(light_log, ",") end
local function boxVisible() return shown[#shown] ~= nil and shown[#shown].visible == true end
local function boxText() return boxVisible() and (shown[#shown].name .. " " .. shown[#shown].number.text) or nil end
local plugin
local function fresh(case)
    print("\n== " .. case)
    advance(5)
    if plugin then plugin:onSuspend() end
    tasks, shown, dirty, light_log = {}, {}, {}, {}
    settings = {}
    has_warmth = true
    powerd.fl_intensity, powerd.is_fl_on, powerd.fl_warmth = 40, true, 50
    plugin = newPlugin()
end

local LEFT, RIGHT, MIDDLE = 40, W - 40, W / 2
local FULL = H * 0.7 -- finger travel for the whole range

do
    fresh("left edge, sliding up: brightness follows the finger before it lifts")
    down(LEFT, 1000)
    check("small wobble under the pan threshold does nothing", to(LEFT, 960) == nil and #light_log == 0)
    local kept = slide(LEFT, 1000 - PAN_THRESHOLD - 1)
    check("the plugin keeps the slide", kept == true)
    check("no jump at the moment the slide is recognized", powerd.fl_intensity == 40, powerd.fl_intensity)
    slide(LEFT, 1000 - PAN_THRESHOLD - FULL * 0.2)
    check("a fifth of the travel is +20, set while the finger is still down", powerd.fl_intensity == 60, powerd.fl_intensity)
    local steps = 0
    for _, e in ipairs(light_log) do if e:sub(1, 1) == "b" then steps = steps + 1 end end
    check("it got there one step at a time, not in a jump", steps == 20, steps)
    check("lifting is kept too", lift() == true)
    check("level unchanged by the lift, resume state recorded once", powerd.fl_intensity == 60 and light_log[#light_log] == "resume-state")
end
do
    fresh("left edge, quick slide that ends as a swipe")
    down(LEFT, 1000)
    slide(LEFT, 700, 0.001)
    local before = powerd.fl_intensity
    check("brightness went up during the slide", before > 40, before)
    check("the closing swipe is kept, so the Gestures plugin does not add its jump", flick() == true)
    check("and changes nothing more", powerd.fl_intensity == before, powerd.fl_intensity)
end
do
    fresh("left edge, up then back down ends as a multiswipe")
    down(LEFT, 1000)
    slide(LEFT, 700); slide(LEFT, 900)
    check("the multiswipe is kept", flick("multiswipe") == true)
    down(MIDDLE, 1000); slide(MIDDLE, 700); slide(MIDDLE, 900)
    check("a multiswipe elsewhere is passed on", flick("multiswipe") == false)
end
do
    fresh("right edge: warmth in the device's own steps")
    down(RIGHT, 800)
    slide(RIGHT, 800 - PAN_THRESHOLD - FULL * 0.3)
    check("three tenths of the travel is +3 of 10", powerd:toNativeWarmth(powerd.fl_warmth) == 8, log())
    check("each step set once", log() == "w6,w7,w8", log())
    slide(RIGHT, 800 - PAN_THRESHOLD + FULL * 0.2)
    check("sliding down past the start goes cooler", powerd:toNativeWarmth(powerd.fl_warmth) == 3, log())
    lift()
    check("brightness untouched", powerd.fl_intensity == 40)
end
do
    fresh("sideways from the left edge (a page turn) is left alone")
    down(LEFT, 800)
    check("pan passed on", slide(500, 810) == false)
    check("still passed on if it turns vertical afterward", slide(500, 400) == false)
    check("swipe passed on", flick() == false)
    check("light untouched, nothing drawn", #light_log == 0 and #shown == 0)
    down(LEFT, 800)
    check("the next touch at the edge is judged afresh", slide(LEFT, 600) == true)
    lift()
end
do
    fresh("vertical slide in the middle of the page is left alone")
    down(MIDDLE, 1000)
    check("pan passed on", slide(MIDDLE, 600) == false)
    check("pan release passed on", lift() == false)
    check("light untouched", #light_log == 0)
end
do
    fresh("the finger may wander off the strip once the slide has started")
    down(LEFT, 1000)
    slide(LEFT, 900)
    check("still kept and still changing out in the page", slide(400, 700) == true and powerd.fl_intensity > 50, powerd.fl_intensity)
    lift()
end
do
    fresh("top of the range: stops at 100, and turning back works at once")
    powerd.fl_intensity = 90
    down(LEFT, 1300)
    slide(LEFT, 300)
    check("stops at 100", powerd.fl_intensity == 100, powerd.fl_intensity)
    slide(LEFT, 300 + FULL * 0.1)
    check("a tenth of the travel back down is 90, without retracing the overshoot", powerd.fl_intensity == 90, powerd.fl_intensity)
    lift()
end
do
    fresh("bottom of the range: zero switches the light off, up brings it back")
    powerd.fl_intensity = 5
    down(LEFT, 400)
    slide(LEFT, 800)
    check("light switched off, once", powerd.is_fl_on == false and log():find("off", 1, true) and not log():find("off.*off"), log())
    check("box says 0", boxText() == "Brightness 0", boxText())
    slide(LEFT, 800 - FULL * 0.1)
    check("sliding up from off turns it on at 10", powerd.is_fl_on and powerd.fl_intensity == 10, log())
    lift()
    fresh("starting with the light off")
    powerd.is_fl_on = false
    down(LEFT, 1000); slide(LEFT, 1000 - PAN_THRESHOLD - 1); slide(LEFT, 1000 - PAN_THRESHOLD - 1 - FULL * 0.25); lift()
    check("counts up from zero, not from the remembered level", powerd.is_fl_on and powerd.fl_intensity == 25, log())
end
do
    fresh("level box: there at once, live but not flooding the screen")
    down(LEFT, 1000)
    slide(LEFT, 1000 - PAN_THRESHOLD - 1)
    check("box appears as soon as the slide is recognized, with the current level", boxText() == "Brightness 40", boxText())
    check("in the fast mode, and without its word yet", #dirty == 1 and dirty[1].mode == "fast" and dirty[1].part == "box" and dirty[1].word == "", #dirty)
    dirty = {}
    slide(LEFT, 1000 - PAN_THRESHOLD - FULL * 0.5, 0.01) -- 50 steps in about half a second
    check("light changed 50 times", powerd.fl_intensity == 90, powerd.fl_intensity)
    local words, numbers, all_fast, rising, last = 0, 0, true, true, 40
    for _, d in ipairs(dirty) do
        if d.part == "word" then
            words = words + 1
            if d.mode ~= "ui" or d.word ~= "Brightness" then words = -99 end
        else
            numbers = numbers + 1
            if d.mode ~= "fast" or d.part ~= "number" then all_fast = false end
            local n = tonumber(d.text:match("(%d+)$"))
            if n < last then rising = false end
            last = n
        end
    end
    check("the word is added once, a moment later, in the smooth mode and by itself", words == 1, words)
    check("number redrawn a handful of times, not 50", numbers >= 2 and numbers <= 5, numbers)
    check("every one of those is fast and covers the number only", all_fast)
    check("the numbers shown climb with the finger", rising and last > 40, last)
    advance(0.2)
    check("when the finger pauses, the box catches up to the true level", boxText() == "Brightness 90", boxText())
    dirty = {}
    advance(3)
    check("and is then left alone, however long the finger rests", #dirty == 0, #dirty)
    lift()
    check("lifting redraws nothing when the number is already right", #dirty == 0, #dirty)
    advance(0.5)
    check("box still there half a second later", boxVisible())
    dirty = {}
    advance(0.6)
    check("then gone, and the page underneath redrawn cleanly", not boxVisible() and #dirty == 1 and dirty[1].mode == "ui" and dirty[1].part == "page")
    check("only one box was ever created", #shown == 1, #shown)
    down(LEFT, 1000); slide(LEFT, 700, 0.001); dirty = {}; lift()
    check("a lift that arrives before the last number was drawn draws it, fast", #dirty == 1 and dirty[1].mode == "fast" and dirty[1].part == "number" and dirty[1].text == boxText(), #dirty)
end
do
    fresh("a slide shorter than the wait for the word")
    down(LEFT, 1000); slide(LEFT, 900, 0.0005); lift()
    dirty = {}
    advance(0.2)
    check("the word is still added while the box lingers", #dirty == 1 and dirty[1].part == "word" and dirty[1].mode == "ui", #dirty)
    advance(1); dirty = {}
    advance(1)
    check("and not after the box has gone", #dirty == 0 and #tasks == 0, #tasks)
end
do
    fresh("a second slide before the box has gone reuses it")
    down(LEFT, 1000); slide(LEFT, 900); lift()
    advance(0.5)
    down(RIGHT, 1000); slide(RIGHT, 1000 - PAN_THRESHOLD - FULL * 0.1)
    advance(1.5)
    check("the warmth box is sized for warmth's own top value, not brightness's", shown[2].widest_value == "10" and shown[1].widest_value == "100", shown[2].widest_value)
    check("a fresh box replaces it, showing warmth, and stays while the slide is going", boxText() == "Warmth 6" and #shown == 2 and not shown[1].visible, boxText())
    lift(); advance(1.1)
    check("gone after that one ends", not boxVisible())
end
do
    fresh("quick flick, too fast to be seen as a slide")
    down(LEFT, 1000); finger.y = 1000 - FULL * 0.3
    check("kept", flick() == true)
    check("applies the whole distance", powerd.fl_intensity == 70, powerd.fl_intensity)
    check("box shown with the result, then removed", boxText() == "Brightness 70", boxText())
    advance(1.1); check("box gone", not boxVisible())
    down(LEFT, 1000); finger.x = 500
    check("a sideways flick from the edge is passed on", flick() == false and powerd.fl_intensity == 70)
    down(MIDDLE, 1000); finger.y = 500
    check("a vertical flick in the middle is passed on", flick() == false and powerd.fl_intensity == 70)
end
do
    fresh("box turned off in settings")
    settings.livelight = { enabled = true, show_level = false }
    down(LEFT, 1000); slide(LEFT, 700); lift()
    check("light changes, nothing drawn", powerd.fl_intensity > 40 and #shown == 0 and #dirty == 0)
end
do
    fresh("plugin turned off in settings")
    settings.livelight = { enabled = false }
    down(LEFT, 1000)
    check("pan passed on", slide(LEFT, 700) == false)
    check("swipe passed on to the Gestures plugin", flick() == false)
    check("light untouched", #light_log == 0)
end
do
    fresh("device without warmth")
    has_warmth = false
    down(RIGHT, 1000)
    check("right edge passed on", slide(RIGHT, 700) == false and lift() == false and #light_log == 0)
    down(LEFT, 1000)
    check("left edge still works", slide(LEFT, 700) == true and powerd.fl_intensity > 40)
    lift()
end
do
    fresh("a slide whose lift never arrives does not leak into the next touch")
    down(LEFT, 1000); slide(LEFT, 800)
    local level = powerd.fl_intensity
    down(MIDDLE, 1000)
    check("next touch, in the middle, is passed on", slide(MIDDLE, 600) == false)
    check("and does not move the light", powerd.fl_intensity == level, powerd.fl_intensity)
    advance(1.1); check("the stale box is cleared", not boxVisible())
end
do
    fresh("device sleeps mid-slide")
    down(LEFT, 1000); slide(LEFT, 800)
    plugin:onSuspend()
    check("box removed, nothing left scheduled", not boxVisible() and #tasks == 0, #tasks)
end
do
    fresh("zones and menu")
    local function has(list, id) for _, v in ipairs(list) do if v == id then return true end end return false end
    check("four zones registered", #zone_order == 4, table.concat(zone_order, ","))
    -- Bookshelf's rule for which of the file browser's zones it will offer a touch to.
    local function bookshelfAllows(id) return id:find("^filemanager_") ~= nil end
    local allowed = 0
    for _, id in ipairs(zone_order) do if bookshelfAllows(id) then allowed = allowed + 1 end end
    check("in the file browser, all four are named so that a home screen on top passes touches to them", allowed == 4, table.concat(zone_order, ","))
    newPlugin({})
    allowed = 0
    for _, id in ipairs(zone_order) do if bookshelfAllows(id) or id:find("^readermenu_") then allowed = allowed + 1 end end
    check("in a book they keep their own names", allowed == 0 and #zone_order == 4, table.concat(zone_order, ","))
    plugin = newPlugin()
    check("all cover the whole screen", zones.pan.screen_zone.ratio_w == 1 and zones.swipe.screen_zone.ratio_h == 1)
    check("pan is ahead of the reader's page and scroll pans", has(zones.pan.overrides, "paging_pan") and has(zones.pan.overrides, "rolling_pan"))
    check("swipe is ahead of the Gestures plugin's four edge swipes",
        has(zones.swipe.overrides, "one_finger_swipe_left_edge_up") and has(zones.swipe.overrides, "one_finger_swipe_left_edge_down")
        and has(zones.swipe.overrides, "one_finger_swipe_right_edge_up") and has(zones.swipe.overrides, "one_finger_swipe_right_edge_down"))
    check("and of page-turn swipes", has(zones.swipe.overrides, "paging_swipe") and has(zones.swipe.overrides, "rolling_swipe"))
    check("multiswipe is ahead of the Gestures plugin's", has(zones.multiswipe.overrides, "multiswipe"))
    local items = {}
    plugin:addToMainMenu(items)
    local sub = items.livelight.sub_item_table
    check("menu entry under Taps and gestures with three items", items.livelight.sorting_hint == "taps_and_gestures" and #sub == 3)
    check("both on by default, sides not swapped", sub[1].checked_func() and sub[2].checked_func() and sub[3].checked_func() == false)
    sub[3].callback(); check("swap toggle saved", settings.livelight.swap_sides == true); sub[3].callback()
    check("every label is short enough for the menu", #sub[1].text <= 26 and #sub[2].text <= 26 and #sub[3].text <= 26)
    sub[2].callback(); check("box toggle saved", settings.livelight.show_level == false); sub[2].callback()
    sub[1].callback(); check("main toggle saved; box toggle grayed out with it", settings.livelight.enabled == false and sub[2].enabled_func() == false)
    sub[1].callback(); check("and back on", settings.livelight.enabled == true and sub[2].enabled_func() == true)
end

do
    fresh("sides swapped in settings")
    settings.livelight = { swap_sides = true }
    down(LEFT, 800); slide(LEFT, 800 - PAN_THRESHOLD - 1); slide(LEFT, 800 - PAN_THRESHOLD - 1 - FULL * 0.3)
    check("left edge is now warmth", powerd:toNativeWarmth(powerd.fl_warmth) == 8 and powerd.fl_intensity == 40, log())
    check("and the box says so", boxText() == "Warmth 8", boxText())
    lift(); advance(1.1)
    down(RIGHT, 800); slide(RIGHT, 800 - PAN_THRESHOLD - 1); slide(RIGHT, 800 - PAN_THRESHOLD - 1 - FULL * 0.2)
    check("right edge is now brightness", powerd.fl_intensity == 60 and powerd:toNativeWarmth(powerd.fl_warmth) == 8, log())
    lift()
    down(MIDDLE, 800)
    check("the middle is still left alone", slide(MIDDLE, 500) == false)
    lift()
    fresh("sides swapped on a device without warmth")
    settings.livelight = { swap_sides = true }
    has_warmth = false
    down(LEFT, 800)
    check("left edge, which would be warmth, is passed on", slide(LEFT, 500) == false and #light_log == 0)
    lift()
    down(RIGHT, 800)
    check("right edge is brightness", slide(RIGHT, 500) == true and powerd.fl_intensity > 40)
    lift()
end
do
    fresh("a device with 24 brightness levels, like a Kindle")
    powerd.fl_max, powerd.fl_intensity = 24, 10
    down(LEFT, 1000); slide(LEFT, 1000 - PAN_THRESHOLD - 1)
    check("the box shows the device's own level, not a percentage", boxText() == "Brightness 10", boxText())
    light_log = {}
    slide(LEFT, 1000 - PAN_THRESHOLD - 1 - FULL * 0.5)
    check("half the travel is 12 of the 24 levels", powerd.fl_intensity == 22, powerd.fl_intensity)
    check("one light change per level, so 12 in all", #light_log == 12, #light_log)
    advance(0.2)
    check("box follows", boxText() == "Brightness 22", boxText())
    slide(LEFT, 100)
    check("stops at the top level", powerd.fl_intensity == 24 and shown[#shown].widest_value == "24", powerd.fl_intensity)
    lift()
    powerd.fl_max = 100
end

-- A list on screen. Events reach it the way KOReader delivers them: pans to
-- onPan, the lift to whichever of its ges_events matches, else onwards (to the
-- file browser's zones when it is the file browser's own list, nowhere otherwise).
local function newList(width, in_file_browser)
    local list = setmetatable({ dimen = { w = width, h = H }, ges_events = {} }, { __index = MenuStub })
    function list:pan(x, y)
        finger.x, finger.y = x, y
        return self:onPan(nil, {
            ges = "pan",
            start_pos = { x = finger.x0, y = finger.y0 },
            pos = { x = x, y = y },
            relative = { x = x - finger.x0, y = y - finger.y0 },
        })
    end
    function list:slide(x, y, pause)
        local steps = math.max(1, math.floor(math.max(math.abs(y - finger.y), math.abs(x - finger.x)) / 10))
        local fx, fy = finger.x, finger.y
        for i = 1, steps do
            self:pan(fx + (x - fx) * i / steps, fy + (y - fy) * i / steps)
            advance(pause or 0.01)
        end
    end
    function list:lift()
        local ev = { ges = "pan_release", pos = { x = finger.x, y = finger.y } }
        for name, ranges in pairs(self.ges_events) do
            if ranges[1].ges == "pan_release" and self["on" .. name](self, nil, ev) then return "list" end
        end
        if in_file_browser and zones.pan_release.handler(ev) then return "zone" end
        return "nobody"
    end
    function list:flick(kind)
        local ev = { ges = kind or "swipe", pos = { x = finger.x0, y = finger.y0 }, end_pos = { x = finger.x, y = finger.y }, direction = direction() }
        if in_file_browser then return zones[ev.ges].handler(ev) end -- its list leaves swipes to the zones
        if ev.ges == "swipe" then return self:onSwipe(nil, ev) end
        return self:onMultiSwipe(nil, ev)
    end
    return list
end
local function freshList(case, width, in_file_browser)
    fresh(case)
    menu_log = {}
    return newList(width or W, in_file_browser)
end
do
    local list = freshList("file browser: brightness follows the finger there too", W, true)
    down(LEFT, 1000)
    list:slide(LEFT, 930)
    local base = powerd.fl_intensity
    check("light already changing a short way in, finger still down", base > 40, base)
    list:slide(LEFT, 930 - FULL * 0.2)
    check("a fifth of the travel further is +20", powerd.fl_intensity == base + 20, powerd.fl_intensity)
    advance(0.2)
    check("box shown", boxText() == "Brightness " .. (base + 20), boxText())
    check("the lift is heard", list:lift() ~= "nobody")
    check("and ends the slide", light_log[#light_log] == "resume-state")
    advance(1.1); check("box goes away", not boxVisible())
    down(RIGHT, 1000); list:slide(RIGHT, 990); list:slide(RIGHT, 990 - FULL * 0.3)
    check("right edge is warmth", powerd:toNativeWarmth(powerd.fl_warmth) == 8, log())
    local level = powerd.fl_intensity
    check("a quick slide's closing swipe is kept from the Gestures plugin", list:flick() == true and powerd.fl_intensity == level)
end
do
    local list = freshList("file browser: everything else is left to the list", W, true)
    down(MIDDLE, 1000); list:slide(MIDDLE, 600)
    check("a pan in the middle goes to the list as before", #light_log == 0 and menu_log[1] == "pan")
    list:lift()
    down(LEFT, 1000); list:slide(500, 1010)
    check("so does a sideways one from the edge", #light_log == 0)
    list:lift(); menu_log = {}
    list:onPan(nil, { ges = "pan", mousewheel_direction = 1, direction = "north", pos = { x = LEFT, y = 500 } })
    check("and a mouse wheel", menu_log[1] == "wheel" and #light_log == 0)
end
do
    local list = freshList("History and other full-screen lists")
    down(LEFT, 600)
    list:slide(LEFT, 610, 0.001)
    list:slide(LEFT, 610 + FULL * 0.2, 0.001)
    check("sliding down dims", powerd.fl_intensity == 20, powerd.fl_intensity)
    check("the swipe that ends a quick downward slide is kept", list:flick() == true)
    check("so the list is not closed by it", menu_log[#menu_log] ~= "closed", table.concat(menu_log, ","))
    down(LEFT, 600); list:slide(LEFT, 400); list:slide(LEFT, 500)
    check("nor by an up-and-down slide", list:flick("multiswipe") == true and menu_log[#menu_log] ~= "closed")
    down(LEFT, 1000); list:slide(LEFT, 800)
    check("a slow slide's lift is heard by the list itself", list:lift() == "list" and light_log[#light_log] == "resume-state")
    advance(1.1); check("box goes away", not boxVisible())
    menu_log = {}
    down(MIDDLE, 600); finger.y = 900
    list:flick()
    check("an ordinary downward swipe still closes the list", menu_log[1] == "closed")
    down(LEFT, 600); finger.y = 900
    list:flick()
    check("even from the edge, if it was too quick to be a slide", menu_log[2] == "closed", table.concat(menu_log, ","))
end
do
    local list = freshList("pop-up menu, narrower than the screen", W * 0.6)
    down(LEFT, 1000); list:slide(LEFT, 700)
    check("left alone", #light_log == 0 and menu_log[1] == "pan" and #shown == 0)
end
do
    local list = freshList("a slide whose lift is never reported is wound up by itself")
    down(LEFT, 1000); list:slide(LEFT, 800)
    advance(4)
    check("box still there while the finger might just be resting", boxVisible())
    advance(2.5)
    check("then the slide is closed and the box removed", not boxVisible() and light_log[#light_log] == "resume-state" and #tasks == 0, #tasks)
    local level = powerd.fl_intensity
    list:pan(LEFT, 790)
    check("if the finger was resting after all, there is no jump when it moves again", powerd.fl_intensity == level, powerd.fl_intensity)
    list:slide(LEFT, 790 - FULL * 0.1)
    check("and it carries on from where it was", powerd.fl_intensity == level + 10, powerd.fl_intensity)
    list:lift()
end
do
    fresh("turned off in settings: lists behave exactly as before")
    settings.livelight = { enabled = false }
    menu_log = {}
    local list = newList(W)
    down(LEFT, 1000); list:slide(LEFT, 900)
    check("pans go to the list", #light_log == 0 and menu_log[1] == "pan")
    finger.y = 1300; list:flick()
    check("swipes too", menu_log[#menu_log] == "closed")
end

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
if failures > 0 then error("failures") end
