param(
    [string]$Source = "$PSScriptRoot/../mobile/assets/brand/app-icon.png"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$mobileRoot = [IO.Path]::GetFullPath("$PSScriptRoot/../mobile")
$original = [Drawing.Image]::FromFile([IO.Path]::GetFullPath($Source))

function Write-Icon([string]$Destination, [int]$Size) {
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $attributes = [Drawing.Imaging.ImageAttributes]::new()
    try {
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $graphics.DrawImage($original, [Drawing.Rectangle]::new(0, 0, $Size, $Size), 0, 0, $original.Width, $original.Height, [Drawing.GraphicsUnit]::Pixel, $attributes)
        $bitmap.Save($Destination, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $attributes.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $catalog = "$mobileRoot/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    $manifest = Get-Content -LiteralPath "$catalog/Contents.json" -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.images) {
        $points = [double]::Parse($entry.size.Split('x')[0], [Globalization.CultureInfo]::InvariantCulture)
        $scale = [double]::Parse($entry.scale.TrimEnd('x'), [Globalization.CultureInfo]::InvariantCulture)
        Write-Icon "$catalog/$($entry.filename)" ([int]($points * $scale))
    }
    $densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.Keys) {
        Write-Icon "$mobileRoot/android/app/src/main/res/mipmap-$density/ic_launcher.png" $densities[$density]
    }
    Write-Host 'Generated opaque iOS and Android app icons.'
} finally {
    $original.Dispose()
}
