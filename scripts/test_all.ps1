# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Lemon4ksan

# scripts/test_all.ps1 - Test runner and verification script for goose-lit.
param(
    [switch]$CheckOnly
)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $env:GOOSE_CC -and (Get-Command gcc -ErrorAction SilentlyContinue)) {
    $env:GOOSE_CC = "gcc"
}

Write-Host "goose-lit verification runner" -ForegroundColor Cyan

# 1. Typecheck library, CLI, and test suite
Write-Host "`n[1/4] Typechecking lit.goose, bin.goose & tests..." -ForegroundColor Yellow
$swCheck = [System.Diagnostics.Stopwatch]::StartNew()

$litCheck = & goose check lit.goose 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: goose check lit.goose failed!" -ForegroundColor Red
    Write-Host ($litCheck -join "`n") -ForegroundColor Red
    exit 1
}

$binCheck = & goose check bin.goose 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: goose check bin.goose failed!" -ForegroundColor Red
    Write-Host ($binCheck -join "`n") -ForegroundColor Red
    exit 1
}

$testFiles = @(
    "tests/auto_runner_test.goose",
    "tests/bench_test.goose",
    "tests/config_test.goose",
    "tests/filecheck_test.goose",
    "tests/gate_test.goose",
    "tests/inspect_test.goose",
    "tests/pipeline_test.goose",
    "tests/standalone_unit_test.goose",
    "tests/testkit_test.goose",
    "tests/wire_test.goose"
)

foreach ($tf in $testFiles) {
    $tc = & goose check $tf 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FATAL: goose check $tf failed!" -ForegroundColor Red
        Write-Host ($tc -join "`n") -ForegroundColor Red
        exit 1
    }
}

$swCheck.Stop()
Write-Host "  OK: lit.goose, bin.goose & tests typechecked cleanly in $($swCheck.ElapsedMilliseconds)ms." -ForegroundColor Green

if ($CheckOnly) {
    Write-Host "`nTypecheck Complete: 100% Valid." -ForegroundColor Green
    exit 0
}

# 2. Build native goose-lit binary
Write-Host "`n[2/4] Building native bin/goose-lit.exe..." -ForegroundColor Yellow
$swBuild = [System.Diagnostics.Stopwatch]::StartNew()
$binDir = Join-Path $root "bin"
if (-not (Test-Path $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}

$buildOut = & goose build --cc gcc -O2 -o bin/goose-lit.exe bin.goose 2>&1
$swBuild.Stop()

if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: goose build failed!" -ForegroundColor Red
    Write-Host ($buildOut -join "`n") -ForegroundColor Red
    exit 1
}
Write-Host "  OK: Built bin/goose-lit.exe in $($swBuild.ElapsedMilliseconds)ms." -ForegroundColor Green

# 3. Run LIT test suite
Write-Host "`n[3/4] Running LIT test suite..." -ForegroundColor Yellow
$swLit = [System.Diagnostics.Stopwatch]::StartNew()
$litOut = & .\bin\goose-lit.exe tests 2>&1
$swLit.Stop()

if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: LIT suite failed!" -ForegroundColor Red
    Write-Host ($litOut -join "`n") -ForegroundColor Red
    exit 1
}
Write-Host ($litOut -join "`n") -ForegroundColor Green

# 4. Run G-CRAP risk analysis on pipeline test
Write-Host "`n[4/4] Verifying G-CRAP integration..." -ForegroundColor Yellow
$crapOut = & .\bin\goose-lit.exe crap tests/pipeline_test.goose 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FATAL: G-CRAP analysis failed!" -ForegroundColor Red
    Write-Host ($crapOut -join "`n") -ForegroundColor Red
    exit 1
}
Write-Host ($crapOut -join "`n") -ForegroundColor Cyan

Write-Host "`nAll goose-lit verification gates passed successfully." -ForegroundColor Green
exit 0
