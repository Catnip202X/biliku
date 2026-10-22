sub init()
    m.top.functionName = "run"
end sub

sub run()
    port = CreateObject("roMessagePort")
    addr = CreateObject("roSocketAddress")
    addr.SetPort(47800)
    server = CreateObject("roStreamSocket")
    server.SetMessagePort(port)
    server.SetReuseAddr(true)
    server.SetAddress(addr)
    server.NotifyReadable(true)
    if not server.Listen(4)
        print "[biliku] manifest server: listen failed"
        return
    end if
    print "[biliku] manifest server listening on 47800"

    crlf = Chr(13) + Chr(10)
    conns = {}
    while true
        msg = wait(0, port)
        if type(msg) = "roSocketEvent"
            sid = msg.getSocketID()
            if sid = server.GetID()
                if server.IsReadable()
                    conn = server.Accept()
                    if conn <> invalid
                        conn.SetMessagePort(port)
                        conn.NotifyReadable(true)
                        conns[conn.GetID().ToStr()] = { sock: conn, buf: "" }
                    end if
                end if
            else
                key = sid.ToStr()
                if conns.DoesExist(key)
                    entry = conns[key]
                    chunk = entry.sock.ReceiveStr(8192)
                    if chunk = ""
                        entry.sock.Close()
                        conns.Delete(key)
                    else
                        entry.buf = entry.buf + chunk
                        if Instr(1, entry.buf, crlf + crlf) > 0
                            respond(entry.sock, entry.buf, m.top.manifest, crlf)
                            entry.sock.Close()
                            conns.Delete(key)
                        end if
                    end if
                end if
            end if
        end if
    end while
end sub

sub respond(sock as Object, request as String, manifest as String, crlf as String)
    body = CreateObject("roByteArray")
    body.FromAsciiString(manifest)
    status = "200 OK"
    if manifest = "" then status = "404 Not Found"
    head = "HTTP/1.1 " + status + crlf + "Content-Type: application/dash+xml" + crlf + "Content-Length: " + body.Count().ToStr() + crlf + "Connection: close" + crlf + crlf
    data = CreateObject("roByteArray")
    data.FromAsciiString(head)
    if Left(request, 4) <> "HEAD" then data.Append(body)
    sent = 0
    tries = 0
    while sent < data.Count() and tries < 400
        n = sock.Send(data, sent, data.Count() - sent)
        if n > 0
            sent = sent + n
        else
            tries = tries + 1
            sleep(5)
        end if
    end while
    print "[biliku] served manifest "; sent; " bytes"
end sub
