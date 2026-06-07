param(
    [string]$Stream  = "main",        # main | sub
    [string]$Host    = "192.168.1.252",
    [string]$Port    = "8554",
    [int]   $Caching = 200            # 200ms minimum confirmed for H.265; below this VLC drops frames
)

$paths = @{ main = "/main"; sub = "/sub" }
if (-not $paths.ContainsKey($Stream)) {
    Write-Error "Unknown stream '$Stream'. Use 'main' or 'sub'."
    exit 1
}

$url = "rtsp://${Host}:${Port}$($paths[$Stream])"
$vlc = "${env:ProgramFiles}\VideoLAN\VLC\vlc.exe"

if (-not (Test-Path $vlc)) {
    $vlc = "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe"
}
if (-not (Test-Path $vlc)) {
    Write-Error "VLC not found. Install from https://videolan.org/vlc/"
    exit 1
}

Write-Host "Connecting to $Stream stream: $url (caching=${Caching}ms)"
& $vlc --rtsp-tcp --network-caching=$Caching --clock-synchro=0 --no-audio $url
