# Sync Upstream Repository - Local PowerShell Script
# This script replicates the GitHub Actions workflow for syncing upstream changes

$ErrorActionPreference = "Stop"
$env:GIT_EDITOR = "true"

function Remove-StaleGitLock {
    # Remove stale index.lock files that block git operations when a previous
    # git process was killed or is still winding down. Waits briefly first to
    # give a legitimate process time to release the lock naturally.
    $lockPath = ".git/index.lock"
    if (Test-Path $lockPath) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $lockPath) {
            Write-Host "  Removing stale index.lock..." -ForegroundColor Yellow
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
                # index.lock errors are transient — retry after clearing the lock
                if ($output -match "index\.lock" -and $attempt -lt $Retries) {
                    Write-Host "  index.lock conflict (attempt $attempt/$Retries), retrying..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }
                Write-Host "${ErrorMessage}" -ForegroundColor Red
                if ($output) { Write-Host $output -ForegroundColor Red }
                return $false
            }
            if ($output) { Write-Host $output }
            return $true
        } catch {
            if ($_.ToString() -match "index\.lock" -and $attempt -lt $Retries) {
                Write-Host "  index.lock conflict (attempt $attempt/$Retries), retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
                continue
            }
            Write-Host "${ErrorMessage}: $_" -ForegroundColor Red
            return $false
        }
    }
    return $false
}

function Test-RebaseInProgress {
    return (Test-Path ".git/rebase-merge") -or (Test-Path ".git/rebase-apply")
}

function Test-MergeInProgress {
    return (Test-Path ".git/MERGE_HEAD")
}

function Update-FileContent {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [Parameter(Mandatory=$true)]
        [string[]]$Patterns,
        [Parameter(Mandatory=$true)]
        [string[]]$Replacements
    )
    if (-not (Test-Path $FilePath)) {
        return $false
    }
    
    $content = Get-Content $FilePath -Raw
    $originalContent = $content
    for ($i = 0; $i -lt $Patterns.Count; $i++) {
        if ($null -ne $Replacements[$i]) {
            $content = $content -replace $Patterns[$i], $Replacements[$i]
        }
    }
    if ($content -ne $originalContent) {
        Set-Content $FilePath -Value $content -NoNewline
    }
    return $true
}

# Cache of upstream-tracked paths (lowercase -> actual casing) for case-collision
# resolution. Built lazily once from the available upstream remotes' main branches.
# Policy: when a case-collision appears (e.g. upstream Tools/ vs fork's tools/),
# prefer the casing the upstream remote actually uses. This keeps the fork's tree
# byte-identical to upstream for the colliding paths and prevents the collision
# from recurring on every future sync. If upstream does not track the path (a
# fork-only file), fall back to the lowercase variant.
$script:upstreamPathCaseMap = $null

function Get-UpstreamPathCaseMap {
    if ($null -ne $script:upstreamPathCaseMap) { return $script:upstreamPathCaseMap }
    $script:upstreamPathCaseMap = @{}
    # $upstreamSources is defined later in the script; during pre-flight (before
    # it is set) this safely yields an empty map and callers fall back to lowercase.
    $sources = Get-Variable -Name upstreamSources -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $sources -or -not $sources.Value) { return $script:upstreamPathCaseMap }
    foreach ($src in $sources.Value) {
        $remote = $src.Name
        $tree = git ls-tree -r "$remote/main" --name-only 2>$null
        if ($LASTEXITCODE -eq 0 -and $tree) {
            foreach ($p in $tree) {
                $p = $p.Trim()
                if ($p) {
                    $lower = $p.ToLower()
                    # First upstream (by $upstreamSources order) wins for any path.
                    if (-not $script:upstreamPathCaseMap.ContainsKey($lower)) {
                        $script:upstreamPathCaseMap[$lower] = $p
                    }
                }
            }
        }
    }
    return $script:upstreamPathCaseMap
}

# Given a set of case-duplicate paths for the same file, return the one to keep.
# Prefers the casing that matches an upstream remote's tree; falls back to the
# lowercase variant (Windows-canonical) when upstream does not track the path.
function Select-CanonicalPath {
    param([string[]]$Variants)
    $map = Get-UpstreamPathCaseMap
    foreach ($v in $Variants) {
        $lower = $v.ToLower()
        # -ceq is case-sensitive: PowerShell's -eq is case-insensitive, which would
        # match "tools/" against an upstream "Tools/" entry and defeat the purpose.
        if ($map.ContainsKey($lower) -and $map[$lower] -ceq $v) { return $v }
    }
    $lowerMatch = $Variants | Where-Object { $_ -ceq $_.ToLower() } | Select-Object -First 1
    if ($lowerMatch) { return $lowerMatch }
    return $Variants[0]
}

