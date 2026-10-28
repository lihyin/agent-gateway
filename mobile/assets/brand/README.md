# Agent Gateway app icon

`app-icon.svg` is the editable master: a solid sky-blue (`#55B9EE`) shield with
a white check on pure white (`#FFFFFF`). It follows the user's shield reference.
The shield has approximately 8% top and bottom margins.

The initial imagegen concept contained subtle texture and tonal variation. The
final artwork is redrawn as geometric vector paths with uniform colors and no
shadows, gradients, filters or transparency. `app-icon.png` is its 1024-pixel
rendered preview; it is not used as an intermediate source for smaller icons.

Regenerate all checked-in iOS and Android sizes on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate-app-icons.ps1
```

Each size is rendered directly from the SVG paths with edge antialiasing, avoiding
repeated bitmap resizing. All PNGs are opaque RGB, including the 1024-pixel App
Store icon and the native 180-pixel iPhone launcher icon. Operating systems apply
their own launcher masks and presentation effects.
