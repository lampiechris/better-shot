# Compose Screenshots

Open **Compose Screenshots** from BetterShot's menu tray.

1. Use **Add Images…** to select multiple files, or drop image files from Finder.
   Images are added in selection/drop order, with the last image in front.
2. Use **Capture Window** for each additional window. The composer hides while
   macOS's native window selector is open and returns after selection or Escape.
   Capture requires Screen Recording permission, just like normal window capture.
3. Choose a row, column, or grid and press **Arrange**, or drag images freely.
   Select any image on the canvas or in the front-to-back screenshot list. Drag
   its blue bottom-right handle to resize while retaining its proportions.
   X, Y, and Width also accept typed values in the left inspector.
4. Choose **Aspect Ratio** for a preset with a 1080-pixel short edge, or enter
   your own width and height. Set the background (transparent, solid color, or one of the
   shared gradients), padding, and layout spacing. Padding constrains image bounds;
   spacing is applied by Arrange. Adjust corners, shadow amount, and shadow style
   independently for the selected screenshot. Backward/Forward changes overlap
   order. Undo/Redo covers imports, removal, geometry, order, and styling.
5. Leave **Export Scale** on **Auto** to retain the original pixel detail of every
   screenshot, or choose 1×, 2×, or 3× for a fixed output size, then **Export PNG…**.
   The footer shows the output dimensions. At 1×, a large or Retina capture fitted
   into a smaller area is downsampled, which can soften fine text. Auto increases
   the whole canvas resolution enough to avoid that reduction. Export uses original
   source pixels, with lossless PNG and transparent backgrounds. Increasing the
   scale cannot invent detail absent from an original image. Native-size images
   are aligned to output pixels and drawn without interpolation.

The new canvas reads General's Default Look when opened. Editing it does not
change those defaults or any imported files. Window captures exclude the native
baked-in shadow, allowing the per-image shadow to remain adjustable.

## Social Post

1. Right-click a screenshot in the floating preview and choose **Create Social Post…**,
   or choose **Post → New Social Post** in **Compose Screenshots**.
2. Choose **Headline Above**, **Screenshot First**, or **Side by Side** under **Layout**.
   Side by Side works well with short copy and a tall screenshot. BetterShot balances
   two-line headlines automatically. Press **Option–Return** in the headline to choose where it wraps.
   Add an optional caption and logo. Use **Replace Screenshot…** to keep the copy and logo
   while swapping the image.
3. Click **Add Callout**, drag over a detail on the screenshot, then click
   **Apply Callout**. You can also enter the selection under **Adjust Selection**.
   Replacing the screenshot clears its callout. Undo restores both.
4. Switch between **1:1** and **4:5**, or turn on **Phone Size** to check either
   layout at up to 390 points wide.
5. Click **Export Both Sizes…** and pick a folder. BetterShot creates a new
   subfolder with two PNGs at 1080 × 1080 and 1080 × 1350 pixels.

### Save and reuse a post

- Choose **Post → Save Post** or press **⌘S** to save a `.bettershotpost` file.
  It contains the layout, screenshot, text, logo, and callout.
- Double-click a saved post in Finder or choose **Post → Open Post…** in either composer.
- Choose **Post → Duplicate Post** to open an independent copy, then save it under its own name.
  Replacing the screenshot clears its callout and keeps the text and logo.

## First-pass limits

- The freeform composition window keeps its canvas in memory and exports flattened PNGs.
  Closing an unexported canvas offers Export, Discard, or Cancel. Export leaves the
  window open so the completed file can be checked before closing.
- Up to 24 images, 64 megapixels per source, and 128 megapixels of imported sources
  per canvas. Animated files use their first frame. Imports decode synchronously;
  large batches may briefly pause the editor.
- Canvas dimensions: 400–6,000 pixels per edge. Exports: at most 64 megapixels and
  16,384 pixels per edge; oversized scale choices, including Auto, give a recoverable
  error. Choose a fixed lower export scale if Auto exceeds this limit.
- Resize is proportional. No crop, per-image annotation editing, rotation,
  snapping guides, multiple selection, or direct capture-deck batch selection.
- Background wallpaper is retained when supplied by Default Look; choosing a new
  wallpaper within the composer is not included. Images retain their own alpha;
  rounded corners cannot remove a shadow already baked into an imported image.
- Preview and export use the same Core Graphics renderer in sRGB. Large source
  sets can cost more during dragging; interactive capture/permissions must also
  be checked in the actual signed app before any release.
- Padding keeps image rectangles inside the canvas. A shadow can extend beyond
  its image; increase padding if a shadow is clipped at the canvas edge.

## Implementation and verification plan

Keep the single-image editor and existing capture paths intact. Add a focused
native window with a left inspector, immutable source images, value snapshots
for undo, shared background/shadow drawing, and atomic PNG export. Verify the
production document/renderer through `make test`, inspect compact and regular
light/dark snapshots, and build unsigned Release. Native window selection and
macOS privacy approval remain distinct from offscreen/rendering checks.
