/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "Shared.hlsli"
#include "RaytracingShared.hlsli"

NRI_RESOURCE( Texture2D<uint3>, gIn_Scrambling_Ranking_1spp, t, 0, 1 );
NRI_RESOURCE( Texture2D<uint3>, gIn_Scrambling_Ranking_32spp, t, 1, 1 );
NRI_RESOURCE( Texture2D<uint4>, gIn_Sobol, t, 2, 1 );
NRI_RESOURCE( Texture2D<float2>, gIn_IntegratedBRDF, t, 3, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_PrevColor_PrevViewZ, t, 4, 1 );

NRI_RESOURCE( RWTexture2D<float3>, gOut_DirectLighting, u, 5, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_TransparentLighting, u, 6, 1 );
NRI_RESOURCE( RWTexture2D<float3>, gOut_ObjectMotion, u, 7, 1 ); // TODO: .w is not used
NRI_RESOURCE( RWTexture2D<float>, gOut_ViewZ, u, 8, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Normal_Roughness, u, 9, 1 );
NRI_RESOURCE( RWTexture2D<unorm float4>, gOut_BaseColor_Metalness, u, 10, 1 );
NRI_RESOURCE( RWTexture2D<float2>, gOut_ShadowData, u, 11, 1 );
NRI_RESOURCE( RWTexture2D<unorm float4>, gOut_Shadow_Translucency, u, 12, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Diff, u, 13, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_DiffDirectionPdf, u, 14, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Spec, u, 15, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_SpecDirectionPdf, u, 16, 1 );

// SPP - must be POW of 2!
// Virtual 32 spp tuned for REBLUR / RELAX purposes (actually, 1 spp but distributed in time)
// Final SPP = sppVirtual x spp (for this value there is a different "gIn_Scrambling_Ranking" texture!)
float2 GetBlueNoise( bool isCheckerboard, uint seed, Texture2D<uint3> texScramblingRanking, uint sampleIndex, const uint sppVirtual, const uint spp )
{
    // Based on:
    //     https://eheitzresearch.wordpress.com/772-2/
    // Source code and textures can be found here:
    //     https://belcour.github.io/blog/research/publication/2019/06/17/sampling-bluenoise.html (but 2D only)

    uint2 pixelPos = DispatchRaysIndex( ).xy;

    // Sample index
    uint frameIndex = isCheckerboard ? ( gFrameIndex >> 1 ) : gFrameIndex;
    uint virtualSampleIndex = ( frameIndex + seed ) & ( sppVirtual - 1 );
    sampleIndex &= spp - 1;
    sampleIndex += virtualSampleIndex * spp;

    // The algorithm
    uint3 A = texScramblingRanking[ pixelPos & 127 ];
    uint rankedSampleIndex = sampleIndex ^ A.z;
    uint4 B = gIn_Sobol[ uint2( rankedSampleIndex & 255, 0 ) ];
    float4 blue = ( float4( B ^ A.xyxy ) + 0.5 ) * ( 1.0 / 256.0 );

    // Randomize in [ 0; 1 / 256 ] area to get rid of possible banding
    uint d = STL::Sequence::Bayer4x4ui( pixelPos, gFrameIndex );
    float2 dither = ( float2( d & 3, d >> 2 ) + 0.5 ) * ( 1.0 / 4.0 );
    blue += ( dither.xyxy - 0.5 ) * ( 1.0 / 256.0 );

    return saturate( blue.xy );
}

float2 GetConeAngle( float mip, float roughness )
{
    // "coneAtRayOrigin" = "pixelAngularSize" ( for primary rays ) or GetSpecularLobeAngle( roughnessAtRayOrigin ) ( for secondary rays )
    // "coneAtRayOrigin" doesn't get propagated, "mip" gets propagated instead

    float coneAngle = STL::ImportanceSampling::GetSpecularLobeHalfAngle( roughness );
    coneAngle *= 0.33333; // Average distance between two random values in range [0; 1] is 1/3!
    coneAngle = max( gPixelAngularRadius, coneAngle ); // In any case, we are limited by the output resolution

    return float2( mip, tan( coneAngle ) );
}

float3 GetIndirectAmbient( float tmin, bool isDiffuse )
{
    float fade = REBLUR_FrontEnd_GetNormHitDist( tmin, 0.0, gSpecHitDistParams, gMeterToUnitsMultiplier, 1.0 ); // TODO: viewZ and roughness are set to 0 and 1
    fade = fade * 0.9 + 0.1;
    fade *= float( tmin != INF );

    // Don't ask me why... probably, just to get reflections brighter
    fade *= STL::Math::Pi( 1.0 );

    // Diffuse ambient is applied in Composition pass
    fade *= float( !isDiffuse );

    return gAmbient * fade;
}

