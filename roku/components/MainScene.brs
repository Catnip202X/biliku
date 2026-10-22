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
    m.qualityMenu = m.top.findNode("qualityMenu")
    m.qualityList = m.top.findNode("qualityList")
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
        m.top.findNode("qualityTitle").font = makeFont(m.global.cjkFont, 44)
        m.qualityList.font = makeFont(m.global.cjkFont, 32)
        m.qualityList.focusedFont = makeFont(m.global.cjkFont, 32)
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
    m.qualityList.observeField("itemSelected", "onQualityChosen")
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
                node.addFields({ bvid: v.bvid, author: v.author, durationText: v.duration })
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
    playTarget(item.bvid, "", item.title, "正在加载…  Loading…")
end sub

' ---------- account ----------

sub refreshAccount()
    startTask("account", { kind: "account" }, "onAccount")
end sub

sub onAccount(event as Object)
    res = event.getData()
    m.loggedIn = res.loggedIn
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
    if not m.video.visible then return
    if cmd = "pause"
        m.video.control = "pause"
    else if cmd = "resume"
        m.video.control = "resume"
    else if cmd = "stop"
        closeVideo()
    else if cmd = "seek" and info["pos"] <> invalid
        m.video.seek = Val(info["pos"])
    end if
end sub

' ---------- playback ----------

sub playTarget(target as String, p as String, title as String, message as String)
    m.playToken = m.playToken + 1
    m.pendingTitle = title
    m.castFallback = invalid
    showToast(message, 0)
    m.playTask = invalid
    task = CreateObject("roSGNode", "ApiTask")
    task.observeField("response", "onPlayResolved")
    task.request = { kind: "play", target: target, p: p, title: title, token: m.playToken }
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
            playDirect(fallback.url, fallback.title)
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
    m.lastPosition = 0
    m.danmaku.items = []
    if res.qualities <> invalid
        m.qualities = res.qualities
        playQuality(0, 0)
    else
        m.qualities = invalid
        startVideo(res.url, displayTitle, 0)
        if res.quality <> invalid then showToast(res.quality, 3) else hideToast()
    end if
    m.current = { bvid: res.bvid, page: res.page, pageCount: res.pageCount, title: title }
    if res.cid <> invalid then startTask("danmaku", { kind: "danmaku", cid: res.cid, duration: res.duration, token: m.playToken }, "onDanmaku")
end sub

' A stream URL that arrives ready to play (cast from the Bilibili app's 投屏 button).
sub playDirect(url as String, title as String)
    m.playToken = m.playToken + 1
    m.current = invalid
    if title = "" then title = "投屏  ·  Cast"
    m.qualities = invalid
    m.danmaku.items = []
    startVideo(url, title, 0)
    showToast("投屏  ·  " + title, 4)
end sub

sub startVideo(url as String, title as String, startAt as Float)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = url
    ' Roku ignores PlayStart for these DASH streams, so also seek once playback starts.
    m.pendingSeek = startAt
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
    m.video.setFocus(true)
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

sub openQualityMenu()
    root = CreateObject("roSGNode", "ContentNode")
    if m.qualities <> invalid
        for i = 0 to m.qualities.Count() - 1
            q = m.qualities[i]
            mark = "    "
            if i = m.qualityIndex then mark = "●  "
            root.createChild("ContentNode").title = mark + q.label + "  ·  " + q.codec
        end for
    else
        root.createChild("ContentNode").title = "    当前视频只有一种画质  ·  Single quality"
    end if
    toggle = "关闭弹幕  ·  Danmaku off"
    if not m.danmaku.enabled then toggle = "开启弹幕  ·  Danmaku on"
    root.createChild("ContentNode").title = "    " + toggle
    m.qualityList.content = root
    m.qualityList.jumpToItem = m.qualityIndex
    m.qualityMenu.visible = true
    m.qualityList.setFocus(true)
end sub

sub closeQualityMenu()
    m.qualityMenu.visible = false
    if m.video.visible then m.video.setFocus(true)
end sub

sub onQualityChosen()
    index = m.qualityList.itemSelected
    count = 0
    if m.qualities <> invalid then count = m.qualities.Count()
    closeQualityMenu()
    if index = m.qualityList.content.getChildCount() - 1
        m.danmaku.enabled = not m.danmaku.enabled
        if m.danmaku.enabled then showToast("弹幕已开启  ·  Danmaku on", 2) else showToast("弹幕已关闭  ·  Danmaku off", 2)
    else if index < count and index <> m.qualityIndex
        playQuality(index, m.video.position)
    end if
end sub

sub onDanmaku(event as Object)
    res = event.getData()
    if res = invalid or res.token <> m.playToken then return
    m.danmaku.items = res.items
end sub

sub onVideoPosition()
    m.danmaku.position = m.video.position
    if m.video.position > 0 then m.lastPosition = m.video.position
end sub

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

sub onVideoState()
    state = m.video.state
    print "[biliku] player "; state; " at "; Int(m.video.position); "s of "; Int(m.video.duration); "s"
    m.danmaku.playing = (state = "playing")
    if state = "playing" and m.pendingSeek <> invalid and m.pendingSeek > 0
        m.video.seek = m.pendingSeek
        m.pendingSeek = 0
    end if
    if recoverIfCutShort(state) then return
    if state = "paused"
        showVideoTitle(0)
    else if state = "playing" and m.videoTitle.visible
        showVideoTitle(3)
    end if
    if state = "finished"
        ' Multi-part videos continue to the next part automatically.
        if m.current <> invalid and m.current.page < m.current.pageCount
            playTarget(m.current.bvid, (m.current.page + 1).ToStr(), m.current.title, "下一集…  Next part…")
        else
            closeVideo()
        end if
    else if state = "error"
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
    m.playToken = m.playToken + 1
    m.video.control = "stop"
    m.video.visible = false
    m.videoTitleTimer.control = "stop"
    m.videoTitle.visible = false
    m.qualityMenu.visible = false
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
    if m.qualityMenu.visible
        if key = "back" or key = "left"
            closeQualityMenu()
            return true
        end if
        return false
    end if
    ' ↓ / ↑ open the player menu. (* is the TV's own settings menu during playback.)
    if (key = "down" or key = "up") and m.video.visible
        print "[biliku] player menu opened"
        openQualityMenu()
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
