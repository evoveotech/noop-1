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

Write-Host "`n[14/14] Sync Complete ===" -ForegroundColor Cyan
Write-Host "Changes have been applied locally. Review the changes and push when ready:" -ForegroundColor Yellow
Write-Host "  git push origin $CURRENT_BRANCH" -ForegroundColor Green
Write-Host "`nSynced from: $source" -ForegroundColor Cyan
