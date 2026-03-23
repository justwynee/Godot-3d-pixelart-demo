# Godot → Unity URP Port — 3D Pixel Art Stylizer

This folder contains a **1:1 Unity URP port** of Leo Peltola's
[Godot 4 3D Pixel Art Shader Demo](https://github.com/leopeltola/Godot-3d-pixelart-demo).

Every algorithm, threshold and compositing step is preserved exactly.

---

## Files

| Unity file | Godot original |
|---|---|
| `Shaders/PixelArtStylizer.shader` | `pixelart_stylizer.gdshader` |
| `Scripts/PixelArtStylizerFeature.cs` | `camera.gd` + the PlaneMesh in `camera.tscn` |

---

## Requirements

| | |
|---|---|
| Unity | 2021.3 LTS or newer |
| URP | 12.x or newer |
| Rendering path | **Forward** (DepthNormals prepass) |

The shader also works with Forward+ (URP 14 / Unity 2022+).  
Deferred rendering is not supported.

---

## Setup

### 1 – Copy the files into your project

Place `Shaders/` and `Scripts/` anywhere inside your project's `Assets/` folder.

### 2 – Enable the Renderer Feature

1. Open **Edit → Project Settings → Graphics** and locate your  
   *Scriptable Render Pipeline Asset*.
2. Open the **Renderer** asset referenced by it (the one that says  
   "Universal Renderer Data").
3. At the bottom click **Add Renderer Feature → Pixel Art Stylizer Feature**.

### 3 – Configure the settings

All parameters map 1:1 to the Godot shader uniforms:

| Unity Inspector field | Godot shader_parameter | Default |
|---|---|---|
| Shadows Enabled | `shadows_enabled` | ✓ |
| Highlights Enabled | `highlights_enabled` | ✓ |
| Shadow Strength | `shadow_strength` | 0.4 |
| Highlight Strength | `highlight_strength` | 0.1 |
| Highlight Color | `highlight_color` | white |
| Shadow Color | `shadow_color` | black |

### 4 – Low-resolution rendering (recommended)

Like the Godot demo, the effect is designed for **low render resolutions**.  
To achieve the same 240 × 135 gameplay resolution:

1. Create a **Render Texture** (240 × 135, no depth).
2. Create a second camera set to *Render Texture* output and disable the
   main camera's direct output.
3. Scale the render texture up to fill the screen with a Canvas UI `RawImage`
   set to *Stretch / Fill*.

Alternatively, lower the **Render Scale** in your URP Asset to ~0.25.

---

## How it works (algorithm overview)

The shader runs as a full-screen blit pass
(`RenderPassEvent.BeforeRenderingPostProcessing`).

### Depth-based shadow outlines

```
getDepth()           →  LinearEyeDepth(_ZBufferParams)
```

Samples the linear eye-space depth at the current pixel and its four
axis-aligned neighbours (±1 px).  
Pixels where neighbours are *farther away* contribute to `depthDiff`
(convex edges / silhouettes → **shadow colour**).  
Pixels where neighbours are *closer* contribute to `negDepthDiff`
(suppresses highlight detection on convex silhouettes).

### Normal-based highlight edges

```
normalIndicator()    →  NormalIndicator()  (identical HLSL)
```

Samples the camera normals texture at the same 5 sample points.  
The `normalIndicator` function detects normal discontinuities
(concave edges / crease lines → **highlight colour**).

`_CameraNormalsTexture` is populated by URP's automatic
**DepthNormals prepass** (requested via `ConfigureInput`).  
Normals are oct-rect encoded in view space and decoded with
`SampleSceneNormals()` from `DeclareNormalsTexture.hlsl`.  
Because the algorithm only measures *differences* between adjacent
pixels, view-space vs. world-space normals produce identical results.

### Compositing

```glsl
// Godot                           // Unity HLSL (identical)
mix(a, b, t)                       lerp(a, b, t)
smoothstep(edge0, edge1, x)        smoothstep(edge0, edge1, x)
```

```
finalColor = originalColor
if highlights: finalColor = lerp(finalColor, highlightColor*strength, normalDiff)
if shadows:    finalColor = lerp(finalColor, shadowColor*strength,    depthDiff)
```

---

## License

MIT — same as the original Godot demo.
