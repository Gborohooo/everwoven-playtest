<#
.SYNOPSIS
Selects and (optionally) publishes the newest Everwoven playtest build that equals the pushed GitHub game code.

.DESCRIPTION
Windows PowerShell 5.1 compatible. Never writes to the game repository. Never builds or launches the game.

-Mode Check (default): read-only. Queries the game's GitHub main branch (git ls-remote), reads
  builds\*\ evidence and committed game history, and prints which builds qualify and why not.
-Mode Publish: runs Check, then for the newest qualifying build creates a DRAFT private prerelease in
  Gborohooo/everwoven-playtest, uploads the ZIP and its SHA-256 file, downloads the ZIP back and compares
  its SHA-256, publishes the release, and records it in data\publish-state.json.
  It never deletes or overwrites a release or tag. On any failure it stops and leaves a draft in place.

A build qualifies only if ALL hold:
  1. Its base_commit is the current GitHub main commit (R) or an ancestor of R.
  2. No runtime file differs between base_commit and R, and the builder's recorded git status lists no
     runtime file. Non-runtime paths are docs/, tests/, tools/, patches/, root *.md, .gitignore,
     .editorconfig and .gitattributes. Everything else (src/, assets/, scenes/, content/,
     project.godot, export_presets.cfg, ...) is runtime.
  3. verification.json: export exit 0, empty stderr, extraction hashes matched.
  4. The recomputed ZIP SHA-256 equals verification.json and the .sha256.txt file.
  5. It is newer than, and descends from, the build in data\publish-state.json.

Not verified: file contents against Git (the builder's recorded status and commit ancestry are trusted),
ignored resource inputs, and any smoke launch or playtest. Output states this honestly.

Final line starting with RESULT_JSON: is machine readable. Exit 0 = completed (even when nothing
qualifies), 1 = stopped by an error, 2 = Check could not establish the remote head.
#>
param(
    [ValidateSet('Check', 'Publish')]
    [string]$Mode = 'Check',
    [switch]$VerifyGh,
    # Test hooks. Refused in Publish mode.
    [string]$GameRoot = 'C:\Everwoven',
    [string]$BuildsRoot = '',
    [string]$StatePath = '',
    [string]$RemoteHeadOverride = ''
)

$ErrorActionPreference = 'Stop'

$DefaultGameRoot = 'C:\Everwoven'
$HubRoot = Split-Path -Parent $PSScriptRoot
$DefaultHubRoot = 'C:\Everwoven\.local\playtest-hub'
if (-not $BuildsRoot) { $BuildsRoot = Join-Path $GameRoot 'builds' }
if (-not $StatePath) { $StatePath = Join-Path $HubRoot 'data\publish-state.json' }

$GameRemote = 'https://github.com/Gborohooo/everwoven.git'
$HubRepo = 'Gborohooo/everwoven-playtest'
$GhExe = 'C:\Everwoven\.local\github-cli-20261104-104015-6cdbe727\portable\bin\gh.exe'
$GhExpectedHash = 'D303D8AC3F5E9438BF7C977B64DD6425513EAE46218F8881D30694F28C1D0DFD'
$GhConfigDir = 'C:\Everwoven\.local\github-cli-config'
$BuildPattern = '^Everwoven-Windows-Playtest-(\d{8})_(\d{6})_\d{3}-([0-9a-f]{12})-local$'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-ArgString {
    param([string[]]$Items)
    $Parts = foreach ($Item in $Items) {
        if ($Item -eq '') { '""' }
        elseif ($Item -match '[\s"]') {
            $Escaped = $Item -replace '(\\*)"', '$1$1\"'
            $Escaped = $Escaped -replace '(\\+)$', '$1$1'
            '"' + $Escaped + '"'
        }
        else { $Item }
    }
    return ($Parts -join ' ')
}

function Invoke-Native {
    param(
        [string]$File,
        [string[]]$Arguments,
        [string]$Directory,
        [hashtable]$Environment = @{},
        [int]$TimeoutMs = 120000
    )
    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName = $File
    $Info.Arguments = ConvertTo-ArgString $Arguments
    $Info.WorkingDirectory = $Directory
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $Info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($Key in $Environment.Keys) { $Info.EnvironmentVariables[$Key] = [string]$Environment[$Key] }
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Info
    try {
        [void]$Process.Start()
        $Out = $Process.StandardOutput.ReadToEndAsync()
        $Err = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit($TimeoutMs)) {
            try { $Process.Kill() } catch {}
            throw "Timed out after $TimeoutMs ms: $(Split-Path -Leaf $File) $($Arguments -join ' ')"
        }
        $Process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $Process.ExitCode
            Out      = $Out.Result
            Err      = $Err.Result
        }
    }
    finally { $Process.Dispose() }
}

