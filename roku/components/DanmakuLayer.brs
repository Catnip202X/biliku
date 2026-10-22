' Scrolling comments cross the screen in 8 s on one of LANES lanes (top ~60% of the screen).
' Top / bottom comments (modes 5 / 4) sit centred for 4 s.
sub init()
    m.LANES = 11
    m.LANE_HEIGHT = 54
    m.FIRST_LANE_Y = 30
    m.SCROLL_MS = 8000
    m.FIXED_MS = 4000
    m.MAX_ON_SCREEN = 90

    m.font = invalid
    if m.global.cjkFont <> ""
        m.font = CreateObject("roSGNode", "Font")
        m.font.uri = m.global.cjkFont
        m.font.size = 38
    end if

    m.items = []
    m.nextItem = 0
    m.basePos = 0.0
    m.clock = CreateObject("roTimespan")
    m.laneFree = []
    m.topFree = []
    m.bottomFree = []
    for i = 0 to m.LANES - 1
        m.laneFree.Push(0)
    end for
    for i = 0 to 3
        m.topFree.Push(0)
        m.bottomFree.Push(0)
    end for
    m.live = {}
    m.serial = 0
    m.spawned = 0

    m.showScroll = true
    m.showFixed = true
    m.showColor = true
    m.avoidSubs = false
    m.fontScale = 1.0
    m.blockWords = []
    m.blockPatterns = []
    m.blockUsers = {}

    m.timer = m.top.findNode("tick")
    m.timer.observeField("fire", "onTick")
    m.timer.control = "start"
end sub

sub onSettings()
    st = m.top.settings
    if st = invalid then return
    m.showScroll = (st.scroll = true)
    m.showFixed = (st.fixed = true)
    m.showColor = (st.color = true)
    m.avoidSubs = (st.avoidsubs = true)
    m.fontScale = st.size / 100
    m.LANE_HEIGHT = Int(54 * m.fontScale)
    speeds = [12000, 10000, 8000, 6500, 5000]
    index = st.speed - 1
    if index < 0 then index = 0
    if index > 4 then index = 4
    m.SCROLL_MS = speeds[index]
    ' 显示区域: share of the screen (from the top) that scrolling danmaku may use.
    usable = 1080 * st.area / 100
    if m.avoidSubs and usable > 860 then usable = 860
    lanes = Int((usable - m.FIRST_LANE_Y) / m.LANE_HEIGHT)
    if lanes < 1 then lanes = 1
    m.LANES = lanes
    m.laneFree = []
    for i = 0 to m.LANES - 1
        m.laneFree.Push(0)
    end for
    m.top.opacity = st.opacity / 100
    if m.global.cjkFont <> ""
        m.font = CreateObject("roSGNode", "Font")
        m.font.uri = m.global.cjkFont
        m.font.size = Int(38 * m.fontScale)
    end if
    clearAll()
end sub

sub onFilters()
    f = m.top.filters
    m.blockWords = []
    m.blockPatterns = []
    m.blockUsers = {}
    if f = invalid then return
    if f.keywords <> invalid then m.blockWords = f.keywords
    if f.users <> invalid
        for each u in f.users
            m.blockUsers[u] = true
        end for
    end if
    if f.patterns <> invalid
        for each pattern in f.patterns
            re = CreateObject("roRegex", pattern, "i")
            if re <> invalid then m.blockPatterns.Push(re)
        end for
    end if
end sub

' Type filters (滚动 / 固定 / 彩色) and the account block list.
function isHidden(item as Object) as Boolean
    if item.mode = 4 or item.mode = 5
        if not m.showFixed then return true
    else if not m.showScroll
        return true
    end if
    if not m.showColor and item.color <> &hFFFFFF then return true
    if item.hash <> invalid and item.hash <> "" and m.blockUsers.DoesExist(item.hash) then return true
    if m.blockWords.Count() > 0 or m.blockPatterns.Count() > 0
        lower = LCase(item.text)
        for each word in m.blockWords
            if Instr(1, lower, word) > 0 then return true
        end for
        for each re in m.blockPatterns
            if re.IsMatch(item.text) then return true
        end for
    end if
    return false
end function

' Current playback time in ms, interpolated between the player's position updates.
function nowMs() as Integer
    t = m.basePos * 1000
    if m.top.playing then t = t + m.clock.TotalMilliseconds()
    return Int(t)
end function

sub onItems()
    clearAll()
    m.items = m.top.items
    if m.items = invalid then m.items = []
    print "[biliku] danmaku layer got "; m.items.Count(); " items"
    m.spawned = 0
    seekTo(m.top.position)
end sub

sub onPosition()
    posSec = m.top.position
    ' A jump of more than 2 s is a seek: drop what's on screen and continue from the new spot.
    if Abs(posSec * 1000 - nowMs()) > 2000
        clearAll()
        seekTo(posSec)
    end if
    m.basePos = posSec
    m.clock.Mark()
end sub

sub seekTo(posSec as Float)
    target = posSec * 1000
    m.nextItem = 0
    while m.nextItem < m.items.Count() and m.items[m.nextItem].t < target
        m.nextItem = m.nextItem + 1
    end while
    for i = 0 to m.LANES - 1
        m.laneFree[i] = 0
    end for
    m.basePos = posSec
    m.clock.Mark()
