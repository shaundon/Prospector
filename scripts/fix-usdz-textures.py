#!/usr/bin/env python3
"""
Repair a USDZ so Apple's renderers can load all of it.

SketchUp (and 3D Warehouse components in particular) export textures with
filenames taken from download URLs, which produces names like ".png" or
"image_download=true.png". Quick Look, RealityKit and visionOS refuse to load
those and draw the material with magenta stripes instead. Faces painted with
SketchUp's default material are exported with no material at all, which draws
with the same stripes.

This script unpacks the USDZ, gives every texture a plain filename (converting
formats Apple can't read to PNG), rewrites the material references to match,
binds a plain grey material to any mesh that has none, and repackages the
result with Apple's own `usdzip`.

Usage:
    fix-usdz-textures.py input.usdz [output.usdz]

Requires macOS 15 or later for /usr/bin/usdcat and /usr/bin/usdzip.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

SAFE_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg"}
CONVERTIBLE_IMAGE_EXTENSIONS = {".tif", ".tiff", ".bmp", ".gif", ".psd", ".tga", ".webp", ".heic"}
ASSET_PATTERN = re.compile(r"@([^@]+)@")
DEFAULT_MATERIAL_NAME = "ProspectorDefaultMaterial"


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"{args[0]} failed:\n{result.stderr.strip()}")
    return result.stdout


def split_extension(path):
    """Like os.path.splitext, but treats a bare ".png" as an extension with no stem."""
    base = os.path.basename(path)
    if base.startswith(".") and base.count(".") == 1:
        return "", base.lower()
    stem, ext = os.path.splitext(base)
    return stem, ext.lower()


def rename_textures(layer_text, root_dir):
    """Gives every referenced texture a plain filename, converting unsupported formats.

    Renames and converts the files on disk and returns (new layer text, list of
    (old, new) references, list of references whose file is missing).
    """
    renames = {}
    used_names = set()
    missing = []

    for index, reference in enumerate(dict.fromkeys(ASSET_PATTERN.findall(layer_text))):
        source = os.path.normpath(os.path.join(root_dir, reference))
        if not os.path.isfile(source):
            missing.append(reference)
            continue

        stem, ext = split_extension(reference)
        needs_conversion = ext in CONVERTIBLE_IMAGE_EXTENSIONS
        if not needs_conversion and ext not in SAFE_IMAGE_EXTENSIONS:
            continue  # Not a texture (e.g. a referenced sub-layer); leave it alone.

        stem = re.sub(r"[^A-Za-z0-9_-]+", "_", stem).rstrip("_") or f"texture_{index}"
        if needs_conversion:
            ext = ".png"
        candidate = stem + ext
        while candidate in used_names:
            index += 1
            candidate = f"{stem}_{index}{ext}"
        used_names.add(candidate)

        new_reference = os.path.join(os.path.dirname(reference), candidate)
        destination = os.path.join(root_dir, new_reference)
        if needs_conversion:
            run("sips", "-s", "format", "png", source, "--out", destination)
            os.remove(source)
        elif source != destination:
            os.rename(source, destination)
        if new_reference != reference:
            renames[reference] = new_reference

    layer_text = ASSET_PATTERN.sub(lambda match: f"@{renames.get(match.group(1), match.group(1))}@", layer_text)
    return layer_text, list(renames.items()), missing


def bind_default_material(layer_text):
    """Gives every mesh without a material binding a plain grey one.

    Returns the new layer text and the number of meshes that were bound.
    """
    lines = layer_text.split("\n")

    # The root prim is the first top-level def; the material goes inside it so
    # it's part of the default prim that renderers load.
    root_index = next((i for i, line in enumerate(lines) if re.match(r"^def\b", line)), None)
    if root_index is None:
        return layer_text, 0
    root_name = re.search(r'"([^"]+)"', lines[root_index]).group(1)
    root_open = next(i for i in range(root_index, len(lines)) if lines[i] == "{")
    material_path = f"/{root_name}/{DEFAULT_MATERIAL_NAME}"

    # Lines to insert after a given line index, collected first so the
    # output is built in one pass.
    insertions = {}
    for index, line in enumerate(lines):
        match = re.match(r'^(\s*)def Mesh "', line)
        if not match:
            continue
        indent = match.group(1)
        block_open = next(i for i in range(index, len(lines)) if lines[i] == indent + "{")
        block_close = next(i for i in range(block_open, len(lines)) if lines[i] == indent + "}")
        if not any("material:binding" in lines[i] for i in range(block_open, block_close)):
            insertions[block_open] = f"{indent}    rel material:binding = <{material_path}>"

    if not insertions:
        return layer_text, 0

    insertions[root_open] = f"""
    def Material "{DEFAULT_MATERIAL_NAME}"
    {{
        token outputs:surface.connect = <{material_path}/Surface.outputs:surface>

        def Shader "Surface"
        {{
            uniform token info:id = "UsdPreviewSurface"
            color3f inputs:diffuseColor = (0.8, 0.8, 0.8)
            float inputs:metallic = 0
            float inputs:roughness = 0.7
            token outputs:surface
        }}
    }}
"""
    output = []
    for index, line in enumerate(lines):
        output.append(line)
        if index in insertions:
            output.append(insertions[index])
    return "\n".join(output), len(insertions) - 1


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    input_path = os.path.abspath(sys.argv[1])
    output_path = os.path.abspath(sys.argv[2]) if len(sys.argv) == 3 else re.sub(r"\.usdz$", "", input_path) + "-fixed.usdz"

    for tool in ("usdcat", "usdzip"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found. It ships with macOS 15 and later.")

    work = tempfile.mkdtemp(prefix="usdzfix-")
    with zipfile.ZipFile(input_path) as archive:
        names = archive.namelist()
        archive.extractall(work)

    # The first file in a USDZ is its root layer.
    root = os.path.join(work, names[0])
    if not root.lower().endswith((".usd", ".usda", ".usdc")):
        sys.exit(f"First file in the archive isn't a USD layer: {names[0]}")
    root_dir = os.path.dirname(root)

    layer_text = run("usdcat", root)
    layer_text, renames, missing = rename_textures(layer_text, root_dir)
    layer_text, bound_meshes = bind_default_material(layer_text)

    fixed_layer = os.path.join(root_dir, "fixed.usda")
    with open(fixed_layer, "w") as handle:
        handle.write(layer_text)
    run("usdcat", fixed_layer, "-o", root)
    os.remove(fixed_layer)

    if os.path.exists(output_path):
        os.remove(output_path)
    run("usdzip", "-a", root, output_path)
    shutil.rmtree(work)

    for old, new in renames:
        print(f"renamed  {old}  ->  {new}")
    for reference in missing:
        print(f"MISSING  {reference}  (referenced but not in the archive; will still render striped)")
    if bound_meshes:
        print(f"bound    {bound_meshes} mesh{'es' if bound_meshes != 1 else ''} with no material to a plain grey one")
    print(f"\nwrote {output_path}")


if __name__ == "__main__":
    main()
