# Agent Gateway app icon

`app-icon.png` is the master artwork generated with the built-in imagegen tool,
using the user's shield-and-check reference. A solid sky-blue shield and white
check represent privacy and protection on an opaque white background. Launcher
corner masks are applied by the operating system.

Regenerate the checked-in iOS and Android launcher sizes on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate-app-icons.ps1
```

The script uses the iOS asset manifest for exact sizes and exports opaque RGB
PNGs, including the 1024-pixel App Store icon and Android density variants.

## Generation prompt

undefined
