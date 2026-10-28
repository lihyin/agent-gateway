# Agent Gateway app icon

`app-icon.png` is the master artwork generated with the built-in imagegen tool,
using the user's shield-and-check reference. A solid sky-blue shield and white
check represent privacy and protection on an opaque white background. Launcher
corner masks are applied by the operating system.

The shield is enlarged to approximately 84% of the canvas height, with balanced
8% top and bottom margins. This is the chosen visual spacing, not an iOS-mandated
padding requirement.

Regenerate the checked-in iOS and Android launcher sizes on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate-app-icons.ps1
```

The script uses the iOS asset manifest for exact sizes and exports opaque RGB
PNGs, including the 1024-pixel App Store icon and Android density variants.

## Latest sizing edit prompt

Edit only the size and placement of the existing blue shield with white check in this app icon. Enlarge the entire shield and its check mark together uniformly, preserving the exact shield shape, check shape, their relative proportions, sky-blue color and pure white background. The shield should occupy 84% of the full square canvas height, leaving exactly approximately 8% blank white padding above its top point and 8% below its bottom point. Keep it horizontally centered; width follows proportionally, roughly 70% of canvas width. The white check scales with the shield. Maintain a clean opaque square app-icon canvas and crisp edges. No new design elements, no added outline, no text, no gradient, no shadow, no outer rounded corners, no mockup. Only enlarge and center the current mark.

## Base generation prompt

Use case: logo-brand. Create the final Agent Gateway mobile app icon using the attached image as the shape reference. Pure opaque white full-bleed square background. Center one solid sky-blue (#55B9EE) shield with the same simple silhouette as the reference: centered shallow peaked top edge, straight upper sides, smoothly curved lower sides meeting in a downward point. Inside it place a bold pure white check mark matching the reference, clean straight strokes with square ends. Shield and check are a single simple flat graphic. Shield occupies about 64% of square width and 74% of height, centered optically, generous equal safe margins. Follow the reference closely; change its black fill to sky blue and provide a square app-icon canvas. Flat uniform fills, crisp edges. No outline, extra symbols, letters, text, gradient, shadow, texture, 3D, border, rounded outer corners or mockup. Output one production app icon only.
