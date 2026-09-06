<#
.SYNOPSIS
  Fully autonomous iOS TestFlight build & upload pipeline for the NOOP project.
  Syncs upstream, builds the iOS app, exports the IPA, and uploads to TestFlight —
  zero human interaction required.

.DESCRIPTION
  Pipeline stages:
    0. Sync upstream (merge latest from ryanbr/noop, apply evoveo identifiers,
       resolve case-collisions using upstream-preferred casing)
    1. Auto-bump build number (CURRENT_PROJECT_VERSION) and commit
    2. Pre-flight checks (tools, signing identity, keychain credentials)
    3. Generate Xcode project (xcodegen)
    4. Resolve Swift package dependencies
    5. Archive the iOS app (xcodebuild archive, automatic signing)
    6. Export IPA (xcodebuild -exportArchive, app-store-connect method)
    7. Validate IPA (xcrun altool --validate-app)
    8. Upload to TestFlight (xcrun altool --upload-app)
    9. Push version bump to origin

  Credentials (Apple ID + app-specific password) are auto-discovered from the
  macOS keychain — no environment variables or command-line arguments needed.
  The keychain entry is created once with:
    security add-generic-password -s 'NOOP-TestFlight-Upload' -a 'Evoveo.tech@gmail.com' -w 'your-app-specific-password'

  Each build/archive/export/upload stage wraps execution in an agentic error-
  resolution loop: capture output, classify against a known-error catalog,
  apply the matching auto-fix, retry (up to MaxRetries).

.NOTES
  Requires: Xcode 26+, xcodegen, pwsh, and a valid Apple Developer signing
  identity in the keychain (Xcode auto-creates the distribution cert on first
  archive with -allowProvisioningUpdates).
#>

[CmdletBinding()]
param(
    [string]$Scheme = "NOOPiOS",
    [string]$Configuration = "Release",
    [string]$ProjectDir = (Get-Location).Path,
    [string]$ArchivePath = "build/NOOPiOS.xcarchive",
    [string]$ExportPath = "build/export",
    [int]$MaxRetries = 3,
    [switch]$SkipSync,        # Skip the upstream sync stage
    [switch]$SkipUpload,      # Build + export only, don't upload to TestFlight
    [switch]$SkipPush,        # Don't push the version-bump commit to origin
    [switch]$Detailed         # Show full command output (for debugging)
)

# ---------------------------------------------------------------------------
# Configuration — auto-discovered, not hardcoded in params
# ---------------------------------------------------------------------------

# Team ID and Apple ID are read from Config/BundleIdSecrets.xcconfig and the
# keychain respectively. These are fallbacks only.
$DefaultTeamId   = "V64Y34CXW2"
$DefaultAppleId  = "Evoveo.tech@gmail.com"
$KeychainService = "NOOP-TestFlight-Upload"

# Upstream source for the sync stage (mirrors sync-upstream.ps1)
$UpstreamSources = @(
    @{ Name = "upstream-ryanbr"; Url = "https://github.com/ryanbr/noop.git"; Label = "github.com/ryanbr/noop" }
)

