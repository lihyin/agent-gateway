param(
    [string]$Source = "$PSScriptRoot/../mobile/assets/brand/app-icon.svg"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$mobileRoot = [IO.Path]::GetFullPath("$PSScriptRoot/../mobile")
[xml]$artwork = Get-Content -LiteralPath $Source -Raw
$culture = [Globalization.CultureInfo]::InvariantCulture

# Render the source's absolute M/L/C/Z paths at each native pixel size.
# There is no intermediate bitmap, resampling, gradient, shadow or texture.
function New-IconPath([string]$Data) {
    $tokens = [regex]::Matches($Data, '[MLCZ]|-?\d+(?:\.\d+)?')
    $path = [Drawing.Drawing2D.GraphicsPath]::new()
    $index = 0
    $x = $y = [single]0
    while ($index -lt $tokens.Count) {
        $command = $tokens[$index++].Value
        if ($command -eq 'Z') {
            $path.CloseFigure()
            continue
        }
        $count = if ($command -eq 'C') { 6 } else { 2 }
        $values = @()
        for ($n = 0; $n -lt $count; $n++) {
            $values += [single]::Parse($tokens[$index++].Value, $culture)
        }
        switch ($command) {
            'M' { $path.StartFigure() }
            'L' { $path.AddLine($x, $y, $values[0], $values[1]) }
            'C' { $path.AddBezier($x, $y, $values[0], $values[1], $values[2], $values[3], $values[4], $values[5]) }
            default { throw "Unsupported SVG path command: $command" }
        }
        $x = $values[-2]
        $y = $values[-1]
    }
    return ,$path
}

function Write-Icon([string]$Destination, [int]$Size) {
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.ScaleTransform([single]($Size / 1024), [single]($Size / 1024))
        foreach ($element in $artwork.SelectNodes('//*[local-name()="path"]')) {
            $path = New-IconPath $element.d
            $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($element.fill))
            try {
                $graphics.FillPath($brush, $path)
            } finally {
                $brush.Dispose()
                $path.Dispose()
            }
        }
        $bitmap.Save($Destination, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

Write-Icon "$mobileRoot/assets/brand/app-icon.png" 1024
$catalog = "$mobileRoot/ios/Runner/Assets.xcassets/AppIcon.appiconset"
$manifest = Get-Content -LiteralPath "$catalog/Contents.json" -Raw | ConvertFrom-Json
foreach ($entry in $manifest.images) {
    $points = [double]::Parse($entry.size.Split('x')[0], $culture)
    $scale = [double]::Parse($entry.scale.TrimEnd('x'), $culture)
    Write-Icon "$catalog/$($entry.filename)" ([int]($points * $scale))
}
$densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
foreach ($density in $densities.Keys) {
    Write-Icon "$mobileRoot/android/app/src/main/res/mipmap-$density/ic_launcher.png" $densities[$density]
}
Write-Host 'Rendered opaque iOS and Android icons directly from the SVG source.'
