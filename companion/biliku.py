#!/usr/bin/env python3
"""Biliku 云屏 companion — installs the 云屏 Bilibili app on a Roku and runs its cast receiver.

Runs on Windows, macOS and Linux with only the Python standard library (or as a standalone build).

  biliku                     interactive menu (what double-clicking runs)
  biliku discover            list Roku devices on the network
  biliku install             install / update the 云屏 app on your Roku (needs developer mode)
  biliku receiver            run the cast receiver: "云屏" shows up in phone apps' cast (投屏) lists
  biliku autostart on|off    start the cast receiver automatically when you log in
  biliku send <link>         play a Bilibili link / BV id / share text on the TV
  biliku shortcut            (macOS) build the iPhone Share-sheet shortcut "投到电视"

The chosen TV is remembered by serial number, so it is found again if its IP address changes.
"""
import getpass, html, json, os, platform, re, shutil, socket, struct, subprocess, sys, threading, time, uuid, zipfile, io
import urllib.parse, urllib.request
import concurrent.futures as cf
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.1.0"
APP_NAME = "云屏"
ECP_PORT = 8060
RECEIVER_PORT = 49494
SSDP_ADDR, SSDP_PORT = "239.255.255.250", 1900
VOLUME_STEP_GAP = 0.6  # seconds between TV volume steps while a phone volume button is pressed or held
IS_WIN, IS_MAC = sys.platform == "win32", sys.platform == "darwin"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def config_dir():
    if IS_WIN:
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(base, "Biliku")
    if IS_MAC:
        return os.path.expanduser("~/Library/Application Support/Biliku")
    return os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "biliku")


def load_config():
    try:
        with open(os.path.join(config_dir(), "config.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_config(cfg):
    os.makedirs(config_dir(), exist_ok=True)
    with open(os.path.join(config_dir(), "config.json"), "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

# ---------------------------------------------------------------- finding the Roku

def device_info(ip, timeout=3):
    """Roku ECP device-info as a dict, or None if ip isn't a Roku."""
    try:
        with urllib.request.urlopen(f"http://{ip}:{ECP_PORT}/query/device-info", timeout=timeout) as r:
            x = r.read().decode("utf-8", "replace")
    except Exception:
        return None
    get = lambda tag: (re.search(rf"<{tag}>(.*?)</{tag}>", x, re.S) or [None, ""])[1].strip()
    if not get("serial-number"):
        return None
    return {"ip": ip, "serial": get("serial-number"), "name": get("friendly-device-name") or get("model-name"),
            "model": get("model-name"), "is_tv": get("is-tv") == "true", "dev_mode": get("developer-enabled") == "true",
            "network": get("network-type"), "ecp_mode": get("ecp-setting-mode")}


def local_ip_towards(ip="8.8.8.8"):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((ip, 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def ssdp_search(timeout=3.0):
    found = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.settimeout(timeout)
        s.sendto(b'M-SEARCH * HTTP/1.1\r\nHost: 239.255.255.250:1900\r\nMan: "ssdp:discover"\r\nST: roku:ecp\r\nMX: 2\r\n\r\n',
                 (SSDP_ADDR, SSDP_PORT))
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, addr = s.recvfrom(2048)
            except socket.timeout:
                break
            if b"roku" in data.lower():
                found.add(addr[0])
    except OSError:
        pass
    return found


def scan_subnet():
    """Fallback when multicast is blocked: probe port 8060 across the local /24."""
    base = local_ip_towards().rsplit(".", 1)[0]

    def probe(i):
        ip = f"{base}.{i}"
        try:
            socket.create_connection((ip, ECP_PORT), timeout=0.5).close()
            return ip
        except OSError:
            return None
    with cf.ThreadPoolExecutor(64) as ex:
        return {ip for ip in ex.map(probe, range(1, 255)) if ip}


def discover():
    ips = ssdp_search() or scan_subnet()
    with cf.ThreadPoolExecutor(16) as ex:
        devices = [d for d in ex.map(device_info, sorted(ips)) if d]
    return sorted(devices, key=lambda d: (not d["is_tv"], d["name"]))


def choose_tv(devices):
    if not devices:
        return None
    if len(devices) == 1:
        return devices[0]
    print("\nRoku devices found:")
    for i, d in enumerate(devices, 1):
        print(f"  {i}. {d['name']}  ({d['model']}, {d['ip']}, {d['network']})")
    while True:
        pick = input(f"Which one? [1-{len(devices)}]: ").strip()
        if pick.isdigit() and 1 <= int(pick) <= len(devices):
            return devices[int(pick) - 1]


def find_tv(interactive=True, forget=False):
    """The configured Roku (by serial), re-discovering it if its IP changed. Asks once if none is set."""
    cfg = load_config()
    if cfg.get("serial") and not forget:
        d = device_info(cfg.get("ip", ""), timeout=2)
        if d and d["serial"] == cfg["serial"]:
            return d
        for d in discover():
            if d["serial"] == cfg["serial"]:
                cfg["ip"] = d["ip"]
                save_config(cfg)
                log(f"{d['name']} moved to {d['ip']}")
                return d
        if not interactive:
            return None
        print(f"Couldn't find your saved Roku ({cfg.get('name', cfg['serial'])}). Searching for others…")
    if not interactive:
        return None
    print("Searching the network for Roku devices…")
    d = choose_tv(discover())
    if d:
        cfg.update({"serial": d["serial"], "ip": d["ip"], "name": d["name"]})
        save_config(cfg)
    return d

# ---------------------------------------------------------------- installing the Roku app

def app_package():
    """The 云屏 Roku app as zip bytes: bundled in standalone builds, else zipped from ../roku."""
    bundled = os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))), "biliku-roku.zip")
    if os.path.exists(bundled):
        with open(bundled, "rb") as f:
            return f.read()
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "roku")
    if not os.path.isdir(src):
        raise SystemExit("Roku app not found (expected biliku-roku.zip next to this program, or ../roku).")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(src):
            for name in files:
                if name != ".DS_Store":
                    path = os.path.join(root, name)
                    z.write(path, os.path.relpath(path, src))
    return buf.getvalue()


