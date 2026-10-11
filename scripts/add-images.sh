#!/usr/bin/env bash
#
# Process images for the blog and write them to <out-dir>. Each image is
# shrunk, converted to sRGB, and has all of its metadata removed (EXIF, GPS,
# camera info).
#
# Usage: scripts/add-images.sh [-s max_px] [-q quality] [-f] <out-dir> <image>...
#
#   -s  Longest edge in pixels (default 2400). Images are never upscaled.
#   -q  JPEG quality (default 85). Hugo re-encodes the image later, so the
#       copy we commit is kept at fairly high quality.
#   -f  Overwrite files that already exist in <out-dir>.
#
# Photos (jpg/heic/avif/webp/tiff) are written as .jpg. PNGs stay PNG, so
# screenshots and transparent images aren't run through lossy JPEG.
#
# Example:
#   scripts/add-images.sh content/posts/smoke-n-fire-2026 ~/Downloads/IMG_*.HEIC

set -euo pipefail

max_px=2400
quality=85
force=0

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":s:q:fh" opt; do
  case $opt in
    s) max_px=$OPTARG ;;
    q) quality=$OPTARG ;;
    f) force=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 2 ]] || usage 1

if command -v magick >/dev/null; then
  im=(magick); identify=(magick identify)
elif command -v convert >/dev/null; then
  im=(convert); identify=(identify)
else
  echo "error: ImageMagick is not installed" >&2; exit 1
fi

out_dir=${1%/}; shift
mkdir -p "$out_dir"

# Photos from phones often use a wide-gamut profile such as Display P3. Hugo
# drops ICC profiles when it resizes, so convert to sRGB here or the colors
# will look washed out on the site.
srgb=""
for p in /usr/share/color/icc/sRGB.icc /usr/share/color/icc/colord/sRGB.icc \
         /opt/homebrew/share/color/icc/sRGB.icc /Library/ColorSync/Profiles/sRGB*.icc; do
  [[ -f $p ]] && { srgb=$p; break; }
done
[[ -n $srgb ]] || echo "warning: no sRGB ICC profile found; wide-gamut photos may look dull" >&2

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }
filesize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

status=0
for src in "$@"; do
  if [[ ! -f $src ]]; then
    echo "skip: $src (not a file)" >&2; status=1; continue
  fi

  base=$(basename "$src")
  stem=${base%.*}
  ext=$(tr '[:upper:]' '[:lower:]' <<<"${base##*.}")

  case $ext in
    jpg|jpeg|heic|heif|avif|webp|tif|tiff) out_ext=jpg ;;
    png) out_ext=png ;;
    *) echo "skip: $src (unsupported type .$ext)" >&2; status=1; continue ;;
  esac

  # Make the name URL-safe: "IMG 1234 (1).HEIC" becomes "img-1234-1.jpg"
  slug=$(tr '[:upper:]' '[:lower:]' <<<"$stem" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g')
  dest=$out_dir/$slug.$out_ext

  if [[ -e $dest && $force -eq 0 ]]; then
    echo "skip: $dest already exists (use -f to overwrite)" >&2; status=1; continue
  fi

  # Order matters: -auto-orient reads the EXIF orientation tag and -profile
  # reads the embedded ICC profile, so both must run before -strip removes them.
  args=("$src[0]" -auto-orient)
  [[ -n $srgb ]] && args+=(-profile "$srgb")
  args+=(-resize "${max_px}x${max_px}>" -strip)
  if [[ $out_ext == jpg ]]; then
    args+=(-quality "$quality")
  else
    args+=(-define png:compression-level=9)
  fi

  tmp=$(mktemp "$out_dir/.add-images.XXXXXX.$out_ext")
  if ! "${im[@]}" "${args[@]}" "$tmp"; then
    rm -f "$tmp"; echo "error: failed to convert $src" >&2; status=1; continue
  fi

  # Check that no EXIF data (including GPS) made it through
  if [[ -n $("${identify[@]}" -format '%[EXIF:*]' "$tmp" 2>/dev/null) ]]; then
    rm -f "$tmp"; echo "error: EXIF data still present in $src output; not adding" >&2; status=1; continue
  fi

  mv "$tmp" "$dest"
  chmod 644 "$dest"
  dims=$("${identify[@]}" -format '%wx%h' "$dest")
  printf '%s -> %s  (%s, %s -> %s)\n' "$src" "$dest" "$dims" \
    "$(human "$(filesize "$src")")" "$(human "$(filesize "$dest")")"
done

exit $status