end sub

sub onPlaying()
    m.clock.Mark()
    control = "pause"
    if m.top.playing then control = "resume"
    for each key in m.live
        m.live[key].anim.control = control
    end for
end sub

sub onEnabled()
    m.top.visible = m.top.enabled
    if not m.top.enabled then clearAll()
    seekTo(m.top.position)
end sub

sub onTick()
    if not m.top.enabled or not m.top.playing then return
    now = nowMs()
    while m.nextItem < m.items.Count() and m.items[m.nextItem].t <= now
        item = m.items[m.nextItem]
        m.nextItem = m.nextItem + 1
        ' Skip comments that are already well in the past (e.g. after buffering).
        if now - item.t < 1500 and m.live.Count() < m.MAX_ON_SCREEN and not isHidden(item) then spawn(item, now)
    end while
end sub

sub spawn(item as Object, now as Integer)
    m.serial = m.serial + 1
    id = "dm" + m.serial.ToStr()
    g = m.top.createChild("Group")
    g.id = id
    shadow = g.createChild("Label")
    text = g.createChild("Label")
    for each l in [shadow, text]
        if m.font <> invalid then l.font = m.font else l.font = "font:MediumBoldSystemFont"
        l.text = item.text
    end for
    shadow.color = "0x000000C0"
    shadow.translation = [2, 2]
    text.color = rgbToColor(item.color)
    width = text.boundingRect().width

    anim = m.top.createChild("Animation")
    anim.easeFunction = "linear"
    anim.repeat = false

    if item.mode = 4 or item.mode = 5
        ' Fixed top / bottom comment
        slots = m.topFree
        if item.mode = 4 then slots = m.bottomFree
        slot = -1
        for i = 0 to slots.Count() - 1
            if slots[i] <= now
                slot = i
                exit for
            end if
        end for
        if slot < 0
            m.top.removeChild(g)
            m.top.removeChild(anim)
            return
        end if
        slots[slot] = now + m.FIXED_MS
        y = m.FIRST_LANE_Y + slot * m.LANE_HEIGHT
        if item.mode = 4
            bottom = 1080 - 140
            if m.avoidSubs then bottom = 860 - m.LANE_HEIGHT
            y = bottom - slot * m.LANE_HEIGHT
        end if
        g.translation = [Int((1920 - width) / 2), y]
        anim.duration = m.FIXED_MS / 1000
        fade = anim.createChild("FloatFieldInterpolator")
        fade.fieldToInterp = id + ".opacity"
        fade.key = [0.0, 0.85, 1.0]
        fade.keyValue = [1.0, 1.0, 0.0]
    else
        ' Scrolling comment: first lane whose previous comment has fully entered the screen.
        lane = -1
        for i = 0 to m.LANES - 1
            if m.laneFree[i] <= now
                lane = i
                exit for
            end if
        end for
        if lane < 0
            m.top.removeChild(g)
            m.top.removeChild(anim)
            return
        end if
        speed = (1920 + width) / m.SCROLL_MS
        m.laneFree[lane] = now + Int((width + 80) / speed)
        y = m.FIRST_LANE_Y + lane * m.LANE_HEIGHT
        g.translation = [1920, y]
        anim.duration = m.SCROLL_MS / 1000
        move = anim.createChild("Vector2DFieldInterpolator")
        move.fieldToInterp = id + ".translation"
        move.key = [0.0, 1.0]
        move.keyValue = [[1920, y], [-width - 20, y]]
    end if

    m.spawned = m.spawned + 1
    if m.spawned <= 3 or m.spawned mod 50 = 0 then print "[biliku] danmaku shown #"; m.spawned; " at "; now; "ms: "; Left(item.text, 20)
    anim.id = id + "a"
    anim.observeField("state", "onAnimState")
    m.live[id] = { group: g, anim: anim }
    anim.control = "start"
end sub

sub onAnimState(event as Object)
    anim = event.getRoSGNode()
    if anim.state <> "stopped" then return
    id = Left(anim.id, Len(anim.id) - 1)
    if m.live.DoesExist(id)
        m.top.removeChild(m.live[id].group)
        m.live.Delete(id)
    end if
    m.top.removeChild(anim)
end sub

sub clearAll()
    for each id in m.live
        entry = m.live[id]
        entry.anim.unobserveField("state")
        entry.anim.control = "stop"
        m.top.removeChild(entry.anim)
        m.top.removeChild(entry.group)
    end for
    m.live = {}
    for i = 0 to m.topFree.Count() - 1
        m.topFree[i] = 0
        m.bottomFree[i] = 0
    end for
end sub

' 0xRRGGBB integer -> "0xRRGGBBFF" color string
function rgbToColor(rgb as Integer) as String
    digits = "0123456789ABCDEF"
    hex = ""
    v = rgb
    for i = 1 to 6
        hex = Mid(digits, (v mod 16) + 1, 1) + hex
        v = v \ 16
    end for
    return "0x" + hex + "FF"
end function
