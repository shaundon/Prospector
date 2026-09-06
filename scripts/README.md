# fix-usdz-textures.py

Repairs a USDZ so Apple devices render all of it, instead of drawing parts of the model as magenta diagonal stripes.

## What the stripes mean

Apple's renderers draw those stripes when a mesh has a material problem. Two causes account for nearly all of them in SketchUp exports:

- **A texture the renderer refuses to load.** SketchUp writes each material's original image filename straight into the USDZ. Textures from 3D Warehouse components keep the name they were downloaded with, so you get files like `.png` (no name at all) or `image_download=true.png`. The image data is fine; the filename is not.
- **A mesh with no material.** Faces still painted with SketchUp's default material are exported with no material binding at all.

## Usage

```
Scripts/fix-usdz-textures.py "My Room.usdz"
```

That writes `My Room-fixed.usdz` next to the original. To choose the output path:

```
Scripts/fix-usdz-textures.py "My Room.usdz" ~/Desktop/room.usdz
```

Requires macOS 15 or later.

## What it does

1. Unpacks the USDZ and converts its root layer to text with `usdcat`.
2. Renames every texture to a plain filename made of letters, digits, underscores and hyphens. A nameless file becomes `texture_N.png`.
3. Converts image formats Apple can't read (TIFF, PSD, BMP, GIF, TGA, WebP, HEIC) to PNG with `sips`.
4. Rewrites every material's texture reference to the new name.
5. Adds a plain grey `UsdPreviewSurface` material inside the root prim and binds it to every mesh that has none.
6. Repackages with `usdzip`, which keeps the archive layout Apple's loaders require.

## Reading the output

```
renamed  0/.png  ->  0/texture_1.png
renamed  0/image_download=true.png  ->  0/image_download_true.png
bound    7 meshes with no material to a plain grey one
MISSING  0/carpet.jpg  (referenced but not in the archive; will still render striped)

wrote /Users/you/Desktop/My Room-fixed.usdz
```

- `renamed` lines are the textures it fixed.
- `bound` reports meshes given the default material. If you'd rather they had a real colour, paint them in SketchUp and re-export.
- `MISSING` means a material points at a file that was never packed into the USDZ. The script can't invent it; re-export from SketchUp with the texture present.