$GitExe = (Get-Command git.exe -ErrorAction Stop).Source
$GitEnv = @{ GIT_OPTIONAL_LOCKS = '0'; GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'never' }

function Invoke-Git {
    param([string]$Directory, [string[]]$GitArgs, [int[]]$Ok = @(0), [int]$TimeoutMs = 120000)
    $All = @('-c', 'core.quotepath=false') + $GitArgs
    $Result = Invoke-Native $GitExe $All $Directory $GitEnv $TimeoutMs
    if ($Ok -notcontains $Result.ExitCode) {
        throw "git $($GitArgs -join ' ') failed (exit $($Result.ExitCode)) in ${Directory}: $($Result.Err.Trim())"
    }
    return $Result
}

function Test-NonRuntimePath {
    param([string]$Path)
    $P = ($Path.Trim().Trim('"') -replace '\\', '/')
    if ($P -match '^(docs|tests|tools|patches)/') { return $true }
    if ($P -match '^[^/]+\.md$') { return $true }
    if (@('.gitignore', '.editorconfig', '.gitattributes') -contains $P) { return $true }
    return $false
}

function Get-RemoteHead {
    if ($RemoteHeadOverride) {
        if ($RemoteHeadOverride -notmatch '^[0-9a-f]{40}$') { throw 'RemoteHeadOverride is not a full SHA.' }
        return $RemoteHeadOverride
    }
    $Result = Invoke-Git $HubRoot @('ls-remote', $GameRemote, 'refs/heads/main') @(0) 60000
    $Line = ($Result.Out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $Line -or $Line -notmatch '^([0-9a-f]{40})\s+refs/heads/main\s*$') {
        throw 'Could not read the game main branch from GitHub.'
    }
    return $Matches[1]
}

function Read-JsonFile {
    param([string]$Path)
    $Text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return (ConvertFrom-Json -InputObject $Text)
}

function ConvertTo-IsoUtc {
    # Windows PowerShell 5.1 keeps JSON dates as strings; PowerShell 7 converts them to DateTime.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return [string]$Value
}

function Get-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    return (Read-JsonFile $StatePath)
}

