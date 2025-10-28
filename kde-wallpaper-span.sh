#!/usr/bin/env bash

set -euo pipefail

# Default scaling mode: fill (scales to cover entire screen, crops excess)
SCALE_MODE="fill"
AUTO_APPLY=true

IMG="${1:-}"

# Parse arguments
shift || true
for arg in "$@"; do
  case "$arg" in
    --no-apply)
      AUTO_APPLY=false
      ;;
    stretch|fit|fill)
      SCALE_MODE="$arg"
      ;;
  esac
done

if [[ -z "$IMG" || ! -f "$IMG" ]]; then
  echo "Usage: $0 /path/to/wallpaper.png [stretch|fit|fill] [--no-apply]"
  echo "  stretch - Distort image to exactly fit screen (may look stretched)"
  echo "  fit     - Scale to fit inside screen (may have black bars)"
  echo "  fill    - Scale to cover screen, crop excess (recommended, default)"
  echo "  --no-apply - Don't automatically set wallpapers (just create files)"
  exit 1
fi

if ! command -v kscreen-doctor >/dev/null 2>&1; then
  echo "Error: kscreen-doctor not found. Run on KDE (install plasma-utils/kscreen)." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found. Install with: sudo pacman -S jq" >&2
  exit 3
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "Error: ImageMagick 7 (magick) not found. Install: sudo pacman -S imagemagick" >&2
  exit 4
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get original image dimensions and extract base filename without extension
IMG_INFO=$(magick identify -format "%w %h" "$IMG")
read -r IMG_W IMG_H <<< "$IMG_INFO"
WALLPAPER_BASE=$(basename "$IMG" | sed 's/\.[^.]*$//')
echo "📐 Source image: ${IMG_W}x${IMG_H} (${WALLPAPER_BASE})"

echo "🖥 Detecting monitor layout (kscreen-doctor --json)..."
JSON="$(kscreen-doctor --json 2>/dev/null || true)"

if [[ -z "$JSON" ]]; then
  echo "Error: kscreen-doctor returned no JSON. Make sure KDE/KScreen is running." >&2
  exit 5
fi

# Parse all enabled outputs and store data
declare -a MONITORS=()
MIN_X=999999
MIN_Y=999999
MAX_X=-999999
MAX_Y=-999999

echo "🔎 Parsing outputs..."

# First, get count of enabled outputs
ENABLED_COUNT=$(echo "$JSON" | jq '[.outputs[] | select(.enabled == true)] | length')
echo "  Found $ENABLED_COUNT enabled output(s)"

# Parse each output individually
mapfile -t OUTPUT_NAMES < <(echo "$JSON" | jq -r '.outputs[] | select(.enabled == true) | .name')

for name in "${OUTPUT_NAMES[@]}"; do
  # Get data for this specific output
  px=$(echo "$JSON" | jq -r ".outputs[] | select(.name == \"$name\") | .pos.x")
  py=$(echo "$JSON" | jq -r ".outputs[] | select(.name == \"$name\") | .pos.y")
  w=$(echo "$JSON" | jq -r ".outputs[] | select(.name == \"$name\") | .size.width")
  h=$(echo "$JSON" | jq -r ".outputs[] | select(.name == \"$name\") | .size.height")
  rot=$(echo "$JSON" | jq -r ".outputs[] | select(.name == \"$name\") | .rotation")
  scale=$(echo "$JSON" | jq -r ".outputs[] | select(.name == \"$name\") | .scale")
  
  # Handle null or missing scale (default to 1)
  if [[ -z "$scale" || "$scale" == "null" ]]; then
    scale=1
  fi
  
  # Validate we got actual numbers
  if [[ -z "$px" || -z "$py" || -z "$w" || -z "$h" || "$px" == "null" || "$py" == "null" || "$w" == "null" || "$h" == "null" ]]; then
    echo "⚠️  Warning: Skipping $name - incomplete data (pos: $px,$py size: $w,$h)" >&2
    continue
  fi
  
  # Calculate effective display size (accounting for scale factor)
  # For scaled displays, divide the size by the scale factor
  # Use bash arithmetic (integer division)
  if [[ "$scale" == "1" ]]; then
    effective_w=$w
    effective_h=$h
  else
    # Convert scale to integer if it's a float (e.g., 2.0 -> 2)
    scale_int=${scale%.*}
    effective_w=$((w / scale_int))
    effective_h=$((h / scale_int))
  fi
  
  scale_note=""
  if [[ "$scale" != "1" ]]; then
    scale_note=" (scaled ${scale}x, effective: ${effective_w}x${effective_h})"
  fi
  
  echo "  Parsed: $name | pos=($px,$py) size=${w}x${h} scale=$scale$scale_note rot=$rot"
  
  # Calculate bounds using effective size
  right=$((px + effective_w))
  bottom=$((py + effective_h))
  
  [[ $px -lt $MIN_X ]] && MIN_X=$px
  [[ $py -lt $MIN_Y ]] && MIN_Y=$py
  [[ $right -gt $MAX_X ]] && MAX_X=$right
  [[ $bottom -gt $MAX_Y ]] && MAX_Y=$bottom
  
  # Store both physical and effective sizes
  MONITORS+=("$name|$px|$py|$w|$h|$rot|$scale|$effective_w|$effective_h")
