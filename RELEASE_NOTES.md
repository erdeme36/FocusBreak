# FocusBreak v1.0.3

Free macOS menu-bar break reminder for developers and office workers.

## Fix

- Fixed the menu-bar eye icon popup countdown so it keeps updating while the macOS menu is open.
- Moved the app timer onto the common run-loop mode so menu tracking no longer freezes the displayed timer.
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
