/**
 * Renders every character in roster.json to an SVG using Big Heads, and writes the
 * `bot-<id>.imageset` folders straight into BallIQ/Assets.xcassets.
 *
 * WHY THIS IS NODE AND THE REST OF THE ROSTER TOOLING IS PYTHON
 * ------------------------------------------------------------
 * Big Heads (@bigheads/core, MIT) is a React component, not a CLI — the only way to get its SVG
 * out is to render it. So `sync.py` shells out to this for `--portraits` and keeps owning the
 * `bots` upsert and validation. roster.json stays the single source of truth for both.
 *
 * Chosen over DiceBear's open-peeps after a three-way comparison: Big Heads has body-shape
 * options none of the alternatives offer and much more expressive faces. Its vocabulary is
 * SMALLER though — 9 hairstyles against open-peeps' 48 — so character distinctness comes from
 * whole combinations rather than hair alone, and remap_bigheads.py asserts all 30 are unique.
 *
 * Setup:  cd tools/roster && npm install
 * Usage:  node tools/roster/portraits.js         (called by `python -m tools.roster.sync --portraits`)
 */
const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");
const React = require("react");
const { renderToStaticMarkup } = require("react-dom/server");
const { BigHead } = require("@bigheads/core");

const ROOT = path.join(__dirname, "..", "..");
const ASSETS = path.join(ROOT, "BallIQ", "Assets.xcassets");
const roster = JSON.parse(fs.readFileSync(path.join(__dirname, "roster.json"), "utf8"));

// Mirrors PALETTE_SOFT in sync.py, which mirrors DesignSystem/Theme.swift. The portrait sits on
// the quiet *Bg tint; the saturated fill stays on the card around it (blockCard).
const PALETTE_SOFT = {
  amber:    ["FFEBD2", "3A2200"],
  teal:     ["DDF5E5", "0E2C19"],
  electric: ["E3E9FF", "16224F"],
  green:    ["EEFAC4", "2A3500"],
  plum:     ["EBE3FE", "251744"],
  gold:     ["ECE6D7", "232019"],
};

/**
 * Applies the character's pose. Big Heads draws one front-facing pose and exposes no transform,
 * so thirty portraits rendered straight out come back identically framed — the exact complaint
 * that killed the previous set. Rotating/mirroring the SVG's contents is the fix: wrap the
 * children in a <g> about the canvas centre rather than transforming the root, which rsvg
 * ignores.
 */
function pose(svg, { flip, tilt }) {
  if (!flip && !tilt) return svg;
  const open = svg.match(/^<svg[^>]*>/)[0];
  const body = svg.slice(open.length, svg.lastIndexOf("</svg>"));
  const vb = (open.match(/viewBox="([^"]+)"/) || [])[1] || "0 0 1000 990";
  const [, , w, h] = vb.split(/\s+/).map(Number);
  const cx = w / 2, cy = h / 2;
  const t = [`translate(${cx} ${cy})`];
  if (tilt) t.push(`rotate(${tilt})`);
  if (flip) t.push("scale(-1 1)");
  t.push(`translate(${-cx} ${-cy})`);
  return `${open}<g transform="${t.join(" ")}">${body}</g></svg>`;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bigheads-"));
let n = 0;
for (const b of roster.bots) {
  const [softLight, softDark] = PALETTE_SOFT[b.palette];
  const svg = pose(
    renderToStaticMarkup(
      React.createElement(BigHead, {
        skinTone: b.skinTone, hair: b.hair, hairColor: b.hairColor, body: b.body,
        clothing: b.clothing, clothingColor: b.clothingColor, eyes: b.eyes,
        eyebrows: b.eyebrows, mouth: b.mouth, facialHair: b.facialHair,
        accessory: b.accessory,
        // Only read by the `lips` mouth variant. Unset it defaults to green/blue,
        // which is how a seventy-year-old archivist ended up in teal lipstick.
        ...(b.lipColor ? { lipColor: b.lipColor } : {}),
        // Pinned off, not left to default: unset, Big Heads randomises a hat (it put a turban on
        // one character and a beanie on another), and `graphics` only offers tech-company logos,
        // which would put a JavaScript framework on a sports fan's shirt.
        hat: "none", graphic: "none", mask: false, faceMask: false, lashes: b.body === "breasts",
      })
    ),
    b
  );
  const svgPath = path.join(tmp, `${b.id}.svg`);
  fs.writeFileSync(svgPath, svg);

  const set = path.join(ASSETS, `bot-${b.id}.imageset`);
  fs.mkdirSync(set, { recursive: true });
  for (const [suffix, bg] of [["", softLight], ["-dark", softDark]]) {
    execFileSync("rsvg-convert", ["-w", "384", "-h", "384", "--background-color", `#${bg}`,
                                  svgPath, "-o", path.join(set, `${b.id}${suffix}.png`)]);
  }
  fs.writeFileSync(path.join(set, "Contents.json"), JSON.stringify({
    images: [
      { filename: `${b.id}.png`, idiom: "universal", scale: "3x" },
      { appearances: [{ appearance: "luminosity", value: "dark" }],
        filename: `${b.id}-dark.png`, idiom: "universal", scale: "3x" },
    ],
    info: { author: "xcode", version: 1 },
  }, null, 2));
  n++;
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`wrote ${n} imagesets to ${ASSETS}`);
