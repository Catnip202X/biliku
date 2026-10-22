sub init()
    m.rows = m.top.findNode("rows")
    m.video = m.top.findNode("video")
    m.toast = m.top.findNode("toast")
    m.toastLabel = m.top.findNode("toastLabel")
    m.toastTimer = m.top.findNode("toastTimer")
    m.status = m.top.findNode("status")
    m.hint = m.top.findNode("hint")
    m.account = m.top.findNode("account")
    m.login = m.top.findNode("login")
    m.loginTitle = m.top.findNode("loginTitle")
    m.loginStatus = m.top.findNode("loginStatus")
    m.qrBg = m.top.findNode("qrBg")
    m.qrModules = m.top.findNode("qrModules")
    m.pollTimer = m.top.findNode("pollTimer")
    m.videoTitle = m.top.findNode("videoTitle")
    m.videoTitleLabel = m.top.findNode("videoTitleLabel")
    m.videoTitleTimer = m.top.findNode("videoTitleTimer")
    m.danmaku = m.top.findNode("danmaku")
    m.controls = m.top.findNode("controls")
    m.seekCover = m.top.findNode("seekCover")
    m.chapters = []
    m.parts = []
    m.qualities = invalid
    m.qualityIndex = 0
    m.manifestSerial = 0

    ' cjkFont is set in main.brs.
    if m.global.cjkFont <> ""
        m.top.findNode("brand").font = makeFont(m.global.cjkFont, 52)
        m.hint.font = makeFont(m.global.cjkFont, 26)
        m.account.font = makeFont(m.global.cjkFont, 26)
        m.status.font = makeFont(m.global.cjkFont, 32)
        m.toastLabel.font = makeFont(m.global.cjkFont, 30)
        m.rows.rowLabelFont = makeFont(m.global.cjkFont, 30)
        m.loginTitle.font = makeFont(m.global.cjkFont, 48)
        m.loginStatus.font = makeFont(m.global.cjkFont, 32)
        m.videoTitleLabel.font = makeFont(m.global.cjkFont, 44)
        m.top.findNode("seekCoverLabel").font = makeFont(m.global.cjkFont, 32)
    end if

    m.hint.text = "在手机上分享视频即可投送  ·  Share from your phone to " + deviceIp()

    m.feeds = [
        { key: "rcmd", title: "推荐  For You" }
        { key: "popular", title: "热门  Popular" }
        { key: "ranking", title: "排行榜  Rankings" }
        { key: "precious", title: "入站必刷  Must-Watch" }
    ]
    m.playToken = 0
    m.current = invalid
    m.loggedIn = false
    m.userName = ""
    m.loginMode = ""
    m.tasks = {}

    m.rows.observeField("rowItemSelected", "onItemSelected")
    m.video.observeField("state", "onVideoState")
    m.toastTimer.observeField("fire", "hideToast")
    m.pollTimer.observeField("fire", "onPollTimer")
    m.videoTitleTimer.observeField("fire", "hideVideoTitle")
    m.controls.observeField("action", "onControlAction")
    ' Saved danmaku settings (loaded in main.brs) and the account block list.
    m.dmSettings = m.global.dmSettings
    m.danmaku.settings = m.dmSettings
    m.danmaku.enabled = (m.dmSettings.enabled = true)
    ' Position updates drive the danmaku timing.
    m.video.notificationInterval = 0.5
    m.video.observeField("position", "onVideoPosition")

    ' Bilibili's CDN answers 403 without a Referer. ContentNode.HttpHeaders isn't used for DASH
    ' segment requests, but headers on the Video node's own HTTP agent are used for all of them.
    agent = m.video.getHttpAgent()
    if agent = invalid
        agent = CreateObject("roHttpAgent")
        m.video.setHttpAgent(agent)
    end if
    agent.AddHeader("Referer", "https://www.bilibili.com/")

    ' Serves DASH manifests to the Video node (see ManifestServer.brs).
    m.mpdServer = CreateObject("roSGNode", "ManifestServer")
    m.mpdServer.control = "run"

    refreshAccount()
    refreshFeeds()
    m.rows.setFocus(true)
    if m.global.fullFont <> true then startTask("font", { kind: "fetchFont" }, "onFontFetched")