$ProjectFile = Join-Path $ProjectDir "Strand.xcodeproj"
$ProjectYml  = Join-Path $ProjectDir "project.yml"
$BundleIdXcconfig = Join-Path $ProjectDir "Config/BundleIdSecrets.xcconfig"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Stage  { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Step   { param([string]$Msg) Write-Host "  > $Msg" -ForegroundColor White }
function Write-Ok     { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn   { param([string]$Msg) Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Err    { param([string]$Msg) Write-Host "  [ERROR] $Msg" -ForegroundColor Red }
function Write-Fix    { param([string]$Msg) Write-Host "  [FIX] $Msg" -ForegroundColor Magenta }
function Write-Info   { param([string]$Msg) Write-Host "  [i] $Msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Credential auto-discovery — finds Apple ID + app-specific password from
# the keychain and team ID from BundleIdSecrets.xcconfig. No env vars needed.
# ---------------------------------------------------------------------------

function Resolve-TeamId {
    # 1. Try Config/BundleIdSecrets.xcconfig (the gitignored per-build config)
    if (Test-Path $BundleIdXcconfig) {
        $content = Get-Content $BundleIdXcconfig -Raw
        $match = [regex]::Match($content, 'DEVELOPMENT_TEAM\s*=\s*(\S+)')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    }
    # 2. Fallback to default
    return $DefaultTeamId
}

function Resolve-AppleId {
    # 1. Scan keychain for the known service name
    $result = & security find-generic-password -s $KeychainService 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Extract the account from the keychain output
        $acctMatch = [regex]::Match(($result | Out-String), '"acct"<blob>="([^"]+)"')
        if ($acctMatch.Success) {
            return $acctMatch.Groups[1].Value
        }
    }
    # 2. Fallback to default
    return $DefaultAppleId
}

function Resolve-AppPassword {
    param([string]$AppleId)
    # Read the app-specific password directly from the keychain (-w = output password only)
    $password = & security find-generic-password -s $KeychainService -a $AppleId -w 2>$null
    if ($LASTEXITCODE -eq 0 -and $password) {
        return $password.Trim()
    }
    # Fallback: try by account only (altool-stored items may have NULL svce)
    $password = & security find-generic-password -a $AppleId -w 2>$null
    if ($LASTEXITCODE -eq 0 -and $password) {
        return $password.Trim()
    }
    return $null
}

# ---------------------------------------------------------------------------
# Git helpers (from sync-upstream.ps1 — proven, with case-collision fix)
# ---------------------------------------------------------------------------

$env:GIT_EDITOR = "true"

function Remove-StaleGitLock {
    $lockPath = ".git/index.lock"
    if (Test-Path $lockPath) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $lockPath) {
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,
        [string]$ErrorMessage = "Git command failed",
        [int]$Retries = 3
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        Remove-StaleGitLock
        try {
            $output = Invoke-Expression $Command
            if ($LASTEXITCODE -ne 0) {
                if ($output -match "index\.lock" -and $attempt -lt $Retries) {
                    Start-Sleep -Seconds 1
                    continue
                }
                return $false
            }
            if ($output) { Write-Host $output }
            return $true
        } catch {
            if ($_.ToString() -match "index\.lock" -and $attempt -lt $Retries) {
                Start-Sleep -Seconds 1
                continue
            }
            return $false
        }
    }
    return $false
}

function Test-RebaseInProgress { return (Test-Path ".git/rebase-merge") -or (Test-Path ".git/rebase-apply") }
function Test-MergeInProgress  { return (Test-Path ".git/MERGE_HEAD") }

# Cache of upstream-tracked paths for case-collision resolution.
$script:upstreamPathCaseMap = $null

function Get-UpstreamPathCaseMap {
    if ($null -ne $script:upstreamPathCaseMap) { return $script:upstreamPathCaseMap }
    $script:upstreamPathCaseMap = @{}
    foreach ($src in $UpstreamSources) {
        $tree = git ls-tree -r "$($src.Name)/main" --name-only 2>$null
        if ($LASTEXITCODE -eq 0 -and $tree) {
            foreach ($p in $tree) {
                $p = $p.Trim()
                if ($p) {
                    $lower = $p.ToLower()
                    if (-not $script:upstreamPathCaseMap.ContainsKey($lower)) {
                        $script:upstreamPathCaseMap[$lower] = $p
                    }
                }
            }
        }
    }
    return $script:upstreamPathCaseMap
}

function Select-CanonicalPath {
    param([string[]]$Variants)
    $map = Get-UpstreamPathCaseMap
    foreach ($v in $Variants) {
        $lower = $v.ToLower()
        # -ceq is case-sensitive: PowerShell's -eq is case-insensitive.
        if ($map.ContainsKey($lower) -and $map[$lower] -ceq $v) { return $v }
    }
    $lowerMatch = $Variants | Where-Object { $_ -ceq $_.ToLower() } | Select-Object -First 1
    if ($lowerMatch) { return $lowerMatch }
    return $Variants[0]
}

function Resolve-ConflictBatch {
    param([string]$ContextLabel)
    $conflictFiles = git diff --name-only --diff-filter=U
    if (-not $conflictFiles) { return $false }

    $caseGroups = @{}
    foreach ($file in $conflictFiles) {
        $file = $file.Trim()
        if (-not $file) { continue }
        $lower = $file.ToLower()
        if (-not $caseGroups.ContainsKey($lower)) { $caseGroups[$lower] = @() }
        $caseGroups[$lower] += $file
    }

    foreach ($lower in @($caseGroups.Keys)) {
        $variants = $caseGroups[$lower]
        if ($variants.Count -gt 1) {
            $keep = Select-CanonicalPath $variants
            foreach ($v in $variants) {
                if ($v -cne $keep) {
                    Write-Info "  Case-collision: removing '$v' (keeping '$keep')"
                    Invoke-GitCommand "git rm --cached '$v' 2>`$null" "Failed to remove case-duplicate $v"
                }
            }
            Invoke-GitCommand "git checkout --theirs '$keep'" "Failed to checkout --theirs for $keep ($ContextLabel)"
        } else {
            Invoke-GitCommand "git checkout --theirs '$($variants[0])'" "Failed to checkout --theirs for $($variants[0]) ($ContextLabel)"
        }
    }
    git add -A
    return $true
}

function Resolve-MergeConflicts {
    param([string]$MergeMessage)
    if (Resolve-ConflictBatch "merge") {
        $null = Invoke-GitCommand "git commit -m '$MergeMessage'" "Failed to commit merge"
        return $true
    }
    return $false
}

function Resolve-RebaseConflicts {
    param([string]$ContextLabel, [int]$MaxIterations = 500)
    $iteration = 0
    while (Test-RebaseInProgress) {
        $iteration++
        if ($iteration -gt $MaxIterations) {
            Invoke-GitCommand "git rebase --abort" "Failed to abort rebase"
            return $false
        }
        if (Resolve-ConflictBatch $ContextLabel) {
            Write-Info "  Resolved conflict batch $iteration, continuing rebase..."
        }
        $null = Invoke-GitCommand "git rebase --continue" "Failed to continue rebase (iteration $iteration)"
        if (Test-RebaseInProgress) {
            $remainingConflicts = git diff --name-only --diff-filter=U 2>$null
            if (-not $remainingConflicts) {
                $null = Invoke-GitCommand "git rebase --skip" "Failed to skip empty commit"
            }
        }
    }
    return $true
}

function Repair-CaseCollisions {
    $allFiles = git ls-files
    if (-not $allFiles) { return }
    $groups = @{}
    foreach ($f in $allFiles) {
        $lower = $f.ToLower()
        if (-not $groups.ContainsKey($lower)) { $groups[$lower] = @() }
        $groups[$lower] += $f
    }
    $fixed = 0
    foreach ($lower in $groups.Keys) {
        $variants = $groups[$lower]
        if ($variants.Count -gt 1) {
            $toKeep = Select-CanonicalPath $variants
            $toRemove = $variants | Where-Object { $_ -cne $toKeep }
            foreach ($remove in $toRemove) {
                Write-Info "  Fixing case-collision: removing '$remove' (keeping '$toKeep')"
                Invoke-GitCommand "git rm --cached '$remove' 2>`$null" "Failed to remove case-duplicate $remove"
                $fixed++
            }
        }
    }
    if ($fixed -gt 0) {
        git add -A
        Write-Info "  Fixed $fixed case-collision duplicate(s)"
        if (-not (Test-RebaseInProgress) -and -not (Test-MergeInProgress)) {
            $null = Invoke-GitCommand "git commit --amend --no-edit 2>`$null" "Failed to amend commit with case-collision fix"
        }
    }
}

function Update-FileContent {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Patterns,
        [Parameter(Mandatory=$true)][string[]]$Replacements
    )
    if (-not (Test-Path $FilePath)) { return $false }
    $content = Get-Content $FilePath -Raw
    $originalContent = $content
    for ($i = 0; $i -lt $Patterns.Count; $i++) {
        if ($Replacements[$i] -ne $null) {
            $content = $content -replace $Patterns[$i], $Replacements[$i]
        }
    }
    if ($content -ne $originalContent) {
        Set-Content $FilePath -Value $content -NoNewline
    }
    return $true
}

# ---------------------------------------------------------------------------
# Stage 0: Sync upstream (integrates sync-upstream.ps1 logic)
# ---------------------------------------------------------------------------

function Invoke-SyncUpstream {
    Write-Stage "Sync Upstream"

    # Pre-flight: finish any in-progress rebase/merge from a previous interrupted run
    if (Test-RebaseInProgress) {
        Write-Warn "In-progress rebase detected — finishing it first..."
        $null = Resolve-RebaseConflicts "pre-flight rebase"
        if (Test-RebaseInProgress) {
            Invoke-GitCommand "git rebase --abort" "Failed to abort pre-flight rebase"
        }
    }
    if (Test-MergeInProgress) {
        Write-Warn "In-progress merge detected — aborting it..."
        Invoke-GitCommand "git merge --abort" "Failed to abort pre-flight merge"
    }

    # Configure Git
    $null = Invoke-GitCommand "git config user.name 'github-actions[bot]'" "Failed to configure git user.name"
    $null = Invoke-GitCommand "git config user.email 'github-actions[bot]@users.noreply.github.com'" "Failed to configure git user.email"
    $null = Invoke-GitCommand "git config core.ignorecase true" "Failed to set core.ignorecase"

    # Add upstream remotes
    $existingRemotes = git remote
    foreach ($src in $UpstreamSources) {
        if ($existingRemotes -notcontains $src.Name) {
            $null = Invoke-GitCommand "git remote add $($src.Name) $($src.Url)" "Failed to add $($src.Name) remote"
        } else {
            $null = Invoke-GitCommand "git remote set-url $($src.Name) $($src.Url)" "Failed to set $($src.Name) URL"
        }
    }

    # Fetch all remotes
    Write-Step "Fetching remotes..."
    $fetchStatus = @{}
    foreach ($src in $UpstreamSources) {
        if (Invoke-GitCommand "git fetch $($src.Name)" "Failed to fetch $($src.Name)") {
            $fetchStatus[$src.Name] = $true
            Write-Ok "$($src.Name) : reachable"
        } else {
            $fetchStatus[$src.Name] = $false
            Write-Warn "$($src.Name) : unreachable — will skip"
        }
    }
    if (Invoke-GitCommand "git fetch origin" "Failed to fetch origin") {
        $fetchStatus["origin"] = $true
    } else {
        $fetchStatus["origin"] = $false
    }

    $availableUpstreams = $UpstreamSources.Name | Where-Object { $fetchStatus[$_] }
    if ($availableUpstreams.Count -eq 0) {
        Write-Err "All upstream sources unreachable. Cannot sync."
        return $false
    }

    # Resolve HEADs
    $LOCAL = git rev-parse HEAD
    $upstreamHeads = @{}
    foreach ($remote in $availableUpstreams) {
        $head = git rev-parse "$remote/main" 2>$null
        if ($LASTEXITCODE -eq 0 -and $head) {
            $upstreamHeads[$remote] = $head.Trim()
        } else {
            $fetchStatus[$remote] = $false
        }
    }
    if ($upstreamHeads.Count -eq 0) {
        Write-Err "No upstream remote had a resolvable main branch."
        return $false
    }

    $ORIGIN = $null
    if ($fetchStatus["origin"]) {
        $ORIGIN = git rev-parse origin/main 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $ORIGIN) { $ORIGIN = $null }
    }

    # Find newest upstream by commit timestamp
    $newerUpstream = $null
    $newerUpstreamCommit = $null
    $newerUpstreamDate = 0
    foreach ($remote in $upstreamHeads.Keys) {
        $date = git log -1 --format=%ct $upstreamHeads[$remote] 2>$null
        if ($LASTEXITCODE -eq 0 -and $date -and [int]$date -gt [int]$newerUpstreamDate) {
            $newerUpstreamDate = [int]$date
            $newerUpstream = $remote
            $newerUpstreamCommit = $upstreamHeads[$remote]
        }
    }

    if (-not $newerUpstream) {
        Write-Err "Could not determine newest upstream."
        return $false
    }

    Write-Info "Local:      $LOCAL"
    Write-Info "Upstream:    $newerUpstreamCommit ($newerUpstream)"
    if ($ORIGIN) { Write-Info "Origin:     $ORIGIN" }

    $source = "none"
    $hasChanges = $false

    if ($LOCAL -ne $newerUpstreamCommit) {
        $source = $newerUpstream
        $hasChanges = $true
        Write-Ok "Upstream has new commits — will sync"
    } elseif ($ORIGIN -and $LOCAL -ne $ORIGIN) {
        $source = "origin"
        $hasChanges = $true
        Write-Ok "Origin has different commits — will sync"
    } else {
        Write-Ok "All sources in sync — nothing to merge"
    }

    if (-not $hasChanges) {
        Write-Ok "Sync complete (no changes)"
        return $true
    }

    # Merge from the chosen source
    $sourceConfig = $UpstreamSources | Where-Object { $_.Name -eq $source }
    $isUpstreamSource = $null -ne $sourceConfig

    if ($isUpstreamSource) {
        $mergeBranch = "$source/main"
        $mergeMessage = "Merge upstream changes from $($sourceConfig.Label) [skip ci]"
    } elseif ($source -eq "origin") {
        $mergeBranch = "origin/main"
        $mergeMessage = "Merge origin changes [skip ci]"
    } else {
        $mergeBranch = "origin/main"
        $mergeMessage = "Merge changes [skip ci]"
    }

    Write-Step "Merging from $source..."
    $null = Invoke-GitCommand "git merge $mergeBranch --allow-unrelated-histories -X theirs -m '$mergeMessage'" "Failed to merge from $source"

    if (Test-MergeInProgress) {
        $null = Resolve-MergeConflicts $mergeMessage
    }
    if (Test-MergeInProgress) {
        Write-Err "Merge still in progress after conflict resolution"
        return $false
    }

    Repair-CaseCollisions

    # Pull latest from origin (rebase)
    if ($isUpstreamSource) {
        Write-Step "Rebasing on origin..."
        $hasStash = $false
        $dirtyFiles = git status --porcelain
        if ($dirtyFiles) {
            $null = Invoke-GitCommand "git stash" "Failed to stash changes"
            $hasStash = $true
        }
        $null = Invoke-GitCommand "git pull origin main --rebase -X theirs" "Failed to pull from origin"
        $null = Resolve-RebaseConflicts "rebase"
        if (Test-RebaseInProgress) {
            Write-Warn "Rebase still in progress — aborting rebase"
            Invoke-GitCommand "git rebase --abort" "Failed to abort rebase"
        }
        Repair-CaseCollisions
        if ($hasStash) {
            $null = Invoke-GitCommand "git stash pop" "Failed to pop stash"
        }
    }

    # Apply evoveo identifier changes
    if ($isUpstreamSource) {
        Write-Step "Applying evoveo identifier changes..."
        $evoveoUpdates = @(
            @{ File = "StrandiOSShared/WidgetSnapshot.swift"; Patterns = @('group\.com\.noopapp\.noop'); Replacements = @('group.com.evoveo.noop') }
            @{ File = "altstore-source.json"; Patterns = @('"bundleIdentifier": "com\.noopapp\.noop"'); Replacements = @('"bundleIdentifier": "com.evoveo.noop"') }
            @{ File = "Packages/NoopLocalAccess/Sources/NoopLocalAccessCore/LocalAccessCore.swift"; Patterns = @('com\.noopapp\.noop'); Replacements = @('com.evoveo.noop') }
            @{ File = "Strand/Collect/RawHistoryArchive.swift"; Patterns = @('com\.noopapp\.noop'); Replacements = @('com.evoveo.noop') }
            @{ File = "Strand/Collect/StorePaths.swift"; Patterns = @('com\.noopapp\.noop'); Replacements = @('com.evoveo.noop') }
        )
        $filesUpdated = 0
        foreach ($upd in $evoveoUpdates) {
            if (Update-FileContent $upd.File $upd.Patterns $upd.Replacements) {
                $filesUpdated++
            }
        }
        # project.yml — special post-processing
        if (Update-FileContent "project.yml" @('group\.com\.noopapp\.noop', 'com\.noopapp\.noop', 'com\.evoveo\.noops') @('group.com.evoveo.noop', 'com.evoveo.noop', 'com.evoveo.noop')) {
            $content = Get-Content "project.yml" -Raw
            $content = $content -replace '- "Data/AppleDemoSeeder\.swift".*', ''
            $content = $content -replace '(PRODUCT_BUNDLE_IDENTIFIER: com\.evoveo\.noop)\.staging(\r?\n        PRODUCT_NAME: "NOOP Staging"\r?\n        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\r?\n        # Ship every)', '$1$2'
            $content = $content -replace 'com\.evoveo\.noop\.staging\.widgets', 'com.evoveo.noop.widgets'
            $content = $content -replace 'com\.evoveo\.noop\.staging\.watch', 'com.evoveo.noop.watch'
            $content = $content -replace 'WKCompanionAppBundleIdentifier: com\.evoveo\.noop\.staging', 'WKCompanionAppBundleIdentifier: com.evoveo.noop'
            Set-Content "project.yml" -Value $content -NoNewline
            $filesUpdated++
        }
        if ($filesUpdated -gt 0) {
            $evoveoFiles = @(
                "StrandiOSShared/WidgetSnapshot.swift", "project.yml", "altstore-source.json",
                "Packages/NoopLocalAccess/Sources/NoopLocalAccessCore/LocalAccessCore.swift",
                "Strand/Collect/RawHistoryArchive.swift", "Strand/Collect/StorePaths.swift"
            )
            $existingFiles = $evoveoFiles | Where-Object { Test-Path $_ }
            if ($existingFiles) { git add $existingFiles }
            $stagedChanges = git diff --cached --name-only
            if ($stagedChanges) {
                $null = Invoke-GitCommand "git commit -m 'Apply evoveo identifier changes after upstream sync [skip ci]'" "Failed to commit evoveo identifier changes"
                Write-Ok "Evoveo identifiers applied and committed"
            }
        }
    }

    # Push synced changes to origin
    if (-not $SkipPush) {
        Write-Step "Pushing synced changes to origin..."
        $currentBranch = git rev-parse --abbrev-ref HEAD
        if (Invoke-GitCommand "git push origin $currentBranch" "Failed to push to origin") {
            Write-Ok "Pushed to origin"
        } else {
            Write-Warn "Push failed — changes are local. Push manually with: git push origin $currentBranch"
        }
    }

    Write-Ok "Sync complete (synced from: $source)"
    return $true
}