function Test-Build {
    param([System.IO.DirectoryInfo]$Dir, [string]$Remote, $State)

    $Id = $Dir.Name
    $Reasons = New-Object System.Collections.Generic.List[string]
    $Row = [ordered]@{
        Id = $Id; Base = ''; BaseShort = ''; CreatedUtc = ''; Qualifies = $false
        ZipPath = ''; ZipName = ''; ShaPath = ''; ZipSha256 = ''; ExeSha256 = ''
        SmokeRequested = $null; Reasons = $Reasons
    }

    if ($Id -notmatch $BuildPattern) { $Reasons.Add('folder name is not a build identifier'); return [pscustomobject]$Row }
    $NameSha = $Matches[3]

    $Zip = Join-Path $Dir.FullName ($Id + '.zip')
    $Sha = Join-Path $Dir.FullName ($Id + '.zip.sha256.txt')
    $Ver = Join-Path $Dir.FullName 'verification.json'
    $Bj = Join-Path (Join-Path $Dir.FullName $Id) 'BUILD.json'
    foreach ($Need in @($Zip, $Sha, $Ver, $Bj)) {
        if (-not (Test-Path -LiteralPath $Need)) { $Reasons.Add('missing ' + (Split-Path -Leaf $Need)) }
    }
    if ($Reasons.Count -gt 0) { return [pscustomobject]$Row }

    try { $Build = Read-JsonFile $Bj; $Verify = Read-JsonFile $Ver }
    catch { $Reasons.Add('evidence JSON unreadable'); return [pscustomobject]$Row }

    $Row.Base = [string]$Build.base_commit
    $Row.CreatedUtc = ConvertTo-IsoUtc $Build.created_utc
    if ($Row.Base -notmatch '^[0-9a-f]{40}$') { $Reasons.Add('BUILD.json base_commit is not a full SHA'); return [pscustomobject]$Row }
    $Row.BaseShort = $Row.Base.Substring(0, 7)
    if ([string]$Build.build_id -ne $Id) { $Reasons.Add('BUILD.json build_id does not match folder') }
    if ($Row.Base.Substring(0, 12) -ne $NameSha) { $Reasons.Add('folder commit does not match base_commit') }

    $Row.ZipPath = $Zip
    $Row.ZipName = $Id + '.zip'
    $Row.ShaPath = $Sha
    $Row.ZipSha256 = ([string]$Verify.zip_sha256).ToUpperInvariant()
    $Row.SmokeRequested = $Verify.smoke_test_requested
    $ExeEntry = @($Build.files | Where-Object { $_.path -eq 'Everwoven.exe' }) | Select-Object -First 1
    if ($ExeEntry) { $Row.ExeSha256 = ([string]$ExeEntry.sha256).ToUpperInvariant() }

    if ([string]$Verify.build_id -ne $Id) { $Reasons.Add('verification.json build_id does not match folder') }
    if ($Verify.export.exit_code -ne 0) { $Reasons.Add('export exit code is not 0') }
    if ($Verify.export.stderr_nonempty -ne $false) { $Reasons.Add('export stderr was not empty') }
    if ($Verify.zip_extraction_hashes_matched -ne $true) { $Reasons.Add('extraction hashes did not match') }
    if ($ExeEntry -and ([string]$Verify.exe_sha256).ToUpperInvariant() -ne $Row.ExeSha256) {
        $Reasons.Add('executable hash differs between BUILD.json and verification.json')
    }

    if ($State -and $State.last_published) {
        $Last = $State.last_published
        $Cmp = [string]::CompareOrdinal($Id, [string]$Last.build_id)
        if ($Cmp -eq 0) { $Reasons.Add('already published') }
        elseif ($Cmp -lt 0) { $Reasons.Add('older than the last published build') }
    }

    $BaseKnown = (Invoke-Git $GameRoot @('cat-file', '-e', ($Row.Base + '^{commit}')) @(0, 1, 128)).ExitCode -eq 0
    if (-not $BaseKnown) {
        $Reasons.Add('base commit is not in the local game repository')
    }
    else {
        $Ancestor = (Invoke-Git $GameRoot @('merge-base', '--is-ancestor', $Row.Base, $Remote) @(0, 1)).ExitCode
        if ($Ancestor -ne 0) {
            $Reasons.Add('base commit is not part of the pushed GitHub main (unpushed work)')
        }
        else {
            $Names = (Invoke-Git $GameRoot @('diff', '--name-only', '--no-renames', $Row.Base, $Remote)).Out -split "`n"
            $RuntimeDiff = @($Names | Where-Object { $_.Trim() -and -not (Test-NonRuntimePath $_) })
            if ($RuntimeDiff.Count -gt 0) {
                $Reasons.Add("pushed main changed $($RuntimeDiff.Count) runtime file(s) after this build, e.g. $($RuntimeDiff[0])")
            }
        }

        if ($State -and $State.last_published) {
            $LastBase = [string]$State.last_published.base_commit
            $LastKnown = (Invoke-Git $GameRoot @('cat-file', '-e', ($LastBase + '^{commit}')) @(0, 1, 128)).ExitCode -eq 0
            if (-not $LastKnown) { $Reasons.Add('last published commit is not in the local game repository') }
            elseif ((Invoke-Git $GameRoot @('merge-base', '--is-ancestor', $LastBase, $Row.Base) @(0, 1)).ExitCode -ne 0) {
                $Reasons.Add('does not descend from the last published build')
            }
        }
    }

    $DirtyRuntime = @()
    foreach ($Line in (([string]$Build.git_status) -split "`n")) {
        if (-not $Line.Trim()) { continue }
        if ($Line.Length -lt 4) { $DirtyRuntime += $Line; continue }
        $Path = $Line.Substring(3)
        if ($Path -match ' -> ') { $Path = ($Path -split ' -> ')[-1] }
        if (-not (Test-NonRuntimePath $Path)) { $DirtyRuntime += $Path.Trim() }
    }
    if ($DirtyRuntime.Count -gt 0) {
        $Reasons.Add("built with $($DirtyRuntime.Count) uncommitted runtime change(s), e.g. $($DirtyRuntime[0])")
    }

    if ($Reasons.Count -eq 0) {
        $Actual = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToUpperInvariant()
        $FileHash = ([IO.File]::ReadAllText($Sha).Trim() -split '\s+')[0].ToUpperInvariant()
        if ($Actual -ne $Row.ZipSha256) { $Reasons.Add('ZIP hash differs from verification.json') }
        if ($Actual -ne $FileHash) { $Reasons.Add('ZIP hash differs from its .sha256.txt file') }
        $Row.ZipSha256 = $Actual
    }

    $Row.Qualifies = ($Reasons.Count -eq 0)
    return [pscustomobject]$Row
}

