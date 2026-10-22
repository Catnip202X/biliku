# Biliku 云屏

**An unofficial Bilibili app for Roku TVs**, with phone casting (投屏), danmaku and 1080P+.

*Biliku* = Bili + Roku. Its Chinese name is 云屏 ("cloud screen").

Roku has no Bilibili app. 云屏 is a Roku app you install yourself through Roku's developer mode, plus a small companion program for Windows, macOS or Linux that installs it and lets the Bilibili phone app cast to your TV.

[中文说明](#中文说明)

## Features

- **Browse on the TV:** 推荐 (your personal recommendations once logged in), 热门, 排行榜, 入站必刷.
- **QR-code login:** press **\*** on the home screen and scan with the Bilibili app. The login is stored only on your TV.
- **Up to 1080P+** with a logged-in account (1080P+ needs 大会员). The default **Auto** mode adapts to your connection. Press **↓** during playback to pick a quality.
- **Danmaku:** every comment for the video, drawn over the picture (display only). Toggle it in the **↓** menu.
- **Cast from the Bilibili app:** tap **投屏** and choose **云屏**. The TV fetches its own HD stream, so you aren't stuck with the 720p that DLNA casting normally gets. Your phone's volume buttons control the TV volume.
- **Share from your phone:** an iPhone Share-sheet shortcut sends any Bilibili link to the TV.
- Multi-part videos play straight through, and Chinese text renders correctly (Noto Sans SC is bundled).

## Setup

### 1. Turn on developer mode on your Roku

On the Roku remote press **Home ×3, Up ×2, Right, Left, Right, Left, Right**. Accept the agreement and **set a developer password**; you'll need it in step 3. The Roku restarts.

### 2. Download the companion for your computer

From the [latest release](../../releases/latest):

| Computer | File |
|---|---|
| Windows | `biliku-windows.exe` |
| Mac with Apple Silicon (M1 and later) | `biliku-macos-apple-silicon` |
| Mac with Intel | `biliku-macos-intel` |
| Linux | `biliku-linux` |

The programs aren't code-signed, so your OS will warn you the first time:
- **macOS:** in Terminal, run `chmod +x ~/Downloads/biliku-macos-*` and `xattr -d com.apple.quarantine ~/Downloads/biliku-macos-*`, then run the file. You can also right-click it → Open.
- **Windows:** on the SmartScreen warning, click **More info → Run anyway**. When Windows Firewall asks, allow access on **private networks**.
- **Linux:** run `chmod +x biliku-linux`, then `./biliku-linux`.

Prefer Python? `python3 companion/biliku.py` from a checkout of this repo does the same thing, using only the standard library.

### 3. Install 云屏 on the TV

Run the companion. It finds your Roku on the network; pick it if you have several. Then choose **1. Install / update 云屏** and enter the developer password from step 1. 云屏 appears as the last tile on the Roku Home screen.

### 4. Turn on casting (optional)

Choose **3. Start the cast receiver automatically at login**. **云屏 · *your TV's name*** then shows up in the Bilibili app's 投屏 list, under the DLNA devices.

The receiver runs on your computer, because Roku apps can't run in the background. The computer has to be on and on the same network as the TV. It also finds the TV again if the TV's IP address changes.

### 5. Share from iPhone (optional)

On a Mac, choose **6. Build the iPhone share shortcut**, then click **Add Shortcut**; it syncs to your iPhone through iCloud. Without a Mac, option 6 shows how to make it by hand in the Shortcuts app.

To use it: in the Bilibili app, tap **Share → More → 投到电视**. It sends the link straight to the TV, and your computer doesn't need to be on.

## Command line

```
biliku                     interactive menu
biliku discover            list Roku devices on the network
biliku install             install / update 云屏 on the Roku
biliku receiver            run the cast receiver in this window
biliku autostart on|off    start the cast receiver at login (or stop doing so)
biliku send <link>         play a Bilibili link / BV id / share text on the TV
biliku shortcut            (macOS) build the iPhone share shortcut
```

## Limitations

- **Maximum quality is 1080P+.** Bilibili only offers 4K as HEVC or AV1, or as 4K H.264 that Roku TVs can't decode. On the Roku TVs tested, Roku's player fails to unpack Bilibili's HEVC and AV1 DASH streams (demux error 970). Pull requests are welcome if you get them working.
- **No search on the TV.** Bilibili blocks it for API clients, so find videos on your phone and send or cast them.
- **No posting danmaku.** They're display only.
- **One developer app per Roku.** Developer mode allows a single sideloaded app, so installing another replaces 云屏.
- **Casting needs the computer on,** since the receiver runs there.

## Troubleshooting

- **"Couldn't reach the Roku" or nothing happens when sending:** on the Roku, set **Settings → System → Advanced system settings → Control by mobile apps → Network access** to **Default** or **Permissive**.
- **云屏 doesn't appear in 投屏:** make sure the receiver is running and your phone and computer are on the same network. On Windows, allow it through the firewall. On macOS, allow "Local Network" access if asked.
- **Buffering:** Wi-Fi on budget TVs is often slow. Use Ethernet if your TV has a port, or leave quality on Auto.

## Privacy

- Your Bilibili login cookies are stored only on your Roku.
- The companion stores your Roku's serial number and IP address in its config folder, and sends nothing anywhere else.
- Video, danmaku and recommendations come straight from Bilibili's own servers.

## Disclaimer

云屏 is an unofficial, personal-use project. It is **not affiliated with, endorsed by or connected to Bilibili (哔哩哔哩) or Roku**. It plays only what your own Bilibili account can access, and does not get around 大会员 or any other restriction. Use it at your own risk and follow Bilibili's terms of service.

## License

MIT, see [LICENSE](LICENSE). The bundled font is a subset of Noto Sans SC under the SIL Open Font License 1.1 ([roku/fonts/OFL.txt](roku/fonts/OFL.txt)).

---

## 中文说明

**云屏**是一个非官方的 Roku 版哔哩哔哩应用，支持手机投屏、弹幕和 1080P+ 画质。

**功能**
- 在电视上浏览推荐（登录后为个人推荐）、热门、排行榜、入站必刷。
- 在首页按遥控器 **\*** 键扫码登录，登录信息只保存在电视上。
- 登录后最高 1080P+（需大会员），默认「自动」画质。播放时按 **↓** 切换画质或开关弹幕。
- 完整弹幕显示（只能看，不能发）。
- 在 B 站 App 点「投屏」，选择「云屏」，电视会自己获取高清画面，不受 DLNA 投屏 720P 的限制。
- iPhone 分享菜单捷径「投到电视」。

**安装步骤**
1. 在 Roku 遥控器上依次按：主页 ×3、上 ×2、右、左、右、左、右，开启开发者模式并设置开发者密码。
2. 从 [Releases](../../releases/latest) 下载对应系统的伴侣程序（Windows / Mac / Linux）。
3. 运行程序，选择「1」把云屏安装到电视，输入开发者密码。
4. 选择「3」让投屏接收器开机自动运行。之后在 B 站 App 的「投屏」里就能看到「云屏」。
5. Mac 用户可选择「6」生成 iPhone 分享捷径。

**限制**：最高 1080P+（4K 目前在 Roku 上无法播放）；电视端不支持搜索；投屏需要电脑开机。

**声明**：本项目与哔哩哔哩、Roku 均无关联，仅供个人使用，不绕过大会员等任何限制。
