// MIT License. Unity URP port of Godot 4 pixelart_stylizer.gdshader by Leo Peltola
// Inspired by https://threejs.org/examples/webgl_postprocessing_pixel.html
//
// All depth calculations, edge-detection thresholds and compositing are ported
// 1:1 from the original GLSL.  The only platform adaptations are:
//   - getDepth()   → LinearEyeDepth(_ZBufferParams) handles reversed-Z / DX12
//   - normals       → SampleSceneNormals() decodes URP's oct-rect encoded normals
//                    (stored in _CameraNormalsTexture by the DepthNormals prepass)
//   - SCREEN_TEXTURE → _BlitTexture  (Blitter API)
//   - VIEWPORT_SIZE  → _ScreenParams.xy

Shader "Hidden/PixelArtStylizer"
{
    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            Name "PixelArtStylizer"
            ZTest  Always
            ZWrite Off
            Cull   Off
            Blend  Off

            HLSLPROGRAM
            #pragma vertex   Vert
            #pragma fragment Frag

            // URP core + full-screen blit helpers
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            // Declares _CameraDepthTexture + SampleSceneDepth(uv)
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            // Declares _CameraNormalsTexture + SampleSceneNormals(uv) → view-space float3
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"

            // ---------------------------------------------------------------
            // Shader parameters — identical to Godot shader_parameter block
            // ---------------------------------------------------------------
            float  _ShadowsEnabled;       // uniform bool shadows_enabled
            float  _HighlightsEnabled;    // uniform bool highlights_enabled
            float  _ShadowStrength;       // uniform float shadow_strength    (hint_range 0..1)
            float  _HighlightStrength;    // uniform float highlight_strength (hint_range 0..1)
            float4 _HighlightColor;       // uniform vec3  highlight_color
            float4 _ShadowColor;          // uniform vec3  shadow_color

            // ---------------------------------------------------------------
            // getDepth() — 1:1 port
            //
            // Godot:
            //   float raw = texture(depth_texture, uv)[0];
            //   vec3  ndc = vec3(uv * 2.0 - 1.0, raw);
            //   vec4  vs  = inv_projection_matrix * vec4(ndc, 1.0);
            //   vs.xyz /= vs.w;
            //   return -vs.z;
            //
            // Unity: LinearEyeDepth() performs the identical NDC→view-space
            // projection and returns the same positive eye-space distance,
            // correctly handling Direct3D reversed-Z and Vulkan depth ranges.
            // ---------------------------------------------------------------
            float GetDepth(float2 uv)
            {
                float rawDepth = SampleSceneDepth(UnityStereoTransformScreenSpaceTex(uv));
                return LinearEyeDepth(rawDepth, _ZBufferParams);
            }

            // ---------------------------------------------------------------
            // normalIndicator() — 1:1 port
            // ---------------------------------------------------------------
            float NormalIndicator(float3 normalEdgeBias, float3 baseNormal,
                                  float3 newNormal,      float  depthDiff)
            {
                float normalDiff     = dot(baseNormal - newNormal, normalEdgeBias);
                float ni             = clamp(smoothstep(-0.01, 0.01, normalDiff), 0.0, 1.0);
                float depthIndicator = clamp(sign(depthDiff * 0.25 + 0.0025), 0.0, 1.0);
                return (1.0 - dot(baseNormal, newNormal)) * depthIndicator * ni;
            }

            // ---------------------------------------------------------------
            // fragment() — 1:1 port
            // ---------------------------------------------------------------
            half4 Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float2 uv = input.texcoord;

                // e = vec2(1. / VIEWPORT_SIZE.xy)
                float2 e = float2(1.0 / _ScreenParams.x, 1.0 / _ScreenParams.y);

                // ==============================================================
                // Shadows (depth-based outline / concavity detection)
                // ==============================================================
                float depthDiff    = 0.0;
                float negDepthDiff = 0.5;

                UNITY_BRANCH
                if (_ShadowsEnabled > 0.5)
                {
                    float depth = GetDepth(uv);
                    float du    = GetDepth(uv + float2( 0.0, -1.0) * e);
                    float dr    = GetDepth(uv + float2( 1.0,  0.0) * e);
                    float dd    = GetDepth(uv + float2( 0.0,  1.0) * e);
                    float dl    = GetDepth(uv + float2(-1.0,  0.0) * e);

                    depthDiff += clamp(du - depth, 0.0, 1.0);
                    depthDiff += clamp(dd - depth, 0.0, 1.0);
                    depthDiff += clamp(dr - depth, 0.0, 1.0);
                    depthDiff += clamp(dl - depth, 0.0, 1.0);

                    negDepthDiff += depth - du;
                    negDepthDiff += depth - dd;
                    negDepthDiff += depth - dr;
                    negDepthDiff += depth - dl;
                    negDepthDiff = clamp(negDepthDiff, 0.0, 1.0);
                    // smoothstep(0.5, 0.5, x) is a degenerate step (edge0==edge1 → acts as step(0.5, x)).
                    // Preserved 1:1 from original Godot shader line 69; the * 10 + outer clamp keep it in [0,1].
                    negDepthDiff = clamp(smoothstep(0.5, 0.5, negDepthDiff) * 10.0, 0.0, 1.0);
                    depthDiff    = smoothstep(0.2, 0.3, depthDiff);
                }

                // ==============================================================
                // Highlights (normal-based convexity / silhouette detection)
                // ==============================================================
                float normalDiff = 0.0;

                UNITY_BRANCH
                if (_HighlightsEnabled > 0.5)
                {
                    // SampleSceneNormals() returns view-space normals decoded with
                    // UnpackNormalOctRectEncode() — the space differs from Godot's
                    // world-space normals, but the per-pixel discontinuity pattern
                    // is identical, so all thresholds remain valid.
                    float3 normal = SampleSceneNormals(UnityStereoTransformScreenSpaceTex(uv));
                    float3 nu     = SampleSceneNormals(UnityStereoTransformScreenSpaceTex(uv + float2( 0.0, -1.0) * e));
                    float3 nr     = SampleSceneNormals(UnityStereoTransformScreenSpaceTex(uv + float2( 1.0,  0.0) * e));
                    float3 nd     = SampleSceneNormals(UnityStereoTransformScreenSpaceTex(uv + float2( 0.0,  1.0) * e));
                    float3 nl     = SampleSceneNormals(UnityStereoTransformScreenSpaceTex(uv + float2(-1.0,  0.0) * e));

                    float3 normalEdgeBias = float3(1.0, 1.0, 1.0);
                    normalDiff += NormalIndicator(normalEdgeBias, normal, nu, depthDiff);
                    normalDiff += NormalIndicator(normalEdgeBias, normal, nr, depthDiff);
                    normalDiff += NormalIndicator(normalEdgeBias, normal, nd, depthDiff);
                    normalDiff += NormalIndicator(normalEdgeBias, normal, nl, depthDiff);
                    normalDiff  = smoothstep(0.2, 0.8, normalDiff);
                    normalDiff  = clamp(normalDiff - negDepthDiff, 0.0, 1.0);
                }

                // ==============================================================
                // Compositing — 1:1 port
                // ==============================================================
                // original_color = texture(SCREEN_TEXTURE, SCREEN_UV).rgb
                float3 originalColor       = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, input.texcoord).rgb;
                float3 finalHighlightColor = lerp(originalColor, _HighlightColor.rgb, _HighlightStrength);
                float3 finalShadowColor    = lerp(originalColor, _ShadowColor.rgb,    _ShadowStrength);
                float3 finalColor          = originalColor;

                if (_HighlightsEnabled > 0.5)
                    finalColor = lerp(finalColor, finalHighlightColor, normalDiff);
                if (_ShadowsEnabled > 0.5)
                    finalColor = lerp(finalColor, finalShadowColor, depthDiff);

                // Godot also outputs ALPHA to composite the plane over the scene.
                // In the URP post-process pass we write opaque; the same blending
                // is implicit in the lerp operations above.
                return half4(finalColor, 1.0);
            }
            ENDHLSL
        }
    }
}
