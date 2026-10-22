**New in 0.2.2:**
- **Faster video starts:** signing keys are cached for the day, chapters and part names load after playback starts, and videos picked from the home rows skip a lookup. That's about 1 s less waiting before playback.
- **线路 (server) button** in the player bar: Bilibili's own pick (default, fastest in testing), Huawei Cloud, or Akamai. Switching continues from the same spot, and the choice is remembered.
- **Auto quality** lists the top 3 qualities, so the player fetches fewer stream indexes before starting.

Update the Roku app with the companion (option **1**).

**Downloads:**
- Windows: `biliku-windows.exe`
- macOS: `biliku-macos-apple-silicon` (M1 and later) or `biliku-macos-intel`
- Linux: `biliku-linux`
- `biliku-roku.zip` is the Roku app on its own, for installing manually.

These builds aren't code-signed. See the README for getting past the first-run warnings.
