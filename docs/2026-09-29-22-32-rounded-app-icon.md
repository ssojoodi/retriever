# Rounded app icon

The approved image contains an opaque square backdrop outside its cream rounded tile. Preserve the approved original and derive `Brand/Retriever-AppIcon.png` with a transparent outer background. Generate all app-icon sizes from the cutout, preserving alpha. Dock and About already load the bundled icon.

Image editing used the built-in imagegen tool. Prompt: remove only the opaque outer background; preserve the cream rounded-square tile, mascot, colors and composition. Refinement prompt: remove outer shadow, halo and fringe, preserving the tile interior and transparent exterior.

Validate generated alpha, build, and inspect Dock/About at native display size.

## Results
All ten generated PNGs have transparent corners and opaque central artwork. Debug build passed. Inspected the 128-pixel rendition and the running bundle’s Dock and About screenshots; the opaque outer square is gone. The approved original remains unchanged.

## Final imagegen prompt
Use case: background-extraction. Refine ONLY the alpha boundary of this app icon cutout. The current outer edge has ragged pale gray/white halo fragments. Remove ALL outer shadow, halo, fringe, and stray pixels outside the cream rounded-square tile. The tile silhouette must have pristine smooth antialiased edges: perfectly straight horizontal/vertical sides joined by consistent smooth round corners. Outside that silhouette must be fully transparent. Do not alter any pixels inside the tile, the mascot, face, colors, layout, size or square canvas. No new shadow. This is precise edge cleanup, not a redesign.
