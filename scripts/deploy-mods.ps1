# ============================================================================
# deploy-mods.ps1
# ============================================================================
# PURPOSE: Deploy TooltipLib to Zomboid mods folder
#
# USAGE:
#   .\scripts\deploy-mods.ps1              # Deploy locally
#   .\scripts\deploy-mods.ps1 -Clean       # Remove deployed mod
#   .\scripts\deploy-mods.ps1 -Workshop    # Deploy to Workshop folder for Steam upload
# ============================================================================

param(
    [switch]$Clean,
    [switch]$Workshop,
    [string]$OutputDir
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$TargetRoot = "$env:USERPROFILE\Zomboid\mods"
$WorkshopRoot = "$env:USERPROFILE\Zomboid\Workshop"

$ModName = "TooltipLib"
$Source = $RepoRoot
$Target = "$TargetRoot\$ModName"

function Deploy-Mod {
    Write-Host "`n=== Deploying $ModName ===" -ForegroundColor Cyan

    if (-not (Test-Path $Source)) {
        Write-Host "ERROR: Source not found: $Source" -ForegroundColor Red
        return $false
    }

    if (Test-Path $Target) {
        Write-Host "Removing existing deployment..." -ForegroundColor Yellow
        Remove-Item -Path $Target -Recurse -Force
    }

    $commonDir = "$Target\common"
    $versionDir = "$Target\42.0"
    New-Item -Path $commonDir -ItemType Directory -Force | Out-Null
    New-Item -Path $versionDir -ItemType Directory -Force | Out-Null

    if (Test-Path "$Source\mod.info") {
        Copy-Item -Path "$Source\mod.info" -Destination $commonDir
        Write-Host "  Copied mod.info -> common/" -ForegroundColor Green
    }

    if (Test-Path "$Source\media") {
        Copy-Item -Path "$Source\media" -Destination $versionDir -Recurse
        Write-Host "  Copied media/ -> 42.0/" -ForegroundColor Green
    }

    $fileCount = (Get-ChildItem -Path $Target -Recurse -File).Count
    Write-Host "  Total files: $fileCount" -ForegroundColor Green

    Write-Host "Deployed $ModName to $Target" -ForegroundColor Green
    return $true
}

function Clean-Mod {
    if (Test-Path $Target) {
        Write-Host "Removing $ModName from $Target..." -ForegroundColor Yellow
        Remove-Item -Path $Target -Recurse -Force
        Write-Host "Removed $ModName" -ForegroundColor Green
    } else {
        Write-Host "$ModName not deployed" -ForegroundColor Gray
    }
}

function Deploy-Workshop {
    Write-Host "`n=== Deploying $ModName to Workshop ===" -ForegroundColor Cyan

    if (-not (Test-Path $Source)) {
        Write-Host "ERROR: Source not found: $Source" -ForegroundColor Red
        return $false
    }

    $workshopModRoot = "$WorkshopRoot\$ModName"
    $contentsModDir = "$workshopModRoot\Contents\mods\$ModName"
    $commonDir = "$contentsModDir\common"
    $versionDir = "$contentsModDir\42.0"

    if (Test-Path $workshopModRoot) {
        Write-Host "  Removing existing workshop deployment..." -ForegroundColor Yellow
        Remove-Item -Path $workshopModRoot -Recurse -Force
    }

    New-Item -Path $workshopModRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $contentsModDir -ItemType Directory -Force | Out-Null
    New-Item -Path $commonDir -ItemType Directory -Force | Out-Null
    New-Item -Path $versionDir -ItemType Directory -Force | Out-Null

    if (Test-Path "$Source\mod.info") {
        Copy-Item -Path "$Source\mod.info" -Destination $commonDir
        Write-Host "  Copied mod.info -> common/" -ForegroundColor Green
    }

    if (Test-Path "$Source\media") {
        Copy-Item -Path "$Source\media" -Destination $versionDir -Recurse
        Write-Host "  Copied media/ -> 42.0/" -ForegroundColor Green
    }

    $fileCount = (Get-ChildItem -Path $workshopModRoot -Recurse -File).Count
    Write-Host "  Total files: $fileCount" -ForegroundColor Green

    Write-Host "`nDeployed $ModName to Workshop folder" -ForegroundColor Green
    Write-Host "  Path: $workshopModRoot" -ForegroundColor Gray

    return $true
}

# Main execution
Write-Host "============================================" -ForegroundColor White
Write-Host "  TooltipLib Deployment Script" -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

$success = $true

if ($Workshop) {
    Write-Host "Mode: Workshop deployment" -ForegroundColor Gray
    Write-Host "Target: $WorkshopRoot" -ForegroundColor Gray
    $success = Deploy-Workshop
} elseif ($Clean) {
    Write-Host "Target: $TargetRoot" -ForegroundColor Gray
    Clean-Mod
} else {
    Write-Host "Target: $TargetRoot" -ForegroundColor Gray
    $success = Deploy-Mod
}

Write-Host "`n============================================" -ForegroundColor White
if ($success) {
    Write-Host "  Done!" -ForegroundColor Green
} else {
    Write-Host "  Deployment had errors!" -ForegroundColor Red
}
Write-Host "============================================" -ForegroundColor White