# ---------------------------------------------------------------------------
# Stage 1: Auto-bump build number
# ---------------------------------------------------------------------------

function Invoke-BumpBuildNumber {
    Write-Stage "Bump Build Number"

    if (-not (Test-Path $ProjectYml)) {
        Write-Err "project.yml not found at $ProjectYml"
        return $false
    }

    $content = Get-Content $ProjectYml -Raw

    # Extract current build number
    $match = [regex]::Match($content, 'CURRENT_PROJECT_VERSION:\s*"(\d+)"')
    if (-not $match.Success) {
        Write-Err "Could not find CURRENT_PROJECT_VERSION in project.yml"
        return $false
    }

    $currentBuild = [int]$match.Groups[1].Value
    $newBuild = $currentBuild + 1

    # Extract marketing version for display
    $versionMatch = [regex]::Match($content, 'MARKETING_VERSION:\s*"([^"]+)"')
    $marketingVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { "unknown" }

    Write-Step "Current: v$marketingVersion build $currentBuild -> bumping to build $newBuild"

    # Bump the build number
    $content = $content -replace 'CURRENT_PROJECT_VERSION:\s*"\d+"', "CURRENT_PROJECT_VERSION: `"$newBuild`""
    Set-Content $ProjectYml -Value $content -NoNewline

    # Commit the bump
    git add project.yml
    $commitResult = Invoke-GitCommand "git commit -m 'Bump iOS build number to $newBuild for TestFlight upload [skip ci]'" "Failed to commit build number bump"
    if ($commitResult) {
        Write-Ok "Build number bumped to $newBuild and committed"
    }

    # Store for later use
    $script:BumpedBuildNumber = $newBuild
    $script:MarketingVersion = $marketingVersion

    return $true
}

# ---------------------------------------------------------------------------
# Agentic error catalog — maps error signatures to auto-fix actions
# ---------------------------------------------------------------------------

$ErrorCatalog = @(
    @{
        Pattern = "iOS \d+\.\d+ is not installed.*download and install the platform"
        Description = "iOS platform runtime not installed"
        Fix = {
            Write-Fix "Downloading iOS platform runtime..."
            & xcodebuild -downloadPlatform iOS 2>&1 | ForEach-Object { Write-Info $_ }
        }
    },
    @{
        Pattern = "watchOS \d+\.\d+ must be installed"
        Description = "watchOS platform runtime not installed"
        Fix = {
            Write-Fix "Downloading watchOS platform runtime..."
            & xcodebuild -downloadPlatform watchOS 2>&1 | ForEach-Object { Write-Info $_ }
        }
    },
    @{
        Pattern = "xcodegen: command not found|xcodegen not found"
        Description = "xcodegen not installed"
        Fix = {
            Write-Fix "Installing xcodegen via Homebrew..."
            & brew install xcodegen 2>&1 | ForEach-Object { Write-Info $_ }
        }
    },
    @{
        Pattern = "no such file.*project\.yml|Could not find.*project\.yml"
        Description = "project.yml not found in working directory"
        Fix = {
            Write-Fix "Searching for project.yml in parent directories..."
            $found = Get-ChildItem -Path $ProjectDir -Filter "project.yml" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $ProjectDir = $found.DirectoryName
                $ProjectYml = $found.FullName
                Write-Fix "Found project.yml at: $ProjectYml"
            } else {
                throw "project.yml not found anywhere in $ProjectDir"
            }
        }
    },
    @{
        Pattern = "Code Sign error: no provisioning profile|provisioning profile.*not found"
        Description = "Missing provisioning profile"
        Fix = {
            Write-Fix "Retrying with automatic signing and provisioning updates..."
            $script:UseAutomaticSigning = $true
        }
    },
    @{
        Pattern = "0 valid identities found|no identities are available"
        Description = "No signing identities in keychain"
        Fix = {
            Write-Fix "Opening Xcode to trigger certificate sync..."
            & open -a Xcode 2>&1
            Start-Sleep -Seconds 10
            Write-Warn "Xcode opened to sync certificates. If this persists, add your Apple ID in Xcode > Settings > Accounts."
        }
    },
    @{
        Pattern = "Could not configure request|Found no destinations"
        Description = "No valid iOS destinations found"
        Fix = {
            Write-Fix "Checking installed platforms..."
            $sdks = & xcodebuild -showsdks 2>&1
            if ($sdks -match "iphoneos") {
                Write-Fix "iphoneos SDK is present. Retrying with -sdk iphoneos."
                $script:UseSdkOverride = $true
            } else {
                Write-Fix "No iOS SDK found. Downloading iOS platform..."
                & xcodebuild -downloadPlatform iOS 2>&1 | ForEach-Object { Write-Info $_ }
            }
        }
    },
    @{
        Pattern = "package dependency.*failed|resolve package dependencies.*failed"
        Description = "Swift package resolution failed"
        Fix = {
            Write-Fix "Cleaning derived data and retrying package resolution..."
            $derivedData = Join-Path $env:HOME "Library/Developer/Xcode/DerivedData"
            if (Test-Path $derivedData) {
                Get-ChildItem $derivedData -Directory -Filter "Strand-*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Fix "Cleared Strand derived data"
            }
        }
    },
    @{
        Pattern = "export.*failed|EXPORT FAILED"
        Description = "IPA export failed"
        Fix = {
            Write-Fix "Regenerating exportOptions.plist with current Team ID..."
            $script:RegenerateExportOptions = $true
        }
    },
    @{
        Pattern = "altool.*authentication|altool.*unauthorized|401|403|Apple Account or password was entered incorrectly"
        Description = "App Store Connect authentication failed"
        Fix = {
            Write-Warn "Apple rejected the app-specific password (401). It may have been revoked."
            Write-Warn "Generate a new one at: https://appleid.apple.com > Sign-In & Security > App-Specific Passwords"
            Write-Warn "Then update keychain:"
            Write-Warn "  security delete-generic-password -s '$KeychainService' -a '$AppleId'"
            Write-Warn "  security add-generic-password -s '$KeychainService' -a '$AppleId' -w 'new-password'"
            throw "App-specific password rejected by Apple (expired or revoked)"
        }
    },
    @{
        Pattern = "expected declaration|extraneous.*at top level.*LiveView"
        Description = "Broken LiveView.swift from incorrect duplicate commenting"
        Fix = {
            Write-Fix "Restoring LiveView.swift from git..."
            $liveView = Join-Path $ProjectDir "Strand/Screens/LiveView.swift"
            if (Test-Path $liveView) {
                & git checkout -- $liveView 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Fix "LiveView.swift restored from git"
                }
            }
        }
    }
)

# ---------------------------------------------------------------------------
# Core agentic executor — runs a stage, detects errors, applies fixes, retries
# ---------------------------------------------------------------------------

function Invoke-AgenticStage {
    param(
        [string]$StageName,
        [scriptblock]$Action,
        [int]$MaxAttempts = $MaxRetries
    )

    Write-Stage $StageName

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Step "Attempt $attempt/$MaxAttempts"

        $script:UseAutomaticSigning = $false
        $script:UseSdkOverride = $false
        $script:RegenerateExportOptions = $false

        $script:StageExitCode = 0
        $output = & $Action 2>&1
        $exitCode = $script:StageExitCode

        if ($Detailed) {
            $output | ForEach-Object { Write-Info $_ }
        }

        if ($exitCode -eq 0) {
            Write-Ok "$StageName succeeded"
            return $true
        }

        $errorText = ($output | Out-String)

        $resolved = $false
        foreach ($entry in $ErrorCatalog) {
            if ($errorText -match $entry.Pattern) {
                Write-Err "$($entry.Description)"
                try {
                    & $entry.Fix
                    $resolved = $true
                    Write-Step "Auto-fix applied, retrying..."
                    break
                } catch {
                    Write-Err "Auto-fix failed: $_"
                    $resolved = $false
                    break
                }
            }
        }

        if (-not $resolved) {
            Write-Err "$StageName failed with unknown error. Last 20 lines:"
            $output | Select-Object -Last 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
            return $false
        }

        Start-Sleep -Seconds 2
    }

    Write-Err "$StageName failed after $MaxAttempts attempts"
    return $false
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

function Invoke-Preflight {
    Write-Stage "Pre-flight Checks"

    # Check Xcode
    $xcodeOutput = & xcodebuild -version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Xcode not found. Install from Mac App Store."
        return $false
    }
    Write-Ok "Xcode: $(($xcodeOutput | Select-Object -First 1))"

    # Check xcodegen
    $xgenVersion = & xcodegen --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "xcodegen not found. Installing..."
        & brew install xcodegen 2>&1 | Out-Null
        $xgenVersion = & xcodegen --version 2>&1
    }
    Write-Ok "xcodegen: $xgenVersion"

    # Check project.yml
    if (-not (Test-Path $ProjectYml)) {
        Write-Err "project.yml not found at $ProjectYml"
        return $false
    }
    Write-Ok "project.yml found"

    # Check signing identity
    $identities = & security find-identity -p codesigning 2>&1
    $identityText = ($identities | Out-String)
    if ($identityText -match "0 identities found") {
        Write-Warn "No signing identities found. Xcode will auto-create on first archive."
        Write-Warn "Ensure your Apple Developer account is added in Xcode > Settings > Accounts."
    } else {
        $identityName = ($identities | Select-String "Apple Development|iPhone Distribution|Apple Distribution" | Select-Object -First 1)
        if ($identityName) {
            Write-Ok "Signing identity: $($identityName.ToString().Trim())"
        }
    }

    # Check keychain credential for upload (only if not skipping upload)
    if (-not $SkipUpload) {
        $script:TeamId   = Resolve-TeamId
        $script:AppleId  = Resolve-AppleId
        $script:AppPassword = Resolve-AppPassword -AppleId $script:AppleId

        if ($script:AppPassword) {
            Write-Ok "Keychain credential found: service='$KeychainService' account='$($script:AppleId)'"
            Write-Ok "Team ID: $($script:TeamId)"
        } else {
            Write-Err "App-specific password not found in keychain."
            Write-Err "Store it once with:"
            Write-Err "  security add-generic-password -s '$KeychainService' -a '$DefaultAppleId' -w 'your-app-specific-password'"
            Write-Err "Generate one at: https://appleid.apple.com > Sign-In & Security > App-Specific Passwords"
            return $false
        }
    } else {
        $script:TeamId = Resolve-TeamId
        Write-Ok "Team ID: $($script:TeamId) (upload skipped)"
    }

    return $true
}

# ---------------------------------------------------------------------------
# Pipeline stages
# ---------------------------------------------------------------------------

function Invoke-XcodeGen {
    $result = & xcodegen generate 2>&1
    $script:StageExitCode = $LASTEXITCODE
    return $result
}

function Invoke-ResolvePackages {
    $result = & xcodebuild -resolvePackageDependencies -project $ProjectFile -scheme $Scheme -destination 'generic/platform=iOS' 2>&1
    $script:StageExitCode = $LASTEXITCODE
    return $result
}

function Invoke-Archive {
    $archiveArgs = @(
        "-project", $ProjectFile,
        "-scheme", $Scheme,
        "-destination", "generic/platform=iOS",
        "-configuration", $Configuration,
        "-archivePath", $ArchivePath,
        "-derivedDataPath", "build",
        "DEVELOPMENT_TEAM=$($script:TeamId)",
        "CODE_SIGN_STYLE=Automatic",
        "-allowProvisioningUpdates",
        "archive"
    )

    if ($script:UseSdkOverride) {
        $archiveArgs += @("-sdk", "iphoneos")
    }

    # Clean previous archive
    if (Test-Path $ArchivePath) {
        Remove-Item $ArchivePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result = & xcodebuild @archiveArgs 2>&1
    $script:StageExitCode = $LASTEXITCODE
    return $result
}

function Invoke-ExportIpa {
    # Generate exportOptions.plist with the resolved Team ID
    $plistPath = "/tmp/exportOptions_$($script:TeamId).plist"

    if ($script:RegenerateExportOptions -or -not (Test-Path $plistPath)) {
        $plist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$($script:TeamId)</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
"@
        Set-Content -Path $plistPath -Value $plist -NoNewline
        Write-Info "Export options written to $plistPath"
    }

    if (-not (Test-Path $ArchivePath)) {
        Write-Err "Archive not found at $ArchivePath"
        $script:StageExitCode = 1
        return "Archive not found"
    }

    if (Test-Path $ExportPath) {
        Remove-Item $ExportPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result = & xcodebuild -exportArchive -archivePath $ArchivePath -exportPath $ExportPath -exportOptionsPlist $plistPath -allowProvisioningUpdates DEVELOPMENT_TEAM=$($script:TeamId) CODE_SIGN_STYLE=Automatic 2>&1
    $script:StageExitCode = $LASTEXITCODE
    return $result
}

function Invoke-ValidateIpa {
    $ipaFile = Get-ChildItem -Path $ExportPath -Filter "*.ipa" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ipaFile) {
        Write-Err "No IPA file found in $ExportPath"
        $script:StageExitCode = 1
        return "No IPA found"
    }

    Write-Step "Validating: $($ipaFile.Name)"
    $result = & xcrun altool --validate-app --type ios --file $ipaFile.FullName --username $script:AppleId --app-password $script:AppPassword 2>&1
    $script:StageExitCode = $LASTEXITCODE
    return $result
}

function Invoke-UploadTestFlight {
    $ipaFile = Get-ChildItem -Path $ExportPath -Filter "*.ipa" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ipaFile) {
        Write-Err "No IPA file found in $ExportPath"
        $script:StageExitCode = 1
        return "No IPA found"
    }

    $sizeMB = [math]::Round($ipaFile.Length / 1MB, 1)
    Write-Step "Uploading: $($ipaFile.Name) ($sizeMB MB)"

    # Read the password fresh from keychain (in case it was updated between pre-flight and upload)
    $password = Resolve-AppPassword -AppleId $script:AppleId
    if (-not $password) {
        Write-Err "Could not retrieve app-specific password from keychain at upload time"
        $script:StageExitCode = 1
        return "No keychain credential"
    }

    $result = & xcrun altool --upload-app --type ios --file $ipaFile.FullName --username $script:AppleId --app-password $password 2>&1
    $script:StageExitCode = $LASTEXITCODE
    return $result
}

# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

Write-Host "`n************************************************************" -ForegroundColor Cyan
Write-Host "  NOOP iOS — Autonomous TestFlight Build & Upload" -ForegroundColor Cyan
Write-Host "************************************************************" -ForegroundColor Cyan
Write-Host "  Scheme:        $Scheme" -ForegroundColor DarkGray
Write-Host "  Configuration: $Configuration" -ForegroundColor DarkGray
Write-Host "  Project:       $ProjectDir" -ForegroundColor DarkGray
Write-Host "  SkipSync:      $SkipSync" -ForegroundColor DarkGray
Write-Host "  SkipUpload:    $SkipUpload" -ForegroundColor DarkGray
Write-Host "  SkipPush:      $SkipPush" -ForegroundColor DarkGray

# Stage 0: Sync upstream
if ($SkipSync) {
    Write-Stage "Sync Upstream"
    Write-Warn "Skipping upstream sync (-SkipSync)"
} else {
    if (-not (Invoke-SyncUpstream)) {
        Write-Host "`n[BLOCKED] Upstream sync failed. Resolve issues and retry." -ForegroundColor Red
        exit 1
    }
}

# Stage 1: Bump build number
if (-not (Invoke-BumpBuildNumber)) {
    Write-Host "`n[BLOCKED] Build number bump failed." -ForegroundColor Red
    exit 1
}

# Stage 2: Pre-flight checks
if (-not (Invoke-Preflight)) {
    Write-Host "`n[BLOCKED] Pre-flight checks failed. Resolve the issues above and retry." -ForegroundColor Red
    exit 2
}

# Stage 3: Generate Xcode project
if (-not (Invoke-AgenticStage -StageName "Generate Xcode Project" -Action ${function:Invoke-XcodeGen})) {
    exit 3
}

# Stage 4: Resolve package dependencies
if (-not (Invoke-AgenticStage -StageName "Resolve Package Dependencies" -Action ${function:Invoke-ResolvePackages})) {
    exit 4
}

# Stage 5: Archive
if (-not (Invoke-AgenticStage -StageName "Archive iOS App" -Action ${function:Invoke-Archive})) {
    exit 5
}

# Stage 6: Export IPA
if (-not (Invoke-AgenticStage -StageName "Export IPA" -Action ${function:Invoke-ExportIpa})) {
    exit 6
}

# Verify IPA exists
$ipaFile = Get-ChildItem -Path $ExportPath -Filter "*.ipa" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ipaFile) {
    $sizeMB = [math]::Round($ipaFile.Length / 1MB, 1)
    Write-Ok "IPA ready: $($ipaFile.Name) ($sizeMB MB)"
} else {
    Write-Err "IPA file not found after export"
    exit 7
}

