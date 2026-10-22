' 云屏 entry point.
' Videos arrive two ways:
'   - launch args, when a phone sends a video while the app is closed
'   - roInputEvent, when a phone sends a video while the app is already open
' Both carry contentId (a BV id, a bilibili URL, or a b23.tv short link) and optional p (part number),
' or cmd (pause / resume / stop / seek) from the cast receiver.
sub Main(args as Dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    ' Roku's system fonts have no Chinese glyphs; use a bundled font when one is present.
    ' roFileSystem only works on the main thread, so the check lives here.
    ' The bundled font is a 2 MB subset (GB2312, ~6,800 characters) to fit Roku's package limit.
    ' The full Noto Sans SC (~27,800 Chinese characters incl. traditional and Japanese kanji) is
    ' downloaded once into the cache by ApiTask "fetchFont" and preferred from the next launch.
    cjkFont = ""
    fullFont = false
    fs = CreateObject("roFileSystem")
    for each path in ["pkg:/fonts/cjk.otf", "pkg:/fonts/cjk.ttf"]
        if fs.Exists(path) then cjkFont = path
    end for
    if fs.Exists("cachefs:/fonts/NotoSansSC-Regular.otf")
        st = fs.Stat("cachefs:/fonts/NotoSansSC-Regular.otf")
        if st <> invalid and st.size = 8331336
            cjkFont = "cachefs:/fonts/NotoSansSC-Regular.otf"
            fullFont = true
        end if
    end if
    ' Danmaku settings (keys kept lowercase: associative-array keys are case-insensitive).
    dm = { enabled: true, scroll: true, fixed: true, color: true, avoidsubs: false, area: 50, opacity: 100, size: 100, speed: 3 }
    saved = CreateObject("roRegistrySection", "danmaku")
    if saved.Exists("settings")
        stored = ParseJson(saved.Read("settings"))
        if stored <> invalid
            for each key in stored
                dm[LCase(key)] = stored[key]
            end for
        end if
    end if
    screen.GetGlobalNode().addFields({ cjkFont: cjkFont, fullFont: fullFont, dmSettings: dm })

    scene = screen.CreateScene("MainScene")
    screen.Show()

    input = CreateObject("roInput")
    input.SetMessagePort(port)

    if args <> invalid and args.contentId <> invalid then scene.incoming = args

    while true
        msg = wait(0, port)
        msgType = type(msg)
        if msgType = "roSGScreenEvent"
            if msg.IsScreenClosed() then return
        else if msgType = "roInputEvent"
            info = msg.GetInfo()
            ' Cast commands from the receiver (pause / resume / stop / seek) carry cmd and no contentId.
            if info <> invalid and (info.contentId <> invalid or info.cmd <> invalid) then scene.incoming = info
        end if
    end while
end sub
