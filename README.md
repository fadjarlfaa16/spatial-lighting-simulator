# Lighting Simulator

Landscape-first iOS prototype that combines spatial lamp planning with a single-photo
GPU relighting editor. The app is offline and uses VIPER feature boundaries.

## User flow

1. Create a **Photo** or **Video** lighting project, or reopen an existing one.
2. Place the planned subject with an AR raycast.
3. Automatically create Key, Fill, and Rim lights two metres left, right, and
   behind the subject relative to the placement camera.
4. Compose and capture one photo, then choose **Cancel / Retake** or **Proceed**.
   The shutter snapshots the AR pose/intrinsics, releases ARKit's video stream,
   and uses `AVCapturePhotoOutput` with `.photo`/`.quality` for the actual still.
5. Proceed consumes the JPEG EXIF orientation exactly once and downsamples the
   photo to at most 2048 px at quality 0.92,
   records the camera/subject/lamp snapshot, and releases the AR session.
6. Sapiens Normal and Apple's Vision foreground-mask request run once.
7. The editor caches photo, normal, and mask as Metal textures. Gestures and sliders
   change only uniforms, so the photo is not inferred again.

### Video projects

Video projects use the same still reference and editor as a photo project. Once the
lighting plan is approved, **Record 720p Video** opens a normal rear-camera recorder
configured for landscape 1280 × 720 at 30 fps. ARKit is not reopened. When recording
ends, the app freezes the already approved light positions, aims, colour, height, beam,
and global settings; it then runs the existing normal-model and Vision foreground-mask
pipeline for every frame and exports an H.264 `.mov` with the same Metal relighting
renderer. The original camera recording stays unmodified during capture, so processing
is explicitly offline and can take longer than the clip duration on some devices.

## Architecture

- `App`: composition root, navigation, dependency injection, in-memory handoff state.
- `Core/AR`: ARKit world tracking and raycasts only.
- `Core/Models`: persistent physical scene, analysis buffers, renderer DTOs.
- `Core/Math`: the only implementation of distance, aiming, beam, CCT, and photometry math.
- `Core/ML`: Normal-only staged Core ML inference and Vision mask generation.
- `Core/Rendering`: cached Metal textures, 60 Hz on-demand preview, export readback.
- `Core/Video`: isolated 720p/30 fps camera recording and offline AVFoundation frame
  reader/writer that reuses the photo renderer.
- `Features/*`: VIPER View, Interactor, Presenter, Entity, and Router files.

The persistent `VirtualLight` is the source of truth in AR world coordinates. The
one-way `SpatialToImageLightingMapper` creates transient `RelightLight` values for
Metal. This avoids the duplicate physical/screen lamp logic that existed in the two
source prototypes.

## Spatial snapshot and lifecycle

`SpatialPlanSnapshot` contains only Codable/value data:

- capture camera transform, intrinsics, sensor resolution, and JPEG image orientation;
- subject position;
- fixed lamp positions and current aim;
- camera-to-subject, camera-to-lamp, lamp-to-subject, and lamp-to-lamp distances.

After Proceed, `ARSessionService.stopAndRelease()` pauses AR and clears its retained
`ARFrame`, camera transform, interruption state, and derived boundary. No `ARSession`,
`ARFrame`, `CVPixelBuffer`, anchor, or RealityKit entity reaches the editor.

## No LiDAR, Pointmap, or segmentation model

Planning uses `ARWorldTrackingConfiguration`, horizontal/vertical plane detection,
and raycasts. It does **not** enable mesh reconstruction, scene depth, or person depth.

The app bundles only the 26 staged `SapiensNormal*.mlpackage` programs. Dense Pointmap
and Sapiens Segmentation models are not used or included. Masking comes from
`VNGenerateForegroundInstanceMaskRequest`; failure is non-fatal and relighting can
still operate over the full frame.

## Model preprocessing

`SapiensImagePreprocessor` reproduces the conversion pipeline:

- orientation-correct upright RGB;
- aspect-fit into 768 × 1024;
- centered black letterbox with deterministic integer truncation;
- ImageNet mean/std normalization;
- contiguous NCHW Float32 tensor.

Inference runs Patch → Block00...Block23 → Head sequentially. Each model is scoped to
an autorelease pool before the next stage loads. Automatic compute tries `.all` first
and falls back to `.cpuAndGPU`, helping devices that reject an ANE execution plan.

## Editor behavior

The photo uses the left two-thirds of the landscape screen. The right third is split
between a metrically uniform Cartesian floor-plan preview and scrollable controls.
Dragging the selected COB ray moves its target in the captured camera's screen-right/
screen-down axes. Its floor X/Z position stays fixed; changing height moves only the
fixture head's world Y before recalculating aim, distance, projection, and attenuation.
**Clean Preview** hides the ray, and export always renders without editor overlays.
The selected ray is rendered as a translucent projected COB fixture and volumetric
beam so its origin remains visually tied to the previously placed AR lamp.

Ambient applies to the whole image. The foreground mask blends detailed normal-based
lighting on lifted objects while the full frame receives spatial falloff. Distance is
the measured COB-head-to-aim distance rather than a free slider. The inverse-square
falloff is exposure-calibrated so a typical 4 m fixture remains visible but weaker than
the same fixture at close range.

## Known limitations

- A single photo plus normals is a 2.5D approximation. It cannot generate cast shadows,
  reveal hidden geometry, or provide per-pixel metric depth.
- Video relighting is deliberately offline and analyses every 720p frame independently.
  It keeps the approved lighting plan stable across the clip, but it does not yet apply
  temporal normal/mask stabilization for fast subject motion.
- A 2D aim drag moves the target on the captured camera's subject-depth plane;
  it cannot identify a new hidden 3D target without returning to AR.
- Stored world coordinates are meaningful within the planning/capture session. This
  prototype does not persist an `ARWorldMap` for cross-day relocalization.
- The world pose is sampled at the shutter tap immediately before ARKit hands the
  camera to the high-quality still session. Hold the device steady during this short
  handoff; the two pipelines cannot own the camera concurrently.
- Vision foreground masks are class-agnostic foreground extraction, not metric
  nearest-object detection.
- The staged Normal model is large and must be benchmarked on every supported device.

## Model assets

Place these in `lighting-simulator-app/Resources/Models/`:

- `SapiensNormalPatch.mlpackage`
- `SapiensNormalBlock00.mlpackage` through `SapiensNormalBlock23.mlpackage`
- `SapiensNormalHead.mlpackage`

Do not add Pointmap or Sapiens Segmentation packages. The runtime also supports staged
compiled models in `Documents/SapiensModels/` for development device deployment.
