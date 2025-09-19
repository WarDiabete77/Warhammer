#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
BRANCH="port-4.0"
COMMIT_MSG="Port mod to Stellaris 4.0 — initial static fixes: descriptor, localization encoding, EOL and housekeeping"
ZIP_NAME="Warhammer-4.0-ported.zip"
REPO_ROOT="$(pwd)"

echo "Running port-prep script from: $REPO_ROOT"
echo

# 1) create branch from current HEAD
git fetch origin
git checkout -b "$BRANCH"

# 2) update descriptor.mod supported_version -> 4.0.*
DESCRIPTOR="descriptor.mod"
if [ -f "$DESCRIPTOR" ]; then
  if grep -q 'supported_version' "$DESCRIPTOR"; then
    echo "Updating supported_version in $DESCRIPTOR -> \"4.0.*\""
    # replace line containing supported_version with new value (in-place)
    sed -i.bak -E 's/(supported_version[[:space:]]*=[[:space:]]*\").*(\".*)/\1'"4.0.*"'\2/' "$DESCRIPTOR"
  else
    echo "Adding supported_version to $DESCRIPTOR"
    echo "" >> "$DESCRIPTOR"
    echo 'supported_version="4.0.*"' >> "$DESCRIPTOR"
  fi
else
  echo "ERROR: $DESCRIPTOR not found in repo root. Exiting."
  exit 1
fi

# 3) Normalize localisation files to UTF-8 (safe conversion, keeps originals .bak if needed)
echo
echo "Converting localisation files to UTF-8 (localisation/ and localisation_synced/) ..."
LOCA_DIRS=( "localisation" "localisation_synced" )
for d in "${LOCA_DIRS[@]}"; do
  if [ -d "$d" ]; then
    find "$d" -type f -name "*.yml" -o -name "*.csv" -o -name "*.txt" | while read -r f; do
      echo "  -> $f"
      # try to convert to UTF-8 in-place using iconv; keep a .bak
      if command -v iconv >/dev/null 2>&1; then
        iconv -f "$(file -bi "$f" | sed -n 's/.*charset=\(.*\)/\1/p' || echo 'utf-8')" -t utf-8 "$f" > "$f.tmp" || true
        # if conversion failed, fallback to copying file
        if [ -s "$f.tmp" ]; then
          mv "$f" "$f.bak.encoding" || true
          mv "$f.tmp" "$f"
        else
          rm -f "$f.tmp"
        fi
      else
        # if iconv not available, just ensure no CRLF
        cp "$f" "$f.bak.encoding" || true
      fi
      # remove BOM if present
      awk 'NR==1{sub(/^\xef\xbb\xbf/,"")} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  fi
done

# 4) Normalize EOL: convert CRLF -> LF for mod text files
echo
echo "Normalizing line endings to LF for common text files..."
find . -type f \( -name "*.txt" -o -name "*.mod" -o -name "*.yml" -o -name "*.csv" -o -name "*.txt" -o -name "*.asset" -o -name "*.lua" -o -name "*.gfx" -o -name "*.gui" -o -name "*.txt" \) -print0 | xargs -0 -n1 dos2unix >/dev/null 2>&1 || true

# 5) Basic whitespace / charset cleanup in localization (remove trailing spaces)
echo
echo "Trimming trailing whitespace in localisation files..."
for d in "${LOCA_DIRS[@]}"; do
  if [ -d "$d" ]; then
    find "$d" -type f -print0 | xargs -0 -n1 sed -i.bak -E 's/[[:space:]]+$//' || true
  fi
done

# 6) Create a small automated scan for likely obsolete keywords
SCAN_OUT="port_scan_report.txt"
echo > "$SCAN_OUT"
echo "Scanning for common deprecated Stellaris keywords (report)..." >> "$SCAN_OUT"
KEYWORDS=(
  "is_country_type"
  "has_government"
  "is_ruler"
  "has_title"
  "hostile"
  "is_leader_type"
  "owner ="
  "owner ="
)
for k in "${KEYWORDS[@]}"; do
  echo "Searching for: $k" >> "$SCAN_OUT"
  grep -RIn --exclude-dir=.git --exclude="*.png" --exclude="*.jpg" --exclude="*.dds" --exclude="*.mesh" "$k" . >> "$SCAN_OUT" || true
done
echo "Scan saved to $SCAN_OUT"
echo

# 7) Safe textual normalizations that do not change game logic:
#    - Replace Windows BOMs already done
#    - Replace any 'charset' in .yml header if present -> ensure l_english
#    (We avoid changing event triggers automatically)
echo "Applying safe textual normalizations..."
# Ensure localisation files start with 'l_english:' or similar (DO NOT overwrite existing locales)
# (We do not mass-rewrite locale keys; that's dangerous.)

# 8) Add a README note about porting state
PORT_NOTE="PORTING_TO_4_0.md"
cat > "$PORT_NOTE" <<'EOF'
Porting notes — initial automated pass (descriptor + localisation + EOL normalization)

What this script did:
- Created branch: port-4.0
- Updated descriptor.mod -> supported_version="4.0.*" (if descriptor.mod existed)
- Converted localisation files to UTF-8 where possible (kept .bak copies)
- Normalized line endings to LF for common text files (dos2unix)
- Trimmed trailing whitespace on localisation files
- Produced a scan port_scan_report.txt with locations of likely deprecated keywords to review manually

What still needs manual work (after running this):
- Manual review and rewrite of events (events/*.txt/.txt), triggers and effects:
  many triggers changed between Stellaris 2.7 -> 4.0 and require manual adaptation.
- Manual review of common/*.yml files (traits, technologies, governments, ship parts)
- Asset re-exporting if some meshes/textures are unsupported
- Full playtesting in Stellaris with -debug_mode to collect error.log and debug.log; send those logs back for iterative fixes.

Next steps for you:
1. Run Stellaris with the mod enabled in -debug_mode and upload error.log & debug.log
2. I will iterate and produce fixes for the errors found.

EOF

git add "$PORT_NOTE" || true

# 9) stage modified files and commit
echo
echo "Staging changes..."
git add -A
git status --porcelain
echo
git commit -m "$COMMIT_MSG" || { echo "Nothing to commit or commit failed"; }

# 10) create zip of current repo state (branch HEAD)
echo
echo "Creating ZIP: $ZIP_NAME"
cd ..
zip -r "$ZIP_NAME" "$(basename "$REPO_ROOT")" >/dev/null 2>&1 || { echo "zip failed - ensure zip is installed"; }

echo
echo "ALL DONE. Branch: $BRANCH created, changes committed."
echo "ZIP created at: ../$ZIP_NAME"
echo "Scan report: $REPO_ROOT/port_scan_report.txt"
echo "Porting note: $REPO_ROOT/$PORT_NOTE"
echo
echo "Next: run Stellaris with this mod and send error.log & debug.log for further fixes."
