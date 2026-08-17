"""One-shot: rewrites roster.json's portrait traits from open-peeps to Big Heads vocabulary.

Kept in the repo rather than deleted because it documents the mapping decisions — Big Heads has
a far smaller vocabulary (9 hairstyles against open-peeps' 48), so distinctness has to come from
COMBINATIONS: skin (6) x eyes (9) x eyebrows (5) x mouth (7) x facialHair (3) x accessory (4) x
clothing (6) x hairColor (7) x body (2). Hair repeats across thirty characters and that is fine;
no two share a full combination.

`graphics` is pinned off everywhere: the only options are tech-company logos (react, vue,
graphQL, gatsby, redwood), which would put a JavaScript framework on a sports fan's t-shirt.
"""
import json
import pathlib

ROSTER = pathlib.Path(__file__).resolve().parent / "roster.json"

# id: (skinTone, hair, hairColor, body, clothing, clothingColor, eyes, eyebrows, mouth,
#      facialHair, accessory)
M = {
 "toby":      ("light",  "short",   "blonde", "chest",   "tankTop",   "red",   "happy",      "raised",      "grin",      "none",        "none"),
 "rookie":    ("yellow", "short",   "black",  "chest",   "shirt",     "blue",  "content",    "raised",      "openSmile", "none",        "none"),
 "bex":       ("brown",  "buzz",    "orange", "chest",   "tankTop",   "black", "squint",     "angry",       "open",      "none",        "shades"),
 "ray":       ("light",  "balding", "white",  "chest",   "vneck",     "white", "squint",     "concerned",   "grin",      "mediumBeard", "tinyGlasses"),
 "simone":    ("dark",   "bob",     "black",  "breasts", "dressShirt","white", "content",    "raised",      "lips",      "none",        "none"),
 "dev":       ("black",  "short",   "black",  "chest",   "dressShirt","blue",  "squint",     "serious",     "serious",   "stubble",     "roundGlasses"),
 "marisol":   ("brown",  "long",    "brown",  "breasts", "shirt",     "red",   "heart",      "raised",      "grin",      "none",        "none"),
 "otto":      ("light",  "balding", "orange", "chest",   "shirt",     "green", "wink",       "raised",      "openSmile", "mediumBeard", "none"),
 "stathead":  ("dark",   "bun",     "black",  "breasts", "dressShirt","green", "normal",     "serious",     "serious",   "none",        "roundGlasses"),
 "jonah":     ("black",  "buzz",    "black",  "chest",   "tankTop",   "red",   "leftTwitch", "angry",       "open",      "stubble",     "none"),
 "ines":      ("light",  "bun",     "white",  "breasts", "dressShirt","blue",  "content",    "concerned",   "lips",      "none",        "tinyGlasses"),
 "curtis":    ("brown",  "buzz",    "black",  "chest",   "tankTop",   "blue",  "normal",     "serious",     "serious",   "stubble",     "none"),
 "wanda":     ("light",  "bob",     "white",  "breasts", "shirt",     "green", "happy",      "raised",      "grin",      "none",        "none"),
 "analyst":   ("black",  "short",   "black",  "chest",   "dressShirt","black", "normal",     "raised",      "open",      "stubble",     "none"),
 "femi":      ("black",  "afro",    "black",  "chest",   "dressShirt","green", "squint",     "serious",     "serious",   "none",        "roundGlasses"),
 "astrid":    ("light",  "long",    "blonde", "breasts", "vneck",     "black", "squint",     "leftLowered", "serious",   "none",        "shades"),
 "bruno":     ("brown",  "balding", "brown",  "chest",   "shirt",     "white", "content",    "concerned",   "serious",      "mediumBeard", "none"),
 "lila":      ("yellow", "pixie",   "black",  "breasts", "dressShirt","white", "normal",     "serious",     "serious",   "none",        "roundGlasses"),
 "scout":     ("brown",  "short",   "brown",  "chest",   "shirt",     "green", "squint",     "leftLowered", "serious",   "mediumBeard", "none"),
 "yusuf":     ("dark",   "short",   "black",  "chest",   "dressShirt","blue",  "simple",     "serious",     "serious",   "stubble",     "roundGlasses"),
 "greta":     ("light",  "bun",     "blonde", "breasts", "vneck",     "white", "content",    "raised",      "lips",      "none",        "none"),
 "cass":      ("dark",   "afro",    "black",  "breasts", "tankTop",   "red",   "happy",      "raised",      "openSmile", "none",        "none"),
 "tomas":     ("brown",  "none",    "black",  "chest",   "vneck",     "black", "normal",     "serious",     "serious",   "mediumBeard", "none"),
 "ingrid":    ("light",  "long",    "black",  "breasts", "dressShirt","black", "leftTwitch", "leftLowered", "serious",   "none",        "shades"),
 "archivist": ("light",  "short",   "white",  "chest",   "dressShirt","blue",  "content",    "serious",     "serious",   "mediumBeard", "roundGlasses"),
 "solomon":   ("black",  "balding", "white",  "chest",   "dressShirt","white", "content",    "raised",      "openSmile",      "mediumBeard", "roundGlasses"),
 "nadia":     ("dark",   "bun",     "black",  "breasts", "dressShirt","black", "squint",     "angry",       "serious",   "none",        "none"),
 "rex":       ("light",  "short",   "white",  "chest",   "dressShirt","red",   "squint",     "serious",     "serious",   "none",        "tinyGlasses"),
 "wren":      ("yellow", "long",    "black",  "breasts", "shirt",     "white", "simple",     "concerned",   "lips",      "none",        "none"),
 "oracle":    ("black",  "none",    "black",  "chest",   "tankTop",   "black", "leftTwitch", "angry",       "serious",   "none",        "none"),
}
KEYS = ("skinTone", "hair", "hairColor", "body", "clothing", "clothingColor",
        "eyes", "eyebrows", "mouth", "facialHair", "accessory")