DEV_MODE_HELP = """Developer mode isn't on for this Roku. To turn it on:
  1. On the Roku remote press: Home ×3, Up ×2, Right, Left, Right, Left, Right
  2. Accept the agreement and set a developer password (you'll type it here next)
  3. The Roku restarts; then run install again."""


def install(tv):
    if not tv["dev_mode"]:
        print(DEV_MODE_HELP)
        return False
    data = app_package()
    boundary = "----biliku" + uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"mysubmit\"\r\n\r\nInstall\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"archive\"; filename=\"biliku.zip\"\r\n"
            "Content-Type: application/zip\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
    print(f"Installing {APP_NAME} on {tv['name']} ({tv['ip']}), {len(data) // 1024} KB.")
    password = getpass.getpass("Roku developer password (the one you set when enabling developer mode): ")
    url = f"http://{tv['ip']}/plugin_install"
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, url, "rokudev", password)
    opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))
    req = urllib.request.Request(url, data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with opener.open(req, timeout=120) as r:
            page = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        print("Wrong developer password." if e.code == 401 else f"The Roku answered HTTP {e.code}.")
        return False
    except OSError as e:
        print(f"Couldn't reach the Roku: {e}")
        return False
    m = re.search(r"(Install Success|Identical to previous version|Install Failure[^\"<\\]*|Compilation Failed[^\"<\\]*)", page)
    status = m.group(1) if m else "No install status in the Roku's reply"
    print(status)
    if "Success" in status or "Identical" in status:
        print(f"{APP_NAME} is on your Roku's Home screen (last tile).")
        if tv.get("ecp_mode") == "limited":
            print("Tip: for sending videos from phones, set Settings → System → Advanced system settings →\n"
                  "     Control by mobile apps → Network access → Default or Permissive on the Roku.")
        return True
    return False

# ---------------------------------------------------------------- sending a video

def ecp(tv, path, timeout=5):
    """POST to the Roku's ECP. If the Roku moved to a new IP, find it again (by serial) and retry once."""
    for attempt in range(2):
        req = urllib.request.Request(f"http://{tv['ip']}:{ECP_PORT}{path}", data=b"", method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status
        except OSError as e:
            if attempt == 0:
                moved = find_tv(interactive=False)
                if moved and moved["ip"] != tv["ip"]:
                    tv.update(moved)
                    continue
            log("Roku didn't respond:", e)
            return 0


def ecp_query(tv, what, timeout=3):
    try:
        with urllib.request.urlopen(f"http://{tv['ip']}:{ECP_PORT}/query/{what}", timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except OSError:
        return ""


def app_is_open(tv):
    return 'id="dev"' in ecp_query(tv, "active-app")


def send(tv, text):
    """The TV app finds the video itself in any Bilibili link, short link, share text, BV or av id."""
    q = urllib.parse.urlencode({"contentId": text, "mediaType": "movie"})
    code = ecp(tv, ("/input?" if app_is_open(tv) else "/launch/dev?") + q)
    print(f"Sent to {tv['name']}." if 200 <= code < 300 else "The Roku didn't accept it — is 云屏 installed?")

# ---------------------------------------------------------------- cast receiver (DLNA MediaRenderer)

SERVICES = {
    "AVTransport": {
        "SetAVTransportURI": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "CurrentURI", "AVTransportURI"), ("in", "CurrentURIMetaData", "AVTransportURIMetaData")],
        "SetNextAVTransportURI": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "NextURI", "NextAVTransportURI"), ("in", "NextURIMetaData", "NextAVTransportURIMetaData")],
        "GetMediaInfo": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("out", "NrTracks", "NumberOfTracks"), ("out", "MediaDuration", "CurrentMediaDuration"), ("out", "CurrentURI", "AVTransportURI"), ("out", "CurrentURIMetaData", "AVTransportURIMetaData"), ("out", "NextURI", "NextAVTransportURI"), ("out", "NextURIMetaData", "NextAVTransportURIMetaData"), ("out", "PlayMedium", "PlaybackStorageMedium"), ("out", "RecordMedium", "RecordStorageMedium"), ("out", "WriteStatus", "RecordMediumWriteStatus")],
        "GetTransportInfo": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("out", "CurrentTransportState", "TransportState"), ("out", "CurrentTransportStatus", "TransportStatus"), ("out", "CurrentSpeed", "TransportPlaySpeed")],
        "GetPositionInfo": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("out", "Track", "CurrentTrack"), ("out", "TrackDuration", "CurrentTrackDuration"), ("out", "TrackMetaData", "CurrentTrackMetaData"), ("out", "TrackURI", "CurrentTrackURI"), ("out", "RelTime", "RelativeTimePosition"), ("out", "AbsTime", "AbsoluteTimePosition"), ("out", "RelCount", "RelativeCounterPosition"), ("out", "AbsCount", "AbsoluteCounterPosition")],
        "GetDeviceCapabilities": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("out", "PlayMedia", "PossiblePlaybackStorageMedia"), ("out", "RecMedia", "PossibleRecordStorageMedia"), ("out", "RecQualityModes", "PossibleRecordQualityModes")],
        "GetTransportSettings": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("out", "PlayMode", "CurrentPlayMode"), ("out", "RecQualityMode", "CurrentRecordQualityMode")],
        "GetCurrentTransportActions": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("out", "Actions", "CurrentTransportActions")],
        "Play": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "Speed", "TransportPlaySpeed")],
        "Pause": [("in", "InstanceID", "A_ARG_TYPE_InstanceID")],
        "Stop": [("in", "InstanceID", "A_ARG_TYPE_InstanceID")],
        "Seek": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "Unit", "A_ARG_TYPE_SeekMode"), ("in", "Target", "A_ARG_TYPE_SeekTarget")],
        "Next": [("in", "InstanceID", "A_ARG_TYPE_InstanceID")],
        "Previous": [("in", "InstanceID", "A_ARG_TYPE_InstanceID")],
    },
    "RenderingControl": {
        "GetVolume": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "Channel", "A_ARG_TYPE_Channel"), ("out", "CurrentVolume", "Volume")],
        "SetVolume": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "Channel", "A_ARG_TYPE_Channel"), ("in", "DesiredVolume", "Volume")],
        "GetMute": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "Channel", "A_ARG_TYPE_Channel"), ("out", "CurrentMute", "Mute")],
        "SetMute": [("in", "InstanceID", "A_ARG_TYPE_InstanceID"), ("in", "Channel", "A_ARG_TYPE_Channel"), ("in", "DesiredMute", "Mute")],
    },
    "ConnectionManager": {
        "GetProtocolInfo": [("out", "Source", "SourceProtocolInfo"), ("out", "Sink", "SinkProtocolInfo")],
        "GetCurrentConnectionIDs": [("out", "ConnectionIDs", "CurrentConnectionIDs")],
        "GetCurrentConnectionInfo": [("in", "ConnectionID", "A_ARG_TYPE_ConnectionID"), ("out", "RcsID", "A_ARG_TYPE_RcsID"), ("out", "AVTransportID", "A_ARG_TYPE_AVTransportID"), ("out", "ProtocolInfo", "A_ARG_TYPE_ProtocolInfo"), ("out", "PeerConnectionManager", "A_ARG_TYPE_ConnectionManager"), ("out", "PeerConnectionID", "A_ARG_TYPE_ConnectionID"), ("out", "Direction", "A_ARG_TYPE_Direction"), ("out", "Status", "A_ARG_TYPE_ConnectionStatus")],
    },
}
TYPES = {"A_ARG_TYPE_InstanceID": "ui4", "NumberOfTracks": "ui4", "CurrentTrack": "ui4", "RelativeCounterPosition": "i4",
         "AbsoluteCounterPosition": "i4", "Volume": "ui2", "Mute": "boolean", "A_ARG_TYPE_ConnectionID": "i4",
         "A_ARG_TYPE_RcsID": "i4", "A_ARG_TYPE_AVTransportID": "i4"}
