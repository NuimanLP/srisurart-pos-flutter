# Fast local static check script: runs oxlint + tsc --noEmit
# Zero database/Docker required. Finishes in ~5 seconds.
$ErrorActionPreference = "Stop"

Write-Host "==> Running oxlint..." -ForegroundColor Cyan
& npx.cmd oxlint src/ test/
if ($LASTEXITCODE -ne 0) {
    Write-Host "Lint failed!" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "==> Running tsc --noEmit..." -ForegroundColor Cyan
& npx.cmd tsc --noEmit
if ($LASTEXITCODE -ne 0) {
    Write-Host "Typecheck failed!" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "All static checks passed successfully!" -ForegroundColor Green
