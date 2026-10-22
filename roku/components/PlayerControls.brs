' Player bar: ←/→ move between buttons, OK activates, Back closes (or closes the open list/panel).
' Lists (章节 / 选集 / 画质) use a LabelList; the danmaku panel is drawn here: ↑/↓ pick a row,
' ←/→ change a slider, OK flips a switch.

sub init()
    m.fill = m.top.findNode("fill")
    m.marks = m.top.findNode("marks")
    m.chapterNow = m.top.findNode("chapterNow")
    m.buttonsGroup = m.top.findNode("buttons")
    m.popup = m.top.findNode("popup")
    m.popupBg = m.top.findNode("popupBg")
    m.popupTitle = m.top.findNode("popupTitle")
    m.popupList = m.top.findNode("popupList")
    m.dmPanel = m.top.findNode("dmPanel")
    m.dmBg = m.top.findNode("dmBg")
    m.dmRows = m.top.findNode("dmRows")
    m.dmHint = m.top.findNode("dmHint")
    m.hideTimer = m.top.findNode("hideTimer")

    m.TRACK_W = 1728
    m.ACCENT = "0x00AEECFF"
    m.fonts = {}
    if m.global.cjkFont <> ""
        for each size in [24, 28, 30, 36]
            f = CreateObject("roSGNode", "Font")
            f.uri = m.global.cjkFont
            f.size = size
            m.fonts[size.ToStr()] = f
        end for
        m.chapterNow.font = m.fonts["28"]
        m.popupTitle.font = m.fonts["36"]
        m.top.findNode("dmTitle").font = m.fonts["36"]
        m.dmHint.font = m.fonts["24"]
        m.popupList.font = m.fonts["30"]
        m.popupList.focusedFont = m.fonts["30"]
    end if

    m.buttons = []
    m.focus = 0
    m.listMode = ""
    m.dmRow = 0
    m.cdnNames = ["B站分配 Default", "华为 Huawei", "Akamai"]
    m.rowDefs = [
        { key: "scroll", label: "滚动弹幕  Scrolling", kind: "toggle" }
        { key: "fixed", label: "顶部/底部  Top & bottom", kind: "toggle" }
        { key: "color", label: "彩色弹幕  Coloured", kind: "toggle" }
        { key: "avoidsubs", label: "防挡字幕  Avoid subtitles", kind: "toggle" }
        { key: "area", label: "显示区域  Area", kind: "slider", low: 25, high: 100, inc: 25, unit: "%" }
        { key: "opacity", label: "不透明度  Opacity", kind: "slider", low: 10, high: 100, inc: 10, unit: "%" }
        { key: "size", label: "弹幕字号  Size", kind: "slider", low: 50, high: 200, inc: 10, unit: "%" }
        { key: "speed", label: "弹幕速度  Speed", kind: "slider", low: 1, high: 5, inc: 1, names: ["极慢", "较慢", "适中", "较快", "极快"] }
    ]
    m.popupList.observeField("itemSelected", "onListChosen")
    m.hideTimer.observeField("fire", "onIdle")
end sub

function fontOf(size as Integer) as Dynamic
    if m.fonts.DoesExist(size.ToStr()) then return m.fonts[size.ToStr()]
    return invalid
end function

' ---------- showing / layout ----------

sub onShow()
    closePopup()
    closeDmPanel()
    buildButtons()
    buildMarks()
    onProgress()
    m.top.setFocus(true)
    restartIdle()
end sub

sub restartIdle()
    m.hideTimer.control = "stop"
    m.hideTimer.control = "start"
end sub

sub onIdle()
    if not m.popup.visible and not m.dmPanel.visible then m.top.action = { type: "close" }
end sub