end sub

sub onFontFetched(event as Object)
    if event.getData().ok then showToast("完整中文字体已下载，重新打开应用后生效  ·  Full Chinese font ready: reopen the app", 6)
end sub

function makeFont(uri as String, size as Integer) as Object
    font = CreateObject("roSGNode", "Font")
    font.uri = uri
    font.size = size
    return font
end function

function deviceIp() as String
    addrs = CreateObject("roDeviceInfo").GetIPAddrs()
    for each iface in addrs
        return addrs[iface]
    end for
    return "this TV"
end function

' Runs an ApiTask; `handler` receives the response. Tasks are kept by name so a newer
' request of the same kind replaces (and ignores) an older one.
sub startTask(name as String, request as Object, handler as String)
    task = CreateObject("roSGNode", "ApiTask")
    task.observeField("response", handler)
    task.request = request
    task.control = "run"
    m.tasks[name] = task
end sub

' ---------- browsing ----------

sub refreshFeeds()
    m.feedItems = {}
    m.feedsDone = 0
    for each f in m.feeds
        startTask("feed_" + f.key, { kind: "feed", key: f.key }, "onFeed")
    end for
end sub

sub onFeed(event as Object)
    res = event.getData()
    if res = invalid then return
    m.feedItems[res.key] = res.items
    m.feedsDone = m.feedsDone + 1
    ' Build once everything has arrived (or rebuild early if nothing is showing yet),
    ' so rows don't reshuffle under the cursor.
    if m.feedsDone = m.feeds.Count() or m.rows.content = invalid then buildRows()
end sub

sub buildRows()
    root = CreateObject("roSGNode", "ContentNode")
    for each f in m.feeds
        items = m.feedItems[f.key]
        if items <> invalid and items.Count() > 0
            row = root.createChild("ContentNode")
            row.title = f.title
            for each v in items
                node = row.createChild("ContentNode")
                node.addFields({ bvid: v.bvid, cid: v.cid, author: v.author, durationText: v.duration })
                node.title = v.title
                node.HDPosterUrl = v.pic
            end for
        end if
    end for

    if root.getChildCount() > 0
        m.rows.content = root
        m.status.visible = false
        if not m.video.visible and not m.login.visible then m.rows.setFocus(true)
    else if m.feedsDone = m.feeds.Count()
        m.status.text = "无法连接 Bilibili  ·  Couldn't reach Bilibili"
    end if
end sub

sub onItemSelected()
    sel = m.rows.rowItemSelected
    item = m.rows.content.getChild(sel[0]).getChild(sel[1])
    playTarget(item.bvid, "", item.title, "正在加载…  Loading…", item.cid)
end sub

' ---------- account ----------

sub refreshAccount()
    startTask("account", { kind: "account" }, "onAccount")
end sub

sub onAccount(event as Object)
    res = event.getData()
    m.loggedIn = res.loggedIn
    if m.loggedIn then startTask("dmFilters", { kind: "dmFilters" }, "onDmFilters")
    m.userName = res.name
    if m.loggedIn
        m.account.text = "已登录  ·  " + m.userName
    else
        m.account.text = "按 * 键扫码登录  ·  Press * to sign in"
    end if
end sub

sub openLogin()
    m.login.visible = true
    m.login.setFocus(true)
    m.qrModules.removeChildrenIndex(m.qrModules.getChildCount(), 0)
    m.qrBg.visible = false
    if m.loggedIn
        m.loginMode = "account"
        m.loginTitle.text = "已登录  ·  " + m.userName
        m.loginStatus.text = "按 OK 退出登录，按返回键关闭  ·  OK to sign out, Back to close"
    else
        m.loginMode = "qr"
        m.loginTitle.text = "用哔哩哔哩 App 扫码登录  ·  Scan with the Bilibili app"
        m.loginStatus.text = "正在生成二维码…  Generating QR code…"
        startTask("qr", { kind: "qrGenerate" }, "onQrGenerated")
    end if
end sub

sub closeLogin()
    m.pollTimer.control = "stop"
    m.loginMode = ""
    m.login.visible = false
    if m.video.visible then m.video.setFocus(true) else m.rows.setFocus(true)