# Resolve all conflicted files in the current state by taking "theirs".
# Handles case-collision conflicts (e.g. upstream adds Tools/ when tools/ already
# exists) by preferring the upstream remote's casing — see Select-CanonicalPath.
# Returns $true if any conflicts were resolved, $false if there were none.
function Resolve-ConflictBatch {
    param([string]$ContextLabel)
    $conflictFiles = git diff --name-only --diff-filter=U
    if (-not $conflictFiles) { return $false }

    # Group conflicted paths by lowercase equivalent to detect case-collisions.
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
            # Case-collision: pick the canonical casing (upstream-preferred) and
            # remove the others from the index. On a case-insensitive filesystem
            # git cannot checkout --theirs for both casings, so we must drop one.
            $keep = Select-CanonicalPath $variants
            foreach ($v in $variants) {
                # -cne is case-sensitive: the variants differ only in case, so the
                # case-insensitive -ne would treat them as equal and skip the removal.
                if ($v -cne $keep) {
                    Write-Host "  Case-collision: removing '$v' (keeping '$keep')" -ForegroundColor Yellow
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

# Resolve all conflicts in an in-progress merge, then commit it.
function Resolve-MergeConflicts {
    param([string]$MergeMessage)
    if (Resolve-ConflictBatch "merge") {
        $null = Invoke-GitCommand "git commit -m '$MergeMessage'" "Failed to commit merge"
        return $true
    }
    Write-Host "No merge conflicts to resolve" -ForegroundColor Green
    return $false
}

# Resolve all conflicts in an in-progress rebase, looping until the rebase
# completes. A rebase can stop at MANY conflicting commits — this function
# keeps resolving (take theirs) and continuing until the rebase finishes.
function Resolve-RebaseConflicts {
    param([string]$ContextLabel, [int]$MaxIterations = 500)
    $iteration = 0
    while (Test-RebaseInProgress) {
        $iteration++
        if ($iteration -gt $MaxIterations) {
            Write-Host "ERROR: exceeded $MaxIterations rebase iterations — aborting rebase" -ForegroundColor Red
            Invoke-GitCommand "git rebase --abort" "Failed to abort rebase"
            return $false
        }
        if (Resolve-ConflictBatch $ContextLabel) {
            Write-Host "  Resolved conflict batch $iteration, continuing rebase..." -ForegroundColor Yellow
        }
        $null = Invoke-GitCommand "git rebase --continue" "Failed to continue rebase (iteration $iteration)"
        # If the continue failed, check if we're stuck
        if (Test-RebaseInProgress) {
            $remainingConflicts = git diff --name-only --diff-filter=U 2>$null
            if (-not $remainingConflicts) {
                # No conflicts but rebase still in progress — might be a no-content commit, skip it
                Write-Host "  No conflicts but rebase still paused — skipping empty commit..." -ForegroundColor Yellow
                $null = Invoke-GitCommand "git rebase --skip" "Failed to skip empty commit"
            }
        }
    }
    Write-Host "Rebase completed after $iteration iteration(s)" -ForegroundColor Green
    return $true
}

# Detect and fix case-collision duplicates in the git index after a merge or
# rebase. On a case-insensitive filesystem git with core.ignorecase=true should
# prevent these, but upstream merges can still introduce them via rename
# detection or --allow-unrelated-histories. This is a safety net.
# Strategy: for any set of tracked paths that differ only in case, keep the
# variant that matches the upstream remote's casing (see Select-CanonicalPath)
# and remove the others. This keeps the fork's tree aligned with upstream so the
# collision does not recur on the next sync.
function Repair-CaseCollisions {
    $allFiles = git ls-files
    if (-not $allFiles) { return }

    # Group by lowercase path to find case-duplicates
    $groups = @{}
    foreach ($f in $allFiles) {
        $lower = $f.ToLower()
        if (-not $groups.ContainsKey($lower)) {
            $groups[$lower] = @()
        }
        $groups[$lower] += $f
    }

    $fixed = 0
    foreach ($lower in $groups.Keys) {
        $variants = $groups[$lower]
        if ($variants.Count -gt 1) {
            # Keep the upstream-canonical variant, remove all others
            $toKeep = Select-CanonicalPath $variants
            # -cne is case-sensitive: variants differ only in case, so case-insensitive
            # -ne would treat them all as equal to $toKeep and remove nothing.
            $toRemove = $variants | Where-Object { $_ -cne $toKeep }
            foreach ($remove in $toRemove) {
                Write-Host "  Fixing case-collision: removing '$remove' (keeping '$toKeep')" -ForegroundColor Yellow
                Invoke-GitCommand "git rm --cached '$remove' 2>`$null" "Failed to remove case-duplicate $remove"
                $fixed++
            }
        }
    }

    if ($fixed -gt 0) {
        git add -A
        Write-Host "  Fixed $fixed case-collision duplicate(s)" -ForegroundColor Green
        # Amend the last commit to include the fix — but only if we're not in the
        # middle of a rebase (where amending would corrupt the rebase state).
        if (-not (Test-RebaseInProgress) -and -not (Test-MergeInProgress)) {
            $null = Invoke-GitCommand "git commit --amend --no-edit 2>`$null" "Failed to amend commit with case-collision fix"
        } else {
            Write-Host "  (rebase/merge in progress — case-collision fix staged, will be picked up on continue)" -ForegroundColor Yellow
        }
    }
}

Write-Host "=== Sync Upstream Repository ===" -ForegroundColor Cyan

# ── Pre-flight: detect and finish any in-progress rebase/merge from a previous
# interrupted run. This is the #1 cause of "re-introduced case collisions" — the
# previous run left a rebase half-done, and the next run started a new merge on
# top of the paused state.
if (Test-RebaseInProgress) {
    Write-Host "`n[pre-flight] Detected an in-progress rebase from a previous run — finishing it first..." -ForegroundColor Yellow
    $null = Resolve-RebaseConflicts "pre-flight rebase"
    if (Test-RebaseInProgress) {
        Write-Host "ERROR: could not finish the in-progress rebase — aborting it to get a clean state" -ForegroundColor Red
        Invoke-GitCommand "git rebase --abort" "Failed to abort pre-flight rebase"
    }
}
if (Test-MergeInProgress) {
    Write-Host "`n[pre-flight] Detected an in-progress merge from a previous run — aborting it to get a clean state..." -ForegroundColor Yellow
    Invoke-GitCommand "git merge --abort" "Failed to abort pre-flight merge"
}

# ── Upstream source definitions ──────────────────────────────────────────────
# Each entry: name, URL, and a human-friendly label for commit messages / logs.
# To add a 4th fallback source, just append another row here — the rest of the
# script is fully data-driven and will pick it up automatically.
$upstreamSources = @(
    @{ Name = "upstream-ryanbr";   Url = "https://github.com/ryanbr/noop.git";   Label = "github.com/ryanbr/noop" }
)

# Configure Git
Write-Host "`n[1/14] Configuring Git..." -ForegroundColor Yellow
$null = Invoke-GitCommand "git config user.name 'github-actions[bot]'" "Failed to configure git user.name"
$null = Invoke-GitCommand "git config user.email 'github-actions[bot]@users.noreply.github.com'" "Failed to configure git user.email"
# Enforce case-insensitive index on Windows — prevents Tools/ vs tools/ duplicates
# from being created during upstream merges. This is the correct setting for NTFS.
$null = Invoke-GitCommand "git config core.ignorecase true" "Failed to set core.ignorecase"

# Add upstream remotes (data-driven — no copy-paste per source)
Write-Host "`n[2/14] Adding upstream remotes..." -ForegroundColor Yellow
$existingRemotes = git remote
foreach ($src in $upstreamSources) {
    if ($existingRemotes -notcontains $src.Name) {
        $null = Invoke-GitCommand "git remote add $($src.Name) $($src.Url)" "Failed to add $($src.Name) remote"
    } else {
        $null = Invoke-GitCommand "git remote set-url $($src.Name) $($src.Url)" "Failed to set $($src.Name) URL"
    }
}

# Fetch all remotes — track which ones succeed so we can fall back gracefully
# if a source is taken down or unreachable.
Write-Host "`n[3/14] Fetching all remotes..." -ForegroundColor Yellow
$fetchStatus = @{}

foreach ($src in $upstreamSources) {
    if (Invoke-GitCommand "git fetch $($src.Name)" "Failed to fetch $($src.Name)") {
        $fetchStatus[$src.Name] = $true
        Write-Host "  $($src.Name) ($($src.Label)) : OK" -ForegroundColor Green
    } else {
        $fetchStatus[$src.Name] = $false
        Write-Host "  $($src.Name) ($($src.Label)) : UNREACHABLE — will skip this source" -ForegroundColor Yellow
    }
}
if (Invoke-GitCommand "git fetch origin" "Failed to fetch origin") {
    $fetchStatus["origin"] = $true
    Write-Host "  origin : OK" -ForegroundColor Green
} else {
    $fetchStatus["origin"] = $false
    Write-Host "  origin : UNREACHABLE" -ForegroundColor Yellow
}

# If every upstream is down, there is nothing to sync from — abort with a clear message.
$availableUpstreams = $upstreamSources.Name | Where-Object { $fetchStatus[$_] }
if ($availableUpstreams.Count -eq 0) {
    Write-Host ""
    Write-Host "ERROR: All $($upstreamSources.Count) upstream sources are unreachable. Cannot sync." -ForegroundColor Red
    foreach ($src in $upstreamSources) {
        Write-Host "  - $($src.Label)   ($($src.Name))" -ForegroundColor Red
    }
    Write-Host "Check your network connection, VPN, or whether all sources have been taken down." -ForegroundColor Red
    exit 1
}

if ($availableUpstreams.Count -lt $upstreamSources.Count) {
    Write-Host "WARNING: Only $($availableUpstreams.Count) of $($upstreamSources.Count) upstream sources are reachable. Continuing with the available ones." -ForegroundColor Yellow
}

# Compare commits between all available sources
Write-Host "`n[4/14] Comparing commits between local, available upstreams, and origin..." -ForegroundColor Yellow
$CURRENT_BRANCH = git rev-parse --abbrev-ref HEAD
$LOCAL = git rev-parse HEAD
if (-not $LOCAL) {
    Write-Host "ERROR: Failed to resolve local HEAD. Are you on a valid branch?" -ForegroundColor Red
    exit 1
}

# Resolve HEAD for each available upstream, skipping any that fail to rev-parse.
$upstreamHeads = @{}
foreach ($remote in $availableUpstreams) {
    $head = git rev-parse "$remote/main" 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) {
        $upstreamHeads[$remote] = $head.Trim()
    } else {
        Write-Host "Warning: could not resolve $remote/main — skipping it." -ForegroundColor Yellow
        $fetchStatus[$remote] = $false
    }
}

if ($upstreamHeads.Count -eq 0) {
    Write-Host "ERROR: No upstream remote had a resolvable 'main' branch." -ForegroundColor Red
    Write-Host "The available sources may use a different default branch name." -ForegroundColor Red
    exit 1
}

$ORIGIN = $null
if ($fetchStatus["origin"]) {
    $ORIGIN = git rev-parse origin/main 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ORIGIN) {
        Write-Host "Warning: could not resolve origin/main — origin sync will be skipped." -ForegroundColor Yellow
        $ORIGIN = $null
    }
}

Write-Host "Current branch: $CURRENT_BRANCH"
Write-Host "Local HEAD: $LOCAL"
foreach ($remote in $upstreamHeads.Keys) {
    Write-Host "$remote HEAD: $($upstreamHeads[$remote])"
}
if ($ORIGIN) { Write-Host "Origin HEAD: $ORIGIN" } else { Write-Host "Origin HEAD: (unavailable)" }

$source = "none"
$hasChanges = $false

# Determine which available upstream is newest by commit timestamp
$newerUpstream = $null
$newerUpstreamCommit = $null
$newerUpstreamDate = 0
foreach ($remote in $upstreamHeads.Keys) {
    $date = git log -1 --format=%ct $upstreamHeads[$remote] 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $date) {
        Write-Host "Warning: could not read commit timestamp for $remote — skipping it." -ForegroundColor Yellow
        continue
    }
    if ([int]$date -gt [int]$newerUpstreamDate) {
        $newerUpstreamDate = [int]$date
        $newerUpstream = $remote
        $newerUpstreamCommit = $upstreamHeads[$remote]
    }
}