done

echo "  Stored ${#MONITORS[@]} monitor(s) in array"

if [[ ${#MONITORS[@]} -eq 0 ]]; then
  echo "❌ Error: no valid enabled outputs detected." >&2
  exit 6
fi

TOTAL_W=$((MAX_X - MIN_X))
TOTAL_H=$((MAX_Y - MIN_Y))

echo
echo "✅ Detected ${#MONITORS[@]} enabled output(s):"
for mon_data in "${MONITORS[@]}"; do
  IFS='|' read -r name px py w h rot scale eff_w eff_h <<< "$mon_data"
  rot_label=""
  case $rot in
    2) rot_label=" (90° rotation)" ;;
    3) rot_label=" (180° rotation)" ;;
    4) rot_label=" (270° rotation)" ;;
  esac
  scale_label=""
  if [[ "$scale" != "1" ]]; then
    scale_label=" [${scale}x scale → ${eff_w}x${eff_h} effective]"
  fi
  echo "  - $name: ${w}x${h} at (${px},${py})${rot_label}${scale_label}"
done

echo
echo "📏 Total virtual screen: ${TOTAL_W}x${TOTAL_H}"
echo "   Bounds: (${MIN_X},${MIN_Y}) to (${MAX_X},${MAX_Y})"
echo "🎨 Scaling mode: $SCALE_MODE"

# Create a temporary scaled/positioned version of the wallpaper
TEMP_SCALED="${BASE_DIR}/.temp_scaled_wallpaper.png"
trap 'rm -f "$TEMP_SCALED"' EXIT

echo
echo "🔧 Scaling wallpaper to match virtual screen..."

case "$SCALE_MODE" in
  stretch)
    # Distort to exactly fit total screen
    magick "$IMG" -resize "${TOTAL_W}x${TOTAL_H}!" -gravity center -extent "${TOTAL_W}x${TOTAL_H}" "$TEMP_SCALED"
    ;;
  fit)
    # Scale to fit inside, maintain aspect ratio (may have black bars)
    magick "$IMG" -resize "${TOTAL_W}x${TOTAL_H}" -gravity center -background black -extent "${TOTAL_W}x${TOTAL_H}" "$TEMP_SCALED"
    ;;
  fill|*)
    # Scale to cover entire screen, crop excess (default)
    magick "$IMG" -resize "${TOTAL_W}x${TOTAL_H}^" -gravity center -extent "${TOTAL_W}x${TOTAL_H}" "$TEMP_SCALED"
    ;;
esac

echo "✅ Scaled wallpaper ready: ${TOTAL_W}x${TOTAL_H}"
echo
echo "🎨 Slicing wallpaper for each monitor..."
echo "   Debug: MONITORS array has ${#MONITORS[@]} elements"
echo "   Debug: Array contents:"
for i in "${!MONITORS[@]}"; do
  echo "      [$i] = ${MONITORS[$i]}"
done
echo

errors=0
declare -a OUTPUT_FILES=()

slice_index=0

