param(
    [string]$VivadoBin = $env:VIVADO_BIN,
    [string]$MatlabExe = $env:MATLAB_EXE,
    [string]$PythonExe = $env:PYTHON_EXE
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $projectRoot 'build\xsim'
$matlabPrefDir = Join-Path $projectRoot 'build\matlab_pref'
$resultsDir = Join-Path $projectRoot 'testdata\results'
$logsDir = Join-Path $buildDir 'logs'
$wavesDir = Join-Path $buildDir 'waves'

function Resolve-CommandPath {
    param(
        [string]$Configured,
        [string[]]$Candidates,
        [string]$Label
    )

    if ($Configured) {
        if (Test-Path -LiteralPath $Configured) {
            return (Resolve-Path -LiteralPath $Configured).Path
        }
        $configuredCommand = Get-Command $Configured -ErrorAction SilentlyContinue
        if ($configuredCommand) {
            return $configuredCommand.Source
        }
        throw "$Label executable not found: $Configured"
    }

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    throw "$Label executable not found. Pass its path explicitly or set the documented environment variable."
}

if (-not $VivadoBin) {
    $xvlogCommand = Get-Command 'xvlog.bat' -ErrorAction SilentlyContinue
    if ($xvlogCommand) {
        $VivadoBin = Split-Path -Parent $xvlogCommand.Source
    }
}
if (-not $VivadoBin -or -not (Test-Path -LiteralPath $VivadoBin)) {
    throw 'Vivado bin directory not found. Pass -VivadoBin or set VIVADO_BIN.'
}

$MatlabExe = Resolve-CommandPath $MatlabExe @('matlab.exe', 'matlab') 'MATLAB'
$PythonExe = Resolve-CommandPath $PythonExe @('python.exe', 'python', 'py.exe', 'py') 'Python'

$xvlog = Join-Path $VivadoBin 'xvlog.bat'
$xelab = Join-Path $VivadoBin 'xelab.bat'
$xsim = Join-Path $VivadoBin 'xsim.bat'

foreach ($requiredPath in @($MatlabExe, $PythonExe, $xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required executable not found: $requiredPath"
    }
}

foreach ($directory in @($buildDir, $matlabPrefDir, $resultsDir, $logsDir, $wavesDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

function Assert-LastExitCode([string]$stage) {
    if ($LASTEXITCODE -ne 0) {
        throw "$stage failed with exit code $LASTEXITCODE"
    }
}

Write-Host '[1/5] Generating deterministic inputs and MATLAB Golden Model...'
$matlabRoot = $projectRoot.Replace('\', '/')
$matlabScriptDir = (Join-Path $projectRoot 'matlab').Replace('\', '/')
$matlabCommand = "addpath('$matlabScriptDir'); generate_golden('$matlabRoot');"
$previousMatlabPrefDir = $env:MATLAB_PREFDIR
$env:MATLAB_PREFDIR = $matlabPrefDir
try {
    & $MatlabExe -nojvm -batch $matlabCommand
} finally {
    $env:MATLAB_PREFDIR = $previousMatlabPrefDir
}
Assert-LastExitCode 'MATLAB Golden Model generation'

Write-Host '[2/5] Compiling pure Verilog RTL and Testbench with Vivado 2020.1...'
Push-Location $buildDir
try {
    & $xvlog --nolog `
        (Join-Path $projectRoot 'rtl\sobel_operator.v') `
        (Join-Path $projectRoot 'rtl\sobel_stream_core.v') `
        (Join-Path $projectRoot 'tb\tb_sobel_image.v')
    Assert-LastExitCode 'xvlog compilation'

    & $xelab --nolog --debug typical tb_sobel_image -s sobel_tb_sim
    Assert-LastExitCode 'xelab elaboration'
} finally {
    Pop-Location
}

Write-Host '[3/5] Running all XSIM image cases...'
$manifest = Import-Csv -LiteralPath (Join-Path $projectRoot 'testdata\manifest.csv')
foreach ($testCase in $manifest) {
    $inputAbsolute = Join-Path $projectRoot $testCase.input_mem
    $outputAbsolute = Join-Path $projectRoot $testCase.rtl_mem
    # Vivado 2020.1 batch wrappers do not reliably preserve quoted absolute
    # paths or test-plusargs containing separators.  Stage each case under the
    # Testbench's fixed local filenames, then copy the result to its final name.
    $logPath = 'logs/' + $testCase.case_name + '.log'
    $wavePath = 'waves/' + $testCase.case_name + '.wdb'

    Write-Host ("  XSIM: {0}" -f $testCase.case_name)
    Push-Location $buildDir
    try {
        Copy-Item -LiteralPath $inputAbsolute -Destination (Join-Path $buildDir 'input.mem') -Force
        & $xsim sobel_tb_sim --runall --onerror quit `
            --log $logPath --wdb $wavePath
        Assert-LastExitCode "XSIM case $($testCase.case_name)"
        $stagedOutput = Join-Path $buildDir 'rtl_output.mem'
        if (-not (Test-Path -LiteralPath $stagedOutput)) {
            throw "XSIM case $($testCase.case_name) did not create rtl_output.mem"
        }
        Copy-Item -LiteralPath $stagedOutput -Destination $outputAbsolute -Force
    } finally {
        Pop-Location
    }
}

Write-Host '[4/5] Comparing every RTL pixel against the MATLAB Golden Model...'
& $PythonExe (Join-Path $projectRoot 'python\compare_results.py') --project-root $projectRoot
Assert-LastExitCode 'Python bit-exact comparison'

Write-Host '[5/5] Complete.'
Write-Host ("Reports  : {0}" -f (Join-Path $projectRoot 'reports'))
Write-Host ("Waveforms: {0}" -f $wavesDir)