if (-not $newerUpstream) {
    Write-Host "ERROR: Could not determine the newest upstream — no commit timestamps could be read." -ForegroundColor Red
    exit 1
}

Write-Host "$newerUpstream is the newest available upstream" -ForegroundColor Cyan

# Simple comparison: if upstream has different commits, pull from upstream
# If origin has different commits, pull from origin
if ($LOCAL -ne $newerUpstreamCommit) {
    $source = $newerUpstream
    $hasChanges = $true
    Write-Host "$newerUpstream has different commits than local - will sync from upstream" -ForegroundColor Green
}
elseif ($ORIGIN -and $LOCAL -ne $ORIGIN) {
    $source = "origin"
    $hasChanges = $true
    Write-Host "Origin has different commits than local - will sync from origin" -ForegroundColor Green
}
elseif (-not $ORIGIN) {
    Write-Host "Origin is unavailable and local matches the newest upstream — nothing more to sync." -ForegroundColor Yellow
}
else {
    Write-Host "All sources are in sync" -ForegroundColor Green
}

if (-not $hasChanges) {
    Write-Host "No changes detected. Exiting." -ForegroundColor Green
    exit 0
}

# Look up the merge branch and message for the chosen source from the config table.
$sourceConfig = $upstreamSources | Where-Object { $_.Name -eq $source }
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

# Capture pre-merge HEAD so we can restore fork-specific features (Coach) that the
# -X theirs merge may overwrite. This is saved BEFORE the merge starts.
$preMergeHead = git rev-parse HEAD
Write-Host "  Pre-merge HEAD: $preMergeHead (saved for Coach feature restoration)" -ForegroundColor DarkGray

Write-Host "`n[5/14] Merging from $source into main..." -ForegroundColor Yellow
$null = Invoke-GitCommand "git merge $mergeBranch --allow-unrelated-histories -X theirs -m '$mergeMessage'" "Failed to merge from $source"

# Resolve conflicts (merge may have stopped with conflicts even with -X theirs,
# e.g. file-location/rename conflicts that -X theirs can't auto-resolve)
Write-Host "`n[6/14] Resolving merge conflicts..." -ForegroundColor Yellow
if (Test-MergeInProgress) {
    $null = Resolve-MergeConflicts $mergeMessage
}

# Verify merge is complete before proceeding
if (Test-MergeInProgress) {
    Write-Host "ERROR: merge is still in progress after conflict resolution — aborting" -ForegroundColor Red
    exit 1
}

# Fix any case-collision duplicates introduced by the upstream merge
Write-Host "`n  Checking for case-collision duplicates..." -ForegroundColor Yellow
Repair-CaseCollisions

# Pull latest from origin (only after upstream merge)
if ($isUpstreamSource) {
    Write-Host "`n[7/14] Pulling latest changes from origin..." -ForegroundColor Yellow
    # Stash any uncommitted changes before rebase
    $hasStash = $false
    $dirtyFiles = git status --porcelain
    if ($dirtyFiles) {
        Write-Host "Stashing uncommitted changes before rebase..." -ForegroundColor Yellow
        $null = Invoke-GitCommand "git stash" "Failed to stash changes"
        $hasStash = $true
    }
    $null = Invoke-GitCommand "git pull origin main --rebase -X theirs" "Failed to pull from origin"

    # Resolve rebase conflicts — loop until the rebase fully completes.
    # A rebase can stop at many commits; the old code only resolved one batch.
    Write-Host "`n[8/14] Resolving rebase conflicts..." -ForegroundColor Yellow
    $null = Resolve-RebaseConflicts "rebase"

    # Verify rebase is complete before proceeding
    if (Test-RebaseInProgress) {
        Write-Host "ERROR: rebase is still in progress after conflict resolution — aborting" -ForegroundColor Red
        Invoke-GitCommand "git rebase --abort" "Failed to abort rebase"
        exit 1
    }

    # Fix any case-collision duplicates introduced by the rebase
    Write-Host "`n  Checking for case-collision duplicates..." -ForegroundColor Yellow
    Repair-CaseCollisions

    # Restore stashed changes
    if ($hasStash) {
        Write-Host "Restoring stashed changes..." -ForegroundColor Yellow
        $null = Invoke-GitCommand "git stash pop" "Failed to pop stash"
    }
}