end sub

sub onQrGenerated(event as Object)
    res = event.getData()
    if m.loginMode <> "qr" then return
    if not res.ok
        m.loginStatus.text = "无法连接 Bilibili  ·  Couldn't reach Bilibili"
        return
    end if
    drawQr(res.url)
    m.qrKey = res.key
    m.loginStatus.text = "打开哔哩哔哩 App，点右上角扫一扫  ·  Open the app and tap Scan"
    m.pollTimer.control = "start"
end sub

' Draws the QR code as rectangles, one per horizontal run of dark modules.
sub drawQr(text as String)
    qr = qrEncode(text)
    if qr = invalid then return
    n = qr.size
    quiet = 4
    px = Int(620 / (n + 2 * quiet))
    side = (n + 2 * quiet) * px
    qrX = Int((1920 - side) / 2)
    qrY = 220
    m.qrBg.translation = [qrX, qrY]
    m.qrBg.width = side
    m.qrBg.height = side
    m.qrBg.visible = true
    m.qrModules.translation = [qrX + quiet * px, qrY + quiet * px]
    m.qrModules.removeChildrenIndex(m.qrModules.getChildCount(), 0)
    for y = 0 to n - 1
        x = 0
        while x < n
            if qr.mods[y * n + x] = 1
                start = x
                while x < n and qr.mods[y * n + x] = 1
                    x = x + 1
                end while
                r = m.qrModules.createChild("Rectangle")
                r.color = "0x000000FF"
                r.translation = [start * px, y * px]
                r.width = (x - start) * px
                r.height = px
            else
                x = x + 1
            end if
        end while
    end for
end sub

sub onPollTimer()
    if m.loginMode <> "qr" or m.qrKey = invalid then return
    startTask("poll", { kind: "qrPoll", key: m.qrKey }, "onQrPoll")
end sub

sub onQrPoll(event as Object)
    res = event.getData()
    if m.loginMode <> "qr" then return
    if res.status = 0
        closeLogin()
        showToast("登录成功  ·  Signed in", 4)
        refreshAccount()
        refreshFeeds()
    else if res.status = -2
        m.pollTimer.control = "stop"
        m.loginStatus.text = "登录未能保存，请按返回后重试  ·  Sign-in didn't save — press Back and try again"
    else if res.status = 86090
        m.loginStatus.text = "已扫码，请在手机上确认  ·  Scanned — confirm on your phone"
    else if res.status = 86038
        m.pollTimer.control = "stop"
        m.loginStatus.text = "二维码已过期，正在刷新…  QR code expired, refreshing…"
        startTask("qr", { kind: "qrGenerate" }, "onQrGenerated")
    end if
end sub

sub onDmFilters(event as Object)
    m.danmaku.filters = event.getData()
end sub

sub onLogout(event as Object)
    closeLogin()
    showToast("已退出登录  ·  Signed out", 4)
    refreshAccount()
    refreshFeeds()
end sub

' ---------- sent from phone / cast ----------

sub onIncoming()
    info = m.top.incoming
    if info = invalid then return
    print "[biliku] incoming: "; FormatJson(info)

    if info.cmd <> invalid
        handleCastCommand(info)
    else if info.url <> invalid and info.url <> ""
        title = ""
        if info.title <> invalid then title = info.title
        if m.login.visible then closeLogin()
        cidMatch = CreateObject("roRegex", "/upgcxcode/\d+/\d+/(\d+)/", "").Match(info.url)
        if cidMatch.Count() > 1
            ' A Bilibili cast: look up the HD version, keeping the phone's stream as a fallback.
            ' (Not gated on m.loggedIn: a cast often launches the app before the account check
            ' finishes. The lookup checks the saved login itself.)
            playTarget("cid:" + cidMatch[1], "", title, "投屏，正在获取高清…  Cast received, fetching HD…")
            m.castFallback = { url: info.url, title: title }
            m.castLoading = true
        else
            playDirect(info.url, title)
        end if
    else if info.contentId <> invalid
        p = ""
        if info.p <> invalid then p = info.p
        if m.login.visible then closeLogin()
        playTarget(info.contentId, p, "", "收到投送，正在加载…  Received from phone, loading…")
    end if
