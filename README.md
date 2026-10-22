# fstn view

A fast, minimal image viewer for macOS, inspired by FastStone Image Viewer.
Opens JPEG, HEIC, PNG, WebP, AVIF, TIFF and camera RAW files (CR3, CR2, NEF, ARW, DNG, RAF and more)
almost instantly and shows an info panel with EXIF data and a histogram.

## Features

- **Fast opening.** Images are decoded straight to screen size. For RAW files the embedded full-size JPEG preview is used, so a 30 MP CR3 opens in about 0.15 s.
- **Instant browsing.** Neighbouring images are preloaded, so the arrow keys switch photos without delay.
- **Info panel** (EXIF, camera, lens, exposure, GPS, RGB histogram). It slides in when you move the mouse to the right edge, and you can pin it with `I`.
- **Info line** in the top-left corner: file name, dimensions, megapixels, file size, position in folder and zoom (like FastStone).
- **Zoom.** Click to toggle 100% at the clicked point. Press and hold to zoom only while the button is down, and drag to look around.
- **Delete to Trash** with `Delete` / `Backspace`; `⌘Z` restores the last deleted photo.
- **Full screen on launch.** `Esc` quits.
- **English and Ukrainian UI.** Switch it in the *Language* menu without restarting.
- **Built-in updates** from GitHub Releases.

## Install

1. Download the latest `fstn-view-X.Y.Z.zip` from [Releases](https://github.com/istvikoo/fstn-view/releases).
2. Unzip it and move **fstn view.app** to `/Applications`.
3. The app is not notarized by Apple, so the first time you open it, **right-click → Open**, then confirm. Or run this command:
   ```
   xattr -dr com.apple.quarantine "/Applications/fstn view.app"
   ```

Requires macOS 14 Sonoma or later.

## Keyboard and mouse

| Action | Shortcut |
|---|---|
| Next / previous image | `→` `↓` `Space` `PageDown` / `←` `↑` `PageUp`, mouse wheel |
| First / last image | `Home` / `End` |
| Toggle fit ↔ 100% | Click, `Z` or `1` |
| Zoom while held | Press and hold the mouse button |
| Zoom in / out | `+` / `−`, `⌘` + wheel, pinch |
| Fit to window | `0` |
| Show info panel | Move the mouse to the right edge |
| Pin / unpin info panel | `I` or `Tab` |
| Show / hide info line | `T` |
| Move to Trash / restore | `Delete` or `Backspace` / `⌘Z` |
| Leave or enter full screen | `F` or `Enter` |
| Quit | `Esc` |
| Open file or folder | `⌘O` |

## Updates

The app checks GitHub Releases once a day at launch. You can also check any time with **fstn view → Check for Updates…**.
When a newer version exists, the app offers to download it, replace itself and relaunch.

## Build from source

Only the Xcode Command Line Tools (Swift 5.10+) are needed. Full Xcode is not required.

```
./build.sh
```

This produces `build/fstn view.app` and `build/fstn-view-<version>.zip`.

### Publishing a release

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, for example to `0.2.0`.
2. Run `./build.sh`.
3. Create a GitHub release tagged `v0.2.0` and attach `build/fstn-view-0.2.0.zip`:
   ```
   gh release create v0.2.0 build/fstn-view-0.2.0.zip --title "fstn view 0.2.0" --notes "What changed…"
   ```

The tag must be the version number with a `v` prefix, and the release must contain a `.zip` with the app. Installed copies use both to find and install the update.

## License

[MIT](LICENSE)
