# Agent Gateway app icon

`app-icon.png` is the master artwork generated with the built-in imagegen tool.
The white gateway mark represents a user-controlled passage; the forest green
matches the app's interface. The artwork is intentionally opaque and square;
launcher corner masks are applied by the operating system.

Regenerate the checked-in iOS and Android launcher sizes on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate-app-icons.ps1
```

The script uses the iOS asset manifest for exact sizes and exports opaque RGB
PNGs, including the 1024-pixel App Store icon and Android density variants.

## Generation prompt

Use case: logo-brand. Create a polished production app icon for Agent Gateway, a device-owned privacy gateway connecting an AI assistant to Gmail with user consent. One single square icon asset, not a presentation or mockup. Full-bleed opaque deep forest green background (#245C4B family), subtle restrained tonal gradient. Center a bold, elegant ivory-white geometric gateway / open arch mark whose negative space subtly suggests a shield and secure passage. Distinctive, very simple, balanced, premium productivity app aesthetic. Broad smooth forms, crisp edges, readable at 32px. Symbol occupies central 62% of canvas, generous safe margins. No letters, words, tiny details, mail logos, Flutter marks, padlock illustrations, decorative sparkles, borders or outer rounded corners. Background fills the entire square; the OS will apply its own corner mask. Flat graphic with only very subtle depth; no glossy 3D, no scene. Square 1024x1024 master suitable for iOS and Android launcher icons.
