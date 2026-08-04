# FocusBreak v1.0.2

Free macOS menu-bar break reminder for developers and office workers.

## Fix

- Restored the intended default FocusBreak rhythm: 20-minute eye break interval, 20-second eye break, 60-minute focus interval, and 5-minute long break.
- Added a settings migration that resets the old fast test profile (`2/1/2/1`) back to production defaults.
- Normalized saved settings so out-of-range values cannot remain stuck after older test builds.
- Rebuilt release assets with ad-hoc app bundle signing.

## What's Included

- `FocusBreak.dmg` - recommended installer with drag-to-Applications layout.
- `FocusBreak-Installer.dmg` - same installer image with explicit installer filename.
- `FocusBreak.app.zip` - zipped unsigned app bundle for direct sharing.
- `AppIcon.png` - app icon for press, listings, or sharing.

## Highlights

- Menu bar eye icon with countdown menu.
- Main FocusBreak dashboard and settings window.
- 20-20-20 eye break reminders.
- 60/5 long break rhythm.
- Pomodoro mode.
- Gentle and insistent reminder styles.
- Full-screen long-break overlay.
- Pause, resume, skip, and snooze controls.
- Launch-at-login setting.
- Local-first app with no analytics or account requirement.

## Install

Open `FocusBreak.dmg`, then drag `FocusBreak.app` into `Applications`.

This build is ad-hoc signed but not Developer ID signed or notarized. macOS may require right click > Open on first launch.

If macOS says the app is "damaged", run:

```bash
xattr -dr com.apple.quarantine /Applications/FocusBreak.app
```

Then open it with right click > Open.

## Notes

FocusBreak is not a medical device and does not claim to prevent eye disease. It is a habit tool for reducing uninterrupted screen time.