# Only meaningful for `mouth: "lips"`, which is the lipstick variant. Left unset it
# defaulted to green and blue on characters who should not have had it at all.
LIP = {"simone": "red", "ines": "pink", "greta": "purple", "wren": "red"}
# open-peeps trait keys, replaced wholesale. `flip`/`tilt` survive — pose is system-independent.
OLD = ("head", "expression", "facialHair", "accessories", "skin", "hair")


def main() -> int:
    lines = ROSTER.read_text().split("\n")
    out, current = [], None
    for ln in lines:
        if '"id": "' in ln:
            current = ln.split('"id": "')[1].split('"')[0]
        if current in M and '"head": "' in ln:
            indent = ln[:len(ln) - len(ln.lstrip())]
            traits = dict(zip(KEYS, M[current]))
            keep = []
            if '"flip": true' in ln:
                keep.append('"flip": true')
            if '"tilt":' in ln:
                tilt = ln.split('"tilt":')[1].split(",")[0].strip()
                keep.append(f'"tilt": {tilt}')
            if current in LIP:
                traits["lipColor"] = LIP[current]
            parts = [f'"{k}": "{v}"' for k, v in traits.items()] + keep
            ln = indent + ", ".join(parts) + ","
        out.append(ln)
    ROSTER.write_text("\n".join(out))

    d = json.loads(ROSTER.read_text())
    assert len(d["bots"]) == 30
    combos = {tuple(b[k] for k in KEYS) for b in d["bots"]}
    missing = [b["id"] for b in d["bots"] if any(k not in b for k in KEYS)]
    assert not missing, f"unmapped: {missing}"
    print(f"remapped 30 characters -> {len(combos)} distinct trait combinations")
    for k in ("skinTone", "hair", "body"):
        counts: dict[str, int] = {}
        for b in d["bots"]:
            counts[b[k]] = counts.get(b[k], 0) + 1
        print(f"  {k:10} " + ", ".join(f"{a} {n}" for a, n in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
