// MIT License. Unity URP port of Godot 4 pixelart_stylizer.gdshader by Leo Peltola.
// Inspired by https://threejs.org/examples/webgl_postprocessing_pixel.html
//
// HOW TO USE:
//   1. Select your URP Renderer asset (Project Settings → Graphics → Scriptable
//      Render Pipeline Settings, then open the Renderer asset listed there).
//   2. Click "Add Renderer Feature" and choose PixelArtStylizerFeature.
//   3. Adjust shadows / highlights in the feature's Settings fold-out.
//   4. Ensure your URP asset has "Depth Texture" and "Depth Normals" enabled
//      (or keep them at "Auto" / leave the feature to request them).
//
// Requires Unity 2021.3+ (URP 12+).

using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Adds a full-screen pixel-art outline / highlight post-process pass to the
/// URP render pipeline.  All settings map 1:1 to the uniforms in the original
/// Godot shader (<c>pixelart_stylizer.gdshader</c>).
/// </summary>
public sealed class PixelArtStylizerFeature : ScriptableRendererFeature
{
    // -------------------------------------------------------------------------
    // Settings — 1:1 with Godot's shader_parameter block
    // -------------------------------------------------------------------------
    [Serializable]
    public sealed class Settings
    {
        [Tooltip("uniform bool shadows_enabled")]
        public bool shadowsEnabled = true;

        [Tooltip("uniform bool highlights_enabled")]
        public bool highlightsEnabled = true;

        [Tooltip("uniform float shadow_strength  (hint_range 0..1)")]
        [Range(0f, 1f)] public float shadowStrength = 0.4f;

        [Tooltip("uniform float highlight_strength (hint_range 0..1)")]
        [Range(0f, 1f)] public float highlightStrength = 0.1f;

        [Tooltip("uniform vec3 highlight_color  (source_color)")]
        public Color highlightColor = Color.white;

        [Tooltip("uniform vec3 shadow_color  (source_color)")]
        public Color shadowColor = Color.black;
    }

    // -------------------------------------------------------------------------
    // Public inspector field
    // -------------------------------------------------------------------------
    public Settings settings = new Settings();

    // -------------------------------------------------------------------------
    // Internal state
    // -------------------------------------------------------------------------
    private PixelArtStylizerPass _pass;
    private Material             _material;

    // -------------------------------------------------------------------------
    // ScriptableRendererFeature overrides
    // -------------------------------------------------------------------------

    /// <inheritdoc/>
    public override void Create()
    {
        _material = CoreUtils.CreateEngineMaterial("Hidden/PixelArtStylizer");
        _pass     = new PixelArtStylizerPass(_material);

        // Run just before built-in post-processing so the stylizer is visible
        // under any additional URP post-processing volumes.
        _pass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
    }

    /// <inheritdoc/>
    public override void AddRenderPasses(ScriptableRenderer renderer,
                                         ref RenderingData   renderingData)
    {
        if (_material == null) return;

        // Skip for scene-view and preview cameras to avoid artefacts.
        var cameraType = renderingData.cameraData.cameraType;
        if (cameraType == CameraType.Preview || cameraType == CameraType.Reflection)
            return;

        _pass.Setup(settings);
        renderer.EnqueuePass(_pass);
    }

    /// <inheritdoc/>
    protected override void Dispose(bool disposing)
    {
        _pass?.Dispose();
        CoreUtils.Destroy(_material);
    }
}

// =============================================================================
// Render pass
// =============================================================================

/// <summary>
/// Full-screen blit pass that applies the pixel-art depth/normal edge shader.
/// </summary>
internal sealed class PixelArtStylizerPass : ScriptableRenderPass
{
    // -------------------------------------------------------------------------
    // Shader property IDs — cached once at construction
    // -------------------------------------------------------------------------
    private static readonly int _idShadowsEnabled    = Shader.PropertyToID("_ShadowsEnabled");
    private static readonly int _idHighlightsEnabled = Shader.PropertyToID("_HighlightsEnabled");
    private static readonly int _idShadowStrength    = Shader.PropertyToID("_ShadowStrength");
    private static readonly int _idHighlightStrength = Shader.PropertyToID("_HighlightStrength");
    private static readonly int _idHighlightColor    = Shader.PropertyToID("_HighlightColor");
    private static readonly int _idShadowColor       = Shader.PropertyToID("_ShadowColor");

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    private readonly Material _material;
    private RTHandle           _tempRT;
    private PixelArtStylizerFeature.Settings _settings;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------
    internal PixelArtStylizerPass(Material material)
    {
        _material = material;

        // Ask URP to supply the depth buffer and the normals buffer
        // (triggers DepthNormals prepass in Forward rendering).
        ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);

        // We need an intermediate RT so we can read-then-write the color buffer.
        requiresIntermediateTexture = true;
    }

    // -------------------------------------------------------------------------
    // Called every frame by the feature before EnqueuePass
    // -------------------------------------------------------------------------
    internal void Setup(PixelArtStylizerFeature.Settings settings)
    {
        _settings = settings;
    }

    // -------------------------------------------------------------------------
    // ScriptableRenderPass overrides
    // -------------------------------------------------------------------------

    /// <inheritdoc/>
    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
        desc.depthBufferBits = 0;   // colour-only temp RT
        RenderingUtils.ReAllocateIfNeeded(
            ref _tempRT, desc,
            FilterMode.Bilinear,
            name: "_PixelArtStylizerTemp");
    }

    /// <inheritdoc/>
    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        if (_material == null || _settings == null) return;

        CommandBuffer cmd = CommandBufferPool.Get("PixelArtStylizer");

        // Upload settings → material uniforms (1:1 mapping to Godot shader_parameters)
        _material.SetFloat(_idShadowsEnabled,    _settings.shadowsEnabled    ? 1f : 0f);
        _material.SetFloat(_idHighlightsEnabled, _settings.highlightsEnabled ? 1f : 0f);
        _material.SetFloat(_idShadowStrength,    _settings.shadowStrength);
        _material.SetFloat(_idHighlightStrength, _settings.highlightStrength);
        _material.SetColor(_idHighlightColor,    _settings.highlightColor);
        _material.SetColor(_idShadowColor,       _settings.shadowColor);

        // Blit: scene colour → apply effect → write back to scene colour
        RTHandle source = renderingData.cameraData.renderer.cameraColorTargetHandle;
        Blitter.BlitCameraTexture(cmd, source,  _tempRT, _material, 0);
        Blitter.BlitCameraTexture(cmd, _tempRT, source);

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    /// <inheritdoc/>
    public override void OnCameraCleanup(CommandBuffer cmd) { }

    // -------------------------------------------------------------------------
    // Disposal
    // -------------------------------------------------------------------------
    internal void Dispose()
    {
        _tempRT?.Release();
        _tempRT = null;
    }
}
