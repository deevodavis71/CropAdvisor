# Crop Advisor

A macOS app that analyses a Nikon NEF (or any RAW/JPEG/HEIC) photo and suggests crops that
strengthen its composition, with side-by-side **Before** / **After** previews.

![Crop Advisor suggesting a 3:2 crop that brings a robin in close](docs/screenshots/main.png)

## Screenshots

**Suggested crop, before and after.** The Before view shows the photo as shot, with the crop, a
rule-of-thirds grid and the detected focal point (yellow ring). The After view shows the result.
The sidebar ranks a crop for every standard aspect ratio. It opens on the camera's own ratio, and
the highest scorer is tagged **BEST**.

**Overlays.** The saliency heat map shows where the eye is drawn, and the detection overlay marks
subjects (dashed boxes), faces, gaze direction and limb joints.

![Saliency heat map and detected subject overlaid on a flower](docs/screenshots/overlays.png)

**Horizon levelling.** A tilted horizon is levelled automatically for scenes that look like
landscapes. The crop is drawn rotated on the original, exactly where it will be cut, and the
After view is straight.

![A castle photo levelled by 1.2° before cropping](docs/screenshots/levelling.png)

**The advice.** Each crop has a score, the reasons it works, any warnings, its exact pixel bounding
box and a per-guideline breakdown.

<img src="docs/screenshots/advice.png" alt="Advice sidebar with ranked crops, reasons, pixel box and score breakdown" width="350">

## Build & run

Requires macOS 15+. Works with just the Command Line Tools (no Xcode needed):

```sh
./build_app.sh            # -> build/CropAdvisor.app
open build/CropAdvisor.app
```

The app icon is drawn in code: edit `scripts/make_icon.swift`, then run `scripts/make_icon.sh`
to regenerate `Resources/AppIcon.icns`.

Open a photo with ⌘O, drag it onto the window, or use Finder's *Open With ▸ CropAdvisor*.

## What it checks

Standard cropping guidelines,
each scored 0–100 and weighted into an overall score:

| Guideline | How it's measured |
|---|---|
| Subject placement | Eyes on the upper third line (portraits) or main subject on a thirds intersection; deliberate centring scores a little less |
| Subject kept | Share of Vision's attention-saliency map kept inside the crop |
| Subject emphasis | How well the subject fills the frame without being cramped |
| Clean edges | Bright, salient or busy areas along each border that pull the eye out |
| Nothing awkwardly cut | Salient objects sliced part-way by an edge |
| Room to look into | Space in front of a face, in the direction it is turned |
| Avoids cutting at joints | Edges passing close to elbows, wrists, knees, ankles, neck (body-pose detection) |
| Horizon placement | A strong horizon on a third line rather than through the middle |
| Resolution kept | Penalises heavy crops that would hurt prints |

Hard rules: faces (and animals) are never cut, the focal point stays clear of the edges, and at
least 20% of the frame is kept. Candidates are searched across standard ratios (original, 3:2,
4:3, 5:4, 1:1, 16:9 and their portrait versions), then re-ranked with Apple's on-device
image-aesthetics model (20% of the final score).

**Horizon levelling:** Vision's horizon detector also fires on perspective lines such as roads and
tables, so *Auto* only levels scenes with a bright sky and no people. Otherwise it shows a hint, and
you can set *Level the horizon* to *On*.

## Using it

- Pick any suggestion in the sidebar to see why it works, plus any warnings.
- In the Before view, drag inside the crop to move it, or drag a corner or edge handle to resize it.
  The aspect ratio is locked by default; hold ⇧ or turn off *Lock aspect ratio* to resize freely.
  Pinching or the size slider also resize it. Scores update live.
- Toolbar toggles: thirds grid, detections overlay (faces, gaze, subjects, joints, horizon),
  saliency heat map, side-by-side or stacked layout.
- **Export** (⌘E) re-develops the RAW at full resolution and writes a cropped JPEG, 16-bit TIFF or HEIC
  with the camera's EXIF. The NEF is never modified.

## Command line

```sh
build/CropAdvisor --analyze photo.NEF [--level auto|on|off] [--export best.jpg]
build/CropAdvisor --snapshot photo.NEF ui.png [--detections] [--heatmap] [--stacked]
```

`--snapshot` renders the window to a PNG; it is how the screenshots above were made, e.g.
`SNAP_WIDTH=1700 SNAP_HEIGHT=640 build/CropAdvisor --snapshot photo.NEF main.png`, then
`sips -Z 1800 main.png`.

## Source layout

- `ImageLoader.swift`: RAW decode (CIRAWFilter), metadata, horizon straightening
- `SceneAnalyzer.swift`: Vision saliency, faces and gaze, people, pose, animals, horizon line
- `CropEngine.swift`: guideline scoring, candidate search and plain-English advice
- `Pipeline.swift`: analysis pipeline, aesthetics re-ranking, full-resolution export
- `AppModel.swift`, `ContentView.swift`, `PreviewViews.swift`, `InspectorView.swift`: SwiftUI app

Note: `Package.swift` is provided for Xcode users. The Command Line Tools on this machine have a
mismatched SwiftPM manifest library, so `build_app.sh` calls `swiftc` directly. View state lives in
the `@Observable` model rather than `@State`, because the CLT SDK lacks SwiftUI's macro plugin.
