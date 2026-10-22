' Bilibili web API calls.
'   feed      -> rcmd (personal when logged in) / popular / ranking / precious
'   play      -> pagelist (cid per part) -> playurl (single progressive MP4, up to 720p)
'   account   -> who is logged in
'   qrGenerate / qrPoll / logout -> QR code login; cookies are kept in the registry

sub init()
    m.top.functionName = "run"
end sub

sub run()
    req = m.top.request
    if req = invalid then return
    if req.kind = "feed"
        m.top.response = { kind: "feed", key: req.key, items: fetchFeed(req.key) }
    else if req.kind = "play"
        m.top.response = resolvePlay(req)
    else if req.kind = "danmaku"
        m.top.response = { kind: "danmaku", token: req.token, items: fetchDanmaku(req.cid, req.duration) }
    else if req.kind = "account"
        m.top.response = fetchAccount()
    else if req.kind = "qrGenerate"
        m.top.response = qrGenerate()
    else if req.kind = "qrPoll"
        m.top.response = qrPoll(req.key)
    else if req.kind = "videoMeta"
        m.top.response = fetchVideoMeta(req.idParam, req.cid, req.token)
    else if req.kind = "fetchFont"
        m.top.response = fetchFullFont()
    else if req.kind = "dmFilters"
        m.top.response = fetchDmFilters()
    else if req.kind = "savePref"
        sec = CreateObject("roRegistrySection", "prefs")
        sec.Write(req.key, req.value)
        sec.Flush()
        m.top.response = { kind: "savePref" }
    else if req.kind = "saveDmSettings"
        sec = CreateObject("roRegistrySection", "danmaku")
        sec.Write("settings", FormatJson(req.settings))
        sec.Flush()
        m.top.response = { kind: "saveDmSettings" }
    else if req.kind = "savePosition"
        ' Per-video resume point, saved when the video is closed. Cleared when it's finished (or closed
        ' in its last few seconds) so a watched video starts fresh next time.
        sec = CreateObject("roRegistrySection", "positions")
        if req.atSec < 1 or (req.duration > 0 and req.atSec > req.duration - 5)
            sec.Delete(req.key)
        else
            sec.Write(req.key, req.atSec.ToStr())
        end if
        sec.Flush()
        m.top.response = { kind: "savePosition" }
    else if req.kind = "logout"
        sec = CreateObject("roRegistrySection", "auth")
        sec.Delete("cookie")
        sec.Flush()
        print "[biliku] logged out"
        m.top.response = { kind: "logout" }
    end if
end sub

' ---------- HTTP ----------

function httpGet(url as String, userAgent = "Mozilla/5.0" as String) as String
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.SetUrl(url)
    xfer.AddHeader("User-Agent", userAgent)
    xfer.AddHeader("Referer", "https://www.bilibili.com")
    cookie = cookieHeader()
    if cookie <> "" then xfer.AddHeader("Cookie", cookie)
    if not xfer.AsyncGetToString() then return ""
    msg = wait(10000, port)
    if type(msg) = "roUrlEvent"
        m.lastHeaders = msg.GetResponseHeadersArray()
        if msg.GetResponseCode() = 200 then return msg.GetString()
        print "[biliku] HTTP "; msg.GetResponseCode(); " "; Left(url, 90)
    else
        print "[biliku] timeout "; Left(url, 90)
    end if
    xfer.AsyncCancel()
    return ""
end function

function getJson(url as String) as Dynamic
    body = httpGet(url)
    if body = "" then return invalid
    return ParseJson(body)
end function

' Device cookie (buvid3/4, fetched once) plus the login cookie when logged in.
function cookieHeader() as String
    sec = CreateObject("roRegistrySection", "auth")
    if not sec.Exists("buvid") and m.fetchingBuvid <> true
        m.fetchingBuvid = true
        spi = getJson("https://api.bilibili.com/x/frontend/finger/spi")
        if spi <> invalid and spi.data <> invalid and spi.data.b_3 <> invalid
            sec.Write("buvid", "buvid3=" + spi.data.b_3 + "; buvid4=" + spi.data.b_4)
            sec.Flush()
        end if
        m.fetchingBuvid = false
    end if
    parts = []
    if sec.Exists("buvid") then parts.Push(sec.Read("buvid"))
    if sec.Exists("cookie") then parts.Push(sec.Read("cookie"))
    return parts.Join("; ")
end function

' ---------- WBI request signing (needed by the recommendation feed) ----------

function wbiSign(params as Object) as String
    ' The signing keys change about once a day, so cache them instead of asking before every request.
    cache = CreateObject("roRegistrySection", "wbi")
    today = (CreateObject("roDateTime").AsSeconds() \ 86400).ToStr()
    raw = ""
    if cache.Exists("day") and cache.Read("day") = today and cache.Exists("raw") then raw = cache.Read("raw")
    if raw = ""
        nav = getJson("https://api.bilibili.com/x/web-interface/nav")
        if nav = invalid or nav.data = invalid or nav.data.wbi_img = invalid then return ""
        raw = keyFromUrl(nav.data.wbi_img.img_url) + keyFromUrl(nav.data.wbi_img.sub_url)
        cache.Write("raw", raw)
        cache.Write("day", today)
        cache.Flush()
    end if
    order = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]
    mixin = ""
    for each i in order
        mixin = mixin + Mid(raw, i + 1, 1)
    end for
    mixin = Left(mixin, 32)

    params.wts = CreateObject("roDateTime").AsSeconds().ToStr()
    keys = []
    for each k in params
        keys.Push(k)
    end for
    keys.Sort()
    xfer = CreateObject("roUrlTransfer")
    strip = CreateObject("roRegex", "[!'()*]", "")
    pairs = []
    for each k in keys
        pairs.Push(k + "=" + xfer.Escape(strip.ReplaceAll(params[k], "")))
    end for
    query = pairs.Join("&")
    digest = CreateObject("roEVPDigest")
    digest.Setup("md5")
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(query + mixin)
    return query + "&w_rid=" + digest.Process(bytes)
