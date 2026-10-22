sub init()
    m.poster = m.top.findNode("poster")
    m.badge = m.top.findNode("badge")
    m.duration = m.top.findNode("duration")
    m.title = m.top.findNode("title")
    m.meta = m.top.findNode("meta")
    if m.global.cjkFont <> ""
        m.title.font = makeFont(m.global.cjkFont, 24)
        m.meta.font = makeFont(m.global.cjkFont, 20)
    end if
end sub

function makeFont(uri as String, size as Integer) as Object
    font = CreateObject("roSGNode", "Font")
    font.uri = uri
    font.size = size
    return font
end function

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    m.poster.uri = c.HDPosterUrl
    m.title.text = c.title
    m.meta.text = c.author
    m.duration.text = c.durationText
    m.badge.visible = (c.durationText <> "")
end sub