float CastShadowRay( GeometryProps geometryProps, MaterialProps materialProps )
{
    bool isOpaqueRayNeeded = STL::Color::Luminance( materialProps.Lsum ) != 0.0 && !materialProps.isEmissive && gDisableShadowsAndEnableImportanceSampling == 0; // also skips INF rays

    RayDesc rayDesc;
    rayDesc.Origin = geometryProps.GetXWithOffset();
    rayDesc.Direction = gSunDirection;
    rayDesc.TMin = 0.0;
    rayDesc.TMax = INF * float( isOpaqueRayNeeded );

    float2 mipAndCone = float2( geometryProps.mip, gTanSunAngularRadius );
    Payload payload = InitPayload( mipAndCone );
    {
        const uint rayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
        const uint instanceInclusionMask = isOpaqueRayNeeded ? FLAGS_DEFAULT : 0;
        const uint rayContributionToHitGroupIndex = 0;
        const uint multiplierForGeometryContributionToHitGroupIndex = 0;
        const uint missShaderIndex = 0;

        TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
    }

    return isOpaqueRayNeeded ? payload.tmin : INF * float( materialProps.isEmissive );
}

float4 CastSoftShadowRay( GeometryProps geometryProps, MaterialProps materialProps )
{
    bool isOpaqueRayNeeded = STL::Color::Luminance( materialProps.Lsum ) != 0.0 && !materialProps.isEmissive && gDisableShadowsAndEnableImportanceSampling == 0; // also skips INF rays

    // Sample sun disk
    float2 rnd = gBlueNoise ? GetBlueNoise( false, 0, gIn_Scrambling_Ranking_1spp, 0, 1, 1 ) : STL::Rng::GetFloat2( );
    rnd = STL::ImportanceSampling::Cosine::GetRay( rnd ).xy;
    rnd *= gTanSunAngularRadius;

    float3x3 mSunBasis = STL::Geometry::GetBasis( gSunDirection ); // TODO: move to CB
    float3 direction = normalize( mSunBasis[ 0 ] * rnd.x + mSunBasis[ 1 ] * rnd.y + mSunBasis[ 2 ] );

    // Cast opaque ray
    RayDesc rayDesc;
    rayDesc.Origin = geometryProps.GetXWithOffset();
    rayDesc.Direction = direction;
    rayDesc.TMin = 0.0;
    rayDesc.TMax = INF * float( isOpaqueRayNeeded );

    float2 mipAndCone = float2( geometryProps.mip, gTanSunAngularRadius );
    Payload payload = InitPayload( mipAndCone );
    {
        const uint rayFlags = 0;
        const uint instanceInclusionMask = isOpaqueRayNeeded ? FLAGS_DEFAULT : 0;
        const uint rayContributionToHitGroupIndex = 0;
        const uint multiplierForGeometryContributionToHitGroupIndex = 0;
        const uint missShaderIndex = 0;

        TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
    }

    float hitDist = payload.tmin;

    // Cast transparent ray
    bool isTransparentRayNeeded = isOpaqueRayNeeded && hitDist == INF;
    payload = InitPayload( mipAndCone );
    {
        const uint rayFlags = 0;
        const uint instanceInclusionMask = isTransparentRayNeeded ? FLAGS_ONLY_TRANSPARENT : 0;
        const uint rayContributionToHitGroupIndex = 0;
        const uint multiplierForGeometryContributionToHitGroupIndex = 0;
        const uint missShaderIndex = 0;

        TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
    }

    // Emulate optical thickness
    float3 translucency = 0;
    if( isTransparentRayNeeded && payload.tmin != INF )
    {
        hitDist = payload.tmin;

        UnpackedPayload unpackedPayload = UnpackPayload( payload, mipAndCone );
        GeometryProps geometryPropsT = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, gPrimaryFullBrdf == 0 );

        float NoV = abs( dot( geometryPropsT.N, rayDesc.Direction ) );
        translucency = lerp( 0.9, 0.0, STL::Math::Pow01( 1.0 - NoV, 2.5 ) ) * GLASS_TINT;
    }

    return float4( translucency, isOpaqueRayNeeded ? hitDist : INF * float( materialProps.isEmissive ) );
}