SINK = ",".join(f"http-get:*:{t}:*" for t in ["video/mp4", "video/x-flv", "video/x-matroska", "application/vnd.apple.mpegurl",
                                               "application/x-mpegURL", "audio/mpeg", "audio/mp4", "*"])


def hms(sec):
    sec = max(0, int(sec))
    return f"{sec // 3600:02d}:{sec // 60 % 60:02d}:{sec % 60:02d}"


def seconds(t):
    try:
        parts = [float(p) for p in t.split(":")]
        return int(parts[0] * 3600 + parts[1] * 60 + parts[2]) if len(parts) == 3 else int(parts[0])
    except ValueError:
        return 0


def scpd(service):
    actions, variables = [], set()
    for name, args in SERVICES[service].items():
        arg_xml = "".join(f"<argument><name>{a}</name><direction>{d}</direction><relatedStateVariable>{v}</relatedStateVariable></argument>"
                          for d, a, v in args)
        variables.update(v for _, _, v in args)
        actions.append(f"<action><name>{name}</name><argumentList>{arg_xml}</argumentList></action>")
    variables.add("LastChange")
    state = "".join(f'<stateVariable sendEvents="{"yes" if v == "LastChange" else "no"}"><name>{v}</name><dataType>{TYPES.get(v, "string")}</dataType></stateVariable>'
                    for v in sorted(variables))
    return ('<?xml version="1.0" encoding="utf-8"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>'
            f"<actionList>{''.join(actions)}</actionList><serviceStateTable>{state}</serviceStateTable></scpd>")