# Stage 7: Validate + Upload to TestFlight
if ($SkipUpload) {
    Write-Stage "Upload to TestFlight"
    Write-Warn "Skipping upload (-SkipUpload)"
    Write-Host "`n  IPA available at: $($ipaFile.FullName)" -ForegroundColor Green
} else {
    # Validate first
    if (-not (Invoke-AgenticStage -StageName "Validate IPA" -Action ${function:Invoke-ValidateIpa})) {
        Write-Warn "Validation failed — attempting upload anyway..."
    }

    # Upload
    if (-not (Invoke-AgenticStage -StageName "Upload to TestFlight" -Action ${function:Invoke-UploadTestFlight})) {
        Write-Host "`n[PARTIAL] Build succeeded but upload failed. IPA at: $($ipaFile.FullName)" -ForegroundColor Yellow
        exit 8
    }
}

# Stage 8: Push version bump to origin
if (-not $SkipPush) {
    Write-Stage "Push Version Bump"
    $currentBranch = git rev-parse --abbrev-ref HEAD
    if (Invoke-GitCommand "git push origin $currentBranch" "Failed to push version bump") {
        Write-Ok "Version bump pushed to origin/$currentBranch"
    } else {
        Write-Warn "Push failed — commit is local. Push manually with: git push origin $currentBranch"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$versionLabel = "v$($script:MarketingVersion) build $($script:BumpedBuildNumber)"

Write-Host "`n************************************************************" -ForegroundColor Green
Write-Host "  BUILD & UPLOAD COMPLETE" -ForegroundColor Green
Write-Host "************************************************************" -ForegroundColor Green
Write-Host "  Version:  $versionLabel" -ForegroundColor White
Write-Host "  Bundle:   com.evoveo.noop" -ForegroundColor DarkGray
Write-Host "  Team:     $($script:TeamId)" -ForegroundColor DarkGray
Write-Host "  Apple ID: $($script:AppleId)" -ForegroundColor DarkGray
Write-Host "  IPA:      $($ipaFile.FullName)" -ForegroundColor DarkGray

if (-not $SkipUpload) {
    Write-Host "`n  The build is now processing on Apple's servers." -ForegroundColor White
    Write-Host "  Check status at: https://appstoreconnect.apple.com/apps" -ForegroundColor DarkGray
    Write-Host "  Processing typically takes 15-30 minutes." -ForegroundColor DarkGray
    Write-Host "  Internal testers get access automatically once processing completes." -ForegroundColor DarkGray
    Write-Host "  External beta groups: activate via App Store Connect web UI." -ForegroundColor DarkGray
}

Write-Host ""