sub buildButtons()
    m.buttonsGroup.removeChildrenIndex(m.buttonsGroup.getChildCount(), 0)
    m.buttons = []
    playText = "‖"
    if m.top.paused then playText = "▶"
    leftDefs = [{ id: "play", text: playText }]
    m.timeLabel = invalid
    chapters = m.top.chapters
    if chapters <> invalid and chapters.Count() > 0 then leftDefs.Push({ id: "chapter", text: "章节 · " + currentChapterTitle() })
    parts = m.top.parts
    if parts <> invalid and parts.Count() > 1 then leftDefs.Push({ id: "part", text: "选集 P" + (m.top.partIndex + 1).ToStr() + "/" + parts.Count().ToStr() })
    rightDefs = []
    qualities = m.top.qualities
    if qualities <> invalid and qualities.Count() > 0 then rightDefs.Push({ id: "quality", text: qualityText() })
    if qualities <> invalid and qualities.Count() > 0 then rightDefs.Push({ id: "cdn", text: "线路 " + m.cdnNames[m.top.cdnIndex] })
    dmText = "弹幕 关"
    if m.top.danmakuOn then dmText = "弹幕 开"
    rightDefs.Push({ id: "danmaku", text: dmText })
    rightDefs.Push({ id: "dmSettings", text: "弹幕设置" })

    x = 96
    for each b in leftDefs
        x = x + addButton(b, x) + 16
        if b.id = "play"
            m.timeLabel = m.buttonsGroup.createChild("Label")
            m.timeLabel.translation = [x, 12]
            m.timeLabel.color = "0xF2F5F8FF"
            if fontOf(30) <> invalid then m.timeLabel.font = fontOf(30) else m.timeLabel.font = "font:MediumSystemFont"
            m.timeLabel.text = "00:00 / 00:00"
            x = x + 230
        end if
    end for
    ' Right-hand group, laid out from the rightDefs edge.
    widths = []
    total = 0
    for each b in rightDefs
        w = measure(b.text) + 40
        widths.Push(w)
        total = total + w + 16
    end for
    x = 1824 - total + 16
    for i = 0 to rightDefs.Count() - 1
        x = x + addButton(rightDefs[i], x) + 16
    end for
    if m.focus >= m.buttons.Count() then m.focus = 0
    paintFocus()
end sub

function measure(text as String) as Integer
    probe = CreateObject("roSGNode", "Label")
    if fontOf(30) <> invalid then probe.font = fontOf(30) else probe.font = "font:MediumSystemFont"
    probe.text = text
    return Int(probe.boundingRect().width)
end function

' Adds a button at x; returns its width.
function addButton(def as Object, x as Integer) as Integer
    g = m.buttonsGroup.createChild("Group")
    g.translation = [x, 0]
    bg = g.createChild("Rectangle")
    label = g.createChild("Label")
    if fontOf(30) <> invalid then label.font = fontOf(30) else label.font = "font:MediumSystemFont"
    label.text = def.text
    label.translation = [20, 12]
    w = Int(label.boundingRect().width) + 40
    bg.width = w
    bg.height = 64
    m.buttons.Push({ id: def.id, group: g, bg: bg, label: label })
    return w
end function

sub paintFocus()
    for i = 0 to m.buttons.Count() - 1
        b = m.buttons[i]
        if i = m.focus and not m.popup.visible and not m.dmPanel.visible
            b.bg.color = m.ACCENT
            b.label.color = "0x101418FF"
        else
            b.bg.color = "0xFFFFFF1F"
            b.label.color = "0xF2F5F8FF"
        end if
    end for
end sub

function buttonIndex(id as String) as Integer
    for i = 0 to m.buttons.Count() - 1
        if m.buttons[i].id = id then return i
    end for
    return -1
end function

sub setButtonText(id as String, text as String)
    i = buttonIndex(id)
    if i >= 0 then m.buttons[i].label.text = text
end sub

sub buildMarks()
    m.marks.removeChildrenIndex(m.marks.getChildCount(), 0)
    chapters = m.top.chapters
    duration = m.top.duration
    if chapters = invalid or duration <= 0 then return
    for each c in chapters
        if c.start > 0
            mark = m.marks.createChild("Rectangle")
            mark.width = 4
            mark.height = 8
            mark.color = "0x000000FF"
            mark.translation = [Int(m.TRACK_W * c.start / duration), 0]
        end if
    end for
end sub

' ---------- live state ----------

sub onProgress()
    duration = m.top.duration
    at = m.top.position
    if duration > 0 then m.fill.width = Int(m.TRACK_W * at / duration) else m.fill.width = 0
    if m.timeLabel <> invalid then m.timeLabel.text = clock(at) + " / " + clock(duration)
    title = currentChapterTitle()
    if title <> "" then m.chapterNow.text = title else m.chapterNow.text = ""
    if buttonIndex("chapter") >= 0 then setButtonText("chapter", "章节 · " + title)
end sub

sub onPaused()
    if m.top.paused then setButtonText("play", "▶") else setButtonText("play", "‖")
