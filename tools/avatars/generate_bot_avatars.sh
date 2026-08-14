#!/bin/bash
#
# Generates the six ladder characters' portraits into BallIQ/Assets.xcassets.
#
# WHY THIS IS A SCRIPT AND NOT SIX HAND-DRAWN FILES
# -------------------------------------------------
# The characters are authored data, not art assets: every trait below is chosen against that
# bot's row in `bots` (backstory, style, palette), so when a character's personality changes the
# portrait can be regenerated to match instead of drifting away from the copy. It also keeps the
# palette hexes in ONE place traceable back to DesignSystem/Theme.swift, rather than baked by
# hand into six files nobody dares touch.
#
# STYLE CHOICE
# ------------
# DiceBear `open-peeps` by Pablo Stanley, CC0 1.0 (public domain — no attribution obligation,
# which matters for a paid App Store app; several otherwise-good DiceBear styles are CC BY 4.0).
#
# It replaced `notionists` for one measurable reason: notionists has **head=1 and no skin
# colours**, so all six characters rendered as the identical body wearing different props — they
# read as one person in six palettes, and Priya, Dee and Marcus were indistinguishable. open-peeps
# has head=48 and skin=5, so the silhouette itself carries the character. The cost is real and
# worth knowing: open-peeps is head-and-shoulders, so it has no hand gestures, and notionists'
# nice touches (Priya holding a phone, Marcus's on-air "OK") are gone.
#
# Requires: node/npx, rsvg-convert (brew install librsvg).
# Usage: tools/avatars/generate_bot_avatars.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="BallIQ/Assets.xcassets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Palette hexes MIRROR BallIQ/DesignSystem/Theme.swift. `soft` is the *Bg token for each role —
# the portrait sits on the quiet tint so the line art keeps its contrast, while the saturated
# `fill` stays on the card around it (blockCard) and in the character's own clothing.
#   amber=warningBg  teal=successBg  electric=accentBg  volt=voltBg  plum=proBg  ink=surfaceMuted
#
# Hair COLOUR is pinned as deliberately as hair shape: left random, `headContrastColor` gave Hal,
# the sixty-something archivist, ginger hair.
#
# id|head|expression|facialHair|accessories|skin|hair|softLight|softDark|clothing
PICKS=(
  "rookie|short2|cheeky|NONE|NONE|edb98a|2c1b18|FFEBD2|3A2200|FF8A1E"
  "stathead|bun|driven|NONE|glasses2|ae5d29|2c1b18|DDF5E5|0E2C19|18A957"
  "analyst|pomp|explaining|goatee1|NONE|694d3d|2c1b18|E3E9FF|16224F|1E50FF"
  "scout|hatBeanie|suspicious|moustache3|NONE|d08b5b|4a312c|EEFAC4|2A3500|C2F03A"
  "archivist|grayShort|old|full2|glasses|ffdbb4|e8e1e1|EBE3FE|251744|6D3BF5"
  "oracle|noHair1|blank|NONE|NONE|694d3d|2c1b18|ECE6D7|232019|15120B"
)

for entry in "${PICKS[@]}"; do
  IFS='|' read -r id head expr fh acc skin hair softL softD clothing <<< "$entry"
  set -- --seed "$id" --format svg --size 512 \
         --headVariant "$head" --headProbability 100 \
         --expressionVariant "$expr" --expressionProbability 100 \
         --skinColor "$skin" --headContrastColor "$hair" \
         --clothingColor "$clothing" --maskProbability 0
  if [ "$fh" = "NONE" ]; then set -- "$@" --facialHairProbability 0
  else set -- "$@" --facialHairVariant "$fh" --facialHairProbability 100; fi
  if [ "$acc" = "NONE" ]; then set -- "$@" --accessoriesProbability 0
  else set -- "$@" --accessoriesVariant "$acc" --accessoriesProbability 100; fi

  npx -y dicebear@latest open-peeps "$WORK" "$@" >/dev/null 2>&1
  mv "$WORK/open-peeps-0.svg" "$WORK/$id.svg"

  set="$OUT/bot-$id.imageset"
  mkdir -p "$set"
  # Light and dark are separate rasterisations rather than one tinted template: iOS template
  # rendering is alpha-only, so it would flatten the skin tones and clothing this style exists
  # to provide. Only the backdrop differs between the two.
  rsvg-convert -w 384 -h 384 --background-color "#${softL}" "$WORK/$id.svg" -o "$set/$id.png"
  rsvg-convert -w 384 -h 384 --background-color "#${softD}" "$WORK/$id.svg" -o "$set/$id-dark.png"
  cat > "$set/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "$id.png", "idiom" : "universal", "scale" : "3x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "$id-dark.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
  echo "  bot-$id.imageset"
done
echo "wrote 6 imagesets to $OUT"
