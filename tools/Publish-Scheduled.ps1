<#
.SYNOPSIS
  Unattended wrapper for the 05:50 Windows Task Scheduler job "Everwoven Playtest Publish".

.DESCRIPTION
  Owner-approved 2026-11-10. Runs tools\Publish-LatestBuild.ps1 -Mode Publish, which publishes the
  newest build that equals the pushed GitHub game code as a private prerelease on
  Gborohooo/everwoven-playtest, or does nothing when no build qualifies. All safety checks live in that
  script (pushed-main equality, packaging evidence, ZIP hash re-download, hub clean and in sync).

  This wrapper only adds a log file outside the repository and one retry for a transient git timeout.
  It never edits, stages or commits anything. It leaves data\publish-state.json modified and
  uncommitted after a release; the 06:00 Claude task commits it together with the page text.
  It reads the game repository (read-only git) and C:\Everwoven\builds, and never builds or launches Godot.

  Log: %LOCALAPPDATA%\EverwovenPlaytestHub\logs\publish-yyyyMMdd.log (files older than 30 days are removed).
  Exit code: the publish script's (0 = published or nothing to publish, 1 = stopped, 2 = pushed commit not local).
  Windows PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HubRoot = 'C:\Everwoven\.local\playtest-hub'
$Publish = Join-Path $HubRoot 'tools\Publish-LatestBuild.ps1'
$LogDir = Join-Path $env:LOCALAPPDATA 'EverwovenPlaytestHub\logs'
[void](New-Item -ItemType Directory -Path $LogDir -Force)
$LogFile = Join-Path $LogDir ('publish-' + (Get-Date -Format 'yyyyMMdd') + '.log')

function Write-Log {
    param([string]$Text)
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Text
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-PublishOnce {
    # Native stderr must not become a terminating error here; judge by exit code and output text.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Publish -Mode Publish 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

Write-Log 'Scheduled playtest publish starting.'

if (-not (Test-Path -LiteralPath $Publish)) {
    Write-Log "STOPPED: missing $Publish"
    exit 1
}

# Remove old logs, only inside the log folder.
Get-ChildItem -LiteralPath $LogDir -Filter 'publish-*.log' -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force

$result = Invoke-PublishOnce
Add-Content -LiteralPath $LogFile -Value $result.Text -Encoding UTF8
Write-Log ('Publish script exit code ' + $result.Code)

# One retry, only for a transient git timeout that happened before any draft release was created.
if ($result.Code -ne 0 -and $result.Text -match 'Timed out after' -and $result.Text -notmatch 'Creating draft') {
    Write-Log 'Transient timeout before any release was created; retrying once in 30 seconds.'
    Start-Sleep -Seconds 30
    $result = Invoke-PublishOnce
    Add-Content -LiteralPath $LogFile -Value $result.Text -Encoding UTF8
    Write-Log ('Retry exit code ' + $result.Code)
}

# Summarise from the script's final RESULT_JSON line (a plain text match on "published" would also hit
# the "Last published:" line of the table).
$summary = $null
foreach ($line in ($result.Text -split "`r?`n")) {
    if ($line.StartsWith('RESULT_JSON: ')) {
        try { $summary = ConvertFrom-Json $line.Substring(13) } catch { $summary = $null }
    }
}
if ($null -eq $summary) {
    Write-Log 'RESULT: no RESULT_JSON line found; see the output above.'
}
elseif ($summary.action -eq 'published') {
    Write-Log ('RESULT: RELEASE PUBLISHED ' + $summary.release_url)
}
elseif ($summary.action -eq 'none') {
    Write-Log 'RESULT: nothing to publish (no new qualifying build).'
}
else {
    $reason = ''
    if ($summary.PSObject.Properties.Name -contains 'reason') { $reason = [string]$summary.reason }
    Write-Log ('RESULT: ' + $summary.action + ' ' + $reason)
}

Write-Log 'Scheduled playtest publish finished.'
exit $result.Code