end function

' ".../bfs/wbi/7cd084941338484aae1ad9425b84077c.png" -> "7cd084941338484aae1ad9425b84077c"
function keyFromUrl(url as String) as String
    match = CreateObject("roRegex", "/([^/.]+)\.[A-Za-z]+$", "").Match(url)
    if match.Count() > 1 then return match[1]
    return ""
end function

' ---------- feeds ----------

function fetchFeed(key as String) as Object
    items = []
    if key = "rcmd"
        query = wbiSign({ fresh_type: "4", ps: "30", fresh_idx: "1", fresh_idx_1h: "1", brush: "1" })
        if query = "" then return items
        json = getJson("https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd?" + query)
        if json = invalid or json.code <> 0 or json.data = invalid or json.data.item = invalid
            print "[biliku] rcmd failed"
            return items
        end if
        list = json.data.item
    else
        urls = {
            popular: "https://api.bilibili.com/x/web-interface/popular?ps=40&pn=1"
            ranking: "https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all"
            precious: "https://api.bilibili.com/x/web-interface/popular/precious?page_size=40&page=1"
        }
        json = getJson(urls[key])
        if json = invalid or json.code <> 0 or json.data = invalid or json.data.list = invalid then return items
        list = json.data.list
    end if
    for each v in list
        ' rcmd mixes in ads and live rooms; keep only videos
        if v.bvid <> invalid and v.bvid <> "" and (v["goto"] = invalid or v["goto"] = "av")
            author = ""
            if v.owner <> invalid and v.owner.name <> invalid then author = v.owner.name
            cidText = ""
            if v.cid <> invalid
                t = type(v.cid)
                if t = "Integer" or t = "roInteger" or t = "LongInteger" or t = "roLongInteger" then cidText = v.cid.ToStr()
            end if
            items.Push({ bvid: v.bvid, cid: cidText, title: v.title, pic: thumbUrl(v.pic), author: author, duration: formatDuration(v.duration) })
        end if
    end for
    print "[biliku] feed "; key; ": "; items.Count(); " videos"
    return items
end function

' ---------- danmaku ----------

' All danmaku for a video part: Bilibili serves them as protobuf in 6-minute segments.
' Returns [{ t: ms, mode: 1 scroll / 4 bottom / 5 top, color: RGB int, text }] sorted by time.
function fetchDanmaku(cid as String, duration as Integer) as Object
    items = []
    segments = Int((duration + 359) / 360)
    if segments < 1 then segments = 1
    if segments > 40 then segments = 40
    for seg = 1 to segments
        bytes = httpGetBytes("https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=" + cid + "&segment_index=" + seg.ToStr(), "tmp:/dm.bin")
        if bytes <> invalid then parseDmSegment(bytes, items)
    end for
    items.SortBy("t")
    print "[biliku] danmaku: "; items.Count(); " in "; segments; " segments"
    return items