float4 GetRadianceFromPreviousFrame( GeometryProps geometryProps, MaterialProps materialProps, float2 pixelUv, float2 jitter )
{
    // TODO: fade doesn't include antilag handling - since the previous frame is used in the current frame it adds "lag",
    // REBLUR doesn't know anything about it, its internal antilag helps... but not entirely. Fade out more if history reset is detected.
    // The simplest way is to fade out more if REBLUR's "maxAccumulatedFrameNum" is low

    float3 albedo, Rf0;
    STL::BRDF::ConvertBaseColorMetalnessToAlbedoRf0( materialProps.baseColor, materialProps.metalness, albedo, Rf0 );

    float4 clipPrev = STL::Geometry::ProjectiveTransform( gWorldToClipPrev, geometryProps.X ); // Not Xprev because confidence is based on viewZ
    float2 uvPrev = ( clipPrev.xy / clipPrev.w ) * float2( 0.5, -0.5 ) + 0.5 - jitter;
    float4 prevLsum = gIn_PrevColor_PrevViewZ.SampleLevel( gNearestMipmapNearestSampler, uvPrev * gRectSizePrev * gInvScreenSize, 0 );
    float prevViewZ = abs( prevLsum.w ) / NRD_FP16_VIEWZ_SCALE;

    // Fade-out on screen edges
    float2 f = STL::Math::LinearStep( 0.0, 0.1, uvPrev ) * STL::Math::LinearStep( 1.0, 0.9, uvPrev );
    float fade = f.x * f.y;
    fade *= float( pixelUv.x > gSeparator );
    fade *= float( uvPrev.x > gSeparator );

    // Confidence - viewZ
    // No "abs" for clipPrev.w, because if it's negative we have a back-projection!
    float err = abs( prevViewZ - clipPrev.w ) * STL::Math::PositiveRcp( min( prevViewZ, abs( clipPrev.w ) ) );
    fade *= STL::Math::LinearStep( 0.03, 0.01, err );

    // Confidence - ignore back-facing
    // Instead of storing previous normal we can store previous NoL, if signs do not match we hit the surface from the opposite side
    float NoL = dot( geometryProps.N, gSunDirection );
    fade *= float( NoL * STL::Math::Sign( prevLsum.w ) > 0.0 );

    // Confidence - ignore too short rays
    float4 clip = STL::Geometry::ProjectiveTransform( gWorldToClip, geometryProps.X );
    float2 uv = ( clip.xy / clip.w ) * float2( 0.5, -0.5 ) + 0.5 - jitter;
    float d = length( ( uv - pixelUv ) * gRectSize );
    fade *= STL::Math::LinearStep( 1.0, 3.0, d );

    // Confidence - ignore mirror specular
    float diffusiness = materialProps.roughness * materialProps.roughness;
    float lumDiff = lerp( STL::Color::Luminance( albedo ), 1.0, diffusiness );
    float lumSpec = lerp( STL::Color::Luminance( Rf0 ), 0.0, diffusiness );
    float diffProb = saturate( lumDiff * STL::Math::PositiveRcp( lumDiff + lumSpec ) );
    fade *= diffProb;

    // Avoid "stuck in history" effect
    fade *= 0.9;

    // Additional
    fade *= float( !materialProps.isEmissive );
    fade *= gDiffSecondBounce;

    prevLsum.w = fade;

    return prevLsum;
}

