#!/bin/bash
#
# Turn source images into the wallpapers the app ships.
#
#   tools/build-wallpapers.sh <source-folder>
#
# For each image in the folder: cover-crop to a phone screen's shape, resample
# to 3x on the largest iPhone, and re-encode as HEIC. Writes into
# prototype/MinimalBrowser/Wallpapers/ and prints the Swift catalogue entries to
# paste into `BuiltInWallpaper.all`.
#
# Why crop rather than letterbox: the wallpaper is drawn `scaleAspectFill`
# behind the start box, so anything not the screen's shape loses its edges at
# run time anyway. Cropping here means that loss is visible now, at build time,
# rather than on someone's phone.
#
# Why HEIC: a 1320x2868 picture is several megabytes as PNG and a few hundred
# kilobytes as HEIC, and the app's download grows by that much per wallpaper.

set -euo pipefail

SOURCE="${1:-}"
if [ -z "$SOURCE" ] || [ ! -d "$SOURCE" ]; then
    echo "usage: $0 <folder-of-images>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/prototype/MinimalBrowser/Wallpapers"
mkdir -p "$OUT"

# iPhone 17 Pro Max at 3x — the largest screen this has to fill. Everything
# smaller downsamples from it at run time.
TARGET_W=1320
TARGET_H=2868
QUALITY=80

echo "// Paste into BuiltInWallpaper.all:"
echo

for src in "$SOURCE"/*; do
    # Lower-cased through `tr` rather than `${src,,}`: the bash on macOS is 3.2
    # and does not have the expansion.
    lower="$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *.jpg|*.jpeg|*.png|*.heic|*.tif|*.tiff|*.webp) ;;
        *) continue ;;
    esac

    base="$(basename "${src%.*}")"
    # Lower case, spaces and underscores to hyphens: this becomes a filename in
    # the bundle and an id in UserDefaults.
    slug="$(echo "$base" | tr '[:upper:] _' '[:lower:]--' | tr -cd 'a-z0-9-')"
    dest="$OUT/$slug.heic"

    w=$(sips -g pixelWidth  "$src" | awk '/pixelWidth/  {print $2}')
    h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')

    # Scale so the picture covers the target in both directions, then crop the
    # overhang off the middle.
    scale=$(awk -v w="$w" -v h="$h" -v tw="$TARGET_W" -v th="$TARGET_H" \
        'BEGIN { sw = tw / w; sh = th / h; print (sw > sh ? sw : sh) }')
    fit_w=$(awk -v w="$w" -v s="$scale" 'BEGIN { printf "%d", (w * s) + 0.5 }')
    fit_h=$(awk -v h="$h" -v s="$scale" 'BEGIN { printf "%d", (h * s) + 0.5 }')

    scratch="$(mktemp -t wallpaper).png"
    sips -z "$fit_h" "$fit_w" "$src" --out "$scratch" > /dev/null
    sips -c "$TARGET_H" "$TARGET_W" "$scratch" --out "$scratch" > /dev/null
    sips -s format heic -s formatOptions "$QUALITY" "$scratch" --out "$dest" > /dev/null
    rm -f "$scratch"

    size=$(du -h "$dest" | cut -f1 | tr -d ' ')
    # Title Case for the name under the swatch.
    name="$(echo "$slug" | tr '-' ' ' | awk '{ for (i=1; i<=NF; i++) $i = toupper(substr($i,1,1)) substr($i,2); print }')"
    echo "        BuiltInWallpaper(id: \"$slug\", name: \"$name\", file: \"$slug\"),   // $size"
done

echo
echo "Written to $OUT"
