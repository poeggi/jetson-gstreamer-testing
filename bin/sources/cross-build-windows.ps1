# Build onvif_simple_server and wsd_simple_server for linux/arm64 (Jetson Orin NX).
#
# Requirements:
#   Docker Desktop for Windows (4.x+) with multi-arch support enabled (default).
#   Internet access to pull ubuntu:22.04 and clone poeggi/onvif_simple_server.
#
# First run is slow (5-15 min) -- Docker pulls Ubuntu arm64 image via QEMU emulation.
# Subsequent runs are fast (image and layer cache reused).
#
# Binaries are always statically linked -- the build fails if static linking is lost.
# Source is cloned from our fork (poeggi/onvif_simple_server) at the given branch.
#
# Usage (run from repo root):
#   .\bin\sources\cross-build-windows.ps1                              # builds feature/onvif-mac-uuid (default)
#   .\bin\sources\cross-build-windows.ps1 -Branch feature/dual-stack-wsd  # build a specific branch
#
# Output: bin/onvif_simple_server  and  bin/wsd_simple_server  (linux/arm64, statically linked)
# After building: git add bin/onvif_simple_server bin/wsd_simple_server && git commit

param(
    [string]$Branch = "feature/onvif-mac-uuid"
)

$ErrorActionPreference = "Stop"

$Root         = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$BinDir       = Join-Path $Root "bin"
$Dockerfile   = Join-Path $Root "bin" "sources" "Dockerfile"
$SafeBranch   = $Branch -replace "[^a-zA-Z0-9._-]", "-"
$ImageTag     = "jetson-onvif-build:$SafeBranch"

# Ensure bin/ exists
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

Write-Host ""
Write-Host "Building onvif_simple_server + wsd_simple_server"
Write-Host "  Platform : linux/arm64  (QEMU emulation)"
Write-Host "  Base     : ubuntu:22.04"
Write-Host "  Branch   : $Branch  (poeggi/onvif_simple_server)"
Write-Host "  Output   : $BinDir"
Write-Host ""

# Build context is the repo root so Dockerfile can COPY from bin/sources/.
docker build `
    --platform linux/arm64 `
    --build-arg "BRANCH=$Branch" `
    --file $Dockerfile `
    --tag $ImageTag `
    $Root

# Extract binaries from the image
$ctr = "onvif-extract-$(Get-Date -Format 'yyyyMMddHHmmss')"
docker create --name $ctr $ImageTag | Out-Null

try {
    docker cp "${ctr}:/src/onvif_simple_server" "$BinDir/onvif_simple_server"
    docker cp "${ctr}:/src/wsd_simple_server"   "$BinDir/wsd_simple_server"
}
finally {
    docker rm $ctr | Out-Null
}

Write-Host ""
Write-Host "Done."
$files = Get-Item "$BinDir/onvif_simple_server", "$BinDir/wsd_simple_server"
$files | Format-Table Name, @{L="Size(KB)"; E={[math]::Round($_.Length / 1KB)}}, LastWriteTime
Write-Host ""
Write-Host "Next steps:"
Write-Host "  git add bin/onvif_simple_server bin/wsd_simple_server"
Write-Host "  git commit -m `"Add onvif_simple_server and wsd_simple_server binaries for linux/arm64`""