[shader( "raygeneration" )]
void ENTRYPOINT( )
{
    uint2 pixelPos = DispatchRaysIndex( ).xy;
    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvRectSize;

    STL::Rng::Initialize( pixelPos, gFrameIndex );

    float2 jitter = gJitter;
    #if( USE_STOCHASTIC_JITTER == 1 )
        jitter = ( STL::Rng::GetFloat2() - 0.5 ) * gInvRectSize;
    #endif
    float2 sampleUv = pixelUv + jitter;

    // Primary ray
    float3 rayOrigin0 = STL::Geometry::ReconstructViewPosition( sampleUv, gCameraFrustum, gNearZ, gIsOrtho );
    float3 rayDirection0 = STL::Geometry::ReconstructViewPosition( sampleUv, gCameraFrustum, gNearZ * 2.0, gIsOrtho );
    rayDirection0 = STL::Geometry::RotateVector( gViewToWorld, normalize( rayDirection0 - rayOrigin0 ) );
    rayOrigin0 = STL::Geometry::AffineTransform( gViewToWorld, rayOrigin0 );

    GeometryProps geometryProps0;
    MaterialProps materialProps0;
    {
        RayDesc rayDesc;
        rayDesc.Origin = rayOrigin0;
        rayDesc.Direction = rayDirection0;
        rayDesc.TMin = 0.0;
        rayDesc.TMax = INF;

        float2 mipAndCone = GetConeAngle( 0.0, 0.0 );
        Payload payload = InitPayload( mipAndCone );
        {
            const uint rayFlags = 0;
            const uint instanceInclusionMask = FLAGS_DEFAULT;
            const uint rayContributionToHitGroupIndex = 0;
            const uint multiplierForGeometryContributionToHitGroupIndex = 0;
            const uint missShaderIndex = 0;

            TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
        }

        UnpackedPayload unpackedPayload = UnpackPayload( payload, mipAndCone );
        geometryProps0 = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, gPrimaryFullBrdf == 0 );
        materialProps0 = GetMaterialProps( geometryProps0, rayDesc.Direction, gPrimaryFullBrdf == 0 );

        // Debug
        if( gOnScreen == SHOW_WORLD_UNITS )
        {
            float3 Xg = geometryProps0.X + gWorldOrigin;
            materialProps0.Lsum = frac( Xg / gMeterToUnitsMultiplier );
        }
        else if( gOnScreen == SHOW_BARY )
            materialProps0.Lsum = unpackedPayload.barycentrics;
        else if( gOnScreen == SHOW_MESH )
        {
            STL::Rng::Initialize( unpackedPayload.GetInstanceId().xx, 0 );
            materialProps0.Lsum = STL::Rng::GetFloat4().xyz;
        }
        else if( gOnScreen == SHOW_MIP_PRIMARY )
        {
            float mipNorm = saturate( 1.0 - geometryProps0.mip / MAX_MIP_LEVEL );
            mipNorm = 1.0 - mipNorm * mipNorm;
            materialProps0.Lsum = STL::Color::ColorizeZucconi( mipNorm );
        }
    }

    // G-buffer
    gOut_ObjectMotion[ pixelPos ] = geometryProps0.motion * STL::Math::LinearStep( 0.0, 0.0000005, abs( geometryProps0.motion ) ); // fix imprecision problems
    gOut_ViewZ[ pixelPos ] = geometryProps0.viewZ;
    gOut_DirectLighting[ pixelPos ] = materialProps0.Lsum;
    gOut_Normal_Roughness[ pixelPos ] = geometryProps0.IsSky( ) ? SKY_MARK : PackNormalAndRoughness( materialProps0.N, materialProps0.roughness );
    gOut_BaseColor_Metalness[ pixelPos ] = float4( STL::Color::LinearToSrgb( materialProps0.baseColor ), materialProps0.metalness );

    // Transparent lighting
    if( gTransparent != 0.0 )
    {
        RayDesc rayDesc;
        rayDesc.Origin = rayOrigin0;
        rayDesc.Direction = rayDirection0;
        rayDesc.TMin = 0.0;
        rayDesc.TMax = geometryProps0.tmin;

        float2 mipAndCone = GetConeAngle( 0.0, 0.0 );
        Payload payload = InitPayload( mipAndCone );
        {
            // TODO: use raster for closest transparent layer
            const uint rayFlags = 0;
            const uint instanceInclusionMask = FLAGS_ONLY_TRANSPARENT;
            const uint rayContributionToHitGroupIndex = 0;
            const uint multiplierForGeometryContributionToHitGroupIndex = 0;
            const uint missShaderIndex = 0;

            TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
        }

        UnpackedPayload unpackedPayload = UnpackPayload( payload, mipAndCone );
        GeometryProps geometryPropsT0 = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, gPrimaryFullBrdf == 0 );

        float4 transparentLayer = 0;
        if( !geometryPropsT0.IsSky() )
        {
           float roughness = 0.0;

            GeometryProps geometryPropsT1;
            MaterialProps materialPropsT1;
            {
                RayDesc rayDesc;
                rayDesc.Origin = geometryPropsT0.GetXWithOffset();
                rayDesc.Direction = reflect( rayDirection0, geometryPropsT0.N );
                rayDesc.TMin = 0.0;
                rayDesc.TMax = INF;

                float2 mipAndCone = GetConeAngle( geometryPropsT0.mip, roughness );
                Payload payload = InitPayload( mipAndCone );
                {
                    const uint rayFlags = 0;
                    const uint instanceInclusionMask = FLAGS_DEFAULT;
                    const uint rayContributionToHitGroupIndex = 0;
                    const uint multiplierForGeometryContributionToHitGroupIndex = 0;
                    const uint missShaderIndex = 0;

                    TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
                }

                unpackedPayload = UnpackPayload( payload, mipAndCone );
                geometryPropsT1 = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, true );
                materialPropsT1 = GetMaterialProps( geometryPropsT1, rayDesc.Direction, true );
            }

            float NoVT0 = abs( dot( geometryPropsT0.N, rayDesc.Direction ) );
            float FT0 = STL::BRDF::FresnelTerm_Schlick( 0.01, NoVT0 ).x;

            float3 Lsum = materialPropsT1.Lsum * float( materialPropsT1.isEmissive );
            Lsum += materialPropsT1.baseColor * gAmbient;

            float4 prevLsum = GetRadianceFromPreviousFrame( geometryPropsT1, materialPropsT1, pixelUv, jitter );
            Lsum = lerp( Lsum, prevLsum.xyz, prevLsum.w );

            transparentLayer.xyz = ( Lsum * FT0 + 0.01 * gAmbient ) * ( 1.0 - FT0 ) * GLASS_TINT;
            transparentLayer.w = FT0;
        }

        gOut_TransparentLighting[ pixelPos ] = transparentLayer;
    }

    // Early out
    if( geometryProps0.IsSky( ) )
    {
        gOut_ShadowData[ pixelPos ] = SIGMA_INF_SHADOW;

        #if( CHECKERBOARD != 0 )
            pixelPos.x >>= 1;
            gOut_Diff[ pixelPos ] = 0;
            gOut_Spec[ pixelPos ] = 0;
        #endif

        return;
    }

    // Sun shadow
    float4 shadowData0 = CastSoftShadowRay( geometryProps0, materialProps0 );

    float4 shadowTranslucency;
    float2 shadowData = SIGMA_FrontEnd_PackShadow( materialProps0.isEmissive ? INF : geometryProps0.viewZ, shadowData0.w == INF ? NRD_FP16_MAX : shadowData0.w, gTanSunAngularRadius, shadowData0.xyz, shadowTranslucency );

    gOut_ShadowData[ pixelPos ] = shadowData;
    gOut_Shadow_Translucency[ pixelPos ] = shadowTranslucency;

    // Secondary rays
    float4 diffIndirect = 0;
    float4 diffDirectionPdf = 0;
    float diffTotalWeight = 0;

    float4 specIndirect = 0;
    float4 specDirectionPdf = 0;
    float specTotalWeight = 0;

    float3x3 mLocalBasis = STL::Geometry::GetBasis( materialProps0.N );
    float3 Vlocal = STL::Geometry::RotateVector( mLocalBasis, -rayDirection0 );
    float trimmingFactor = NRD_GetTrimmingFactor( materialProps0.roughness, gTrimmingParams );

