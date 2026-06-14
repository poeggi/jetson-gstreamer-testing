param(
    [string]$Stream  = "main",        # main | sub | main-auth | sub-auth
    [string]$Jetson  = "192.168.1.252",
    [string]$Port    = "8554",
    [int]   $Caching = 200            # 200ms minimum confirmed for H.265; below this VLC drops frames
)

$paths = @{
    "main"      = "/main"
    "sub"       = "/sub"
    "main-auth" = "/main-auth"
    "sub-auth"  = "/sub-auth"
}
$creds = @{
    "main-auth" = "guest:guest@"
    "sub-auth"  = "guest:guest@"
}
if (-not $paths.ContainsKey($Stream)) {
    Write-Error "Unknown stream '$Stream'. Use 'main', 'sub', 'main-auth', or 'sub-auth'."
    exit 1
}

$cred = if ($creds.ContainsKey($Stream)) { $creds[$Stream] } else { "" }
$url = "rtsp://${cred}${Jetson}:${Port}$($paths[$Stream])"
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
