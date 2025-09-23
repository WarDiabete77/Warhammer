# fix_core_compat.ps1 (version corrigée)
Set-StrictMode -Version Latest

$branch = "fix/core-compat-auto"
$backupRoot = Join-Path (Get-Location) "disabled_for_4_0_backup"
$repoRoot = Get-Location

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git n'est pas installé ou pas sur le PATH. Installe git avant d'exécuter ce script."
    exit 1
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

function Backup-And-Move($path) {
    if (Test-Path $path) {
        $rel = Split-Path -NoQualifier $path
        $destDir = Join-Path $backupRoot (Split-Path $path -Parent)
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        $dest = Join-Path $destDir (Split-Path $path -Leaf)
        Move-Item -Path $path -Destination $dest -Force
        Write-Host "Moved: $path -> $dest"
        return $true
    } else {
        Write-Host "Not found (no move): $path"
        return $false
    }
}

function Read-LinesAsArray($filePath) {
    if (-not (Test-Path $filePath)) { return @() }
    try {
        $raw = Get-Content -Raw -Encoding UTF8 -ErrorAction Stop $filePath
    } catch {
        # fallback to non-raw read
        $raw = (Get-Content -Encoding UTF8 -ErrorAction SilentlyContinue $filePath) -join "`n"
    }
    # split into lines (support CRLF and LF)
    $lines = $raw -split "`r?`n"
    return ,$lines   # ensure array even if single line
}

function Write-Lines($filePath, [string[]]$lines) {
    # backup original
    Copy-Item $filePath "$filePath.bak" -Force -ErrorAction SilentlyContinue
    $lines -join "`n" | Out-File -FilePath $filePath -Encoding utf8
}

function Safe-ReplaceInFile($filePath, $pattern, $replacement) {
    if (-not (Test-Path $filePath)) { return }
    $lines = Read-LinesAsArray $filePath
    if ($lines.Length -eq 0) { return }
    $content = $lines -join "`n"
    $new = [regex]::Replace($content, $pattern, $replacement, 'IgnoreCase')
    if ($new -ne $content) {
        Copy-Item $filePath "$filePath.bak" -Force
        $new | Out-File -FilePath $filePath -Encoding utf8
        Write-Host "Replaced in: $filePath"
    }
}

function CommentLinesMatching($filePath, [string]$regex) {
    if (-not (Test-Path $filePath)) { return }
    $lines = Read-LinesAsArray $filePath
    $changed = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match $regex) {
            if ($lines[$i] -notmatch '^\s*#') {
                $lines[$i] = '# ' + $lines[$i]
                $changed = $true
            }
        }
    }
    if ($changed) {
        Write-Lines $filePath $lines
        Write-Host "Commented matches in: $filePath"
    }
}

function CommentBlockByStart($filePath, [string]$startRegex) {
    if (-not (Test-Path $filePath)) { return }
    $lines = Read-LinesAsArray $filePath
    $changed = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match $startRegex) {
            if ($lines[$i] -notmatch '^\s*#') { $lines[$i] = '# ' + $lines[$i]; $changed = $true }
            # count braces on start line (after adding comment it still contains braces)
            $depth = ([regex]::Matches($lines[$i], '{')).Count - ([regex]::Matches($lines[$i], '}')).Count
            $j = $i + 1
            while ($j -lt $lines.Length -and $depth -gt 0) {
                if ($lines[$j] -notmatch '^\s*#') { $lines[$j] = '# ' + $lines[$j]; $changed = $true }
                $depth += ([regex]::Matches($lines[$j], '{')).Count
                $depth -= ([regex]::Matches($lines[$j], '}')).Count
                $j++
            }
            $i = $j - 1
        }
    }
    if ($changed) {
        Write-Lines $filePath $lines
        Write-Host "Commented blocks starting with regex '$startRegex' in $filePath"
    }
}

# === Begin auto-fix ops ===

git fetch origin
git checkout -b $branch

