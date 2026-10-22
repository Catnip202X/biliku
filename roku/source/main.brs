' 云屏 entry point.
' Videos arrive two ways:
'   - launch args, when a phone sends a video while the app is closed
'   - roInputEvent, when a phone sends a video while the app is already open
' Both carry contentId (a BV id, a bilibili URL, or a b23.tv short link) and optional p (part number).
sub Main(args as Dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    ' Roku's system fonts have no Chinese glyphs; use a bundled font when one is present.
    ' roFileSystem only works on the main thread, so the check lives here.
    cjkFont = ""
    fs = CreateObject("roFileSystem")
    for each path in ["pkg:/fonts/cjk.otf", "pkg:/fonts/cjk.ttf"]
        if fs.Exists(path) then cjkFont = path
    end for
    screen.GetGlobalNode().addFields({ cjkFont: cjkFont })

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
            if info <> invalid and info.contentId <> invalid then scene.incoming = info
        end if
    end while
end sub