function Invoke-Gh {
    param([string[]]$GhArgs, [int[]]$Ok = @(0), [int]$TimeoutMs = 120000)
    $Result = Invoke-Native $GhExe $GhArgs $HubRoot @{
        GH_CONFIG_DIR = $GhConfigDir; GH_PROMPT_DISABLED = '1'; GH_NO_UPDATE_NOTIFIER = '1'
    } $TimeoutMs
    if ($Ok -notcontains $Result.ExitCode) {
        throw "gh $($GhArgs -join ' ') failed (exit $($Result.ExitCode)): $($Result.Err.Trim())"
    }
    return $Result
}

function Assert-GhIdentity {
    if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) { throw 'Token environment variable detected. Do not share its value.' }
    if ((Get-FileHash -LiteralPath $GhExe -Algorithm SHA256).Hash -ne $GhExpectedHash) { throw 'GitHub CLI identity changed.' }
    $Account = (Invoke-Gh @('api', '--method', 'GET', 'user', '--jq', '.login')).Out.Trim()
    if ($Account -ne 'Gborohooo') { throw 'Unexpected GitHub account.' }
}

function Write-Result {
    param([hashtable]$Data)
    Write-Output ('RESULT_JSON: ' + (ConvertTo-Json -InputObject $Data -Depth 6 -Compress))
}

function ConvertTo-Lf {
    param([string]$Text)
    return ($Text -replace "`r`n", "`n")
}

