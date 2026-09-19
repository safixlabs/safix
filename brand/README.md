# Safix brand

Everything the three surfaces draw from. Nothing here is redrawn by hand anywhere
else: the icons, the social cards and the in-product mark are all generated from
these files, so the brand cannot drift between them.

## The files

| File | What it is |
| --- | --- |
| `mark.png` | The mark alone, transparent, 1280px. The supplied original. |
| `mark-square.png` | The same mark trimmed to its own edges and centred on a square canvas. This is what every derived size is built from, so a square render never distorts it. |
| `icon.png` | The finished app icon: the mark on its own field, with its own corner radius, 1800px. |
| `icon-vivid.png` | The same icon on the brighter field. An alternative, not in use. |
| `social-square.png` | Square social card, 1800px. |
| `social-banner.png` | Wide banner with the wordmark, 6000x2000. |
| `banner-1500.png` | The banner at the width a README or a header renders. |
| `repo-social-1280x640.png` | A repository's social preview, cropped from the banner's middle rather than squeezed into the ratio. Uploaded in repository settings, not committed anywhere. |
| `avatar-1024.png` | Square, flattened, for a profile picture. |

## Which asset goes where

**The mark, bare.** In product, on the application's own dark surfaces: the top
navigation, the documentation sidebar, and the social cards each page generates.
It ships with transparency and no field of its own, because it is always placed on
a surface the product controls.

**The icon, finished.** Anywhere the destination controls the background: the
favicon, the touch icon, the launcher icon, the wallet connection prompt. It
carries its own field, so it stays legible on a light tab strip as well as a dark
one, and it survives the mask iOS and Android apply to a home screen icon.

Using the bare mark as a favicon is the mistake worth naming: on a light tab strip
a near-white mark on transparency disappears completely.

## How the derived sizes are made

Each surface holds the two masters it builds from in `assets/brand/`, and
generates the rest:

```
npm run build:icons     favicon, apple touch icon, and the 192, 256 and 512 launcher icons
npm run build:og        one social card per page, each carrying the mark
```

Both downsample from a master and neither scales anything up. `build-icons`
refuses to run if the master is smaller than the largest size it is asked for.

## Colour

The mark is `#e0e0e0`, near-white rather than pure white, which is what keeps it
from glaring against a dark field.

The product's own palette is separate and has not changed: carbon `#070c0c` as the
canvas and mint `#10e7c0` as the accent, defined in `app/globals.css` and paired
against each other by the contrast check. The deep green in the social assets is
the brand's field colour, not a product surface.