# Move broken ascension perks if present, create stub
$ascPath = Join-Path $repoRoot "common\ascension_perks\00_ascension_perks.txt"
if (Test-Path $ascPath) {
    Backup-And-Move $ascPath
    $stub = Join-Path $repoRoot "common\ascension_perks\00_ascension_perks_stub.txt"
    if (-not (Test-Path $stub)) {
        @"
# 00_ascension_perks_stub.txt
# Stub to avoid crash — original ascension perks file removed for compatibility with Stellaris 4.0.
# TODO: reimplement perks in 4.0-compatible format.
"@ | Out-File -FilePath $stub -Encoding utf8
        Write-Host "Created stub: $stub"
    }
}

# deposits: comment 'is_for_colonizeable' occurrences
Get-ChildItem -Path (Join-Path $repoRoot "common\deposits") -Filter *.txt -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    CommentLinesMatching $_.FullName '(?i)is_for_colonizeable'
}

# prescripted_countries: change 'flags =' to 'country_flags =' and replace 'ruler = default'
Get-ChildItem -Path (Join-Path $repoRoot "prescripted_countries") -Filter *.txt -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    Safe-ReplaceInFile $_.FullName '^[ \t]*flags[ \t]*=' 'country_flags ='
    Safe-ReplaceInFile $_.FullName '^[ \t]*ruler[ \t]*=[ \t]*default[ \t]*$' 'ruler = { name = "Auto Ruler" species = "HUM" gender = male }'
}

# comment common bad districts/district refs
$unknownDistricts = @("district_hive_1","district_hive_2","district_hive_3","district_nexus_1","district_nexus_2")
Get-ChildItem -Path $repoRoot -Include *.txt -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($d in $unknownDistricts) {
        CommentLinesMatching $_.FullName ("(?i)\b" + [regex]::Escape($d) + "\b")
    }
}

# comment invalid civics in councilors folder (conservative)
$invalidCivics = @(
"civic_anglers","civic_machine_anglers","civic_ascensionists","civic_catalytic_processing",
"civic_crafters","civic_crusader_spirit","civic_death_cult","civic_eager_explorers",
"civic_idyllic_bloom","civic_memorialist","civic_memory_vault","civic_pleasure_seekers",
"civic_pompous_purists","civic_reanimated_armies","civic_relentless_industrialists",
"civic_scavengers","civic_toxic_baths","civic_toxic_baths_individual_machine","civic_heroic_tales",
"civic_dystopian_society","civic_selective_kinship","civic_guided_sapience","civic_hyperspace_specialty",
"civic_dimensional_worship","civic_dark_consortium","civic_sovereign_guardianship","civic_natural_design",
"civic_individual_machine_predictive_analysis","civic_individual_machine_warbots","civic_individual_machine_replication"
)
Get-ChildItem -Path (Join-Path $repoRoot "common\governments\councilors") -Filter *.txt -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($c in $invalidCivics) {
        CommentLinesMatching $_.FullName ("(?i)\b" + [regex]::Escape($c) + "\b")
    }
}

# backup user empire designs if exists
$userEmp = Join-Path $repoRoot "user_empire_designs_v3.4.txt"
if (Test-Path $userEmp) { Backup-And-Move $userEmp }

# add localisation fallback if missing
$locDir = Join-Path $repoRoot "localisation\english"
New-Item -ItemType Directory -Path $locDir -Force | Out-Null
$locFile = Join-Path $locDir "warhammer_economic_categories_l_english.yml"
if (-not (Test-Path $locFile)) {
    @"
l_english:
 planet_administrators: "Administrators"
 planet_military_artisans: "Military Artisans"
 planet_electronics_manufacturers: "Electronics Manufacturers"
 planet_truth_preachers: "Truth Preachers"
 planet_seers: "Seers"
"@ | Out-File -FilePath $locFile -Encoding utf8
    Write-Host "Created localisation fallback: $locFile"
}

# stage + commit
git add -A
$commitMsg = "Auto-fix(core): disable broken ascension perks, comment deprecated tokens, fix prescripted_countries flags/ruler, add localisation fallback"
git commit -m $commitMsg 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Commit created on branch $branch."
    git push origin $branch
    Write-Host "Attempted git push origin $branch (check output above for success)."
} else {
    Write-Host "Nothing to commit or commit failed (check git status)."
}

Write-Host "---- DONE ----"
Write-Host "Backup folder: $backupRoot"
Write-Host "Branch: $branch (check and push if needed)"
Write-Host "Relance Stellaris en -debug_mode et envoie-moi les dernières lignes de error.log si le crash persiste."
