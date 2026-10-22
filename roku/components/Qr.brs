' QR code encoder: byte mode, error correction level M, versions 1-10 (up to 213 bytes), mask 0.
' Port of tools/qrref.py, which is verified against macOS's QR decoder.
' Returns { size: n, mods: flat array of n*n (1 = dark) }, or invalid if the text is too long.

function qrEncode(text as String) as Object
    dataCw = [0, 16, 28, 44, 64, 86, 108, 124, 154, 182, 216]
    eccPer = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
    blockTbl = [invalid, [16], [28], [44], [32, 32], [43, 43], [27, 27, 27, 27], [31, 31, 31, 31], [38, 38, 39, 39], [36, 36, 36, 37, 37], [43, 43, 43, 43, 44]]
    alignTbl = [invalid, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]]

    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    ver = 0
    countBits = 8
    for v = 1 to 10
        cb = 8
        if v >= 10 then cb = 16
        if 4 + cb + 8 * bytes.Count() <= dataCw[v] * 8
            ver = v
            countBits = cb
            exit for
        end if
    end for
    if ver = 0 then return invalid

    ' Data bits -> codewords
    bits = []
    qrPushBits(bits, 4, 4)
    qrPushBits(bits, bytes.Count(), countBits)
    for each b in bytes
        qrPushBits(bits, b, 8)
    end for
    capacity = dataCw[ver] * 8
    term = capacity - bits.Count()
    if term > 4 then term = 4
    for i = 1 to term
        bits.Push(0)
    end for
    while bits.Count() mod 8 <> 0
        bits.Push(0)
    end while
    cw = []
    for i = 0 to bits.Count() - 1 step 8
        value = 0
        for j = 0 to 7
            value = value * 2 + bits[i + j]
        end for
        cw.Push(value)
    end for
    pad = 236
    while cw.Count() < dataCw[ver]
        cw.Push(pad)
        if pad = 236 then pad = 17 else pad = 236
    end while

    ' Reed-Solomon per block, then interleave
    gf = qrGaloisTables()
    blocks = []
    eccs = []
    k = 0
    longest = 0
    for each blockLen in blockTbl[ver]
        blk = []
        for i = 0 to blockLen - 1
            blk.Push(cw[k + i])
        end for
        k = k + blockLen
        if blockLen > longest then longest = blockLen
        blocks.Push(blk)
        eccs.Push(qrReedSolomon(blk, eccPer[ver], gf))
    end for
    final = []
    for i = 0 to longest - 1
        for each blk in blocks
            if i < blk.Count() then final.Push(blk[i])
        end for
    end for
    for i = 0 to eccPer[ver] - 1
        for each e in eccs
            final.Push(e[i])
        end for
    end for

    ' Function patterns
    n = 17 + 4 * ver
    q = { n: n, mods: [], fn: [] }
    for i = 0 to n * n - 1
        q.mods.Push(0)
        q.fn.Push(false)
    end for
    for i = 0 to n - 1
        dark = 0
        if i mod 2 = 0 then dark = 1
        qrSet(q, 6, i, dark)
        qrSet(q, i, 6, dark)
    end for
    for each c in [[3, 3], [n - 4, 3], [3, n - 4]]
        for dy = -4 to 4
            for dx = -4 to 4
                x = c[0] + dx
                y = c[1] + dy
                if x >= 0 and x < n and y >= 0 and y < n
                    d = qrMax(Abs(dx), Abs(dy))
                    dark = 1
                    if d = 2 or d = 4 then dark = 0
                    qrSet(q, x, y, dark)
                end if
            end for
        end for
    end for
    al = alignTbl[ver]
    last = al.Count() - 1
    for i = 0 to last
        for j = 0 to last
            corner = (i = 0 and j = 0) or (i = 0 and j = last) or (i = last and j = 0)
            if not corner
                for dy = -2 to 2
                    for dx = -2 to 2
                        dark = 1
                        if qrMax(Abs(dx), Abs(dy)) = 1 then dark = 0
                        qrSet(q, al[j] + dx, al[i] + dy, dark)
                    end for
                end for
            end if
        end for
    end for

    ' Format information (level M = 00, mask 0)
    fmtData = 0
    acc = fmtData
    for i = 1 to 10
        acc = qrXor(acc * 2, (acc >> 9) * &h537)
    end for
    fmt = qrXor((fmtData << 10) or acc, &h5412)
    for i = 0 to 5
        qrSet(q, 8, i, (fmt >> i) and 1)
    end for
    qrSet(q, 8, 7, (fmt >> 6) and 1)
    qrSet(q, 8, 8, (fmt >> 7) and 1)
    qrSet(q, 7, 8, (fmt >> 8) and 1)
    for i = 9 to 14
        qrSet(q, 14 - i, 8, (fmt >> i) and 1)
    end for
    for i = 0 to 7
        qrSet(q, n - 1 - i, 8, (fmt >> i) and 1)
    end for
    for i = 8 to 14
        qrSet(q, 8, n - 15 + i, (fmt >> i) and 1)
    end for
    qrSet(q, 8, n - 8, 1)

    ' Version information (versions 7+)
    if ver >= 7
        acc = ver
        for i = 1 to 12
            acc = qrXor(acc * 2, (acc >> 11) * &h1F25)
        end for
        vbits = (ver << 12) or acc
        for i = 0 to 17
            bit = (vbits >> i) and 1
            a = n - 11 + (i mod 3)
            b = i \ 3
            qrSet(q, a, b, bit)
            qrSet(q, b, a, bit)
        end for
    end if

    ' Data placement in the zigzag order
    totalBits = final.Count() * 8
    idx = 0
    col = n - 1
    while col >= 1
        if col = 6 then col = 5
        for vert = 0 to n - 1
            for j = 0 to 1
                x = col - j
                upward = ((col + 1) and 2) = 0
                if upward then y = n - 1 - vert else y = vert
                p = y * n + x
                if not q.fn[p] and idx < totalBits
                    q.mods[p] = (final[idx >> 3] >> (7 - (idx and 7))) and 1
                    idx = idx + 1
                end if
            end for
        end for
        col = col - 2
    end while

    ' Mask 0: flip data modules where (x + y) is even
    for y = 0 to n - 1
        for x = 0 to n - 1
            p = y * n + x
            if not q.fn[p] and (x + y) mod 2 = 0 then q.mods[p] = 1 - q.mods[p]
        end for
    end for

    return { size: n, mods: q.mods }
