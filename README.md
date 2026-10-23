# fstn view

A fast, minimal image viewer for macOS, inspired by FastStone Image Viewer.
Opens JPEG, HEIC, PNG, WebP, AVIF, TIFF and camera RAW files (CR3, CR2, NEF, ARW, DNG, RAF and more)
almost instantly and shows an info panel with EXIF data and a histogram.

## Features

- **Fast opening.** A lower-resolution preview appears in about 35 ms and is replaced by the sharp image a moment later. Images are decoded straight to screen size, and for RAW files the embedded full-size JPEG preview is used.
- **Instant browsing.** Neighbouring images are preloaded, so the arrow keys switch photos without delay.
- **Info panel** (EXIF, camera, lens, exposure, GPS, RGB histogram). It slides in when you move the mouse to the right edge, and you can pin it with `I`.
- **Thumbnail strip.** It slides up when you move the mouse to the bottom edge; click a thumbnail to open that photo.
- **Info line** in the top-left corner: file name, dimensions, megapixels, file size, position in folder and zoom (like FastStone).
- **Zoom.** Click to toggle 100% at the clicked point. Press and hold to zoom only while the button is down, and drag to look around.
- **Compare photos zoomed in.** Hold the mouse button and switch photos with the wheel or arrow keys: each photo opens at the same zoom and the same spot, so you can compare focus or expression across a series. Release the button to fit again. After `Z` (100%), the arrow keys also keep the zoom until you click or press `0`.
- **Develop RAW on demand.** RAW files are shown from their embedded JPEG for speed. Press `A` to develop the current RAW file with the macOS RAW engine (about 0.5 s); 100% zoom then shows the developed image too. Press `A` again to go back. Some cameras (for example Sony ARW) embed only a small preview, so it looks softer full screen until you press `A`.
- **RAW+JPEG pairs as one photo.** When a folder has `IMG_0001.JPG` and `IMG_0001.CR3`, only the JPEG is shown and the counter counts photos, not files; the line says `[ JPEG+RAW ]`. Press `A` to develop the paired RAW, and `A` again to go back to the JPEG. `E`, `⌘C` and `⌘R` use the file on screen. Turn it off with *View → Group RAW+JPEG Pairs*.
- **Delete to Trash** with `Delete` / `Backspace`. The app asks for confirmation (with a *Don’t show again* option), and `⌘Z` restores the last deleted photo. RAW+JPEG pairs with the same name (`IMG_0001.CR3` + `IMG_0001.JPG`) are deleted and restored together.
- **Rotate** with `L` / `R` (on screen only, files are not changed).
- **Open in another app** (Lightroom, Photoshop, DxO…) with `E`; the app is chosen the first time. **Show in Finder** with `⌘R`.
- **Copy to clipboard.** `⌘C` copies the file itself (like Finder). `⌥⌘C` copies it as an image to paste into a messenger or document: JPEGs byte for byte, RAW files as the image on screen (embedded JPEG, or the developed RAW after `A`), including rotation.
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

On first launch the app offers to become the default app for photos. You choose regular photos (JPEG, HEIC, PNG…), RAW files (CR3, NEF, ARW, DNG…) or both.
You can change this later with **fstn view → Make Default for Photos…**.

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
| Show thumbnail strip | Move the mouse to the bottom edge |
| Show info panel | Move the mouse to the right edge |
| Pin / unpin info panel | `I` or `Tab` |
| Show / hide info line | `T` |
| Develop current RAW (or the RAW of a JPEG pair) / back | `A` |
| Move to Trash / restore | `Delete` or `Backspace` / `⌘Z` |
| Rotate left / right | `L` / `R` |
| Open in another app | `E` |
| Show in Finder | `⌘R` |
| Copy file / copy as image | `⌘C` / `⌥⌘C` |
| Leave or enter full screen | `F` or `Enter` |
| Quit | `Esc` |
| Open file or folder | `⌘O` |
| All actions in one menu | Right-click the photo |

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

Releases are built automatically by GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml)).

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, for example to `0.2.0`, and commit.
2. Tag the commit and push the tag:
   ```
   git tag -a v0.2.0 -m "fstn view 0.2.0"
   git push origin main v0.2.0
   ```

The workflow checks that the tag matches the app version, builds the app on macOS, and publishes a release with `fstn-view-0.2.0.zip` and auto-generated notes.
Installed copies find the new release and update themselves.

## License

[MIT](LICENSE)