# Process each monitor in the array
for mon_data in "${MONITORS[@]}"; do
  echo "   Debug: Processing mon_data = '$mon_data'"
  IFS='|' read -r nm px py w h rot scale eff_w eff_h <<< "$mon_data"
  
  echo
  echo "📺 Processing monitor #$((slice_index+1)): $nm"
  
  # Use effective size for cropping (accounts for display scaling)
  crop_w=$eff_w
  crop_h=$eff_h
  
  # Adjust coordinates relative to minimum (normalize to 0,0)
  adj_x=$((px - MIN_X))
  adj_y=$((py - MIN_Y))
  
  outfile="${BASE_DIR}/${WALLPAPER_BASE}_${nm}.jpg"
  
  echo "   Position: ($px,$py) → Adjusted: ($adj_x,$adj_y)"
  if [[ "$scale" != "1" ]]; then
    echo "   Physical size: ${w}x${h} (scale ${scale}x)"
    echo "   Effective size: ${eff_w}x${eff_h}"
  fi
  echo "   Crop size: ${crop_w}x${crop_h}"
  echo "   Geometry: ${crop_w}x${crop_h}+${adj_x}+${adj_y}"
  echo "   Output: $outfile"
  
  # Perform crop from the scaled image
  if magick "$TEMP_SCALED" -crop "${crop_w}x${crop_h}+${adj_x}+${adj_y}" +repage -quality 95 "$outfile"; then
    echo "   ✅ Saved successfully"
    OUTPUT_FILES+=("$nm|$outfile")
  else
    echo "   ❌ Crop failed!" >&2
    errors=$((errors + 1))
  fi
  
  slice_index=$((slice_index + 1))
done

echo
echo "═══════════════════════════════════════════════════════"
if (( errors == 0 )); then
  echo "🎉 Success! Created $slice_index wallpaper(s) in: $BASE_DIR"
  echo
  
  # List created files
  for i in "${!OUTPUT_FILES[@]}"; do
    IFS='|' read -r screen_name wallpaper_file <<< "${OUTPUT_FILES[$i]}"
    filesize=$(du -h "$wallpaper_file" | cut -f1)
    echo "   [$((i+1))] $screen_name → $(basename "$wallpaper_file") ($filesize)"
  done
  
  # Auto-apply wallpapers if requested
  if [[ "$AUTO_APPLY" == true ]]; then
    echo
    echo "🖼️  Auto-applying wallpapers to screens..."
    
    # Reverse the OUTPUT_FILES array to match correct desktop order
    declare -a REVERSED_FILES=()
    for ((i=${#OUTPUT_FILES[@]}-1; i>=0; i--)); do
      REVERSED_FILES+=("${OUTPUT_FILES[$i]}")
    done
    
    # Apply each wallpaper sequentially from reversed array
    idx=0
    for entry in "${REVERSED_FILES[@]}"; do
      IFS='|' read -r screen_name wallpaper_file <<< "$entry"
      
      echo "   Applying wallpaper $((idx+1)): $screen_name → $(basename "$wallpaper_file")"
      
      # Apply wallpaper using direct JavaScript approach
      qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
        var allDesktops = desktops();
        if (allDesktops.length > $idx) {
          var d = allDesktops[$idx];
          d.wallpaperPlugin = 'org.kde.image';
          d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
          d.writeConfig('Image', 'file://$wallpaper_file');
          d.writeConfig('FillMode', '2');
          print('Applied to desktop ' + $idx);
        }
      " 2>&1 | grep -i "Applied" || echo "      (applied)"
      
      idx=$((idx + 1))
    done
    
    echo
    echo "✅ Wallpapers applied!"
  else
    echo
    echo "💡 To skip auto-apply next time, use:"
    echo "   $0 \"$IMG\" $SCALE_MODE --no-apply"
    echo
    echo "💡 Or apply manually:"
    for entry in "${OUTPUT_FILES[@]}"; do
      IFS='|' read -r screen_name wallpaper_file <<< "$entry"
      echo "   plasma-apply-wallpaperimage \"$wallpaper_file\""
    done
  fi
else
  echo "⚠️  Completed with $errors error(s). Check output above." >&2
fi
echo "═══════════════════════════════════════════════════════"