end function

sub qrPushBits(bits as Object, value as Integer, count as Integer)
    for i = count - 1 to 0 step -1
        bits.Push((value >> i) and 1)
    end for
end sub

sub qrSet(q as Object, x as Integer, y as Integer, value as Integer)
    p = y * q.n + x
    q.mods[p] = value
    q.fn[p] = true
end sub

function qrXor(a as Integer, b as Integer) as Integer
    return (a or b) - (a and b)
end function

function qrMax(a as Integer, b as Integer) as Integer
    if a > b then return a
    return b
end function

function qrGaloisTables() as Object
    expT = []
    logT = []
    for i = 0 to 255
        logT.Push(0)
    end for
    x = 1
    for i = 0 to 254
        expT.Push(x)
        logT[x] = i
        x = x * 2
        if x >= 256 then x = qrXor(x, &h11D)
    end for
    for i = 255 to 511
        expT.Push(expT[i - 255])
    end for
    return { exp: expT, log: logT }
end function

function qrMul(a as Integer, b as Integer, gf as Object) as Integer
    if a = 0 or b = 0 then return 0
    return gf.exp[gf.log[a] + gf.log[b]]
end function

function qrReedSolomon(data as Object, degree as Integer, gf as Object) as Object
    gen = [1]
    for i = 0 to degree - 1
        grown = []
        for j = 0 to gen.Count()
            grown.Push(0)
        end for
        for j = 0 to gen.Count() - 1
            grown[j] = qrXor(grown[j], gen[j])
            grown[j + 1] = qrXor(grown[j + 1], qrMul(gen[j], gf.exp[i], gf))
        end for
        gen = grown
    end for
    res = []
    for i = 0 to degree - 1
        res.Push(0)
    end for
    for each d in data
        factor = qrXor(d, res[0])
        res.Shift()
        res.Push(0)
        for j = 0 to degree - 1
            res[j] = qrXor(res[j], qrMul(gen[j + 1], factor, gf))
        end for
    end for
    return res
end function
