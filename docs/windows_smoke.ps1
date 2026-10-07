param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,
    [Parameter(Mandatory = $true)]
    [string]$Store
)

$ErrorActionPreference = 'Stop'
$timeoutSeconds = if ($env:SMOKE_TIMEOUT_S) { [int]$env:SMOKE_TIMEOUT_S } else { 300 }

if (-not $Store.EndsWith('.db')) {
    throw "refusing store path '$Store': it must end in .db"
}
if (Test-Path -LiteralPath $Store) {
    $item = Get-Item -LiteralPath $Store -Force
    if (-not $item.PSIsContainer) {
        Remove-Item -LiteralPath $Store -Force
    } else {
        throw "refusing store path '$Store': it is a directory"
    }
}

$inputPath = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllLines($inputPath, @(
        'start LC quartermaster Erik Kalmar',
        'newco Alpha',
        'summary',
        'quit'
    ))

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = (Resolve-Path -LiteralPath $Executable).Path
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.ArgumentList.Add('--repl')
    $process.StartInfo.ArgumentList.Add('--store')
    $process.StartInfo.ArgumentList.Add($Store)
    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write([System.IO.File]::ReadAllText($inputPath))
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
        $process.Kill($true)
        throw "Windows smoke exceeded $timeoutSeconds seconds"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $output = $stdout + $stderr
    if ($process.ExitCode -ne 0) {
        throw "game.exe exited with status $($process.ExitCode):`n$output"
    }
    foreach ($landmark in @('done.', 'CAMPAIGN SUMMARY')) {
        if (-not $output.Contains($landmark)) {
            throw "Windows smoke missing '$landmark':`n$output"
        }
    }
    Write-Output 'WINDOWS SMOKE OK'
} finally {
    Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
}