end sub

function currentChapterTitle() as String
    chapters = m.top.chapters
    if chapters = invalid then return ""
    at = m.top.position
    title = ""
    for each c in chapters
        if at >= c.start then title = c.title
    end for
    return title
end function

function currentChapterIndex() as Integer
    chapters = m.top.chapters
    index = 0
    if chapters = invalid then return 0
    for i = 0 to chapters.Count() - 1
        if m.top.position >= chapters[i].start then index = i
    end for
    return index
end function

function qualityText() as String
    q = m.top.qualities[m.top.qualityIndex]
    return "画质 " + q.label
end function

function clock(sec as Float) as String
    s = Int(sec)
    if s < 0 then s = 0
    text = Right("0" + ((s \ 60) mod 60).ToStr(), 2) + ":" + Right("0" + (s mod 60).ToStr(), 2)
    if s >= 3600 then text = (s \ 3600).ToStr() + ":" + text
    return text
end function

' ---------- lists: 章节 / 选集 / 画质 ----------

sub openList(mode as String, title as String, items as Object, current as Integer)
    root = CreateObject("roSGNode", "ContentNode")
    for i = 0 to items.Count() - 1
        mark = "    "
        if i = current then mark = "●  "
        root.createChild("ContentNode").title = mark + items[i]
    end for
    m.listMode = mode
    m.popupTitle.text = title
    rows = items.Count()
    if rows > 9 then rows = 9
    m.popupBg.height = 84 + rows * 64 + 24
    ' Sit above the button that opened it, kept on screen.
    b = m.buttons[m.focus]
    x = b.group.translation[0]
    if x + 560 > 1824 then x = 1824 - 560
    m.popup.translation = [x, 930 - 16 - m.popupBg.height]
    m.popupList.content = root
    m.popupList.jumpToItem = current
    m.popup.visible = true
    paintFocus()
    m.popupList.setFocus(true)
    m.hideTimer.control = "stop"
end sub

sub closePopup()
    if not m.popup.visible then return
    m.popup.visible = false
    m.listMode = ""
    paintFocus()
    m.top.setFocus(true)
    restartIdle()
end sub

sub onListChosen()
    index = m.popupList.itemSelected
    mode = m.listMode
    closePopup()
    if mode = "chapter"
        m.top.action = { type: "chapter", index: index }
    else if mode = "part"
        m.top.action = { type: "part", index: index }
    else if mode = "quality"
        m.top.action = { type: "quality", index: index }
    else if mode = "cdn"
        m.top.action = { type: "cdn", index: index }
    end if
end sub

sub activate()
    id = m.buttons[m.focus].id
    if id = "play"
        m.top.action = { type: "togglePlay" }
    else if id = "chapter"
        items = []
        for each c in m.top.chapters
            items.Push(clock(c.start) + "  " + c.title)
        end for
        openList("chapter", "章节  ·  Chapters", items, currentChapterIndex())
    else if id = "part"
        items = []
        parts = m.top.parts
        for i = 0 to parts.Count() - 1
            items.Push("P" + (i + 1).ToStr() + "  " + parts[i])
        end for
        openList("part", "选集  ·  Parts", items, m.top.partIndex)
    else if id = "quality"
        items = []
        for each q in m.top.qualities
            items.Push(q.label)
        end for
        openList("quality", "画质  ·  Quality", items, m.top.qualityIndex)
    else if id = "cdn"
        openList("cdn", "线路  ·  Server", m.cdnNames, m.top.cdnIndex)
    else if id = "danmaku"
        m.top.danmakuOn = not m.top.danmakuOn
        if m.top.danmakuOn then setButtonText("danmaku", "弹幕 开") else setButtonText("danmaku", "弹幕 关")
        m.top.action = { type: "danmaku", on: m.top.danmakuOn }
    else if id = "dmSettings"
        openDmPanel()
    end if
end sub

' ---------- 弹幕设置 panel ----------