end sub

sub handleCastCommand(info as Object)
    cmd = info.cmd
    ' The phone seeks to its position right after starting a cast, usually before the TV has the
    ' HD stream ready. Keep it and start there.
    if cmd = "seek" and info["pos"] <> invalid and (m.castLoading = true or not m.video.visible)
        m.castStartAt = Val(info["pos"])
        return
    end if
    if not m.video.visible then return
    if cmd = "pause"
        m.video.control = "pause"
    else if cmd = "resume"
        m.video.control = "resume"
    else if cmd = "stop"
        closeVideo()
    else if cmd = "seek" and info["pos"] <> invalid
        seekTo(Val(info["pos"]))
    end if
end sub

' ---------- playback ----------

sub playTarget(target as String, p as String, title as String, message as String, cid = "" as String)
    m.playToken = m.playToken + 1
    m.pendingTitle = title
    m.castFallback = invalid
    m.castLoading = false
    m.castStartAt = invalid
    m.switchStartAt = invalid
    showToast(message, 0)
    m.playTask = invalid
    task = CreateObject("roSGNode", "ApiTask")
    task.observeField("response", "onPlayResolved")
    task.request = { kind: "play", target: target, p: p, title: title, cid: cid, cdn: m.global.cdn, token: m.playToken }
    task.control = "run"
    m.playTask = task
end sub

sub onPlayResolved(event as Object)
    res = event.getData()
    if res = invalid or res.token <> m.playToken then return
    if not res.ok
        if m.castFallback <> invalid
            fallback = m.castFallback
            m.castFallback = invalid
            startAt = 0
            if m.castStartAt <> invalid then startAt = m.castStartAt
            m.castLoading = false
            m.castStartAt = invalid
            playDirect(fallback.url, fallback.title)
            if startAt > 0 then m.pendingSeek = startAt
            showToast("未找到高清版本，使用手机画质  ·  HD not found, using the phone's stream", 5)
        else
            showToast(res.error, 8)
        end if
        return
    end if
    m.castFallback = invalid

    title = m.pendingTitle
    if title = "" then title = res.part
    displayTitle = title
    if res.pageCount > 1 then displayTitle = title + "  (P" + res.page.ToStr() + "/" + res.pageCount.ToStr() + ")"
    m.displayTitle = displayTitle
    m.retries = 0
    m.queuedSeek = invalid
    m.lastPosition = 0
    m.danmaku.items = []
    resumeAt = 0
    if res.resumeAt <> invalid then resumeAt = res.resumeAt
    if m.castStartAt <> invalid and m.castStartAt > 0 then resumeAt = m.castStartAt
    if m.switchStartAt <> invalid and m.switchStartAt > 0 then resumeAt = m.switchStartAt
    m.switchStartAt = invalid
    m.castLoading = false
    m.castStartAt = invalid
    if res.qualities <> invalid
        m.qualities = res.qualities
        playQuality(0, resumeAt)
    else
        m.qualities = invalid
        startVideo(res.url, displayTitle, resumeAt)
        if res.quality <> invalid then showToast(res.quality, 3) else hideToast()
    end if
    if resumeAt > 0 then showToast("从 " + clockText(resumeAt) + " 继续  ·  Resuming at " + clockText(resumeAt), 4)
    m.chapters = []
    if res.chapters <> invalid then m.chapters = res.chapters
    m.parts = []
    if res.parts <> invalid then m.parts = res.parts
    m.current = { bvid: res.bvid, page: res.page, pageCount: res.pageCount, title: title }
    if res.cid <> invalid then startTask("videoMeta", { kind: "videoMeta", idParam: videoParam(res.bvid), cid: res.cid, token: m.playToken }, "onVideoMeta")
    if res.cid <> invalid then startTask("danmaku", { kind: "danmaku", cid: res.cid, duration: res.duration, token: m.playToken }, "onDanmaku")
end sub