class Receiver:
    """Shows up as a DLNA renderer. Casts open 云屏 on the Roku (via ECP) with the stream URL; play / pause /
    seek / stop and phone volume buttons are forwarded; state and position are read from the Roku."""

    def __init__(self, tv):
        self.tv = tv
        self.name = f"{APP_NAME} · {tv['name']}"
        self.udn = "uuid:" + str(uuid.uuid5(uuid.NAMESPACE_DNS, "biliku-receiver-" + tv["serial"]))
        self.server = f"{platform.system()} UPnP/1.0 Biliku/{VERSION}"
        self.ip = local_ip_towards(tv["ip"])
        self.location = f"http://{self.ip}:{RECEIVER_PORT}/description.xml"
        self.uri = self.meta = ""
        self.loading_until = 0.0
        self.volume, self.mute = 100, 0
        self.last_volume_key, self.last_volume_time = "", 0.0
        self.targets = ["upnp:rootdevice", self.udn, "urn:schemas-upnp-org:device:MediaRenderer:1"] + \
                       [f"urn:schemas-upnp-org:service:{s}:1" for s in SERVICES]

    # ---- TV side
    def media_player(self):
        x = ecp_query(self.tv, "media-player")
        state = (re.search(r'<player state="(\w+)"', x) or [None, "close"])[1]
        ms = lambda tag: int((re.search(rf"<{tag}>(\d+) ms</{tag}>", x) or [None, 0])[1])
        return state, ms("position") // 1000, ms("duration") // 1000

    def load(self, uri, meta):
        m = re.search(r"<dc:title>(.*?)</dc:title>", meta, re.S)
        title = html.unescape(m.group(1)) if m else ""
        self.uri, self.meta = uri, meta
        self.loading_until = time.time() + 20
        log("Cast:", title or "(no title)")
        q = urllib.parse.urlencode({"contentId": "cast", "mediaType": "movie", "url": uri, "title": title})
        # /launch restarts an app that's already open, so hand an open app the cast directly.
        ecp(self.tv, ("/input?" if app_is_open(self.tv) else "/launch/dev?") + q)

    def transport(self):
        state, pos, dur = self.media_player()
        if state == "play":
            self.loading_until = 0
            ts = "PLAYING"
        elif state == "pause":
            ts = "PAUSED_PLAYBACK"
        elif state in ("buffer", "startup") or time.time() < self.loading_until:
            ts = "TRANSITIONING"
        else:
            ts = "STOPPED" if self.uri else "NO_MEDIA_PRESENT"
        return ts, pos, dur

    # ---- UPnP
    def description(self):
        services = "".join(
            f"<service><serviceType>urn:schemas-upnp-org:service:{s}:1</serviceType><serviceId>urn:upnp-org:serviceId:{s}</serviceId>"
            f"<SCPDURL>/{s}/scpd.xml</SCPDURL><controlURL>/{s}/control</controlURL><eventSubURL>/{s}/event</eventSubURL></service>"
            for s in SERVICES)
        name = html.escape(self.name)
        return ('<?xml version="1.0" encoding="utf-8"?><root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">'
                "<specVersion><major>1</major><minor>0</minor></specVersion><device>"
                "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
                f"<friendlyName>{name}</friendlyName><manufacturer>Biliku</manufacturer><modelName>{APP_NAME}</modelName>"
                "<modelDescription>Roku cast receiver</modelDescription><modelNumber>1</modelNumber>"
                f"<UDN>{self.udn}</UDN><dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC><serviceList>{services}</serviceList></device></root>")

    def soap(self, service, action, body):
        def arg(name):
            m = re.search(rf"<(?:\w+:)?{name}(?:\s[^>]*)?>(.*?)</(?:\w+:)?{name}>", body, re.S)
            return html.unescape(m.group(1)) if m else ""

        out, tv = {}, self.tv
        if action == "SetAVTransportURI":
            self.load(arg("CurrentURI"), arg("CurrentURIMetaData"))
        elif action == "Play":
            state, _, _ = self.media_player()
            if state == "pause":
                ecp(tv, "/input?cmd=resume")
            elif state in ("close", "stop", "none") and self.uri and time.time() > self.loading_until:
                self.load(self.uri, self.meta)
        elif action == "Pause":
            ecp(tv, "/input?cmd=pause")
        elif action == "Stop":
            self.loading_until = 0
            ecp(tv, "/input?cmd=stop")
        elif action == "Seek":
            ecp(tv, f"/input?cmd=seek&pos={seconds(arg('Target'))}")
        elif action == "GetTransportInfo":
            out = {"CurrentTransportState": self.transport()[0], "CurrentTransportStatus": "OK", "CurrentSpeed": "1"}
        elif action == "GetPositionInfo":
            _, pos, dur = self.transport()
            out = {"Track": "1" if self.uri else "0", "TrackDuration": hms(dur), "TrackMetaData": self.meta, "TrackURI": self.uri,
                   "RelTime": hms(pos), "AbsTime": hms(pos), "RelCount": "2147483647", "AbsCount": "2147483647"}
        elif action == "GetMediaInfo":
            out = {"NrTracks": "1" if self.uri else "0", "MediaDuration": hms(self.transport()[2]), "CurrentURI": self.uri,
                   "CurrentURIMetaData": self.meta, "NextURI": "", "NextURIMetaData": "", "PlayMedium": "NETWORK",
                   "RecordMedium": "NOT_IMPLEMENTED", "WriteStatus": "NOT_IMPLEMENTED"}
        elif action == "GetTransportSettings":
            out = {"PlayMode": "NORMAL", "RecQualityMode": "NOT_IMPLEMENTED"}
        elif action == "GetDeviceCapabilities":
            out = {"PlayMedia": "NETWORK", "RecMedia": "NOT_IMPLEMENTED", "RecQualityModes": "NOT_IMPLEMENTED"}
        elif action == "GetCurrentTransportActions":
            out = {"Actions": "Play,Pause,Stop,Seek"}
        elif action == "GetVolume":
            out = {"CurrentVolume": str(self.volume)}
        elif action == "SetVolume":
            # A phone volume press arrives as a burst of SetVolume calls: allow one TV step per press.
            desired = int(arg("DesiredVolume") or self.volume)
            if desired != self.volume:
                key = "VolumeUp" if desired > self.volume else "VolumeDown"
                now = time.time()
                if key != self.last_volume_key or now - self.last_volume_time >= VOLUME_STEP_GAP:
                    ecp(tv, "/keypress/" + key)
                    self.last_volume_key, self.last_volume_time = key, now
            self.volume = desired
        elif action == "GetMute":
            out = {"CurrentMute": str(self.mute)}
        elif action == "SetMute":
            mute = 1 if arg("DesiredMute") in ("1", "true") else 0
            if mute != self.mute:
                ecp(tv, "/keypress/VolumeMute")
            self.mute = mute
        elif action == "GetProtocolInfo":
            out = {"Source": "", "Sink": SINK}
        elif action == "GetCurrentConnectionIDs":
            out = {"ConnectionIDs": "0"}
        elif action == "GetCurrentConnectionInfo":
            out = {"RcsID": "0", "AVTransportID": "0", "ProtocolInfo": "", "PeerConnectionManager": "",
                   "PeerConnectionID": "-1", "Direction": "Input", "Status": "OK"}
        args = "".join(f"<{k}>{html.escape(v, quote=False)}</{k}>" for k, v in out.items())
        return ('<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:{action}Response xmlns:u="urn:schemas-upnp-org:service:{service}:1">{args}</u:{action}Response></s:Body></s:Envelope>')

    def http_handler(self):
        receiver = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def send(self, code, body="", headers=None):
                data = body.encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", 'text/xml; charset="utf-8"')
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Server", receiver.server)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                path = self.path.split("?")[0]
                if path == "/description.xml":
                    return self.send(200, receiver.description())
                m = re.fullmatch(r"/(\w+)/scpd\.xml", path)
                if m and m.group(1) in SERVICES:
                    return self.send(200, scpd(m.group(1)))
                self.send(404)

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8", "replace")
                m = re.fullmatch(r"/(\w+)/control", self.path.split("?")[0])
                action = (self.headers.get("SOAPACTION") or "").strip('"').split("#")[-1]
                if not m or m.group(1) not in SERVICES:
                    return self.send(404)
                self.send(200, receiver.soap(m.group(1), action, body))

            def do_SUBSCRIBE(self):
                self.send(200, headers={"SID": "uuid:" + str(uuid.uuid4()), "TIMEOUT": "Second-1800"})

            def do_UNSUBSCRIBE(self):
                self.send(200)
        return Handler

    # ---- SSDP
    def usn(self, t):
        return self.udn if t == self.udn else f"{self.udn}::{t}"

    def notify(self, sock, nts):
        for t in self.targets:
            msg = (f"NOTIFY * HTTP/1.1\r\nHOST: {SSDP_ADDR}:{SSDP_PORT}\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: {self.location}\r\n"
                   f"NT: {t}\r\nNTS: {nts}\r\nSERVER: {self.server}\r\nUSN: {self.usn(t)}\r\n\r\n")
            try:
                sock.sendto(msg.encode(), (SSDP_ADDR, SSDP_PORT))
            except OSError as e:
                log("Announce failed (network not ready?):", e)
                return

    def run(self):
        httpd = ThreadingHTTPServer(("", RECEIVER_PORT), self.http_handler())
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        listening = True
        try:
            sock.bind(("", SSDP_PORT))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4s4s", socket.inet_aton(SSDP_ADDR), socket.inet_aton(self.ip)))
        except OSError as e:
            # e.g. Windows' SSDP Discovery service holding port 1900: announcements still go out.
            listening = False
            log(f"Can't listen for device searches ({e}); announcing only. Phones may take up to 30 s to see {APP_NAME}.")
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(self.ip))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
        sock.settimeout(1.0)
        log(f'"{self.name}" is ready for casting ({self.ip}:{RECEIVER_PORT} → Roku {self.tv["ip"]}). Press Ctrl+C to stop.')
        self.notify(sock, "ssdp:alive")
        last = time.time()
        try:
            while True:
                data = None
                if listening:
                    try:
                        data, addr = sock.recvfrom(4096)
                    except socket.timeout:
                        pass
                    except OSError:
                        time.sleep(1)
                else:
                    time.sleep(1)
                if data and data.startswith(b"M-SEARCH"):
                    st = (re.search(r"(?im)^ST:\s*(.+?)\s*$", data.decode("utf-8", "replace")) or [None, ""])[1]
                    for t in self.targets:
                        if st == "ssdp:all" or st.lower() == t.lower():
                            resp = (f"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: {self.location}\r\n"
                                    f"SERVER: {self.server}\r\nST: {t}\r\nUSN: {self.usn(t)}\r\n\r\n")
                            try:
                                sock.sendto(resp.encode(), addr)
                            except OSError:
                                pass
                if time.time() - last > 30:
                    self.notify(sock, "ssdp:alive")
                    last = time.time()
        except KeyboardInterrupt:
            pass
        finally:
            self.notify(sock, "ssdp:byebye")