end function

function httpGetBytes(url as String, path as String) as Dynamic
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.SetUrl(url)
    xfer.AddHeader("User-Agent", "Mozilla/5.0")
    xfer.AddHeader("Referer", "https://www.bilibili.com/")
    cookie = cookieHeader()
    if cookie <> "" then xfer.AddHeader("Cookie", cookie)
    if not xfer.AsyncGetToFile(path) then return invalid
    msg = wait(15000, port)
    if type(msg) <> "roUrlEvent" or msg.GetResponseCode() <> 200
        xfer.AsyncCancel()
        return invalid
    end if
    bytes = CreateObject("roByteArray")
    if not bytes.ReadFile(path) then return invalid
    return bytes
end function

' DmSegMobileReply { repeated DanmakuElem elems = 1 }
sub parseDmSegment(b as Object, items as Object)
    st = { i: 0 }
    total = b.Count()
    while st.i < total
        key = pbVarint(b, st)
        wire = key and 7
        if wire = 2
            size = pbVarint(b, st)
            finish = st.i + size
            if (key >> 3) = 1
                e = parseDmElem(b, st.i, finish)
                if e <> invalid then items.Push(e)
            end if
            st.i = finish
        else if wire = 0
            pbVarint(b, st)
        else if wire = 5
            st.i = st.i + 4
        else if wire = 1
            st.i = st.i + 8
        else
            exit while
        end if
    end while
end sub

' DanmakuElem: 2 progress (ms), 3 mode, 5 color, 6 sender hash, 7 content. Other fields are skipped.
function parseDmElem(b as Object, start as Integer, finish as Integer) as Dynamic
    st = { i: start }
    e = { t: 0, mode: 1, color: &hFFFFFF, text: "", hash: "" }
    while st.i < finish
        key = pbVarint(b, st)
        field = key >> 3
        wire = key and 7
        if wire = 0
            value = pbVarint(b, st)
            if field = 2
                e.t = value
            else if field = 3
                e.mode = value
            else if field = 5
                e.color = value
            end if
        else if wire = 2
            size = pbVarint(b, st)
            if field = 6 or field = 7
                text = CreateObject("roByteArray")
                for k = st.i to st.i + size - 1
                    text.Push(b[k])
                end for
                if field = 7 then e.text = text.ToAsciiString() else e.hash = LCase(text.ToAsciiString())
            end if
            st.i = st.i + size
        else if wire = 5
            st.i = st.i + 4
        else if wire = 1
            st.i = st.i + 8
        else
            return invalid
        end if
    end while
    ' Modes 7-9 are positioned / scripted danmaku, which need a full renderer; skip them.
    if e.text = "" or e.mode > 6 then return invalid
    return e
end function

' Reads a protobuf varint. Only the low 28 bits are kept (ids are 64-bit but unused here).
function pbVarint(b as Object, st as Object) as Integer
    result = 0
    mult = 1
    shift = 0
    while st.i < b.Count()
        c = b[st.i]
        st.i = st.i + 1
        if shift < 28 then result = result + (c and 127) * mult
        if shift < 21 then mult = mult * 128
        shift = shift + 7
        if c < 128 then exit while
    end while
    return result
end function