' A stream URL that arrives ready to play (cast from the Bilibili app's 投屏 button).
sub playDirect(url as String, title as String)
    m.playToken = m.playToken + 1
    m.current = invalid
    if title = "" then title = "投屏  ·  Cast"
    m.qualities = invalid
    m.chapters = []
    m.parts = []
    m.danmaku.items = []
    startVideo(url, title, 0)
    showToast("投屏  ·  " + title, 4)
end sub

sub startVideo(url as String, title as String, startAt as Float)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = url
    ' Roku often ignores PlayStart for these DASH streams, so also seek once playback starts,
    ' behind a black cover with the sound muted so the jump from 0:00 isn't seen or heard.
    m.pendingSeek = startAt
    m.pendingSeekSent = false
    if startAt > 0
        content.PlayStart = startAt
        m.seekCover.visible = true
        m.video.mute = true
    else
        revealVideo()
    end if
    format = "mp4"
    lower = LCase(url)
    if Instr(1, lower, ".m3u8") > 0 then format = "hls"
    if Instr(1, lower, ".mpd") > 0 then format = "dash"
    content.streamFormat = format
    ' No content.title: the player's built-in title bar can't render Chinese. The overlay shows it instead.
    m.videoTitleLabel.text = title + "      按 ↓ 画质 / 弹幕  ·  ↓ for quality & danmaku"
    showVideoTitle(5)
    content.HttpHeaders = ["Referer:https://www.bilibili.com", "User-Agent:Mozilla/5.0"]
    print "[biliku] play "; format; ": "; Left(url, 120)

    m.video.control = "stop"
    m.video.content = content
    m.video.visible = true
    ' Don't pull focus away from the player bar if a reload happens while it's open.
    if not m.controls.visible then m.video.setFocus(true)
    m.video.control = "play"
end sub

' Plays quality `index` from m.qualities, starting at `startAt` seconds (used when switching).
sub playQuality(index as Integer, startAt as Float)
    m.qualityIndex = index
    q = m.qualities[index]
    m.manifestSerial = m.manifestSerial + 1
    m.mpdServer.manifest = q.mpd
    startVideo("http://127.0.0.1:47800/" + m.manifestSerial.ToStr() + ".mpd", m.displayTitle, startAt)
    showToast(q.label + "  ·  " + q.codec, 3)
end sub

sub showControls()
    c = m.controls
    c.chapters = m.chapters
    c.parts = m.parts
    partIndex = 0
    if m.current <> invalid and m.current.page <> invalid then partIndex = m.current.page - 1
    c.partIndex = partIndex
    if m.qualities <> invalid
        labels = []
        for each q in m.qualities
            labels.Push({ label: q.label, codec: q.codec })
        end for
        c.qualities = labels
        c.qualityIndex = m.qualityIndex
    else
        c.qualities = []
    end if
    cdnIndex = 0
    if m.global.cdn = "hw" then cdnIndex = 1
    if m.global.cdn = "akam" then cdnIndex = 2
    c.cdnIndex = cdnIndex
    c.danmakuOn = m.danmaku.enabled
    c.dmSettings = m.dmSettings
    c.paused = (m.video.state = "paused")
    c.duration = m.video.duration
    c.position = m.video.position
    c.visible = true
    c.show = true
end sub

sub hideControls()
    m.controls.visible = false
    if m.video.visible then m.video.setFocus(true)
end sub

sub onControlAction()
    a = m.controls.action
    print "[biliku] player bar: "; a.type
    if a.type = "close"
        hideControls()
    else if a.type = "togglePlay"
        if m.video.state = "paused" then m.video.control = "resume" else m.video.control = "pause"
    else if a.type = "quality" and m.qualities <> invalid and a.index <> m.qualityIndex
        hideControls()
        playQuality(a.index, m.lastPosition)
    else if a.type = "chapter" and a.index < m.chapters.Count()
        seekTo(m.chapters[a.index].start)
    else if a.type = "part" and m.current <> invalid and a.index + 1 <> m.current.page
        hideControls()
        playTarget(m.current.bvid, (a.index + 1).ToStr(), m.current.title, "正在加载…  Loading…")
    else if a.type = "cdn" and m.current <> invalid
        choices = ["auto", "hw", "akam"]
        if a.index < choices.Count() and choices[a.index] <> m.global.cdn
            m.global.cdn = choices[a.index]
            startTask("savePref", { kind: "savePref", key: "cdn", value: m.global.cdn }, "onPositionSaved")
            ' Reload the same video and part on the new server, continuing from here.
            resumeAt = m.lastPosition
            hideControls()
            playTarget(m.current.bvid, m.current.page.ToStr(), m.current.title, "切换线路…  Switching server…")
            m.switchStartAt = resumeAt
        end if
    else if a.type = "danmaku"
        m.danmaku.enabled = a.on
        m.dmSettings.enabled = a.on
        saveDmSettings()
    else if a.type = "dmSettings"
        enabled = m.dmSettings.enabled
        m.dmSettings = a.settings
        m.dmSettings.enabled = enabled
        m.danmaku.settings = m.dmSettings
        saveDmSettings()
    end if
