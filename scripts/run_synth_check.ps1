param(
    [string]$VivadoBat = $env:VIVADO_BAT
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $VivadoBat) {
    $vivadoCommand = Get-Command 'vivado.bat' -ErrorAction SilentlyContinue
    if ($vivadoCommand) {
        $VivadoBat = $vivadoCommand.Source
    }
}
if (-not $VivadoBat -or -not (Test-Path -LiteralPath $VivadoBat)) {
    throw 'Vivado executable not found. Pass -VivadoBat or set VIVADO_BAT.'
}

$previousProjectRoot = $env:SOBEL_PROJECT_ROOT
$shortProjectRoot = (& cmd.exe /d /s /c "for %I in (`"$projectRoot`") do @echo %~sI").Trim()
if (-not $shortProjectRoot) {
    throw 'Could not resolve a space-free Windows short path for the project.'
}
$vivadoTempDir = Join-Path $shortProjectRoot 'build\vivado_temp'
New-Item -ItemType Directory -Force -Path $vivadoTempDir | Out-Null
$reportDir = Join-Path $projectRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$consoleLog = Join-Path $reportDir 'synthesis_console_xc7z010.log'
$statusFile = Join-Path $reportDir 'synthesis_status_xc7z010.txt'
$env:SOBEL_PROJECT_ROOT = $shortProjectRoot
Push-Location $projectRoot
try {
    $vivadoOutput = @(& $VivadoBat -mode batch -nojournal -nolog -tempDir $vivadoTempDir -source '.\scripts\synth_check.tcl' 2>&1)
    $vivadoExitCode = $LASTEXITCODE
    $vivadoOutput | ForEach-Object { Write-Host $_ }
    $vivadoOutput | Set-Content -LiteralPath $consoleLog -Encoding utf8

    if ($vivadoExitCode -ne 0) {
        $combinedOutput = $vivadoOutput -join "`n"
        $designSynthesisPassed = $combinedOutput.Contains('Synthesis finished with 0 errors, 0 critical warnings and 0 warnings.')
        $knownCleanupOnly = $combinedOutput.Contains('error deleting') -and $combinedOutput.Contains('realtime/tmp')
        if ($designSynthesisPassed -and $knownCleanupOnly) {
            @(
                'DESIGN_SYNTHESIS=PASS',
                'TARGET=xc7z010clg400-1',
                'DESIGN_ERRORS=0',
                'DESIGN_WARNINGS=0',
                'TOOL_EXIT=TEMP_DIRECTORY_CLEANUP_WARNING',
                'CONSOLE_LOG=reports/synthesis_console_xc7z010.log'
            ) | Set-Content -LiteralPath $statusFile -Encoding ascii
            Write-Warning 'RTL synthesis completed with zero design errors; Vivado then hit its known temporary-directory cleanup problem.'
        } else {
            throw "Vivado synthesis check failed with exit code $vivadoExitCode"
        }
    } else {
        @(
            'DESIGN_SYNTHESIS=PASS',
            'TARGET=xc7z010clg400-1',
            'DESIGN_ERRORS=0',
            'TOOL_EXIT=PASS',
            'CONSOLE_LOG=reports/synthesis_console_xc7z010.log'
        ) | Set-Content -LiteralPath $statusFile -Encoding ascii
    }
} finally {
    Pop-Location
    $env:SOBEL_PROJECT_ROOT = $previousProjectRoot
}