# ── Fork-specific feature preservation (generic) ─────────────────────────────
# The -X theirs merge silently overwrites or deletes ANY fork-specific code — not
# just Coach, but every feature this fork has added or will add in the future.
# Rather than hardcode a list of files (which would need manual updates every time
# a new feature is built), this step automatically detects and restores ALL
# fork-specific changes by comparing the pre-merge tree against upstream.
#
# How it works:
#   1. Before the merge (step 5), we saved $preMergeHead.
#   2. We also need the upstream HEAD we're merging from — saved below as
#      $upstreamMergeHead. This is the commit we're merging INTO our branch.
#   3. We compute two sets of files:
#      a) Fork-only files: exist in pre-merge but NOT in upstream
#         (git diff --diff-filter=A upstream preMerge --name-only)
#         → These are ENTIRELY ours. If the merge deleted them, restore fully.
#      b) Fork-modified shared files: exist in both but differ between upstream
#         and our pre-merge version
#         (git diff --diff-filter=M upstream preMerge --name-only)
#         → After the merge, if the file now matches upstream's version (meaning
#           -X theirs overwrote our changes), restore our pre-merge version.
#   4. Every restored file is logged with a REVIEW NEEDED warning, because
#      restoring a shared file means any upstream changes to it in this sync
#      are lost and must be manually merged.
#
# This is fully generic: any new feature you build is automatically protected
# without touching this script. The only thing that could defeat it is a file
# that upstream and the fork modify in the SAME way (same content) — but that
# means there's nothing to restore.
if ($isUpstreamSource -and $preMergeHead) {
    Write-Host "`n[9/14] Preserving fork-specific changes..." -ForegroundColor Yellow

    # The upstream HEAD we're merging from. $mergeBranch was set earlier (e.g.
    # "upstream-ryanbr/main"). Resolve it to a commit hash for reliable diffs.
    $upstreamMergeHead = git rev-parse "$mergeBranch" 2>$null
    if (-not $upstreamMergeHead) {
        Write-Host "  WARNING: could not resolve upstream HEAD for fork-preservation diff — skipping" -ForegroundColor Yellow
        $upstreamMergeHead = $null
    }

    if ($upstreamMergeHead) {
        $upstreamMergeHead = $upstreamMergeHead.Trim()

        # Fork-only files: added by the fork, not in upstream.
        # --diff-filter=A selects files Added in the preMerge side relative to upstream.
        $forkOnlyFiles = git diff --diff-filter=A --name-only "$upstreamMergeHead" "$preMergeHead" 2>$null
        if ($forkOnlyFiles) { $forkOnlyFiles = $forkOnlyFiles | Where-Object { $_.Trim() } }

        # Fork-modified shared files: exist in both but the fork changed them.
        # --diff-filter=M selects files Modified between upstream and preMerge.
        $forkModifiedShared = git diff --diff-filter=M --name-only "$upstreamMergeHead" "$preMergeHead" 2>$null
        if ($forkModifiedShared) { $forkModifiedShared = $forkModifiedShared | Where-Object { $_.Trim() } }

        Write-Host "  Fork-only files: $($forkOnlyFiles.Count)" -ForegroundColor DarkGray
        Write-Host "  Fork-modified shared files: $($forkModifiedShared.Count)" -ForegroundColor DarkGray

        $restoredFiles = @()

        # Tier 1: restore fork-only files if the merge deleted them.
        # These are entirely ours — upstream never touches them — so restoring
        # the full file is always correct.
        if ($forkOnlyFiles) {
            Write-Host "  Checking fork-only files..." -ForegroundColor DarkGray
            foreach ($file in $forkOnlyFiles) {
                $file = $file.Trim()
                if (-not $file) { continue }
                if (-not (Test-Path $file)) {
                    Write-Host "  RESTORING (deleted by merge): $file" -ForegroundColor Yellow
                    $dir = Split-Path $file -Parent
                    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    $null = Invoke-GitCommand "git show '${preMergeHead}:${file}' > '$file' 2>`$null" "Failed to restore $file"
                    if (Test-Path $file) {
                        $restoredFiles += $file
                    } else {
                        Write-Host "  WARNING: could not restore $file" -ForegroundColor Red
                    }
                }
            }
        }

        # Tier 2: restore fork-modified shared files if -X theirs overwrote our changes.
        # Detection: after the merge, if the file's content matches upstream's version
        # (meaning our changes were discarded), restore our pre-merge version.
        # We compare hashes, not content, for speed and reliability.
        if ($forkModifiedShared) {
            Write-Host "  Checking fork-modified shared files..." -ForegroundColor DarkGray
            foreach ($file in $forkModifiedShared) {
                $file = $file.Trim()
                if (-not $file) { continue }
                if (-not (Test-Path $file)) {
                    # File was in both but is now gone — merge deleted it. Restore ours.
                    Write-Host "  RESTORING (shared file deleted): $file" -ForegroundColor Yellow
                    $dir = Split-Path $file -Parent
                    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    $null = Invoke-GitCommand "git show '${preMergeHead}:${file}' > '$file' 2>`$null" "Failed to restore $file"
                    if (Test-Path $file) {
                        $restoredFiles += $file
                        Write-Host "    Restored fork version — review for lost upstream changes" -ForegroundColor DarkYellow
                    }
                    continue
                }

                # Compare post-merge file hash against upstream's hash for this file.
                # If they match, -X theirs took upstream's version and our changes are gone.
                $postMergeBlob = git hash-object "$file" 2>$null
                $upstreamBlob = git rev-parse "${upstreamMergeHead}:${file}" 2>$null
                $forkBlob = git rev-parse "${preMergeHead}:${file}" 2>$null

                if ($postMergeBlob -and $upstreamBlob -and $forkBlob `
                    -and $postMergeBlob -eq $upstreamBlob -and $forkBlob -ne $upstreamBlob) {
                    # Post-merge matches upstream but fork had different content → overwritten.
                    Write-Host "  RESTORING (fork changes overwritten by -X theirs): $file" -ForegroundColor Yellow
                    $null = Invoke-GitCommand "git show '${preMergeHead}:${file}' > '$file' 2>`$null" "Failed to restore $file"
                    $restoredFiles += $file
                    Write-Host "    Restored fork version — review for lost upstream changes" -ForegroundColor DarkYellow
                }
            }
        }

        # Tier 3: marker-based detection for partial overwrites.
        # The blob-hash comparison in Tier 2 only catches a COMPLETE overwrite (post-merge
        # blob == upstream blob). If upstream ALSO changed the file in this sync, the
        # post-merge blob will differ from upstream's (it has upstream's new changes), so
        # Tier 2 won't flag it — even though -X theirs may have silently dropped the fork's
        # specific additions in conflicting hunks. This tier checks for known fork-specific
        # markers (regex patterns) that MUST be present in certain files. If a marker is
        # missing after the merge, the fork's changes were partially overwritten.
        #
        # Unlike Tier 2, this tier does NOT auto-restore — because the file has upstream
        # changes we want to keep, blindly restoring the pre-merge version would lose them.
        # Instead it warns loudly so the operator can manually merge.
        $forkMarkerChecks = @(
            @{ File = "Strand/Collect/StorePaths.swift"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID" }
            @{ File = "Strand/Collect/RawHistoryArchive.swift"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID" }
            @{ File = "StrandiOSShared/WidgetSnapshot.swift"; Pattern = "group\.com\.evoveo\.noop"; Desc = "evoveo App Group" }
            @{ File = "Packages/NoopLocalAccess/Sources/NoopLocalAccessCore/LocalAccessCore.swift"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID" }
            @{ File = "Strand/Screens/SettingsView.swift"; Pattern = "showsGitHubDistributionLinks"; Desc = "distribution UI gating" }
            @{ File = "Strand/Liquid/LiquidTodayView.swift"; Pattern = "viewportWidth"; Desc = "#1532 width cap" }
            @{ File = "Strand/Screens/ScreenScaffold.swift"; Pattern = "viewportWidth"; Desc = "#1532 width cap" }
        )
        foreach ($check in $forkMarkerChecks) {
            $f = $check.File
            if (-not (Test-Path $f)) { continue }
            $postContent = Get-Content $f -Raw -ErrorAction SilentlyContinue
            if (-not $postContent) { continue }
            if ($postContent -notmatch $check.Pattern) {
                # Check if the pre-merge version HAD the marker — if so, it was lost.
                $preContent = git show "${preMergeHead}:$f" 2>$null
                if ($preContent -and ($preContent -match $check.Pattern)) {
                    Write-Host "  WARNING: fork marker lost in $f ($($check.Desc))" -ForegroundColor Red
                    Write-Host "    The file has upstream changes but fork-specific code was dropped." -ForegroundColor DarkYellow
                    Write-Host "    Manually merge: git diff ${preMergeHead}..HEAD -- $f" -ForegroundColor DarkYellow
                }
            }
        }

        # Commit all restored files
        if ($restoredFiles.Count -gt 0) {
            $existingRestored = $restoredFiles | Where-Object { Test-Path $_ }
            if ($existingRestored) {
                git add $existingRestored
                $stagedFork = git diff --cached --name-only
                if ($stagedFork) {
                    $null = Invoke-GitCommand "git commit -m 'Restore fork-specific changes after upstream sync [skip ci]'" "Failed to commit fork restoration"
                    Write-Host "  Committed $($restoredFiles.Count) restored file(s)" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "  *** REVIEW NEEDED ***" -ForegroundColor DarkYellow
                    Write-Host "  Upstream changes to restored shared files were lost." -ForegroundColor DarkYellow
                    Write-Host "  Run: git diff HEAD~1 -- <file> to see what was restored" -ForegroundColor DarkYellow
                    Write-Host "  Manually merge any upstream improvements into the restored files." -ForegroundColor DarkYellow
                }
            }
        } else {
            Write-Host "  All fork-specific changes intact — no restoration needed" -ForegroundColor Green
        }
    }
}

# Apply evoveo identifier changes (only after upstream merge)
if ($isUpstreamSource) {
    Write-Host "`n[10/14] Applying evoveo identifier changes..." -ForegroundColor Yellow
    
    # Each entry: file path, regex patterns, replacement strings.
    # Files with special post-processing (project.yml) are handled separately below.
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
            Write-Host "Updated $($upd.File)" -ForegroundColor Green
            $filesUpdated++
        }
    }
    
    # Update project.yml — needs special post-processing beyond simple regex replace
    if (Update-FileContent "project.yml" @('group\.com\.noopapp\.noop', 'com\.noopapp\.noop', 'com\.evoveo\.noops') @('group.com.evoveo.noop', 'com.evoveo.noop', 'com.evoveo.noop')) {
        # Remove Data/AppleDemoSeeder.swift line separately
        $content = Get-Content "project.yml" -Raw
        $content = $content -replace '- "Data/AppleDemoSeeder\.swift".*', ''
        # Strip .staging from iOS-family bundle IDs (PR #27 fix — AltStore requires the production
        # bundle ID, not .staging). Leave the macOS bundle ID and APP_GROUP_ID unchanged.
        # iOS app target: identified by the "Ship every *.appiconset" comment that only the iOS target has.
        $content = $content -replace '(PRODUCT_BUNDLE_IDENTIFIER: com\.evoveo\.noop)\.staging(\r?\n        PRODUCT_NAME: "NOOP Staging"\r?\n        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\r?\n        # Ship every)', '$1$2'
        # Widgets, watch, complications, and WKCompanion — unique patterns, safe to replace globally.
        $content = $content -replace 'com\.evoveo\.noop\.staging\.widgets', 'com.evoveo.noop.widgets'
        $content = $content -replace 'com\.evoveo\.noop\.staging\.watch', 'com.evoveo.noop.watch'
        $content = $content -replace 'WKCompanionAppBundleIdentifier: com\.evoveo\.noop\.staging', 'WKCompanionAppBundleIdentifier: com.evoveo.noop'
        Set-Content "project.yml" -Value $content -NoNewline
        Write-Host "Updated project.yml" -ForegroundColor Green
        $filesUpdated++
    }
    
    if ($filesUpdated -gt 0) {
        $evoveoFiles = @(
            "StrandiOSShared/WidgetSnapshot.swift",
            "project.yml",
            "altstore-source.json",
            "Packages/NoopLocalAccess/Sources/NoopLocalAccessCore/LocalAccessCore.swift",
            "Strand/Collect/RawHistoryArchive.swift",
            "Strand/Collect/StorePaths.swift"
        )
        $existingFiles = $evoveoFiles | Where-Object { Test-Path $_ }
        if ($existingFiles) {
            git add $existingFiles
        }
        $stagedChanges = git diff --cached --name-only
        if ($stagedChanges) {
            $null = Invoke-GitCommand "git commit -m 'Apply evoveo identifier changes after upstream sync [skip ci]'" "Failed to commit evoveo identifier changes"
        } else {
            Write-Host "No changes to commit after evoveo identifier updates" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No files needed updating" -ForegroundColor Yellow
    }
}

# Re-apply MOVA branding (only after upstream merge — upstream still uses "NOOP")
if ($isUpstreamSource) {
    Write-Host "`n[11/14] Re-applying MOVA branding..." -ForegroundColor Yellow

    # 1. project.yml — CFBundleName, CFBundleDisplayName, and usage descriptions
    if (Test-Path "project.yml") {
        $content = Get-Content "project.yml" -Raw
        $content = $content -creplace 'CFBundleName:\s*NOOP\b', 'CFBundleName: MOVA'
        $content = $content -creplace 'CFBundleDisplayName:\s*NOOP\b', 'CFBundleDisplayName: MOVA'
        $content = $content -creplace '(NS\w+UsageDescription:\s*")NOOP ', '$1MOVA '
        Set-Content "project.yml" -Value $content -NoNewline
        Write-Host "  Updated project.yml (display name + usage descriptions)" -ForegroundColor Green
    }

    # 2. Swift files — replace NOOP → MOVA inside double-quoted string literals only.
    #    Uses \bNOOP\b so identifiers like NOOPiOS, NOOPWatch, NOOPAppIntents are untouched
    #    (no word boundary between NOOP and the following uppercase letter).
    $swiftDirs = @("Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch", "NOOPWatchComplications")
    $swiftCount = 0
    foreach ($dir in $swiftDirs) {
        if (-not (Test-Path $dir)) { continue }
        $files = Get-ChildItem -Path $dir -Filter "*.swift" -Recurse -File
        foreach ($file in $files) {
            $content = Get-Content $file.FullName -Raw
            if (-not $content) { continue }
            $original = $content
            # Replace \bNOOP\b inside double-quoted string literals only.
            # The regex matches complete string literals (handling escaped chars),
            # then the callback replaces NOOP → MOVA within each match.
            $content = [regex]::Replace($content, '"(?:[^"\\]|\\.)*"', {
                param($m) ($m.Value -creplace '\bNOOP\b', 'MOVA')
            })
            if ($content -ne $original) {
                Set-Content $file.FullName -Value $content -NoNewline
                $swiftCount++
            }
        }
    }
    Write-Host "  Updated $swiftCount Swift file(s) with MOVA branding" -ForegroundColor Green

    # 3. xcstrings files — replace NOOP → MOVA in both keys and values.
    #    \bNOOP\b is safe here: xcstrings keys are user-facing strings, never code
    #    identifiers like NOOPWatch, so there are no false positives.
    $xcstringsFiles = @(
        "Strand/Resources/Localizable.xcstrings",
        "NOOPWatch/Localizable.xcstrings",
        "NOOPWatchComplications/Localizable.xcstrings"
    )
    $xcstringsCount = 0
    foreach ($file in $xcstringsFiles) {
        if (-not (Test-Path $file)) { continue }
        $content = Get-Content $file -Raw
        if (-not $content) { continue }
        $original = $content
        $content = $content -creplace '\bNOOP\b', 'MOVA'
        if ($content -ne $original) {
            Set-Content $file -Value $content -NoNewline
            $xcstringsCount++
        }
    }
    Write-Host "  Updated $xcstringsCount xcstrings file(s) with MOVA branding" -ForegroundColor Green

    # Commit the branding changes
    $movaFiles = @("project.yml") +
        (Get-ChildItem -Path $swiftDirs -Filter "*.swift" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) +
        $xcstringsFiles
    $existingMovaFiles = $movaFiles | Where-Object { Test-Path $_ }
    if ($existingMovaFiles) {
        git add $existingMovaFiles
    }
    $stagedMova = git diff --cached --name-only
    if ($stagedMova) {
        $null = Invoke-GitCommand "git commit -m 'Re-apply MOVA branding after upstream sync [skip ci]'" "Failed to commit MOVA branding"
        Write-Host "  Committed MOVA branding changes" -ForegroundColor Green
    } else {
        Write-Host "  No MOVA branding changes needed (already applied)" -ForegroundColor Yellow
    }
}

# Re-apply the TestFlight/App Store distribution UI gating in SettingsView.swift (only after upstream
# merge — upstream doesn't have this fork-only feature, so a merge can wipe it out).
#
# Background: com.evoveo.noop is the SAME bundle id whether the install is a genuine sideload/dev build
# or a TestFlight/App Store one — bundle id alone can't tell them apart. So instead of gating on the
# bundle id, three pieces of Settings UI are gated at runtime on IOSDiagnostics.isSideloaded (embedded
# provisioning profile + no App Store receipt = sideloaded; a receipt means TestFlight/App Store):
#   1. The "Using MOVA on iPhone" sideloading-expectations card (iphoneExpectations) — re-signing
#      cadence / Data Protection lock / background-BLE limits don't apply to a TestFlight/App Store install.
#   2. "Check for updates" (reads GitHub releases) and "Project home & source" (GitHub link) — a
#      TestFlight/App Store install already updates through Apple's mechanism; GitHub doesn't apply there.
# All three stay visible unconditionally on macOS (unsigned, no App Store route — GitHub is the only
# channel there), so only the iOS call sites are touched.
#
# Patches anchor on small, stable boundary lines rather than replacing the whole block, so they survive
# unrelated upstream edits to the body in between. Each patch is idempotency-guarded (skipped if the
# fork's wrapper is already present) so re-running this step after it has already applied is a no-op.
if ($isUpstreamSource) {
    Write-Host "`n[12/14] Re-applying TestFlight/App Store distribution UI gating..." -ForegroundColor Yellow

    $settingsPath = "Strand/Screens/SettingsView.swift"
    if (Test-Path $settingsPath) {
        $content = Get-Content $settingsPath -Raw
        $original = $content
        $patchCount = 0

        # Patch 1: gate the "Using MOVA on iPhone" sideloading card on isSideloaded.
        if ($content -notmatch [regex]::Escape('if IOSDiagnostics.capture().isSideloaded == true {')) {
            $sideloadPattern = '(?m)^([ \t]*)iosDiagnosticsRow\r?\n[ \t]*iphoneExpectations\r?\n'
            if ($content -match $sideloadPattern) {
                $content = [regex]::Replace($content, $sideloadPattern, {
                    param($m)
                    $indent = $m.Groups[1].Value
                    -join @(
                        "${indent}iosDiagnosticsRow`n"
                        "${indent}// The sideloading callout (re-sign cadence, Data Protection lock, background-BLE limits)`n"
                        "${indent}// only applies to an actual sideload/dev install — gate on IOSDiagnostics.isSideloaded`n"
                        "${indent}// (embedded provisioning profile + no App Store receipt) rather than the bundle id, since`n"
                        "${indent}// com.evoveo.noop is also the bundle id NOOP's normal sideload distribution ships under.`n"
                        "${indent}// A TestFlight/App Store install carries a receipt, so isSideloaded is false and none of`n"
                        "${indent}// this text (which would be wrong there) is shown.`n"
                        "${indent}if IOSDiagnostics.capture().isSideloaded == true {`n"
                        "${indent}    iphoneExpectations`n"
                        "${indent}}`n"
                    )
                }, 1)
                $patchCount++
                Write-Host "  Patched: sideloading card gated on isSideloaded" -ForegroundColor Green
            } else {
                Write-Host "  Skipped sideloading-card patch: anchor lines not found (upstream layout changed?)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Sideloading card already gated — skipping" -ForegroundColor DarkGray
        }

        # Patch 2: insert the showsGitHubDistributionLinks computed property before aboutCard, if missing.
        if ($content -notmatch [regex]::Escape('showsGitHubDistributionLinks')) {
            $aboutCardPattern = '(?m)^([ \t]*)private var aboutCard: some View \{'
            if ($content -match $aboutCardPattern) {
                $content = [regex]::Replace($content, $aboutCardPattern, {
                    param($m)
                    $indent = $m.Groups[1].Value
                    -join @(
                        "${indent}/// Whether to show `"Check for updates`" and `"Project home & source`" (both point at GitHub,`n"
                        "${indent}/// NOOP's sideload/dev release channel). macOS ships unsigned with no App Store route, so`n"
                        "${indent}/// GitHub is the ONLY channel there — always show it. On iOS the same bundle id`n"
                        "${indent}/// (com.evoveo.noop) ships either as a genuine sideload/dev install OR via TestFlight/App`n"
                        "${indent}/// Store, so gate on the runtime IOSDiagnostics.isSideloaded signal (embedded provisioning`n"
                        "${indent}/// profile + no App Store receipt) rather than the bundle id: a TestFlight/App Store install`n"
                        "${indent}/// already updates through Apple's mechanism, and a GitHub source/releases link doesn't`n"
                        "${indent}/// apply — and isn't appropriate to surface — there.`n"
                        "${indent}private var showsGitHubDistributionLinks: Bool {`n"
                        "${indent}    #if os(macOS)`n"
                        "${indent}    return true`n"
                        "${indent}    #elseif os(iOS)`n"
                        "${indent}    return IOSDiagnostics.capture().isSideloaded == true`n"
                        "${indent}    #else`n"
                        "${indent}    return false`n"
                        "${indent}    #endif`n"
                        "${indent}}`n"
                        "`n"
                        "${indent}private var aboutCard: some View {"
                    )
                }, 1)
                $patchCount++
                Write-Host "  Patched: showsGitHubDistributionLinks property inserted" -ForegroundColor Green
            } else {
                Write-Host "  Skipped showsGitHubDistributionLinks insertion: aboutCard anchor not found" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  showsGitHubDistributionLinks already present — skipping" -ForegroundColor DarkGray
        }

        # Patch 3: wrap "Check for updates" + "Project home & source" in `if showsGitHubDistributionLinks { }`.
        # Anchors on the two boundary lines only (not the ~90-line body), so unrelated edits to the body
        # in between don't break the match. Body indentation is left as-is — Swift doesn't require the
        # extra nesting level to be reflected in whitespace to compile correctly.
        if ($content -notmatch [regex]::Escape('if showsGitHubDistributionLinks {')) {
            $startPattern = '(?m)^([ \t]*)// Check for updates — a single, user-initiated read of GitHub''s public releases API\.'
            $endPattern = '(?m)^([ \t]*)\.accessibilityLabel\("Project home and source code on GitHub"\)'
            if ($content -match $startPattern -and $content -match $endPattern) {
                $content = [regex]::Replace($content, $startPattern, {
                    param($m)
                    $indent = $m.Groups[1].Value
                    "${indent}if showsGitHubDistributionLinks {`n${indent}// Check for updates — a single, user-initiated read of GitHub's public releases API."
                }, 1)
                $content = [regex]::Replace($content, $endPattern, {
                    param($m)
                    $indent = $m.Groups[1].Value
                    "${indent}.accessibilityLabel(`"Project home and source code on GitHub`")`n${indent}}"
                }, 1)
                $patchCount++
                Write-Host "  Patched: Check for updates + Project home & source wrapped in showsGitHubDistributionLinks" -ForegroundColor Green
            } else {
                Write-Host "  Skipped GitHub-links wrap: start/end anchor lines not found (upstream layout changed?)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  GitHub-links block already wrapped — skipping" -ForegroundColor DarkGray
        }

        if ($content -ne $original) {
            Set-Content $settingsPath -Value $content -NoNewline
            git add $settingsPath
            $stagedSettings = git diff --cached --name-only
            if ($stagedSettings) {
                $null = Invoke-GitCommand "git commit -m 'Re-apply TestFlight/App Store distribution UI gating after upstream sync [skip ci]'" "Failed to commit distribution UI gating"
                Write-Host "  Committed $patchCount distribution-gating patch(es)" -ForegroundColor Green
            }
        } else {
            Write-Host "  No distribution-gating changes needed (already applied)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Skipped: $settingsPath not found" -ForegroundColor Yellow
    }
}

# Re-apply the #1532 recurrence fix: the GeometryReader + hard width cap on the scroll content
# (only after upstream merge — upstream #1532 only merged `.scrollBounceBehavior(.basedOnSize)`,
# which the PR author themselves said was "insufficient on its own." The width cap was withdrawn
# by the upstream reviewer due to concerns about macOS layout and content clipping. This fork's
# version addresses both: the GeometryReader is iOS-only (guarded by #if os(iOS)), and `.frame
# (width:)` sets the reported content width without clipping — children wrap/truncate per
# SwiftUI's normal layout. Without this, navigating between yesterday and today on the home screen
# can trigger horizontal panning when the header row briefly overflows during a day-switch.)
if ($isUpstreamSource) {
    Write-Host "`n[12b/14] Re-applying #1532 recurrence fix (scroll content width cap)..." -ForegroundColor Yellow

    $patchedFiles = @()

    # 1. LiquidTodayView.swift — add viewportWidth @State and the width cap on the scroll content.
    $todayPath = "Strand/Liquid/LiquidTodayView.swift"
    if (Test-Path $todayPath) {
        $content = Get-Content $todayPath -Raw
        $original = $content

        # Add the @State viewportWidth property if missing (after headerControlsWidth).
        if ($content -notmatch [regex]::Escape('@State private var viewportWidth: CGFloat = 0')) {
            $content = $content -replace '(@State private var headerControlsWidth = NoopMetrics\.headerControlReserveWidth\r?\n)',
                '$1
    #if os(iOS)
    /// #1532 recurrence fix: the real viewport width, measured by a background GeometryReader on the
    /// ScrollView. Used to hard-cap the scroll content column so no child can ever widen the
    /// ScrollView''s reported content size and enable horizontal panning. iOS-only; macOS keeps its
    /// existing 680pt-centered layout. Zero until the first layout pass, so the initial frame uses
    /// `.infinity` (no cap) — the cap locks in on the very next redraw.
    @State private var viewportWidth: CGFloat = 0
    #endif
'
            Write-Host "  Added viewportWidth @State to LiquidTodayView" -ForegroundColor Green
        }

        # Add the width cap in the #else branch of the macOS frame (if not already present).
        if ($content -notmatch [regex]::Escape('.frame(width: viewportWidth > 0 ? viewportWidth : .infinity)')) {
            # Replace the macOS-only frame block with an #if/#else that adds the iOS width cap.
            $content = $content -replace '(?m)^(\s*)#if os\(macOS\)\r?\n\s*// Keep the phone-shaped column readable.*?\r?\n\s*\.frame\(maxWidth: 680\)\r?\n\s*\.frame\(maxWidth: \.infinity\)\r?\n\s*#endif\r?\n',
                '$1#if os(macOS)
$1   // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
$1   // ScrollView background (full-bleed), so constraining the content column here doesn''t touch it.
$1   .frame(maxWidth: 680)
$1   .frame(maxWidth: .infinity)
$1#else
$1   // #1532 recurrence fix: hard-cap the scroll content to the measured viewport width so no
$1   // child can ever widen the ScrollView''s reported content size and enable horizontal panning.
$1   .frame(width: viewportWidth > 0 ? viewportWidth : .infinity)
$1#endif
'
            Write-Host "  Added width cap to LiquidTodayView scroll content" -ForegroundColor Green
        }

        # Add the background GeometryReader to measure viewport width (if not already present).
        if ($content -notmatch [regex]::Escape('#1532 recurrence fix: measure the viewport width')) {
            $content = $content -replace '(\.scrollBounceBehavior\(\.basedOnSize, axes: \.horizontal\)\r?\n\s*)(#endif)',
                '$1// #1532 recurrence fix: measure the viewport width via a background GeometryReader so we
        // can hard-cap the scroll content above. Background so it doesn''t affect layout; iOS-only.
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { viewportWidth = g.size.width }
                    .onChange(of: g.size.width) { _, newWidth in viewportWidth = newWidth }
            }
        }
        $2'
            Write-Host "  Added background GeometryReader to LiquidTodayView" -ForegroundColor Green
        }

        if ($content -ne $original) {
            Set-Content $todayPath -Value $content -NoNewline
            $patchedFiles += $todayPath
        }
    }

    # 2. ScreenScaffold.swift — same fix for every screen that renders through ScreenScaffold.
    $scaffoldPath = "Strand/Screens/ScreenScaffold.swift"
    if (Test-Path $scaffoldPath) {
        $content = Get-Content $scaffoldPath -Raw
        $original = $content

        # Add the @State viewportWidth property if missing (after hSizeClass).
        if ($content -notmatch [regex]::Escape('@State private var viewportWidth: CGFloat = 0')) {
            $content = $content -replace '(@Environment\(\.horizontalSizeClass\) private var hSizeClass\r?\n\s*#endif)',
                '$1
    /// #1532 recurrence fix: the real viewport width, measured by a background GeometryReader.
    /// Used to hard-cap the scroll content column so no child can widen the ScrollView''s reported
    /// content size and enable horizontal panning. iOS-only; macOS is unchanged. Zero until the
    /// first layout pass, so the initial frame uses `.infinity` (no cap) — the cap locks in on
    /// the very next redraw.
    @State private var viewportWidth: CGFloat = 0
    #endif'
            Write-Host "  Added viewportWidth @State to ScreenScaffold" -ForegroundColor Green
        }

        # Add the width cap after the existing frame chain (if not already present).
        if ($content -notmatch [regex]::Escape('#1532 recurrence fix: hard-cap the entire scroll content')) {
            $content = $content -replace '(\.frame\(maxWidth: \.infinity, alignment: \.center\)\r?\n)(\s*#else)',
                '$1            // #1532 recurrence fix: hard-cap the entire scroll content to the measured viewport
            // width so no child can ever widen the ScrollView''s reported content size and enable
            // horizontal panning. iOS-only; macOS is unchanged. `.frame(width:)` sets the reported
            // content width without clipping — children that need more wrap/truncate per SwiftUI''s
            // normal layout. Zero on the first frame, so fall back to `.infinity` (no cap).
            .frame(width: viewportWidth > 0 ? viewportWidth : .infinity)
$2'
            Write-Host "  Added width cap to ScreenScaffold scroll content" -ForegroundColor Green
        }

        # Add the background GeometryReader to measure viewport width (if not already present).
        if ($content -notmatch [regex]::Escape('#1532 recurrence fix: measure the viewport width')) {
            $content = $content -replace '(\.scrollBounceBehavior\(\.basedOnSize, axes: \.horizontal\)\r?\n\s*)(#endif)',
                '$1// #1532 recurrence fix: measure the viewport width via a background GeometryReader so we
        // can hard-cap the scroll content above. Background so it doesn''t affect layout; iOS-only.
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { viewportWidth = g.size.width }
                    .onChange(of: g.size.width) { _, newWidth in viewportWidth = newWidth }
            }
        }
        $2'
            Write-Host "  Added background GeometryReader to ScreenScaffold" -ForegroundColor Green
        }

        if ($content -ne $original) {
            Set-Content $scaffoldPath -Value $content -NoNewline
            $patchedFiles += $scaffoldPath
        }
    }

    # Commit the #1532 recurrence fix patches
    if ($patchedFiles.Count -gt 0) {
        git add $patchedFiles
        $staged1532 = git diff --cached --name-only
        if ($staged1532) {
            $null = Invoke-GitCommand "git commit -m 'Re-apply #1532 recurrence fix (scroll content width cap) after upstream sync [skip ci]'" "Failed to commit #1532 recurrence fix"
            Write-Host "  Committed #1532 recurrence fix to $($patchedFiles.Count) file(s)" -ForegroundColor Green
        }
    } else {
        Write-Host "  No #1532 recurrence fix changes needed (already applied)" -ForegroundColor Yellow
    }
}

# Preserve iOS CI/CD infrastructure (only after upstream merge)
if ($isUpstreamSource) {
    Write-Host "`n[13/14] Preserving iOS CI/CD infrastructure..." -ForegroundColor Yellow
    
    $iosFiles = @(
        ".github/workflows/ios-testflight.yml",
        "codemagic.yaml",
        "exportOptions.plist"
    )
    
    foreach ($file in $iosFiles) {
        if (Test-Path $file) {
            Write-Host "✓ $file exists, keeping it" -ForegroundColor Green
        } else {
            Write-Host "⚠ WARNING: $file missing - may need manual restoration" -ForegroundColor Yellow
        }
    }
    
    # Check for sync-upstream workflow (should be preserved)
    if (Test-Path ".github/workflows/sync-upstream.yml") {
        Write-Host "✓ sync-upstream.yml exists, keeping it" -ForegroundColor Green
    } else {
        Write-Host "⚠ WARNING: sync-upstream.yml missing" -ForegroundColor Yellow
    }
}

# ── Fork-marker audit ─────────────────────────────────────────────────────
# The single most important lesson from the #1532 recurrence: the generic step 9
# and the specific re-application steps (10-12b) can all fail silently. A regex
# anchor may not match after an upstream refactor, a file may be renamed, or a
# hard reset (instead of a merge) may bypass the entire workflow. This step is
# the safety net: it checks for known fork-specific markers in key files AFTER
# all re-application steps have run. If any marker is missing, it warns LOUDLY
# so the operator knows exactly what to fix before pushing.
#
# Each entry: file path, a regex pattern that MUST be present in the file, and
# a human-readable description of what the marker is. The check is read-only —
# it never modifies files, only reports. This is intentional: automatic
# restoration of a marker whose anchor has shifted could silently patch the
# wrong place. Better to warn and let a human decide.
if ($isUpstreamSource) {
    Write-Host "`n[13b/14] Auditing fork-specific markers..." -ForegroundColor Yellow

    $forkMarkers = @(
        @{ File = "Strand/Collect/StorePaths.swift"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID in StorePaths" }
        @{ File = "Strand/Collect/RawHistoryArchive.swift"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID in RawHistoryArchive" }
        @{ File = "StrandiOSShared/WidgetSnapshot.swift"; Pattern = "group\.com\.evoveo\.noop"; Desc = "evoveo App Group in WidgetSnapshot" }
        @{ File = "Packages/NoopLocalAccess/Sources/NoopLocalAccessCore/LocalAccessCore.swift"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID in LocalAccessCore" }
        @{ File = "altstore-source.json"; Pattern = '"bundleIdentifier":\s*"com\.evoveo\.noop"'; Desc = "evoveo bundle ID in altstore-source" }
        @{ File = "project.yml"; Pattern = "BUNDLE_ID_PREFIX"; Desc = "BUNDLE_ID_PREFIX setting in project.yml" }
        @{ File = "project.yml"; Pattern = "CFBundleDisplayName: MOVA"; Desc = "MOVA display name in project.yml" }
        @{ File = "Strand/Screens/SettingsView.swift"; Pattern = "showsGitHubDistributionLinks"; Desc = "distribution UI gating in SettingsView" }
        @{ File = "Strand/Screens/SettingsView.swift"; Pattern = "IOSDiagnostics\.capture\(\)\.isSideloaded"; Desc = "isSideloaded gate in SettingsView" }
        @{ File = "Strand/Liquid/LiquidTodayView.swift"; Pattern = "viewportWidth"; Desc = "#1532 width cap in LiquidTodayView" }
        @{ File = "Strand/Screens/ScreenScaffold.swift"; Pattern = "viewportWidth"; Desc = "#1532 width cap in ScreenScaffold" }
        @{ File = "Config/BundleIdSecrets.xcconfig"; Pattern = "BUNDLE_ID_PREFIX = com\.evoveo"; Desc = "evoveo prefix in BundleIdSecrets.xcconfig" }
        @{ File = "Config/BundleIdSecrets.xcconfig"; Pattern = "DEVELOPMENT_TEAM = V64Y34CXW2"; Desc = "development team in BundleIdSecrets.xcconfig" }
        @{ File = "sync-upstream.ps1"; Pattern = "1532"; Desc = "#1532 fix step in sync-upstream.ps1 itself" }
        @{ File = "testflight-build.ps1"; Pattern = "TestFlight"; Desc = "TestFlight build script" }
        @{ File = "exportOptions.plist"; Pattern = "com\.evoveo\.noop"; Desc = "evoveo bundle ID in exportOptions.plist" }
    )

    $missingMarkers = @()
    $presentCount = 0

    foreach ($marker in $forkMarkers) {
        $file = $marker.File
        $pattern = $marker.Pattern
        $desc = $marker.Desc

        if (-not (Test-Path $file)) {
            Write-Host "  MISSING FILE: $file ($desc)" -ForegroundColor Red
            $missingMarkers += $marker
            continue
        }

        $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
        if (-not $content) {
            Write-Host "  MISSING MARKER: $file — file empty or unreadable ($desc)" -ForegroundColor Red
            $missingMarkers += $marker
            continue
        }

        if ($content -match $pattern) {
            $presentCount++
        } else {
            Write-Host "  MISSING MARKER: $file — pattern not found: $desc" -ForegroundColor Red
            $missingMarkers += $marker
        }
    }

    Write-Host ""
    Write-Host "  Fork-marker audit: $presentCount/$($forkMarkers.Count) markers present" -ForegroundColor $(if ($missingMarkers.Count -eq 0) { "Green" } else { "Red" })

    if ($missingMarkers.Count -gt 0) {
        Write-Host ""
        Write-Host "  *** FORK-MARKER AUDIT FAILED ***" -ForegroundColor Red
        Write-Host "  $($missingMarkers.Count) marker(s) missing — fork-specific changes were lost." -ForegroundColor Red
        Write-Host "  DO NOT PUSH until these are manually restored:" -ForegroundColor Red
        Write-Host ""
        foreach ($m in $missingMarkers) {
            Write-Host "    - $($m.File): $($m.Desc)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  To restore from the last known-good fork commit:" -ForegroundColor Yellow
        Write-Host "    git show <fork-commit>:<file> > <file>" -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Host "  All fork-specific markers present — safe to push." -ForegroundColor Green
    }
}

# ── Build verification ────────────────────────────────────────────────────
# The final safety net: actually compile the app after sync. If the merge or
# any re-application step produced code that doesn't compile (e.g. a regex
# patch landed in the wrong place, or an upstream API change broke fork code),
# this catches it BEFORE the sync is pushed. A failed build here means the
# sync is incomplete — do not push.
if ($isUpstreamSource) {
    Write-Host "`n[13c/14] Build verification..." -ForegroundColor Yellow

    # Regenerate the Xcode project — project.yml changes (bundle IDs, build number,
    # branding) don't take effect until xcodegen runs.
    Write-Host "  Running xcodegen generate..." -ForegroundColor DarkGray
    $xgenOutput = & xcodegen generate 2>&1
    $xgenExit = $LASTEXITCODE
    if ($xgenOutput) { Write-Host "  $xgenOutput" -ForegroundColor DarkGray }
    if ($xgenExit -ne 0) {
        Write-Host "  xcodegen FAILED (exit $xgenExit) — project.yml may have a syntax error" -ForegroundColor Red
        Write-Host "  DO NOT PUSH — fix project.yml and re-run xcodegen generate" -ForegroundColor Red
    } else {
        Write-Host "  xcodegen succeeded" -ForegroundColor Green

        # Build for simulator — fast, no signing needed, catches compile errors.
        # Use a temporary derivedDataPath so it doesn't interfere with any
        # concurrent Xcode session.
        Write-Host "  Building for iOS Simulator..." -ForegroundColor DarkGray
        $buildOutput = & xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -configuration Debug -derivedDataPath build/sync-verify build 2>&1
        $buildExit = $LASTEXITCODE

        # Check the last few lines for the result
        $buildTail = $buildOutput | Select-Object -Last 5
        foreach ($line in $buildTail) { Write-Host "  $line" -ForegroundColor DarkGray }

        if ($buildExit -ne 0 -or ($buildOutput -notmatch "\*\* BUILD SUCCEEDED \*\*")) {
            Write-Host ""
            Write-Host "  BUILD FAILED — the synced code does not compile." -ForegroundColor Red
            Write-Host "  DO NOT PUSH — fix compile errors first." -ForegroundColor Red
            Write-Host "  Common causes: upstream API change not reflected in fork code," -ForegroundColor Yellow
            Write-Host "  regex patch landed in wrong place, or MOVA branding hit an identifier." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  To see errors: xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \\" -ForegroundColor Yellow
            Write-Host "    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \\" -ForegroundColor Yellow
            Write-Host "    -configuration Debug -derivedDataPath build/sync-verify build 2>&1 | grep -E 'error:|warning:'" -ForegroundColor Yellow
        } else {
            Write-Host "  BUILD SUCCEEDED — synced code compiles cleanly" -ForegroundColor Green

            # Verify the built app's bundle ID — catches a project.yml / xcconfig
            # issue that would ship the wrong bundle ID to TestFlight.
            $appPath = "build/sync-verify/Build/Products/Debug-iphonesimulator/NOOP Staging.app"
            if (Test-Path "$appPath/Info.plist") {
                $bundleId = & plutil -extract CFBundleIdentifier raw "$appPath/Info.plist" 2>$null
                $displayName = & plutil -extract CFBundleDisplayName raw "$appPath/Info.plist" 2>$null
                Write-Host "  Built app bundle ID: $bundleId" -ForegroundColor DarkGray
                Write-Host "  Built app display name: $displayName" -ForegroundColor DarkGray
                if ($bundleId -ne "com.evoveo.noop") {
                    Write-Host ""
                    Write-Host "  WARNING: bundle ID is '$bundleId', expected 'com.evoveo.noop'" -ForegroundColor Red
                    Write-Host "  Check Config/BundleIdSecrets.xcconfig and project.yml" -ForegroundColor Red
                } else {
                    Write-Host "  Bundle ID verified: com.evoveo.noop" -ForegroundColor Green
                }
                if ($displayName -ne "MOVA") {
                    Write-Host "  WARNING: display name is '$displayName', expected 'MOVA'" -ForegroundColor Yellow
                }
            }
        }
    }
}

Write-Host "`n[14/14] Sync Complete ===" -ForegroundColor Cyan
Write-Host "Changes have been applied locally. Review the changes and push when ready:" -ForegroundColor Yellow
Write-Host "  git push origin $CURRENT_BRANCH" -ForegroundColor Green
Write-Host "`nSynced from: $source" -ForegroundColor Cyan