sub openDmPanel()
    m.settings = {}
    current = m.top.dmSettings
    if current <> invalid
        for each key in current
            m.settings[LCase(key)] = current[key]
        end for
    end if
    m.dmRows.removeChildrenIndex(m.dmRows.getChildCount(), 0)
    m.rowNodes = []
    for i = 0 to m.rowDefs.Count() - 1
        def = m.rowDefs[i]
        row = m.dmRows.createChild("Group")
        row.translation = [0, i * 66]
        hi = row.createChild("Rectangle")
        hi.width = 768
        hi.height = 58
        name = row.createChild("Label")
        name.translation = [20, 12]
        if fontOf(28) <> invalid then name.font = fontOf(28) else name.font = "font:SmallSystemFont"
        name.text = def.label
        value = row.createChild("Label")
        value.translation = [640, 12]
        if fontOf(28) <> invalid then value.font = fontOf(28) else value.font = "font:SmallSystemFont"
        track = invalid
        fillBar = invalid
        if def.kind = "slider"
            track = row.createChild("Rectangle")
            track.translation = [370, 26]
            track.width = 250
            track.height = 6
            track.color = "0xFFFFFF40"
            fillBar = row.createChild("Rectangle")
            fillBar.translation = [370, 26]
            fillBar.height = 6
            fillBar.color = m.ACCENT
        end if
        m.rowNodes.Push({ hi: hi, name: name, value: value, fill: fillBar })
        paintRow(i)
    end for
    m.dmBg.height = 84 + m.rowDefs.Count() * 66 + 64
    m.dmHint.translation = [32, 84 + m.rowDefs.Count() * 66 + 12]
    m.dmHint.text = "↑↓ 选择  ←→ 调整  OK 开/关  返回 关闭  ·  已同步账号屏蔽词"
    m.dmRow = 0
    m.dmPanel.visible = true
    paintRows()
    paintFocus()
    m.top.setFocus(true)
    m.hideTimer.control = "stop"
end sub

sub closeDmPanel()
    if not m.dmPanel.visible then return
    m.dmPanel.visible = false
    paintFocus()
    restartIdle()
end sub

sub paintRow(i as Integer)
    def = m.rowDefs[i]
    nodes = m.rowNodes[i]
    v = m.settings[def.key]
    if def.kind = "toggle"
        if v = true then nodes.value.text = "☑ 显示" else nodes.value.text = "☐ 隐藏"
    else
        if v = invalid then v = def.low
        span = def.high - def.low
        nodes.fill.width = Int(250 * (v - def.low) / span)
        if def.names <> invalid then nodes.value.text = def.names[v - def.low] else nodes.value.text = v.ToStr() + def.unit
    end if
end sub

sub paintRows()
    for i = 0 to m.rowNodes.Count() - 1
        nodes = m.rowNodes[i]
        if i = m.dmRow
            nodes.hi.color = "0xFFFFFF26"
            nodes.name.color = m.ACCENT
        else
            nodes.hi.color = "0x00000000"
            nodes.name.color = "0xF2F5F8FF"
        end if
        nodes.value.color = "0xF2F5F8FF"
    end for
end sub

sub changeRow(direction as Integer)
    def = m.rowDefs[m.dmRow]
    if def.kind = "toggle"
        m.settings[def.key] = not (m.settings[def.key] = true)
    else
        v = m.settings[def.key]
        if v = invalid then v = def.low
        v = v + direction * def.inc
        if v < def.low then v = def.low
        if v > def.high then v = def.high
        m.settings[def.key] = v
    end if
    paintRow(m.dmRow)
    m.top.dmSettings = m.settings
    m.top.action = { type: "dmSettings", settings: m.settings }
end sub

' ---------- keys ----------

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    restartIdle()
    if m.popup.visible
        if key = "back" or key = "left" or key = "right"
            closePopup()
        end if
        return true
    end if
    if m.dmPanel.visible
        if key = "back"
            closeDmPanel()
        else if key = "up" and m.dmRow > 0
            m.dmRow = m.dmRow - 1
            paintRows()
        else if key = "down" and m.dmRow < m.rowDefs.Count() - 1
            m.dmRow = m.dmRow + 1
            paintRows()
        else if key = "left"
            changeRow(-1)
        else if key = "right" or key = "OK"
            changeRow(1)
        end if
        return true
    end if
    if key = "left"
        if m.focus > 0 then m.focus = m.focus - 1
        paintFocus()
    else if key = "right"
        if m.focus < m.buttons.Count() - 1 then m.focus = m.focus + 1
        paintFocus()
    else if key = "OK"
        activate()
    else if key = "play"
        m.top.action = { type: "togglePlay" }
    else if key = "back" or key = "up"
        m.top.action = { type: "close" }
    end if
    return true
end function