' The account's danmaku block list (the same rules as the Bilibili app's 屏蔽设置):
' type 0 = keyword, 1 = regex, 2 = sender (hash, matching DanmakuElem.midHash). Needs login.
function fetchDmFilters() as Object
    result = { kind: "dmFilters", keywords: [], patterns: [], users: [] }
    json = getJson("https://api.bilibili.com/x/dm/filter/user")
    if json = invalid or json.code <> 0 or json.data = invalid or json.data.rule = invalid
        print "[biliku] danmaku block list unavailable"
        return result
    end if
    for each rule in json.data.rule
        text = rule.filter
        if text <> invalid and text <> ""
            if rule.type = 0
                result.keywords.Push(LCase(text))
            else if rule.type = 1
                ' Stored as /pattern/ by some clients; keep just the pattern.
                if Len(text) > 2 and Left(text, 1) = "/" and Right(text, 1) = "/" then text = Mid(text, 2, Len(text) - 2)
                result.patterns.Push(text)
            else if rule.type = 2
                result.users.Push(LCase(text))
            end if
        end if
    end for
    print "[biliku] danmaku block list: "; result.keywords.Count(); " words, "; result.patterns.Count(); " patterns, "; result.users.Count(); " users"
    return result
end function

' Full Noto Sans SC (SIL OFL), pinned to the noto-cjk Sans2.004 release. Downloaded to a .part file
' and only kept if the size matches exactly, so an interrupted download is never used.
function fetchFullFont() as Object
    final = "cachefs:/fonts/NotoSansSC-Regular.otf"
    part = final + ".part"
    fs = CreateObject("roFileSystem")
    fs.CreateDirectory("cachefs:/fonts")
    if fs.Exists(part) then fs.Delete(part)
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.SetUrl("https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@Sans2.004/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf")
    ok = false
    if xfer.AsyncGetToFile(part)
        msg = wait(300000, port)
        if type(msg) = "roUrlEvent" and msg.GetResponseCode() = 200
            st = fs.Stat(part)
            if st <> invalid and st.size = 8331336
                if fs.Exists(final) then fs.Delete(final)
                ok = fs.Rename(part, final)
            end if
        else
            xfer.AsyncCancel()
        end if
    end if
    if not ok and fs.Exists(part) then fs.Delete(part)
    print "[biliku] full font download: "; ok
    return { kind: "fetchFont", ok: ok }
end function

' ---------- account / QR login ----------

function fetchAccount() as Object
    result = { kind: "account", loggedIn: false, name: "" }
    sec = CreateObject("roRegistrySection", "auth")
    if not sec.Exists("cookie") then return result
    nav = getJson("https://api.bilibili.com/x/web-interface/nav")
    if nav <> invalid and nav.data <> invalid and nav.data.isLogin = true
        result.loggedIn = true
        result.name = nav.data.uname
    end if
    print "[biliku] account loggedIn="; result.loggedIn
    return result
end function

function qrGenerate() as Object
    json = getJson("https://passport.bilibili.com/x/passport-login/web/qrcode/generate")
    if json = invalid or json.code <> 0 or json.data = invalid
        return { kind: "qrGenerate", ok: false }
    end if
    return { kind: "qrGenerate", ok: true, url: json.data.url, key: json.data.qrcode_key }
end function

' status: 0 logged in, 86101 waiting for scan, 86090 scanned (confirm on phone), 86038 expired
function qrPoll(key as String) as Object
    result = { kind: "qrPoll", status: -1 }
    json = getJson("https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=" + key)
    if json = invalid or json.data = invalid then return result
    result.status = json.data.code
    if result.status = 0
        ' Bilibili sets the login cookies with Set-Cookie headers on this response.
        wanted = { SESSDATA: true, bili_jct: true, DedeUserID: true, DedeUserID__ckMd5: true }
        found = {}
        if m.lastHeaders <> invalid
            for each header in m.lastHeaders
                for each name in header
                    if LCase(name) = "set-cookie"
                        pair = header[name].Split(";")[0].Trim()
                        eq = pair.Instr("=")
                        if eq > 0 and wanted.DoesExist(pair.Left(eq)) then found[pair.Left(eq)] = pair
                    end if
                end for
            end for
        end if
        ' Fallback: some responses also carry them as query parameters on data.url.
        if found.Count() = 0 and json.data.url <> invalid
            for each name in wanted
                match = CreateObject("roRegex", "[?&]" + name + "=([^&]+)", "i").Match(json.data.url)
                ' match[0] is "&NAME=value"; keep its original case (AA keys come back lowercased).
                if match.Count() > 1 then found[name] = Mid(match[0], 2)
            end for
        end if
        cookies = []
        for each name in found
            cookies.Push(found[name])
        end for
        print "[biliku] login cookies found: "; cookies.Count()
        if cookies.Count() = 0
            result.status = -2
            return result
        end if
        sec = CreateObject("roRegistrySection", "auth")
        sec.Write("cookie", cookies.Join("; "))
        sec.Flush()
    end if
    return result
end function

' ---------- playback ----------

function resolvePlay(req as Object) as Object
    result = { kind: "play", token: req.token, ok: false }
    m.cdn = "auto"
    if req.cdn <> invalid and req.cdn <> "" then m.cdn = req.cdn
    target = req.target
    print "[biliku] resolve: "; target
    if Instr(1, target, "%") > 0 then target = CreateObject("roUrlTransfer").Unescape(target)

    ' "cid:<cid>" comes from a 投屏 cast: the cast only carries the part's cid, so find its video first.
    wantCid = ""
    if Left(target, 4) = "cid:"
        wantCid = Mid(target, 5)
        if not CreateObject("roRegistrySection", "auth").Exists("cookie")
            result.error = "cast lookup needs login"
            return result
        end if
        title = ""
        if req.title <> invalid then title = req.title
        target = bvidForCid(wantCid, title)
        if target = ""
            result.error = "cast lookup failed"
            return result
        end if
    end if

    ' target can be a BV id, an av number, a full link, a short link, or the app's whole share text.
    id = videoIdParam(target)
    if id = ""
        link = CreateObject("roRegex", "https?://[^\s""<>]+|(b23\.tv|bili2233\.cn)/[^\s""<>]+", "i").Match(target)
        if link.Count() > 0
            url = link[0]
            if Left(url, 4) <> "http" then url = "https://" + url
            ' Short links (b23.tv, bili2233.cn) redirect to the video page. The mobile page
            ' contains the BV id; the desktop page served to non-browsers does not.
            id = videoIdParam(httpGet(url, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"))
        end if
    end if
    if id = ""
        shown = target
        if Len(shown) > 60 then shown = Left(shown, 60) + "…"
        if shown = "" then shown = "(empty)"
        result.error = "无法识别视频链接  ·  Unrecognized link: " + shown
        print "[biliku] no video id in: "; target
        return result
    end if

    page = 1
    if req.p <> invalid and req.p <> ""
        page = Int(Val(req.p))
    else
        pm = CreateObject("roRegex", "[?&]p=(\d+)", "").Match(target)
        if pm.Count() > 1 then page = Int(Val(pm[1]))
    end if

    ' Videos picked from a home row already carry their first part's cid, so skip the lookup.
    knownCid = ""
    if req.cid <> invalid and req.cid <> "" and wantCid = "" and (req.p = invalid or req.p = "") then knownCid = req.cid
    part = ""
    if knownCid <> ""
        cid = knownCid
        page = 1
        pageCount = 1
    else
        ' cids can exceed 32 bits, so read them from the raw text instead of ParseJson numbers.
        body = httpGet("https://api.bilibili.com/x/player/pagelist?" + id)
        pages = invalid
        if body <> "" then pages = ParseJson(body)
        cids = CreateObject("roRegex", """cid"":(\d+)", "").MatchAll(body)
        if pages = invalid or pages.code <> 0 or cids.Count() = 0
            result.error = "视频不存在或不可用  ·  Video unavailable"
            return result
        end if
        if wantCid <> ""
            for i = 0 to cids.Count() - 1
                if cids[i][1] = wantCid then page = i + 1
            end for
        end if
        if page < 1 or page > cids.Count() then page = 1
        cid = cids[page - 1][1]
        pageCount = cids.Count()
        if pages.data <> invalid and pages.data.Count() >= page and pages.data[page - 1].part <> invalid
            part = pages.data[page - 1].part
        end if
    end if

    result.bvid = videoRef(id)
    result.page = page
    result.pageCount = pageCount
    result.part = part
    ' Chapters and part names are fetched after playback starts (ApiTask "videoMeta").

    ' Resume where this video was left off. Casts start where the phone was (from watch history;
    ' the phone's own seek, if it arrives in time, overrides this in the scene).
    if wantCid <> "" and m.castProgress <> invalid and m.castProgress > 0
        result.resumeAt = m.castProgress
        print "[biliku] cast resumes at history position "; m.castProgress
    end if
    if wantCid = ""
        positions = CreateObject("roRegistrySection", "positions")
        key = result.bvid + "_" + page.ToStr()
        if positions.Exists(key) then result.resumeAt = Val(positions.Read(key))
    end if

    ' Logged in: DASH (1080p, up to 4K with 大会员). Logged out DASH stops at 480p, so MP4 720p is better.
    if CreateObject("roRegistrySection", "auth").Exists("cookie")
        dash = resolveDash(id, cid)
        if dash <> invalid
            result.ok = true
            result.qualities = dash.qualities
            result.duration = dash.duration
            result.cid = cid
            return result
        end if
    end if

    play = getJson("https://api.bilibili.com/x/player/playurl?" + id + "&cid=" + cid + "&qn=80&fnval=1&platform=html5&high_quality=1")
    if play = invalid or play.code <> 0 or play.data = invalid or play.data.durl = invalid or play.data.durl.Count() = 0
        result.error = "无法获取播放地址  ·  Could not get stream"
        if play <> invalid and play.message <> invalid then result.error = result.error + " (" + play.message + ")"
        return result
    end if

    print "[biliku] stream "; id; " p"; page; " quality "; play.data.quality
    result.ok = true
    result.url = play.data.durl[0].url
    result.quality = "720P"
    result.cid = cid
    result.duration = 0
    if play.data.timelength <> invalid then result.duration = Int(play.data.timelength / 1000)
    return result
end function

' Requests DASH streams and builds one MPD manifest per quality (for the quality menu).
' Returns { qualities: [{ id, label, codec, mpd }] best first, duration } or invalid.
function resolveDash(id as String, cid as String) as Dynamic
    eq = id.Instr("=")
    params = { cid: cid, qn: "127", fnval: "2192", fourk: "1", fnver: "0" }
    params[id.Left(eq)] = id.Mid(eq + 1)
    query = wbiSign(params)
    if query = "" then return invalid
    json = getJson("https://api.bilibili.com/x/player/wbi/playurl?" + query)
    if json = invalid or json.code <> 0 or json.data = invalid or json.data.dash = invalid
        print "[biliku] dash unavailable"
        return invalid
    end if
    dash = json.data.dash
    if dash.video = invalid or dash.video.Count() = 0 or dash.audio = invalid or dash.audio.Count() = 0 then return invalid

    ' Only AVC plays: Roku demuxes Bilibili's HEVC and AV1 DASH streams with error 970 (tested on a
    ' Roku TV that reports it can decode both). AVC above 1080p needs level 5.1, which most Roku
    ' TVs' AVC decoders reject, so keep 4K AVC only when the TV says it can decode it.
    di = CreateObject("roDeviceInfo")
    avc4k = canDecode(di, { Codec: "mpeg4 avc", Profile: "high", Level: "5.1" })
    names = { "7": "AVC" }

    ' Best audio (regular tracks; Dolby / FLAC are listed separately and skipped).
    audio = dash.audio[0]
    for each a in dash.audio
        if a.bandwidth > audio.bandwidth then audio = a
    end for
    audioSet = "<AdaptationSet mimeType=""audio/mp4"" contentType=""audio"" segmentAlignment=""true"" startWithSAP=""1"">" + Chr(10) + dashRep("a" + audio.id.ToStr(), audio, "audioSamplingRate=""48000""") + "</AdaptationSet>" + Chr(10)

    ' Pick one stream per quality id.
    chosen = {}
    for each v in dash.video
        key = v.id.ToStr()
        if v.codecid = 7 and (v.height <= 1080 or avc4k) and not chosen.DoesExist(key)
            chosen[key] = { v: v }
        end if
    end for

    labels = {}
    if json.data.accept_quality <> invalid and json.data.accept_description <> invalid
        for i = 0 to json.data.accept_quality.Count() - 1
            if i < json.data.accept_description.Count() then labels[json.data.accept_quality[i].ToStr()] = json.data.accept_description[i]
        end for
    end if

    duration = 0
    if dash.duration <> invalid then duration = dash.duration
    qualities = []
    for each key in chosen
        v = chosen[key].v
        codecName = names[v.codecid.ToStr()]
        label = key
        if labels.DoesExist(key) then label = labels[key]
        rep = dashRep("v" + key, v, "width=""" + v.width.ToStr() + """ height=""" + v.height.ToStr() + """")
        mpd = "<?xml version=""1.0"" encoding=""UTF-8""?>" + Chr(10)
        mpd = mpd + "<MPD xmlns=""urn:mpeg:dash:schema:mpd:2011"" profiles=""urn:mpeg:dash:profile:isoff-on-demand:2011"" type=""static"" mediaPresentationDuration=""PT" + duration.ToStr() + "S"" minBufferTime=""PT1.5S"">" + Chr(10) + "<Period>" + Chr(10)
        mpd = mpd + "<AdaptationSet mimeType=""video/mp4"" contentType=""video"" segmentAlignment=""true"" startWithSAP=""1"">" + Chr(10) + rep + "</AdaptationSet>" + Chr(10)
        mpd = mpd + audioSet + "</Period>" + Chr(10) + "</MPD>" + Chr(10)
        qualities.Push({ id: v.id, label: label, codec: codecName, mpd: mpd, rep: rep })
    end for
    if qualities.Count() = 0 then return invalid
    qualities.SortBy("id", "r")

    ' "Auto" (default): every quality in one adaptation set, so Roku's player switches with the
    ' connection instead of stalling when Wi-Fi dips below a fixed quality's bitrate.
    if qualities.Count() > 1
        reps = ""
        for i = 0 to qualities.Count() - 1
            if i < 3 then reps = reps + qualities[i].rep
        end for
        auto = "<?xml version=""1.0"" encoding=""UTF-8""?>" + Chr(10)
        auto = auto + "<MPD xmlns=""urn:mpeg:dash:schema:mpd:2011"" profiles=""urn:mpeg:dash:profile:isoff-on-demand:2011"" type=""static"" mediaPresentationDuration=""PT" + duration.ToStr() + "S"" minBufferTime=""PT4S"">" + Chr(10) + "<Period>" + Chr(10)
        auto = auto + "<AdaptationSet mimeType=""video/mp4"" contentType=""video"" segmentAlignment=""true"" startWithSAP=""1"">" + Chr(10) + reps + "</AdaptationSet>" + Chr(10)
        auto = auto + audioSet + "</Period>" + Chr(10) + "</MPD>" + Chr(10)
        qualities.Unshift({ id: 0, label: "自动 Auto · 最高 " + qualities[0].label, codec: "AVC", mpd: auto, rep: "" })
    end if
    print "[biliku] dash "; id; " qualities: "; qualities.Count(); ", best "; qualities[0].label
    return { qualities: qualities, duration: duration }
end function

function canDecode(di as Object, check as Object) as Boolean
    res = di.CanDecodeVideo(check)
    return res <> invalid and res.result = true
end function

' Bilibili labels every AVC stream as level 5.1 ("avc1.640033"), even 360p. Roku checks the label against
' its decoder and rejects the whole manifest ("malformed data"), so label the level the stream really needs.
function avcCodecLabel(s as Object) as String
    codecs = s.codecs
    if Left(codecs, 5) <> "avc1." or Len(codecs) <> 11 then return codecs
    fps = 30
    rate = s.frame_rate
    if rate = invalid then rate = s.frameRate
    if rate <> invalid then fps = Val(rate)
    level = "2A"
    if s.height <= 720 and fps <= 31 then
        level = "1F"
    else if s.height <= 720 then
        level = "20"
    else if s.height <= 1080 and fps <= 31 then
        level = "28"
    end if
    return Left(codecs, 9) + level
end function

function dashRep(repId as String, s as Object, extra as String) as String
    url = pickStreamUrl(s)
    seg = s.segment_base
    if seg = invalid then seg = s.SegmentBase
    initRange = seg.initialization
    if initRange = invalid then initRange = seg.Initialization
    indexRange = seg.index_range
    if indexRange = invalid then indexRange = seg.indexRange
    return "<Representation id=""" + repId + """ bandwidth=""" + s.bandwidth.ToStr() + """ codecs=""" + avcCodecLabel(s) + """ " + extra + ">" + Chr(10) + "<BaseURL>" + xmlEscape(url) + "</BaseURL>" + Chr(10) + "<SegmentBase indexRange=""" + indexRange + """><Initialization range=""" + initRange + """/></SegmentBase>" + Chr(10) + "</Representation>" + Chr(10)
end function

' Which CDN server streams come from (the player bar's 线路 button):
'   "hw"   upos-sz-mirrorhw (Huawei Cloud): highest sustained speed from the US, slower per request
'   "auto" the server Bilibili picked for this location
'   "akam" Bilibili's Akamai link when it offers one (fastest for uncached seeks in tests)
function pickStreamUrl(s as Object) as String
    url = s.base_url
    if url = invalid then url = s.baseUrl
    if m.cdn = "akam"
        backups = s.backup_url
        if backups = invalid then backups = s.backupUrl
        if Instr(1, url, "akamaized") = 0 and backups <> invalid
            for each b in backups
                if Instr(1, b, "akamaized") > 0 then return b
            end for
        end if
        return url
    end if
    if m.cdn = "hw"
        return CreateObject("roRegex", "^https?://upos-[a-z]+-mirror[a-z0-9]+\.bilivideo\.com/", "").Replace(url, "https://upos-sz-mirrorhw.bilivideo.com/")
    end if
    return url
end function

function xmlEscape(s as String) as String
    return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("""", "&quot;")
end function

' Finds the BV id of the video containing part `cid`.
' 1) Watch history: a cast comes from a video the phone was just playing, so it's usually there.
' 2) Otherwise search the title and confirm a result by its cid.
function bvidForCid(cid as String, title as String) as String
    marks = ["""cid"":" + cid + ",", """cid"":" + cid + "}"]
    history = httpGet("https://api.bilibili.com/x/web-interface/history/cursor?ps=30&type=archive")
    for each mark in marks
        at = Instr(1, history, mark)
        if at > 0
            ' In each history entry, "bvid" comes before "cid"; take the nearest one.
            found = CreateObject("roRegex", """bvid"":""(BV[0-9A-Za-z]{10})""", "").MatchAll(Left(history, at))
            ' The same history entry records how far the phone got ("progress", seconds; -1 = finished).
            progress = CreateObject("roRegex", """progress"":(-?\d+)", "").Match(Mid(history, at, 800))
            if progress.Count() > 1 then m.castProgress = Val(progress[1])
            if found.Count() > 0
                print "[biliku] cast cid "; cid; " found in history: "; found[found.Count() - 1][1]
                return found[found.Count() - 1][1]
            end if
        end if
    end for

    if title <> ""
        query = wbiSign({ search_type: "video", keyword: title, page: "1" })
        json = invalid
        if query <> "" then json = getJson("https://api.bilibili.com/x/web-interface/wbi/search/type?" + query)
        if json <> invalid and json.data <> invalid and json.data.result <> invalid
            checked = 0
            for each r in json.data.result
                if r.bvid <> invalid and checked < 5
                    checked = checked + 1
                    pages = httpGet("https://api.bilibili.com/x/player/pagelist?bvid=" + r.bvid)
                    for each mark in marks
                        if Instr(1, pages, mark) > 0
                            print "[biliku] cast cid "; cid; " found by title search: "; r.bvid
                            return r.bvid
                        end if
                    end for
                end if
            end for
        end if
    end if
    print "[biliku] cast cid "; cid; " not found"
    return ""
end function

' Part names (选集) and chapters (章节) for the player bar, fetched after playback has started.
function fetchVideoMeta(idParam as String, cid as String, token as Dynamic) as Object
    result = { kind: "videoMeta", token: token, parts: [], chapters: [] }
    pages = getJson("https://api.bilibili.com/x/player/pagelist?" + idParam)
    if pages <> invalid and pages.data <> invalid
        for each pg in pages.data
            name = ""
            if pg.part <> invalid then name = pg.part
            result.parts.Push(name)
        end for
    end if
    info = getJson("https://api.bilibili.com/x/player/v2?" + idParam + "&cid=" + cid)
    if info <> invalid and info.data <> invalid and info.data.view_points <> invalid
        for each vp in info.data.view_points
            ' "to" is a BrightScript keyword, so read it by name.
            result.chapters.Push({ start: vp["from"], finish: vp["to"], title: vp.content })
        end for
    end if
    return result
end function

' Returns the API query parameter for the first video id in s: "bvid=BV..." or "aid=123", or "".
function videoIdParam(s as String) as String
    bv = CreateObject("roRegex", "BV[0-9A-Za-z]{10}", "i").Match(s)
    if bv.Count() > 0 then return "bvid=BV" + Mid(bv[0], 3)
    av = CreateObject("roRegex", "(?:^|[^0-9A-Za-z])av(\d+)", "i").Match(s)
    if av.Count() > 1 then return "aid=" + av[1]
    return ""
end function

' Turns a query parameter from videoIdParam back into an id that videoIdParam accepts.
function videoRef(id as String) as String
    if Left(id, 5) = "bvid=" then return Mid(id, 6)
    return "av" + Mid(id, 5)
end function

function thumbUrl(pic as Dynamic) as String
    if pic = invalid or pic = "" then return ""
    if Left(pic, 5) = "http:" then pic = "https:" + Mid(pic, 6)
    return pic + "@480w_270h_1c.jpg"
end function

function formatDuration(sec as Dynamic) as String
    if sec = invalid then return ""
    s = Int(sec)
    h = s \ 3600
    mins = (s \ 60) mod 60
    secs = s mod 60
    text = pad2(mins) + ":" + pad2(secs)
    if h > 0 then text = h.ToStr() + ":" + text
    return text
end function

function pad2(n as Integer) as String
    return Right("0" + n.ToStr(), 2)
end function
