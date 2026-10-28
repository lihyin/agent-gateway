# Agent Gateway app icon

`app-icon.png` is the master artwork generated with the built-in imagegen tool.
The simplified white shield represents privacy and protection on a sky-blue
background. The artwork is intentionally opaque and square;
launcher corner masks are applied by the operating system.

Regenerate the checked-in iOS and Android launcher sizes on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate-app-icons.ps1
```

The script uses the iOS asset manifest for exact sizes and exports opaque RGB
PNGs, including the 1024-pixel App Store icon and Android density variants.

## Current edit prompt

Edit the referenced Agent Gateway app icon. Replace the green background with a clean uniform sky blue (#55B9EE). Replace the arch/gateway symbol with a simplified white shield: one bold smooth shield outline, horizontally symmetric, gently rounded upper corners, broad straight upper edge, sides curving into one soft downward point, open sky-blue interior. Center it optically, occupying about 58% of the square width and 62% of its height. Minimal professional mobile app icon, flat graphic, crisp clean edges, generous safe margins, excellent legibility at 32px. No interior symbols, ticks, letters, locks, gradients, textures, shadows, borders or embellishments. Full-bleed opaque square blue background, no outer rounded corners; OS applies mask. Deliver one icon asset only, not a mockup.

## Original generation prompt

Use case: logo-brand. Create a polished production app icon for Agent Gateway, a device-owned privacy gateway connecting an AI assistant to Gmail with user consent. One single square icon asset, not a presentation or mockup. Full-bleed opaque deep forest green background (#245C4B family), subtle restrained tonal gradient. Center a bold, elegant ivory-white geometric gateway / open arch mark whose negative space subtly suggests a shield and secure passage. Distinctive, very simple, balanced, premium productivity app aesthetic. Broad smooth forms, crisp edges, readable at 32px. Symbol occupies central 62% of canvas, generous safe margins. No letters, words, tiny details, mail logos, Flutter marks, padlock illustrations, decorative sparkles, borders or outer rounded corners. Background fills the entire square; the OS will apply its own corner mask. Flat graphic with only very subtle depth; no glossy 3D, no scene. Square 1024x1024 master suitable for iOS and Android launcher icons.