# ---------------------------------------------------------------- start at login

def installed_command():
    """Copy this program somewhere stable (background jobs can't read ~/Documents or ~/Downloads on macOS)
    and return the command that runs it."""
    dest = config_dir()
    os.makedirs(dest, exist_ok=True)
    if getattr(sys, "frozen", False):
        target = os.path.join(dest, os.path.basename(sys.executable))
        if os.path.abspath(sys.executable) != os.path.abspath(target):
            shutil.copy2(sys.executable, target)
        return [target]
    target = os.path.join(dest, "biliku.py")
    shutil.copy2(os.path.abspath(__file__), target)
    pkg = os.path.join(dest, "biliku-roku.zip")
    with open(pkg, "wb") as f:
        f.write(app_package())
    return [sys.executable, target]


def autostart(enable):
    label = "com.biliku.receiver"
    if IS_MAC:
        plist = os.path.expanduser(f"~/Library/LaunchAgents/{label}.plist")
        domain = f"gui/{os.getuid()}"
        subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], capture_output=True)
        if not enable:
            if os.path.exists(plist):
                os.remove(plist)
            print("Cast receiver will no longer start at login.")
            return
        cmd = installed_command() + ["receiver"]
        logfile = os.path.expanduser("~/Library/Logs/biliku-receiver.log")
        args = "".join(f"<string>{html.escape(c)}</string>" for c in cmd)
        os.makedirs(os.path.dirname(plist), exist_ok=True)
        with open(plist, "w", encoding="utf-8") as f:
            f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array>{args}</array>
  <key>EnvironmentVariables</key><dict><key>PYTHONUNBUFFERED</key><string>1</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>{html.escape(logfile)}</string><key>StandardErrorPath</key><string>{html.escape(logfile)}</string>
