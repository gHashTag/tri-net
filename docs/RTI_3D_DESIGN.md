# 3D RTI — how to best do radio tomography in space (design + prototype)

Goal: locate a body/obstruction in a VOLUME (x, y, and height/floor), not just on a floor plan, and
show it live in the macOS app. This is the design study behind the shipped prototype
(`phone/desktop/RTI3D.swift`).

## 1. The science (Radio Tomographic Imaging, Wilson & Patwari 2010)

A mesh of N nodes has M = N(N-1)/2 links. A body attenuates each link's received power. Model the
space as a grid of voxels with an unknown attenuation field `x`. Each link's attenuation is a
weighted sum of the voxels it passes through:

```
  y = W x        y ∈ R^M (per-link RSS drops),  x ∈ R^V (voxel attenuations),  W ∈ R^{M×V}
```

**Ellipsoid weight model (the 3D generalization of the 2D ellipse).** A voxel at p contributes to
link (a,b) only if it lies inside the ellipsoid with foci a,b and excess-path-length width λ:

```
  |a-p| + |p-b| - |a-b| < λ     →    W[link,voxel] = 1 / sqrt(|a-b|)      else 0
```

(λ ~ a fraction of a wavelength/voxel; wider λ = fatter beam = blurrier but more robust.) This is the
first Fresnel-zone influence region; the 1/sqrt(length) normalizes for link length.

**Reconstruction.**
- Real-time first order = **backprojection** `x = Wᵀ y` — each voxel accumulates the drops of the
  links whose ellipsoid contains it. Cheap, streams live. **This is what the prototype does.**
- Better = **regularized (Tikhonov) inverse** `x = (WᵀW + C⁻¹)⁻¹ Wᵀ y`, where C is a spatial
  correlation prior (neighboring voxels correlated, correlation length δ). Sharper, less noise;
  the `(WᵀW+C⁻¹)⁻¹Wᵀ` matrix is precomputed once (geometry is fixed) and applied per frame.
- Motion = **VRTI** (variance-based RTI): use the RSS *variance* per link instead of mean drop —
  a moving body is detected even without a static baseline.

## 2. The crux: making the z-axis observable

A body's height is only recoverable if the links **span the vertical dimension**. If all nodes are at
one height, every link is coplanar and the ellipsoids are vertical prisms — z is unobservable (the
reconstruction smears through all floors). **Nodes MUST have vertical diversity.** Practical rules:
- Place nodes at ≥2 heights (floor + ceiling, or staggered).
- More nodes = more links = better conditioning. 4 corner nodes (6 links) give a coarse blob;
  ~12-20 nodes around a room give sub-meter 3D localization in the literature.
- Voxel grids in practice: ~0.15-0.3 m voxels; a room is ~15-30 voxels per axis.

The prototype places the 4 boards at TWO heights (.13/.10 high, .11/.12 low) precisely so z is
partially observable with only 4 nodes.

## 3. Rendering (macOS SwiftUI)

**SceneKit is the right tool** for ~1000 live voxels — far simpler than raw Metal, more capable than
a 2D Canvas. `SCNView` wrapped in `NSViewRepresentable`; `allowsCameraControl = true` gives free
orbit/zoom. Each voxel is a small `SCNBox`; a `Timer` reads the engine's voxel array a few times a
second and sets each node's `opacity` + material `diffuse/emission` color (blue→cyan→green→
yellow→red). `writesToDepthBuffer = false` + `.dualLayer` transparency gives the volumetric look.
Node markers are `SCNSphere` + billboard-constrained `SCNText` labels; a wireframe `SCNBox`
(`fillMode = .lines`) frames the volume. (RealityKit is overkill and macOS-version-touchy; Metal is
too low-level for the payoff.)

## 4. What shipped (prototype, verified on-screen)

- `RTIEngine` backprojects every UDP link packet into a 12×12×6 ellipsoid field (`RTIHeatmap.swift`).
- `RTI3DView` renders it in SceneKit with orbit camera; a `3D / 2D-floor` toggle in the RTI tab
  (3D default).
- Fed the two crossing diagonals over the air: two link "beams" cross inside the cube, localizing
  presence in 3D. Coarse (4 nodes) but real and live.

## 5. Roadmap to production-grade 3D RTI

1. **More anchors, real heights** — deploy 8-16 boards at surveyed 3D positions; this is the single
   biggest resolution win.
2. **Regularized inverse** — precompute `(WᵀW+C⁻¹)⁻¹Wᵀ` for the fixed geometry; apply per frame for a
   sharp blob instead of fat beams.
3. **VRTI for motion** — feed per-link RSS variance (the boards already stream RSS); detect movement
   with no calibration.
4. **linkq gate** — only update a link's measurement when preamble correlation confirms signal
   (the other agent's primitive), so noise doesn't smear the field.
5. **Real surveyed room** — put the boards around an actual room at known (x,y,z); walk through it and
   watch the blob track in 3D (the bench-gated biological positive).