$TempDir = $null
try {
    if ($Mode -eq 'Publish') {
        if ($RemoteHeadOverride -or $GameRoot -ne $DefaultGameRoot -or $HubRoot -ne $DefaultHubRoot) {
            throw 'Publish mode refuses test overrides and non-default roots.'
        }
    }

    $Remote = Get-RemoteHead
    $RemoteKnown = (Invoke-Git $GameRoot @('cat-file', '-e', ($Remote + '^{commit}')) @(0, 1, 128)).ExitCode -eq 0
    if (-not $RemoteKnown) {
        Write-Output "STOPPED: GitHub main ($Remote) is not in the local game repository. The pushed commit has to be present locally; this tool never fetches into the game repository."
        Write-Result @{ action = 'stopped'; reason = 'remote head not present locally'; remote_head = $Remote }
        exit 2
    }

    $State = Get-State
    Write-Output "EVERWOVEN PLAYTEST PUBLISH CHECK | Mode $Mode"
    Write-Output "GitHub game main (R): $Remote"
    if ($State -and $State.last_published) {
        Write-Output "Last published: $($State.last_published.build_id) (commit $(([string]$State.last_published.base_commit).Substring(0, 7)))"
    }
    else { Write-Output 'Last published: none recorded' }

    $Dirs = @()
    if (Test-Path -LiteralPath $BuildsRoot) {
        $Dirs = @(Get-ChildItem -LiteralPath $BuildsRoot -Directory -Filter 'Everwoven-Windows-Playtest-*' |
                Sort-Object Name -Descending)
    }
    Write-Output "Builds found: $($Dirs.Count)"
    Write-Output ''

    $Rows = @()
    foreach ($Dir in $Dirs) { $Rows += Test-Build $Dir $Remote $State }

    foreach ($Row in $Rows) {
        if ($Row.Qualifies) { Write-Output "[QUALIFIES] $($Row.Id) (commit $($Row.BaseShort))" }
        else { Write-Output "[rejected]  $($Row.Id) (commit $($Row.BaseShort)): $($Row.Reasons -join '; ')" }
    }
    Write-Output ''

    $Qualifying = @($Rows | Where-Object { $_.Qualifies })
    $Selected = $Qualifying | Select-Object -First 1

    if ($VerifyGh -or ($Mode -eq 'Publish' -and $Selected)) {
        Assert-GhIdentity
        Write-Output 'GitHub CLI identity and account verified (Gborohooo).'
        if ($State -and $State.last_published -and $State.last_published.release_tag) {
            $Probe = Invoke-Gh @('release', 'view', [string]$State.last_published.release_tag, '--repo', $HubRepo,
                '--json', 'tagName,isDraft,isPrerelease,url,assets')
            $Release = ConvertFrom-Json -InputObject $Probe.Out
            Write-Output "Last release readable: $($Release.url) draft=$($Release.isDraft) prerelease=$($Release.isPrerelease) assets=$(@($Release.assets).Count)"
        }
    }

    if (-not $Selected) {
        Write-Output 'NOTHING TO PUBLISH: no build equals the pushed GitHub game code and is newer than the last published build.'
        if ($Rows.Count -gt 0) {
            Write-Output 'To get one: finish and push the feature, then build once on the clean tree (tools\Build-WindowsPlaytest.ps1 -AllowDirty).'
        }
        Write-Output 'Check does not compare file contents against Git and does not claim any smoke launch or playtest.'
        Write-Output 'No GitHub or Git changes made.'
        Write-Result @{ action = 'none'; mode = $Mode; remote_head = $Remote; builds_checked = $Rows.Count; qualifying = 0 }
        exit 0
    }

    Write-Output "SELECTED: $($Selected.Id) (commit $($Selected.BaseShort), pushed main is $($Remote.Substring(0, 7)))"

    if ($Mode -eq 'Check') {
        Write-Output 'Check only. No GitHub or Git changes made.'
        Write-Result @{
            action = 'would_publish'; mode = 'Check'; remote_head = $Remote; selected = $Selected.Id
            base_commit = $Selected.Base; zip_sha256 = $Selected.ZipSha256
        }
        exit 0
    }

    # ---- Publish ----
    if ($Selected.Id -notmatch $BuildPattern) { throw 'Selected build identifier is malformed.' }
    $Tag = 'playtest-' + $Matches[1] + '-' + $Matches[2] + '-' + $Matches[3]

    $HubBranch = (Invoke-Git $HubRoot @('branch', '--show-current')).Out.Trim()
    $HubHead = (Invoke-Git $HubRoot @('rev-parse', 'HEAD')).Out.Trim()
    $HubStatus = (Invoke-Git $HubRoot @('status', '--porcelain=v1', '--untracked-files=all')).Out.Trim()
    $HubRemote = ((Invoke-Git $HubRoot @('ls-remote', 'origin', 'refs/heads/main') @(0) 60000).Out -split '\s+')[0]
    if ($HubBranch -ne 'main') { throw "Hub checkout is on '$HubBranch', not main." }
    if ($HubStatus) { throw "Hub checkout is not clean:`n$HubStatus" }
    if ($HubHead -ne $HubRemote) { throw "Hub HEAD $HubHead differs from GitHub main $HubRemote." }

    $Listed = ConvertFrom-Json -InputObject (Invoke-Gh @('release', 'list', '--repo', $HubRepo,
            '--limit', '100', '--json', 'tagName,isDraft')).Out
    if (@($Listed | Where-Object { $_.tagName -eq $Tag }).Count -gt 0) {
        throw "Release $Tag already exists (possibly a draft). Not overwriting; owner action needed."
    }

    $TempDir = Join-Path ([IO.Path]::GetTempPath()) ('ew-publish-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $TempDir)

    $SmokeText = 'not requested'
    if ($Selected.SmokeRequested -eq $true) { $SmokeText = 'requested (see the build evidence)' }
    $Notes = @(
        'Everwoven private Windows playtest.',
        '',
        "Build: $($Selected.Id)",
        "Game commit: $($Selected.Base)",
        "Pushed GitHub main when published: $Remote",
        "Built (UTC): $($Selected.CreatedUtc)",
        "ZIP SHA256: $($Selected.ZipSha256)",
        "Executable SHA256: $($Selected.ExeSha256)",
        '',
        'This build has no uncommitted runtime changes: every runtime file equals the pushed GitHub code.',
        'Only documentation, tests or tools may differ.',
        'Builder checks recorded: export exit 0, empty stderr, ZIP extraction hashes matched.',
        'The uploaded ZIP was downloaded again and its SHA256 matched before this release was published.',
        "Smoke launch by the builder: $SmokeText.",
        'An owner playtest of this exact ZIP is not recorded by this publication.',
        'Second-computer compatibility is not established.',
        '',
        'Use a new disposable world. Release data uses %APPDATA%\Everwoven; this ZIP is not a save backup.',
        'Report the build ID with every bug or idea.'
    ) -join "`n"
    $NotesPath = Join-Path $TempDir 'notes.md'
    [IO.File]::WriteAllText($NotesPath, $Notes + "`n", $Utf8NoBom)

    Write-Output "Creating draft prerelease $Tag ..."
    [void](Invoke-Gh @('release', 'create', $Tag, $Selected.ZipPath, $Selected.ShaPath, '--repo', $HubRepo,
            '--draft', '--prerelease', '--target', $HubHead, '--title', $Selected.Id, '--notes-file', $NotesPath) @(0) 900000)

    $Draft = ConvertFrom-Json -InputObject (Invoke-Gh @('release', 'view', $Tag, '--repo', $HubRepo,
            '--json', 'tagName,isDraft,isPrerelease,url,assets')).Out
    $ZipAsset = @($Draft.assets | Where-Object { $_.name -eq $Selected.ZipName }) | Select-Object -First 1
    if (-not $ZipAsset) { throw 'Draft release has no ZIP asset.' }
    if ([int64]$ZipAsset.size -ne (Get-Item -LiteralPath $Selected.ZipPath).Length) { throw 'Uploaded ZIP size differs from the local ZIP.' }
    if (@($Draft.assets).Count -ne 2) { throw "Draft release has $(@($Draft.assets).Count) assets, expected 2." }

    Write-Output 'Downloading the uploaded ZIP to compare its SHA256 ...'
    $Down = Join-Path $TempDir 'download'
    [void](New-Item -ItemType Directory -Path $Down)
    [void](Invoke-Gh @('release', 'download', $Tag, '--repo', $HubRepo, '--pattern', $Selected.ZipName, '--dir', $Down) @(0) 900000)
    $DownHash = (Get-FileHash -LiteralPath (Join-Path $Down $Selected.ZipName) -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($DownHash -ne $Selected.ZipSha256) { throw "Downloaded ZIP SHA256 $DownHash does not match $($Selected.ZipSha256). Draft left in place." }

    Write-Output 'Hash matched. Publishing the release ...'
    [void](Invoke-Gh @('release', 'edit', $Tag, '--repo', $HubRepo, '--draft=false'))
    $Live = ConvertFrom-Json -InputObject (Invoke-Gh @('release', 'view', $Tag, '--repo', $HubRepo,
            '--json', 'tagName,isDraft,isPrerelease,url,assets')).Out
    if ($Live.isDraft -ne $false -or $Live.isPrerelease -ne $true) {
        throw "Release state unexpected after publishing: draft=$($Live.isDraft) prerelease=$($Live.isPrerelease)"
    }

    $DownloadUrl = "https://github.com/$HubRepo/releases/download/$Tag/$($Selected.ZipName)"
    $StateOut = [ordered]@{
        schema         = 1
        last_published = [ordered]@{
            build_id      = $Selected.Id
            base_commit   = $Selected.Base
            zip_sha256    = $Selected.ZipSha256
            exe_sha256    = $Selected.ExeSha256
            release_tag   = $Tag
            release_url   = [string]$Live.url
            download_url  = $DownloadUrl
            built_utc     = $Selected.CreatedUtc
            published_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            game_main_at_publish = $Remote
        }
    }
    $StateDir = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir) }
    [IO.File]::WriteAllText($StatePath, (ConvertTo-Lf (ConvertTo-Json -InputObject $StateOut -Depth 6)) + "`n", $Utf8NoBom)

    Write-Output "PUBLISHED: $($Live.url)"
    Write-Output 'State recorded in data\publish-state.json (not committed). Update public\index.html next.'
    Write-Result @{
        action = 'published'; mode = 'Publish'; build_id = $Selected.Id; base_commit = $Selected.Base
        remote_head = $Remote; release_tag = $Tag; release_url = [string]$Live.url; download_url = $DownloadUrl
        zip_name = $Selected.ZipName; zip_sha256 = $Selected.ZipSha256; exe_sha256 = $Selected.ExeSha256
        built_utc = $Selected.CreatedUtc; smoke_requested = $Selected.SmokeRequested; state_written = $true
    }
    exit 0
}
catch {
    Write-Output ('STOPPED: ' + $_.Exception.Message)
    Write-Output 'Nothing further was changed by this tool. Any draft release it created was left in place.'
    Write-Result @{ action = 'stopped'; mode = $Mode; reason = $_.Exception.Message }
    exit 1
}
finally {
    if ($TempDir -and (Test-Path -LiteralPath $TempDir)) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