</dict></plist>
''')
        subprocess.run(["launchctl", "bootstrap", domain, plist], check=False)
        print(f"Cast receiver will start at login, and is running now. Log: {logfile}")
    elif IS_WIN:
        startup = os.path.join(os.environ["APPDATA"], r"Microsoft\Windows\Start Menu\Programs\Startup", "Biliku receiver.vbs")
        if not enable:
            if os.path.exists(startup):
                os.remove(startup)
            print("Cast receiver will no longer start at login.")
            return
        cmd = installed_command() + ["receiver"]
        line = " ".join(f'""{c}""' for c in cmd)
        with open(startup, "w", encoding="utf-8") as f:
            # Window style 0 = hidden, so no console window sits on the desktop.
            f.write(f'CreateObject("WScript.Shell").Run "{line}", 0, False\n')
        subprocess.Popen(["wscript", startup])
        print("Cast receiver will start at login (hidden), and is running now.\n"
              "If Windows Firewall asks, allow access on private networks.")
    else:
        unit_dir = os.path.expanduser("~/.config/systemd/user")
        unit = os.path.join(unit_dir, "biliku-receiver.service")
        has_systemd = shutil.which("systemctl") is not None
        if has_systemd:
            subprocess.run(["systemctl", "--user", "disable", "--now", "biliku-receiver.service"], capture_output=True)
        if not enable:
            if os.path.exists(unit):
                os.remove(unit)
            print("Cast receiver will no longer start at login.")
            return
        if not has_systemd:
            print("systemd isn't available; add this command to your desktop's startup programs instead:\n  "
                  + " ".join(installed_command() + ["receiver"]))
            return
        cmd = " ".join(f'"{c}"' for c in installed_command() + ["receiver"])
        os.makedirs(unit_dir, exist_ok=True)
        with open(unit, "w", encoding="utf-8") as f:
            f.write(f"[Unit]\nDescription=Biliku cast receiver for Roku\nAfter=network-online.target\n\n"
                    f"[Service]\nExecStart={cmd}\nRestart=always\nRestartSec=10\nEnvironment=PYTHONUNBUFFERED=1\n\n"
                    f"[Install]\nWantedBy=default.target\n")
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
        subprocess.run(["systemctl", "--user", "enable", "--now", "biliku-receiver.service"], check=False)
        print("Cast receiver will start at login, and is running now. Logs: journalctl --user -u biliku-receiver")

# ---------------------------------------------------------------- iPhone shortcut (macOS can sign it)

def make_shortcut(tv):
    import plistlib
    if not IS_MAC or not shutil.which("shortcuts"):
        print(f"Building the shortcut file needs macOS. On the iPhone, make it by hand instead:\n"
              f"  Shortcuts → + → enable 'Show in Share Sheet' (URLs and Text), then add:\n"
              f"   1. URL Encode (Shortcut Input)\n"
              f"   2. Get Contents of URL: http://{tv['ip']}:{ECP_PORT}/launch/dev?contentId=[URL Encoded Text]&mediaType=movie — Method POST")
        return
    uid = str(uuid.uuid4()).upper()
    url_text = f"http://{tv['ip']}:{ECP_PORT}/launch/dev?contentId=￼&mediaType=movie"
    slot = url_text.index("￼")
    actions = [
        ("is.workflow.actions.urlencode", {"UUID": uid, "WFEncodeMode": "Encode", "WFInput": {
            "Value": {"string": "￼\n￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}, "{2, 1}": {"Type": "Clipboard"}}},
            "WFSerializationType": "WFTextTokenString"}}),
        ("is.workflow.actions.downloadurl", {"WFHTTPMethod": "POST", "WFURL": {
            "Value": {"string": url_text, "attachmentsByRange": {f"{{{slot}, 1}}": {"Type": "ActionOutput", "OutputUUID": uid, "OutputName": "URL Encoded Text"}}},
            "WFSerializationType": "WFTextTokenString"}}),
        ("is.workflow.actions.notification", {"WFNotificationActionTitle": APP_NAME, "WFNotificationActionBody": "已投送到电视  ·  Sent to TV"}),
    ]
    data = {"WFWorkflowClientVersion": "2607.0.0", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": {"WFWorkflowIconStartColor": 1440408063, "WFWorkflowIconGlyphNumber": 59511},
            "WFWorkflowTypes": ["ActionExtension"], "WFWorkflowInputContentItemClasses": ["WFURLContentItem", "WFStringContentItem"],
            "WFWorkflowHasShortcutInputVariables": True, "WFWorkflowImportQuestions": [],
            "WFWorkflowActions": [{"WFWorkflowActionIdentifier": a, "WFWorkflowActionParameters": p} for a, p in actions]}
    out_dir = os.path.expanduser("~/Downloads")
    unsigned = os.path.join(config_dir(), "unsigned.shortcut")
    signed = os.path.join(out_dir, "投到电视.shortcut")
    os.makedirs(config_dir(), exist_ok=True)
    with open(unsigned, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    if os.path.exists(signed):
        os.remove(signed)
    subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", signed], check=False)
    if os.path.exists(signed):
        subprocess.run(["open", signed])
        print(f"Opened {signed} — click 'Add Shortcut'. It syncs to your iPhone via iCloud.\n"
              "Use it from the Bilibili app: Share → More → 投到电视.")

# ---------------------------------------------------------------- command line / menu

def need_tv():
    tv = find_tv()
    if not tv:
        raise SystemExit("No Roku found. Make sure it's on and on the same network as this computer.")
    return tv


def menu():
    print(f"{APP_NAME} Biliku companion {VERSION}")
    tv = need_tv()
    while True:
        print(f"\nRoku: {tv['name']} ({tv['ip']})\n"
              f"  1. Install / update {APP_NAME} on the Roku\n"
              f"  2. Start the cast receiver now (keep this window open)\n"
              f"  3. Start the cast receiver automatically at login\n"
              f"  4. Stop starting it at login\n"
              f"  5. Send a Bilibili link to the TV\n"
              f"  6. {'Build the iPhone share shortcut' if IS_MAC else 'iPhone share shortcut instructions'}\n"
              f"  7. Choose a different Roku\n"
              f"  0. Quit")
        choice = input("> ").strip()
        if choice == "1":
            install(tv)
        elif choice == "2":
            Receiver(tv).run()
        elif choice == "3":
            autostart(True)
        elif choice == "4":
            autostart(False)
        elif choice == "5":
            text = input("Paste a Bilibili link, share text or BV id: ").strip()
            if text:
                send(tv, text)
        elif choice == "6":
            make_shortcut(tv)
        elif choice == "7":
            tv = find_tv(forget=True) or tv
        elif choice in ("0", "q", ""):
            return


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
    elif cmd in ("-v", "--version"):
        print(VERSION)
    elif cmd == "discover":
        for d in discover():
            print(f"{d['name']:24} {d['model']:16} {d['ip']:16} {d['network']:9} dev mode {'on' if d['dev_mode'] else 'off'}")
    elif cmd == "install":
        sys.exit(0 if install(need_tv()) else 1)
    elif cmd == "receiver":
        tv = None
        while not tv:  # at login the network may not be up yet
            tv = find_tv(interactive=sys.stdin.isatty())
            if not tv:
                log("Roku not found yet; retrying in 30 s.")
                time.sleep(30)
        Receiver(tv).run()
    elif cmd == "autostart" and len(argv) > 1 and argv[1] in ("on", "off"):
        if argv[1] == "on":
            need_tv()
        autostart(argv[1] == "on")
    elif cmd == "send" and len(argv) > 1:
        send(need_tv(), " ".join(argv[1:]))
    elif cmd == "shortcut":
        make_shortcut(need_tv())
    elif not cmd:
        try:
            menu()
        except (KeyboardInterrupt, EOFError):
            print()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