end sub

sub saveDmSettings()
    startTask("saveDm", { kind: "saveDmSettings", settings: m.dmSettings }, "onPositionSaved")
end sub

' "BV..." -> "bvid=BV...", "av123" -> "aid=123"
function videoParam(ref as String) as String
    if Left(ref, 2) = "av" then return "aid=" + Mid(ref, 3)
    return "bvid=" + ref
end function

sub onVideoMeta(event as Object)
    res = event.getData()
    if res = invalid or res.token <> m.playToken then return
    m.chapters = res.chapters
    m.parts = res.parts
    if m.current <> invalid and res.parts.Count() > 0 then m.current.pageCount = res.parts.Count()
    if m.controls.visible then showControls()
end sub

sub onDanmaku(event as Object)
    res = event.getData()
    if res = invalid or res.token <> m.playToken then return
    m.danmaku.items = res.items
end sub

' The player ignores a seek while it's still buffering from the previous one, so it would carry on
' to the earlier target. Hold the newest request and apply it once the player is ready.
sub seekTo(target as Float)
    state = m.video.state
    if state = "playing" or state = "paused"
        m.queuedSeek = invalid
        m.video.seek = target
    else
        m.queuedSeek = target
    end if
end sub

sub onVideoPosition()
    m.danmaku.position = m.video.position
    if m.controls.visible
        m.controls.position = m.video.position
        m.controls.duration = m.video.duration
    end if
    if m.video.position > 0 then m.lastPosition = m.video.position
end sub

sub savePosition(posSec as Float)
    if m.current = invalid or m.current.bvid = invalid or m.qualities = invalid and m.video.content = invalid then return
    key = m.current.bvid + "_" + m.current.page.ToStr()
    startTask("savePosition", { kind: "savePosition", key: key, atSec: Int(posSec), duration: Int(m.video.duration) }, "onPositionSaved")
end sub

sub onPositionSaved()
end sub

function clockText(totalSec as Float) as String
    s = Int(totalSec)
    text = Right("0" + ((s \ 60) mod 60).ToStr(), 2) + ":" + Right("0" + (s mod 60).ToStr(), 2)
    if s >= 3600 then text = (s \ 3600).ToStr() + ":" + text
    return text
end function

' Streams sometimes stop mid-video (an "error", or "finished" well before the end).
' Reload the stream and continue from the last position, at most twice per video.
function recoverIfCutShort(state as String) as Boolean
    if m.qualities = invalid or m.retries = invalid or m.retries >= 2 then return false
    duration = m.video.duration
    cutShort = state = "finished" and duration > 0 and m.lastPosition < duration - 15
    midError = state = "error" and m.lastPosition > 5
    if not cutShort and not midError then return false
    m.retries = m.retries + 1
    print "[biliku] stream stopped at "; Int(m.lastPosition); "s ("; state; " "; m.video.errorCode; " "; m.video.errorMsg; " "; FormatJson(m.video.errorInfo); "), retry "; m.retries
    showToast("网络中断，正在恢复…  Stream dropped, resuming…", 3)
    playQuality(m.qualityIndex, m.lastPosition)
    return true
end function

' Shows the title overlay; seconds = 0 keeps it up until hidden (used while paused).
sub showVideoTitle(seconds as Integer)
    m.videoTitle.visible = true
    m.videoTitleTimer.control = "stop"
    if seconds > 0
        m.videoTitleTimer.duration = seconds
        m.videoTitleTimer.control = "start"
    end if
