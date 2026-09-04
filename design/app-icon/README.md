# Aureways mark

Layered source for the A-orbit app icon. Production rules: [`docs/brand/app-icon.md`](../../docs/brand/app-icon.md).

| File | Use |
|---|---|
| `A.svg` / `Orbit.svg` / `Spark.svg` | Icon Composer layers (1024², white fill, no corner crop) |
| `logo_default_1024.png` | Default / Dock preview — Orbit Blue `#003DA5` + white mark |
| `logo_dark_1024.png` | Dark preview — Deep Navy `#002B73` + `#F2F5FA` |
| `logo_on_white.svg` | Print / docs / in-app `BrandMark` light (blue mark, transparent ground) |
| `logo_on_dark.svg` | Web on dark / in-app `BrandMark` dark (white mark, transparent ground) |
| `preview_{16,32,64,128,256}.png` | Scale check |
| `preview_composer_{default,dark}.png` | `ictool` export of the real Liquid Glass render |
| `reference/mark_on_{blue,black,white}_1408.png` | The three supplied renders the geometry is fitted to |

The Xcode source of truth is `Aureways/AppIcon.icon` (three Liquid Glass groups).
Flattened sizes also live in `Aureways/Assets.xcassets/AppIcon.appiconset/` as a
fallback. The in-app planar mark is `Aureways/Assets.xcassets/BrandMark.imageset/`
(copied from the two transparent SVGs above).

## Rebuild

```
python3 design/app-icon/build_icon.py           # write everything, then verify
python3 design/app-icon/build_icon.py --check   # verify only
```

Everything above is generated. Edit the numbers at the top of `build_icon.py`,
never the SVGs.

## How the geometry is defined

The mark is described analytically rather than traced, so every path is a
handful of true curves instead of a tessellated polyline (Liquid Glass lights
each facet of a tessellated path, which is what made the earlier draft look
faceted and wrong):

- **A** — four straight leg edges (`x = m·y + b`), a circular fillet at the
  apex, a small fillet at the tip of the counter, and four equal fillets on the
  flat-bottomed feet. It ships as two subpaths: the orbit knocks a clearance
  band out of the right stroke, which is what makes the ring read as passing in
  front.
- **Orbit** — two concentric-ish ellipse arcs (`A` commands) that sweep ~300° of
  parameter space, joined at each tip by one cubic that tapers the ribbon to a
  knife point.
- **Spark** — four cubics with both handles pulled toward the centre.

All numbers live in the 1408 px reference space and are scaled to the 1024 px
canvas on output. `--check` re-renders the model and reports IoU against the
majority vote of the three reference renders; it currently scores **0.979**,
which is tighter than the three references agree with each other (0.93–0.96).
It also writes `_diag_overlay.png` (green = match, red = reference only,
yellow = model only).

## After rebuilding

`build_icon.py` calls `ictool` itself when Xcode is installed, so
`preview_composer_*.png` is the real render, not an approximation. For anything
beyond a sanity check, open `Aureways/AppIcon.icon` in Icon Composer
(Xcode → Open Developer Tool) and verify Default / Dark / Clear / Tinted at
32 px and 1024 px. Do not pre-clip squircle corners.