#if( CHECKERBOARD == 0 )
    uint N = gSampleNum << 1;
    for( uint i = 0; i < N; i++ )
    {
        bool isDiffuse = ( i & 0x1 ) == 0;
        bool isCheckerboard = false;
#else
        bool isDiffuse = STL::Sequence::CheckerBoard( pixelPos, gFrameIndex ) != 0;
        bool isCheckerboard = true;
#endif
        // Generate ray
        float3 rayDirection1 = 0;
        float throughput1 = 0;
        float HoV0 = 0;
        float pdf = 0;
        uint tryNum = 0;

    #if( USE_IMPORTANCE_SAMPLING > 0 )
        // Adds a non significant overhead, but allows to skip rays with zero throughput (for specular rays).
        while( tryNum < ZERO_TROUGHPUT_SAMPLE_NUM && throughput1 == 0.0 )
    #endif
        {
            // Low descrepancy sampling is your friend in the "Low Rpp World"
            float2 rnd = ( gBlueNoise && tryNum == 0 ) ? GetBlueNoise( isCheckerboard, 0, gIn_Scrambling_Ranking_32spp, 0, 32, 1 ) : STL::Rng::GetFloat2( );

            if( isDiffuse )
            {
                float3 rayLocal = STL::ImportanceSampling::Cosine::GetRay( rnd );
                rayDirection1 = STL::Geometry::RotateVectorInverse( mLocalBasis, rayLocal );

                // No PDF and NoL for diffuse because it gets canceled out by STL::ImportanceSampling::Cosine::GetPDF
                // But we don't want to cast rays inside the surface
                float NoL = saturate( dot( geometryProps0.N, rayDirection1 ) );
                throughput1 = STL::Math::LinearStep( 0.0, 0.001, NoL );

                pdf = STL::ImportanceSampling::Cosine::GetPDF( saturate( dot( materialProps0.N, rayDirection1 ) ) );
            }
            else
            {
                float3 Hlocal = STL::ImportanceSampling::VNDF::GetRay( rnd, materialProps0.roughness, Vlocal, trimmingFactor );
                float3 H = STL::Geometry::RotateVectorInverse( mLocalBasis, Hlocal );
                rayDirection1 = reflect( rayDirection0, H );

                // FIX for non-parallaxed normal mapping - normal maps can easily force rays to go under the surface, it should be avoided for specular rays
                float f = 1.0 - STL::Math::SmoothStep( 0.0, 0.3, materialProps0.roughness );
                f *= saturate( -dot( rayDirection1, geometryProps0.N ) );
                rayDirection1 += 2.0 * geometryProps0.N * f;

                // It's a part of VNDF sampling - see http://jcgt.org/published/0007/04/01/paper.pdf (paragraph "Usage in Monte Carlo renderer")
                float NoL = saturate( dot( materialProps0.N, rayDirection1 ) );
                throughput1 = STL::BRDF::GeometryTerm_Smith( materialProps0.roughness, NoL );

                HoV0 = abs( dot( H, -rayDirection0 ) );
                pdf = STL::ImportanceSampling::VNDF::GetPDF( abs( dot( materialProps0.N, -rayDirection0 ) ), saturate( dot( materialProps0.N, H ) ), materialProps0.roughness );
            }

            tryNum++;
        }

        throughput1 /= float( tryNum );
        bool isNotCanceled1 = throughput1 != 0.0;

        // 1st bounce (unshadowed)
        GeometryProps geometryProps1;
        MaterialProps materialProps1;
        {
            RayDesc rayDesc;
            rayDesc.Origin = geometryProps0.GetXWithOffset();
            rayDesc.Direction = rayDirection1;
            rayDesc.TMin = 0.0;
            rayDesc.TMax = INF * float( isNotCanceled1 );

            float2 mipAndCone = GetConeAngle( geometryProps0.mip + 1.0, isDiffuse ? 1.0 : materialProps0.roughness );
            Payload payload = InitPayload( mipAndCone );
            {
                const uint rayFlags = 0;
                const uint instanceInclusionMask = isNotCanceled1 ? FLAGS_DEFAULT : 0;
                const uint rayContributionToHitGroupIndex = 0;
                const uint multiplierForGeometryContributionToHitGroupIndex = 0;
                const uint missShaderIndex = 0;

                TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
            }

            UnpackedPayload unpackedPayload = UnpackPayload( payload, mipAndCone );
            geometryProps1 = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, gIndirectFullBrdf == 0 );
            materialProps1 = GetMaterialProps( geometryProps1, rayDesc.Direction, gIndirectFullBrdf == 0 );
        }

        float3 Clight1 = materialProps1.Lsum;

        // Our sampling is not just random, it follow diffuse / specular lobe, paths separation here is mostly for clarity
        // because for the 1st bounce roughness will be canceled out in any case inside "NRD_GetCorrectedHitDist"
        float2 pathLength;
        pathLength.x = NRD_GetCorrectedHitDist( geometryProps1.tmin, 1 );
        pathLength.y = NRD_GetCorrectedHitDist( geometryProps1.tmin, 1, materialProps0.roughness );

        if( !materialProps1.isEmissive )
        {
            // Many bounces (previous frame)
            float4 prevLsum = GetRadianceFromPreviousFrame( geometryProps1, materialProps1, pixelUv, jitter );
            materialProps1.Lsum *= float( prevLsum.w != 1.0 );

            // 1st bounce (with shadow)
            float distanceToOccluder1 = CastShadowRay( geometryProps1, materialProps1 );
            Clight1 = materialProps1.Lsum * float( distanceToOccluder1 == INF );

            // 2nd bounce (can be approximated if data prom the previous frame is invalid or specular is needed)
            float3 albedo1, Rf01;
            STL::BRDF::ConvertBaseColorMetalnessToAlbedoRf0( materialProps1.baseColor, materialProps1.metalness, albedo1, Rf01 );
            float NoV1 = abs( dot( materialProps1.N, rayDirection1 ) );
            float3 F1 = STL::BRDF::EnvironmentTerm_Ross( Rf01, NoV1, materialProps1.roughness );
            float2 GG1 = gIn_IntegratedBRDF.SampleLevel( gLinearSampler, float2( NoV1, materialProps1.roughness ), 0 );
            float3 brdf1 = albedo1 * GG1.x / STL::Math::Pi( 1.0 ) + F1 * GG1.y;

            float3 Clight2 = GetIndirectAmbient( geometryProps1.tmin, isDiffuse );

            #if( SECOND_BOUNCE_SPECULAR == 1 )
                float threshold = lerp( 0.01, 0.25, materialProps0.roughness );
                float brdfLuma = STL::Color::Luminance( brdf1 ) * ( 1.0 - prevLsum.w );

                if( !isDiffuse && isNotCanceled1 && brdfLuma > threshold )
                {
                    float3 ggxDominantDirection = STL::ImportanceSampling::GetSpecularDominantDirection( materialProps1.N, -rayDirection1, materialProps1.roughness, STL_SPECULAR_DOMINANT_DIRECTION_G1 ).xyz; // geometryProps1.N can be used as well!

                    RayDesc rayDesc;
                    rayDesc.Origin = geometryProps1.GetXWithOffset();
                    rayDesc.Direction = ggxDominantDirection;
                    rayDesc.TMin = 0.0;
                    rayDesc.TMax = INF;

                    float2 mipAndCone = GetConeAngle( geometryProps1.mip, materialProps1.roughness );
                    Payload payload = InitPayload( mipAndCone );
                    {
                        const uint rayFlags = 0;
                        const uint instanceInclusionMask = FLAGS_DEFAULT;
                        const uint rayContributionToHitGroupIndex = 0;
                        const uint multiplierForGeometryContributionToHitGroupIndex = 0;
                        const uint missShaderIndex = 0;

                        TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
                    }

                    UnpackedPayload unpackedPayload = UnpackPayload( payload, mipAndCone );
                    GeometryProps geometryProps2 = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, true );
                    MaterialProps materialProps2 = GetMaterialProps( geometryProps2, rayDesc.Direction, true );

                    Clight2 = materialProps2.Lsum;

                    if( !materialProps2.isEmissive )
                    {
                        float distanceToOccluder2 = CastShadowRay( geometryProps2, materialProps2 );
                        Clight2 *= float( distanceToOccluder2 == INF );

                        float3 albedo2, Rf02;
                        STL::BRDF::ConvertBaseColorMetalnessToAlbedoRf0( materialProps2.baseColor, materialProps2.metalness, albedo2, Rf02 );
                        float NoV2 = abs( dot( materialProps2.N, ggxDominantDirection ) );
                        float3 F2 = STL::BRDF::EnvironmentTerm_Ross( Rf02, NoV2, materialProps2.roughness );
                        float2 GG2 = gIn_IntegratedBRDF.SampleLevel( gLinearSampler, float2( NoV2, materialProps2.roughness ), 0 );
                        float3 brdf2 = F2 * GG2.x + albedo2 * GG2.y / STL::Math::Pi( 1.0 );

                        Clight2 += GetIndirectAmbient( geometryProps2.tmin, isDiffuse ) * brdf2;
                    }

                    float l1 = STL::Color::Luminance( Clight1 );
                    float l2 = STL::Color::Luminance( Clight2 * brdf1 );
                    float importance2 = saturate( l2 / ( l1 + l2 + 0.01 ) );

                    pathLength.y += NRD_GetCorrectedHitDist( geometryProps2.tmin, 2, materialProps0.roughness, importance2 );
                }
            #endif

            Clight1 += Clight2 * brdf1;
            Clight1 = lerp( Clight1, prevLsum.xyz, prevLsum.w );
        }

        // Apply throughput1
        Clight1 *= throughput1;

        #if( USE_IMPORTANCE_SAMPLING > 1 )
            if( gDisableShadowsAndEnableImportanceSampling != 0 )
            {
                Payload payload = (Payload)0;

                RayDesc rayDesc;
                rayDesc.Origin = geometryProps0.GetXWithOffset();
                rayDesc.Direction = rayDirection1;
                rayDesc.TMin = 0.0;
                rayDesc.TMax = INF;

                float2 mipAndCone = GetConeAngle( geometryProps0.mip + 1.0, isDiffuse ? 1.0 : materialProps0.roughness );

                throughput1 = 0.0;
                tryNum = 0;

                // Sample emissive surfaces
                while( tryNum < IMPORTANCE_SAMPLE_NUM && throughput1 == 0.0 )
                {
                    float2 rnd = STL::Rng::GetFloat4( ).xy;

                    if( isDiffuse )
                    {
                        float3 rayLocal = STL::ImportanceSampling::Cosine::GetRay( rnd );
                        rayDirection1 = STL::Geometry::RotateVectorInverse( mLocalBasis, rayLocal );

                        // No PDF and NoL for diffuse because it gets canceled out by STL::ImportanceSampling::Cosine::GetPDF
                        throughput1 = 1.0;

                        pdf = STL::ImportanceSampling::Cosine::GetPDF( saturate( dot( materialProps0.N, rayDirection1 ) ) );
                    }
                    else
                    {
                        float3 Hlocal = STL::ImportanceSampling::VNDF::GetRay( rnd, materialProps0.roughness, Vlocal, trimmingFactor );
                        float3 H = STL::Geometry::RotateVectorInverse( mLocalBasis, Hlocal );
                        rayDirection1 = reflect( rayDirection0, H );

                        // FIX for non-parallaxed normal mapping - normal maps can easily force rays to go under the surface, it should be avoided for specular rays
                        float f = 1.0 - STL::Math::SmoothStep( 0.0, 0.3, materialProps0.roughness );
                        f *= saturate( -dot( rayDirection1, geometryProps0.N ) );
                        rayDirection1 += 2.0 * geometryProps0.N * f;

                        // It's a part of VNDF sampling - see http://jcgt.org/published/0007/04/01/paper.pdf (paragraph "Usage in Monte Carlo renderer")
                        float NoL = saturate( dot( materialProps0.N, rayDirection1 ) );
                        throughput1 = STL::BRDF::GeometryTerm_Smith( materialProps0.roughness, NoL );

                        pdf = STL::ImportanceSampling::VNDF::GetPDF( abs( dot( materialProps0.N, -rayDirection0 ) ), saturate( dot( materialProps0.N, H ) ), materialProps0.roughness );
                    }

                    // But we don't want to cast rays inside the surface
                    float NoL = saturate( dot( geometryProps0.N, rayDirection1 ) );
                    throughput1 *= STL::Math::LinearStep( 0.0, 0.001, NoL );

                    // Emissive surfaces importance sampling
                    rayDesc.Direction = rayDirection1;

                    payload = InitPayload( mipAndCone );
                    {
                        const uint rayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
                        const uint instanceInclusionMask = throughput1 != 0.0 ? FLAGS_ONLY_EMISSION : 0;
                        const uint rayContributionToHitGroupIndex = 0;
                        const uint multiplierForGeometryContributionToHitGroupIndex = 0;
                        const uint missShaderIndex = 0;

                        TraceRay( gLightTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
                    }

                    throughput1 *= float( payload.tmin != INF );
                    tryNum++;
                }

                throughput1 /= float( tryNum );

                // Visibility
                UnpackedPayload unpackedPayload = UnpackPayload( payload, mipAndCone );
                geometryProps1 = GetGeometryProps( unpackedPayload, rayDesc.Origin, rayDesc.Direction, gIndirectFullBrdf == 0 );
                materialProps1 = GetMaterialProps( geometryProps1, rayDesc.Direction, gIndirectFullBrdf == 0 );

                rayDesc.TMax = geometryProps1.tmin;

                payload = InitPayload( mipAndCone );
                {
                    const uint rayFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
                    const uint instanceInclusionMask = throughput1 != 0.0 ? FLAGS_DEFAULT : 0;
                    const uint rayContributionToHitGroupIndex = 0;
                    const uint multiplierForGeometryContributionToHitGroupIndex = 0;
                    const uint missShaderIndex = 0;

                    TraceRay( gWorldTlas, rayFlags, instanceInclusionMask, rayContributionToHitGroupIndex, multiplierForGeometryContributionToHitGroupIndex, missShaderIndex, rayDesc, payload );
                }

                Clight1 += materialProps1.Lsum * throughput1 * float( payload.tmin == INF );

                // TODO: should I do it? This part is direct lighting only but the previous is most likely something else...
                // TODO: Direct lighting from emissives should be disabled for the previous ray
                //Clight1 *= 0.5;
            }
        #endif

        // A tip for path tracing - signal de-modulation
        #if( USE_MODULATED_IRRADIANCE == 1 )
            // In some cases material information at the primary hit is already included into the signal, transforming radiance into irradiance.
            // The code below shows how such signals can be de-modulated before denoising and modulated again after denoising to preserve material detail:
            // Steps:
            //    1. De-modulation: signalNew = signal / albedo (for specular "albedo" depends on roughness and view vector, see code below)
            //    2. Denoising
            //    3. Modulation: multiply the denoised signal by previously used albedo values (see Composition.hlsl)

            float3 albedo0, Rf00;
            STL::BRDF::ConvertBaseColorMetalnessToAlbedoRf0( materialProps0.baseColor, materialProps0.metalness, albedo0, Rf00 );

            if( isDiffuse )
            {
                // Diffuse modulation resolves to 1 in one line in this example, but in other apps it can be done in separated parts of the rendering pipeline
                float3 diffDemodulation = albedo0;
                Clight1 *= albedo0 / max( diffDemodulation, 0.001 );
            }
            else
            {
                // Schlick-Ross approximation can be used or the pre-integrated F-term stored in a 2D texture from Unreal Engine
                float NoV0 = abs( dot( materialProps0.N, -rayDirection0 ) );
                float3 specDemodulation = STL::BRDF::EnvironmentTerm_Ross( Rf00, NoV0, materialProps0.roughness );
                Clight1 *= STL::BRDF::FresnelTerm_Schlick( Rf00, HoV0 ) / max( specDemodulation, 0.001 );
            }
        #endif

        // Store output
        float viewZ = geometryProps0.viewZ;
        float sampleWeight = NRD_GetSampleWeight( Clight1, USE_SANITIZATION );

        if( isDiffuse )
        {
            float normDist = REBLUR_FrontEnd_GetNormHitDist( pathLength.x, viewZ, gDiffHitDistParams, gMeterToUnitsMultiplier );

            float4 Clight1Nrd = REBLUR_FrontEnd_PackRadianceAndHitDist( Clight1, normDist, USE_SANITIZATION );
            if( gDenoiserType != REBLUR )
                Clight1Nrd = RELAX_FrontEnd_PackRadianceAndHitDist( Clight1, pathLength.x, USE_SANITIZATION );

            diffIndirect += Clight1Nrd * sampleWeight;
            diffDirectionPdf += float4( rayDirection1, pdf ) * sampleWeight;
            diffTotalWeight += sampleWeight;
        }
        else
        {
            // Debug
            if( gOnScreen >= SHOW_MIP_PRIMARY )
            {
                float mipNorm = saturate( 1.0 - geometryProps1.mip / MAX_MIP_LEVEL );
                mipNorm = 1.0 - mipNorm * mipNorm;
                Clight1 = STL::Color::ColorizeZucconi( mipNorm );
            }

            float normDist = REBLUR_FrontEnd_GetNormHitDist( pathLength.y, viewZ, gSpecHitDistParams, gMeterToUnitsMultiplier, materialProps0.roughness );

            float4 Clight1Nrd = REBLUR_FrontEnd_PackRadianceAndHitDist( Clight1, normDist, USE_SANITIZATION );
            if( gDenoiserType != REBLUR )
                Clight1Nrd = RELAX_FrontEnd_PackRadianceAndHitDist( Clight1, pathLength.y, USE_SANITIZATION );

            specIndirect += Clight1Nrd * sampleWeight;
            specDirectionPdf += float4( rayDirection1, pdf ) * sampleWeight;
            specTotalWeight += sampleWeight;
        }

#if( CHECKERBOARD == 0 )
    }
