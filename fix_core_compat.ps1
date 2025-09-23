# fix_core_compat.ps1
# Usage: powershell -ExecutionPolicy Bypass -File .\fix_core_compat.ps1
# NOTE: run at repository root (where common/, prescripted_countries/, localisation/ exist)

Set-StrictMode -Version Latest

# Config
$branch = "fix/core-compat-auto"
$backupRoot = Join-Path (Get-Location) "disabled_for_4_0_backup"
$repoRoot = Get-Location

# Ensure git present
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git n'est pas installé ou pas sur le PATH. Installe git avant d'exécuter ce script."
    exit 1
}

# Create backup dir
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

function Safe-ReplaceInFile($filePath, $pattern, $replacement) {
    if (-not (Test-Path $filePath)) { return }
    $raw = Get-Content $filePath -Raw
    $new = $raw -replace $pattern, $replacement
    if ($new -ne $raw) {
        Copy-Item $filePath "$filePath.bak" -Force
        $new | Out-File -FilePath $filePath -Encoding utf8
        Write-Host "Replaced in: $filePath"
    }
}

function CommentLinesMatching($filePath, [string]$regex) {
    if (-not (Test-Path $filePath)) { return }
    $lines = Get-Content $filePath
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $regex) {
            if ($lines[$i] -notmatch '^\s*#') {
                $lines[$i] = "# " + $lines[$i]
                $changed = $true
            }
        }
    }
    if ($changed) {
        Copy-Item $filePath "$filePath.bak" -Force
        $lines | Out-File -FilePath $filePath -Encoding utf8
        Write-Host "Commented matches in: $filePath"
    }
}

function CommentBlockByStart($filePath, [string]$startRegex) {
    if (-not (Test-Path $filePath)) { return }
    $lines = Get-Content $filePath
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $startRegex) {
            # start commenting from this line until matching braces balance
            if ($lines[$i] -notmatch '^\s*#') { $lines[$i] = "# " + $lines[$i]; $changed = $true }
            $depth = 0
            # count braces on the start line
            $depth += ([regex]::Matches($lines[$i], '{')).Count
            $depth -= ([regex]::Matches($lines[$i], '}')).Count
            $j = $i + 1
            while ($j -lt $lines.Count -and $depth -gt 0) {
                if ($lines[$j] -notmatch '^\s*#') { $lines[$j] = "# " + $lines[$j]; $changed = $true }
                $depth += ([regex]::Matches($lines[$j], '{')).Count
                $depth -= ([regex]::Matches($lines[$j], '}')).Count
                $j++
            }
            # continue scanning after j
            $i = $j - 1
        }
    }
    if ($changed) {
        Copy-Item $filePath "$filePath.bak" -Force
        $lines | Out-File -FilePath $filePath -Encoding utf8
        Write-Host "Commented blocks starting with regex '$startRegex' in $filePath"
    }
}

# 1) create branch
git fetch origin
git checkout -b $branch

# 2) Move the broken ascension perks out (so it's not parsed)
$ascPath = Join-Path $repoRoot "common\ascension_perks\00_ascension_perks.txt"
if (Test-Path $ascPath) {
    Backup-And-Move $ascPath
    # create a safe stub in its place
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

# 3) deposits: comment any 'is_for_colonizeable' lines in all files under common/deposits
Get-ChildItem -Path (Join-Path $repoRoot "common\deposits") -Filter *.txt -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    CommentLinesMatching $_.FullName '(?i)is_for_colonizeable'
}

# 4) prescripted_countries: replace 'flags = ' with 'country_flags = ' and replace 'ruler = default'
Get-ChildItem -Path (Join-Path $repoRoot "prescripted_countries") -Filter *.txt -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_.FullName
    # replace flags =  (only lines starting with optional whitespace + flags)
    Safe-ReplaceInFile $file '(?m)^[ \t]*flags[ \t]*=' 'country_flags ='
    # replace ruler = default with a simple ruler object
    Safe-ReplaceInFile $file '(?m)^[ \t]*ruler[ \t]*=[ \t]*default[ \t]*$' 'ruler = { name = "Auto Ruler" species = "HUM" gender = male }'
}

# 5) councilors: comment lines that mention invalid civics found in logs (conservative)
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
    $file = $_.FullName
    foreach ($c in $invalidCivics) {
        CommentLinesMatching $file ("(?i)\b" + [regex]::Escape($c) + "\b")
    }
}

# 6) Move dangerous user empire designs out (backup) to avoid invalid traits/civics killing load
$userEmp = Join-Path $repoRoot "user_empire_designs_v3.4.txt"
if (Test-Path $userEmp) { Backup-And-Move $userEmp }

# 7) Comment references to unknown district/district_xxx across events/districts (conservative)
$unknownDistricts = @("district_hive_1","district_hive_2","district_hive_3","district_nexus_1","district_nexus_2")
Get-ChildItem -Path $repoRoot -Include *.txt -Recurse | ForEach-Object {
    foreach ($d in $unknownDistricts) {
        CommentLinesMatching $_.FullName ("(?i)\b" + [regex]::Escape($d) + "\b")
    }
}

# 8) Add localisation fallback file for economic categories (if not present)
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

# 9) Stage + commit
git add -A
$commitMsg = "Auto-fix(core): disable broken ascension perks, comment deprecated tokens, fix prescripted_countries flags/ruler, add localisation fallback"
git commit -m $commitMsg 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Commit created on branch $branch."
    # try to push (may ask credentials)
    git push origin $branch
    Write-Host "Attempted git push origin $branch (check output above for success)."
} else {
    Write-Host "Nothing to commit or commit failed (check git status)."
}

Write-Host "---- DONE ----"
Write-Host "Backup folder: $backupRoot"
Write-Host "Branch: $branch (check and push if needed)"
Write-Host "Relance Stellaris en -debug_mode et envoie-moi les dernières lignes de error.log si le crash persiste."