end sub

sub hideVideoTitle()
    m.videoTitle.visible = false
end sub

sub revealVideo()
    m.seekCover.visible = false
    m.video.mute = false
end sub

sub onVideoState()
    state = m.video.state
    print "[biliku] player "; state; " at "; Int(m.video.position); "s of "; Int(m.video.duration); "s"
    m.danmaku.playing = (state = "playing")
    if m.controls.visible then m.controls.paused = (state = "paused")
    if state = "playing" and m.pendingSeek <> invalid and m.pendingSeek > 0
        if m.video.position < m.pendingSeek - 3 and not m.pendingSeekSent
            ' Started from the beginning: jump (still covered) and reveal once there.
            m.pendingSeekSent = true
            m.video.seek = m.pendingSeek
        else
            m.pendingSeek = 0
            revealVideo()
        end if
    else if (state = "playing" or state = "paused") and m.queuedSeek <> invalid
        target = m.queuedSeek
        m.queuedSeek = invalid
        m.video.seek = target
    end if
    if recoverIfCutShort(state) then return
    if state = "paused"
        showVideoTitle(0)
    else if state = "playing" and m.videoTitle.visible
        showVideoTitle(3)
    end if
    if state = "finished"
        savePosition(0)
        ' Multi-part videos continue to the next part automatically.
        if m.current <> invalid and m.current.page < m.current.pageCount
            playTarget(m.current.bvid, (m.current.page + 1).ToStr(), m.current.title, "下一集…  Next part…")
        else
            closeVideo()
        end if
    else if state = "error"
        revealVideo()
        print "[biliku] playback error "; m.video.errorCode; " "; m.video.errorMsg; " "; m.video.errorStr; " "; FormatJson(m.video.errorInfo)
        ' A quality this TV can't play (fails before playing): step down to the next one.
        if m.qualities <> invalid and m.qualityIndex < m.qualities.Count() - 1 and m.lastPosition < 5
            failed = m.qualities[m.qualityIndex].label
            playQuality(m.qualityIndex + 1, m.lastPosition)
            showToast(failed + " 无法播放，已切换  ·  Can't play here, switched to " + m.qualities[m.qualityIndex].label, 6)
            return
        end if
        closeVideo()
        showToast("播放失败  ·  Playback failed: " + m.video.errorMsg, 8)
    end if
end sub

sub closeVideo()
    ' Remember exactly where the video was closed (Back, or Stop from the phone).
    if m.video.visible and m.lastPosition > 0 then savePosition(m.lastPosition)
    m.playToken = m.playToken + 1
    m.video.control = "stop"
    m.video.visible = false
    m.pendingSeek = 0
    revealVideo()
    m.videoTitleTimer.control = "stop"
    m.videoTitle.visible = false
    m.controls.visible = false
    m.qualities = invalid
    m.danmaku.playing = false
    m.danmaku.items = []
    m.current = invalid
    m.rows.setFocus(true)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.login.visible
        if key = "back"
            closeLogin()
            return true
        else if key = "OK" and m.loginMode = "account"
            startTask("logout", { kind: "logout" }, "onLogout")
            return true
        end if
        return true
    end if
    ' ↓ / ↑ open the player bar. (* is the TV's own settings menu during playback.)
    if (key = "down" or key = "up") and m.video.visible and not m.controls.visible
        showControls()
        return true
    end if
    if key = "back" and m.video.visible
        closeVideo()
        return true
    end if
    if not m.video.visible
        if key = "options"
            openLogin()
            return true
        else if key = "replay"
            showToast("正在刷新…  Refreshing…", 2)
            refreshFeeds()
            return true
        end if
    end if
    return false
end function

' ---------- toast ----------

sub showToast(text as String, seconds as Integer)
    m.toastLabel.text = text
    m.toast.visible = true
    m.toastTimer.control = "stop"
    if seconds > 0
        m.toastTimer.duration = seconds
        m.toastTimer.control = "start"
    end if
end sub

sub hideToast()
    m.toast.visible = false
end sub