#endif

    float invSum = STL::Math::PositiveRcp( diffTotalWeight );
    diffIndirect *= invSum;
    diffDirectionPdf *= invSum;
    diffDirectionPdf = NRD_FrontEnd_PackDirectionAndPdf( diffDirectionPdf.xyz, diffDirectionPdf.w );

    invSum = STL::Math::PositiveRcp( specTotalWeight );
    specIndirect *= invSum;
    specDirectionPdf *= invSum;
    specDirectionPdf = NRD_FrontEnd_PackDirectionAndPdf( specDirectionPdf.xyz, specDirectionPdf.w );

    [flatten]
    if( gOcclusionOnly )
    {
        diffIndirect = diffIndirect.wwww;
        specIndirect = specIndirect.wwww;
    }

    // Indirect lighting output
#if( CHECKERBOARD == 0 )
    gOut_Diff[ pixelPos ] = diffIndirect;
    gOut_DiffDirectionPdf[ pixelPos ] = diffDirectionPdf;

    gOut_Spec[ pixelPos ] = specIndirect;
    gOut_SpecDirectionPdf[ pixelPos ] = specDirectionPdf;
#else
    pixelPos.x >>= 1;

    if( isDiffuse )
    {
        gOut_Diff[ pixelPos ] = diffIndirect;
        gOut_DiffDirectionPdf[ pixelPos ] = diffDirectionPdf;
    }
    else
    {
        gOut_Spec[ pixelPos ] = specIndirect;
        gOut_SpecDirectionPdf[ pixelPos ] = specDirectionPdf;
    }
#endif
}
