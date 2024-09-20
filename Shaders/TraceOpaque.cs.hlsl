/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "Include/Shared.hlsli"
#include "Include/RaytracingShared.hlsli"

#define SHARC_QUERY 1
#include "SharcCommon.h"

// Inputs
NRI_RESOURCE( Texture2D<float3>, gIn_PrevComposedDiff, t, 0, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_PrevComposedSpec_PrevViewZ, t, 1, 1 );
NRI_RESOURCE( Texture2D<uint3>, gIn_ScramblingRanking, t, 2, 1 );
NRI_RESOURCE( Texture2D<uint4>, gIn_Sobol, t, 3, 1 );

// Outputs
NRI_RESOURCE( RWTexture2D<float4>, gOut_Mv, u, 0, 1 );
NRI_RESOURCE( RWTexture2D<float>, gOut_ViewZ, u, 1, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Normal_Roughness, u, 2, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_BaseColor_Metalness, u, 3, 1 );
NRI_RESOURCE( RWTexture2D<float3>, gOut_DirectLighting, u, 4, 1 );
NRI_RESOURCE( RWTexture2D<float3>, gOut_DirectEmission, u, 5, 1 );
NRI_RESOURCE( RWTexture2D<float3>, gOut_PsrThroughput, u, 6, 1 );
NRI_RESOURCE( RWTexture2D<float2>, gOut_ShadowData, u, 7, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Shadow_Translucency, u, 8, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Diff, u, 9, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Spec, u, 10, 1 );
#if( NRD_MODE == SH )
    NRI_RESOURCE( RWTexture2D<float4>, gOut_DiffSh, u, 11, 1 );
    NRI_RESOURCE( RWTexture2D<float4>, gOut_SpecSh, u, 12, 1 );
#endif

float2 GetBlueNoise( uint2 pixelPos, bool isCheckerboard, uint seed = 0 )
{
    // https://eheitzresearch.wordpress.com/772-2/
    // https://belcour.github.io/blog/research/publication/2019/06/17/sampling-bluenoise.html

    // Sample index
    uint frameIndex = isCheckerboard ? ( gFrameIndex >> 1 ) : gFrameIndex;
    uint sampleIndex = ( frameIndex + seed ) & ( BLUE_NOISE_TEMPORAL_DIM - 1 );

    // The algorithm
    uint3 A = gIn_ScramblingRanking[ pixelPos & ( BLUE_NOISE_SPATIAL_DIM - 1 ) ];
    uint rankedSampleIndex = sampleIndex ^ A.z;
    uint4 B = gIn_Sobol[ uint2( rankedSampleIndex & 255, 0 ) ];
    float4 blue = ( float4( B ^ A.xyxy ) + 0.5 ) * ( 1.0 / 256.0 );

    // ( Optional ) Randomize in [ 0; 1 / 256 ] area to get rid of possible banding
    uint d = Sequence::Bayer4x4ui( pixelPos, gFrameIndex );
    float2 dither = ( float2( d & 3, d >> 2 ) + 0.5 ) * ( 1.0 / 4.0 );
    blue += ( dither.xyxy - 0.5 ) * ( 1.0 / 256.0 );

    // Don't use blue noise in these cases
    if( gDenoiserType == DENOISER_REFERENCE || gRR )
        blue.xy = Rng::Hash::GetFloat2( );

    return saturate( blue.xy );
}

float4 GetRadianceFromPreviousFrame( GeometryProps geometryProps, MaterialProps materialProps, uint2 pixelPos, bool isDiffuse )
{
    // Reproject previous frame
    float3 prevLdiff, prevLspec;
    float prevFrameWeight = ReprojectIrradiance( true, false, gIn_PrevComposedDiff, gIn_PrevComposedSpec_PrevViewZ, geometryProps, pixelPos, prevLdiff, prevLspec );

    // Estimate how strong lighting at hit depends on the view direction
    float diffuseProbabilityBiased = EstimateDiffuseProbability( geometryProps, materialProps, true );
    float3 prevLsum = prevLdiff + prevLspec * diffuseProbabilityBiased;

    float diffuseLikeMotion = lerp( diffuseProbabilityBiased, 1.0, Math::Sqrt01( materialProps.curvature ) );
    prevFrameWeight *= isDiffuse ? 1.0 : diffuseLikeMotion;

    float a = Color::Luminance( prevLdiff );
    float b = Color::Luminance( prevLspec );
    prevFrameWeight *= lerp( diffuseProbabilityBiased, 1.0, ( a + NRD_EPS ) / ( a + b + NRD_EPS ) );

    // Avoid really bad reprojection
    return NRD_MODE < OCCLUSION ? float4( prevLsum * saturate( prevFrameWeight / 0.001 ), prevFrameWeight ) : 0.0;
}

//========================================================================================
// TRACE OPAQUE
//========================================================================================

/*
"TraceOpaque" traces "pathNum" paths, doing up to "bounceNum" bounces. The function
has not been designed to trace primary hits. But still can be used to trace
direct and indirect lighting.

Prerequisites:
    Rng::Hash::Initialize( )

Derivation:
    Lsum = L0 + BRDF0 * ( L1 + BRDF1 * ( L2 + BRDF2 * ( L3 +  ... ) ) )

    Lsum = L0 +
        L1 * BRDF0 +
        L2 * BRDF0 * BRDF1 +
        L3 * BRDF0 * BRDF1 * BRDF2 +
        ...
*/

struct TraceOpaqueDesc
{
    // Geometry properties
    GeometryProps geometryProps;

    // Material properties
    MaterialProps materialProps;

    // Pixel position
    uint2 pixelPos;

    // Checkerboard
    uint checkerboard;

    // Number of paths to trace
    uint pathNum;

    // Number of bounces to trace ( up to )
    uint bounceNum;

    // Instance inclusion mask ( DXR )
    uint instanceInclusionMask;

    // Ray flags ( DXR )
    uint rayFlags;
};

struct TraceOpaqueResult
{
    float3 diffRadiance;
    float diffHitDist;

    float3 specRadiance;
    float specHitDist;

    #if( NRD_MODE == SH || NRD_MODE == DIRECTIONAL_OCCLUSION )
        float3 diffDirection;
        float3 specDirection;
    #endif
};

TraceOpaqueResult TraceOpaque( inout TraceOpaqueDesc desc )
{
    // TODO: for RESOLUTION_FULL_PROBABILISTIC with 1 path per pixel the tracer can be significantly simplified

    //=====================================================================================================================================================================
    // Primary surface replacement ( PSR )
    //=====================================================================================================================================================================

    float viewZ = Geometry::AffineTransform( gWorldToView, desc.geometryProps.X ).z;
    float4 Lpsr = 0;
    float3x3 mirrorMatrix = Geometry::GetMirrorMatrix( 0 ); // identity

    #if( USE_PSR == 1 )
    {
        float3 psrThroughput = 1.0;

        GeometryProps geometryProps = desc.geometryProps;
        MaterialProps materialProps = desc.materialProps;

        float accumulatedHitDist = 0.0;
        float accumulatedPseudoCurvature = 0.0; // TODO: is there a less empirical solution?
        bool isPSR = false;

        [loop]
        while( desc.bounceNum && !geometryProps.IsSky( ) && IsPsrAllowed( materialProps ) )
        {
            isPSR = true;

            // Origin point
            float curvature = materialProps.curvature;
            accumulatedPseudoCurvature += Math::Pow01( abs( curvature ), 0.25 );

            {
                // Accumulate mirror matrix
                mirrorMatrix = mul( Geometry::GetMirrorMatrix( materialProps.N ), mirrorMatrix );

                // Choose a ray
                float3 ray = reflect( -geometryProps.V, materialProps.N );

                // Update throughput
                #if( NRD_MODE < OCCLUSION )
                    float3 albedo, Rf0;
                    BRDF::ConvertBaseColorMetalnessToAlbedoRf0( materialProps.baseColor, materialProps.metalness, albedo, Rf0 );

                    float NoV = abs( dot( materialProps.N, geometryProps.V ) );
                    float3 Fenv = BRDF::EnvironmentTerm_Rtg( Rf0, NoV, materialProps.roughness );

                    psrThroughput *= Fenv;
                #endif

                // Abort if expected contribution of the current bounce is low
                if( PSR_THROUGHPUT_THRESHOLD != 0.0 && Color::Luminance( psrThroughput ) < PSR_THROUGHPUT_THRESHOLD )
                    break;

                // Trace to the next hit
                float2 mipAndCone = GetConeAngleFromRoughness( geometryProps.mip, materialProps.roughness );
                geometryProps = CastRay( geometryProps.GetXoffset( geometryProps.N ), ray, 0.0, INF, mipAndCone, gWorldTlas, desc.instanceInclusionMask, desc.rayFlags );
                materialProps = GetMaterialProps( geometryProps );
            }

            // Hit point
            {
                // Accumulate hit distance representing virtual point position ( see "README/NOISY INPUTS" )
                // TODO: this heuristic works best so far
                float hitDistFocused = geometryProps.tmin / ( 2.0 * curvature * geometryProps.tmin + 1.0 );
                accumulatedHitDist += hitDistFocused * Math::SmoothStep( 0.2, 0.0, accumulatedPseudoCurvature );
            }

            desc.bounceNum--;
        }

        if( isPSR )
        {
            // Update materials, direct lighting and emission
            float3 psrNormal = float3( 0, 0, 1 );
            uint materialID = materialProps.metalness < 0.5 ? MATERIAL_ID_DEFAULT : MATERIAL_ID_METAL;

            if( !geometryProps.IsSky( ) )
            {
                psrNormal = Geometry::RotateVectorInverse( mirrorMatrix, materialProps.N );

                gOut_BaseColor_Metalness[ desc.pixelPos ] = float4( Color::ToSrgb( materialProps.baseColor ), materialProps.metalness );

                // L1 cache - reproject previous frame, carefully treating specular
                Lpsr = GetRadianceFromPreviousFrame( geometryProps, materialProps, desc.pixelPos, false );

                // L2 cache - SHARC
                GridParameters gridParameters = ( GridParameters )0;
                gridParameters.cameraPosition = gCameraGlobalPos.xyz;
                gridParameters.cameraPositionPrev = gCameraGlobalPosPrev.xyz;
                gridParameters.sceneScale = SHARC_SCENE_SCALE;
                gridParameters.logarithmBase = SHARC_GRID_LOGARITHM_BASE;

                float3 Xglobal = GetGlobalPos( geometryProps.X );
                uint level = GetGridLevel( Xglobal, gridParameters );
                float voxelSize = GetVoxelSize( level, gridParameters );
                float smc = GetSpecMagicCurve( materialProps.roughness );

                float3x3 mBasis = Geometry::GetBasis( geometryProps.N );
                float2 rndScaled = ( Rng::Hash::GetFloat2( ) - 0.5 ) * voxelSize * USE_SHARC_DITHERING;
                Xglobal += mBasis[ 0 ] * rndScaled.x + mBasis[ 1 ] * rndScaled.y;

                SharcHitData sharcHitData = ( SharcHitData )0;
                sharcHitData.positionWorld = Xglobal;
                sharcHitData.normalWorld = geometryProps.N;

                SharcState sharcState;
                sharcState.gridParameters = gridParameters;
                sharcState.hashMapData.capacity = SHARC_CAPACITY;
                sharcState.hashMapData.hashEntriesBuffer = gInOut_SharcHashEntriesBuffer;
                sharcState.voxelDataBuffer = gInOut_SharcVoxelDataBuffer;

                bool isSharcAllowed = gSHARC && NRD_MODE < OCCLUSION; // trivial
                isSharcAllowed &= geometryProps.tmin > voxelSize; // voxel angular size is acceptable
                isSharcAllowed &= Rng::Hash::GetFloat( ) > Lpsr.w; // probabilistically estimate the need
                isSharcAllowed &= desc.bounceNum == 0; // allow only for the last bounce for PSR

                float3 sharcRadiance;
                if( isSharcAllowed && SharcGetCachedRadiance( sharcState, sharcHitData, sharcRadiance, false ) )
                    Lpsr = float4( sharcRadiance, 1.0 );

                // TODO: add a macro switch for old mode ( with coupled direct lighting )

                // Subtract direct lighting, process it separately
                float3 L = GetShadowedLighting( geometryProps, materialProps );

                if( desc.bounceNum != 0 )
                    Lpsr.xyz *= Lpsr.w;

                Lpsr.xyz = max( Lpsr.xyz - L, 0.0 );

                gOut_DirectLighting[ desc.pixelPos ] = materialProps.Ldirect * psrThroughput;
            }

            gOut_DirectEmission[ desc.pixelPos ] = materialProps.Lemi * psrThroughput;
            gOut_Normal_Roughness[ desc.pixelPos ] = NRD_FrontEnd_PackNormalAndRoughness( psrNormal, materialProps.roughness, materialID );

            // PSR - Update motion
            float3 Xvirtual = desc.geometryProps.X - desc.geometryProps.V * accumulatedHitDist;
            float3 XvirtualPrev = Xvirtual + geometryProps.Xprev - geometryProps.X;
            float3 motion = GetMotion( Xvirtual, XvirtualPrev );

            gOut_Mv[ desc.pixelPos ] = float4( motion, viewZ * FP16_VIEWZ_SCALE ); // keep viewZ before PSR ( needed for glass )

            // PSR - Update viewZ
            viewZ = Geometry::AffineTransform( gWorldToView, Xvirtual ).z;
            viewZ = geometryProps.IsSky( ) ? Math::Sign( viewZ ) * INF : viewZ;

            gOut_ViewZ[ desc.pixelPos ] = viewZ;

            // PSR - Replace primary surface props with the replacement props
            desc.geometryProps = geometryProps;
            desc.materialProps = materialProps;
        }

        gOut_PsrThroughput[ desc.pixelPos ] = psrThroughput;
    }
    #endif

    //=====================================================================================================================================================================
    // Tracing from the primary hit or PSR
    //=====================================================================================================================================================================

    TraceOpaqueResult result = ( TraceOpaqueResult )0;

    #if( NRD_MODE < OCCLUSION )
        result.specHitDist = NRD_FrontEnd_SpecHitDistAveraging_Begin( );
    #endif

    uint pathNum = desc.pathNum << ( gTracingMode == RESOLUTION_FULL ? 1 : 0 );
    uint diffPathsNum = 0;

    [loop]
    for( uint path = 0; path < pathNum; path++ )
    {
        GeometryProps geometryProps = desc.geometryProps;
        MaterialProps materialProps = desc.materialProps;

        float accumulatedHitDist = 0;
        float accumulatedDiffuseLikeMotion = 0;

        bool isDiffusePath = gTracingMode == RESOLUTION_HALF ? desc.checkerboard : ( path & 0x1 );
        uint2 blueNoisePos = desc.pixelPos + uint2( Sequence::Weyl2D( 0.0, path ) * ( BLUE_NOISE_SPATIAL_DIM - 1 ) );

        float diffProb0 = EstimateDiffuseProbability( geometryProps, materialProps ) * float( !geometryProps.Has( FLAG_HAIR ) );
        float3 Lsum = Lpsr.xyz * ( gTracingMode == RESOLUTION_FULL ? ( isDiffusePath ? diffProb0 : ( 1.0 - diffProb0 ) ) : 1.0 );
        float3 pathThroughput = 1.0 - Lpsr.w;

        [loop]
        for( uint bounce = 1; bounce <= desc.bounceNum && !geometryProps.IsSky( ); bounce++ )
        {
            //=============================================================================================================================================================
            // Origin point
            //=============================================================================================================================================================

            bool isDiffuse = isDiffusePath;
            {
                // Estimate diffuse probability
                float diffuseProbability = EstimateDiffuseProbability( geometryProps, materialProps ) * float( !geometryProps.Has( FLAG_HAIR ) );

                // Clamp probability to a sane range to guarantee a sample in 3x3 ( or 5x5 ) area
                float rnd = Rng::Hash::GetFloat( );
                if( gTracingMode == RESOLUTION_FULL_PROBABILISTIC && bounce == 1 && !gRR )
                {
                    diffuseProbability = float( diffuseProbability != 0.0 ) * clamp( diffuseProbability, gMinProbability, 1.0 - gMinProbability );
                    rnd = Sequence::Bayer4x4( desc.pixelPos, gFrameIndex ) + rnd / 16.0;
                }

                // Diffuse or specular path?
                if( gTracingMode == RESOLUTION_FULL_PROBABILISTIC || bounce > 1 )
                {
                    isDiffuse = rnd < diffuseProbability;
                    pathThroughput /= abs( float( !isDiffuse ) - diffuseProbability );

                    if( bounce == 1 )
                        isDiffusePath = isDiffuse;
                }

                float2 mipAndCone = GetConeAngleFromRoughness( geometryProps.mip, isDiffuse ? 1.0 : materialProps.roughness );

                // Choose a ray
                float3x3 mLocalBasis = geometryProps.Has( FLAG_HAIR ) ? HairGetBasis( materialProps.N, materialProps.T ) : Geometry::GetBasis( materialProps.N );

                float3 Vlocal = Geometry::RotateVector( mLocalBasis, geometryProps.V );
                float3 ray = 0;
                uint samplesNum = 0;

                // If IS is enabled, generate up to IMPORTANCE_SAMPLES_NUM rays depending on roughness
                // If IS is disabled, there is no need to generate up to IMPORTANCE_SAMPLES_NUM rays for specular because VNDF v3 doesn't produce rays pointing inside the surface
                uint maxSamplesNum = 0;
                if( bounce == 1 && gDisableShadowsAndEnableImportanceSampling && NRD_MODE < OCCLUSION ) // TODO: use IS in each bounce?
                    maxSamplesNum = IMPORTANCE_SAMPLES_NUM * ( isDiffuse ? 1.0 : materialProps.roughness );
                maxSamplesNum = max( maxSamplesNum, 1 );

                if( geometryProps.Has( FLAG_HAIR ) && NRD_MODE < OCCLUSION )
                {
                    if( isDiffuse )
                        break;

                    HairSurfaceData hairSd = ( HairSurfaceData )0;
                    hairSd.N = float3( 0, 0, 1 );
                    hairSd.T = float3( 1, 0, 0 );
                    hairSd.V = Vlocal;

                    HairData hairData = ( HairData )0;
                    hairData.baseColor = materialProps.baseColor;
                    hairData.betaM = materialProps.roughness;
                    hairData.betaN = materialProps.metalness;

                    HairContext hairBrdf = HairContextInit( hairSd, hairData );

                    float3 r;
                    float pdf = HairSampleRay( hairBrdf, Vlocal, Rng::Hash::GetFloat4( ), r );

                    float3 throughput = HairEval( hairBrdf, Vlocal, r ) / pdf;
                    pathThroughput *= throughput;

                    ray = Geometry::RotateVectorInverse( mLocalBasis, r );
                }
                else
                {
                    for( uint sampleIndex = 0; sampleIndex < maxSamplesNum; sampleIndex++ )
                    {
                        #if( NRD_MODE < OCCLUSION )
                            float2 rnd = Rng::Hash::GetFloat2( );
                        #else
                            float2 rnd = GetBlueNoise( blueNoisePos, gTracingMode == RESOLUTION_HALF );
                        #endif

                        // Generate a ray in local space
                        float3 r;
                        if( isDiffuse )
                            r = ImportanceSampling::Cosine::GetRay( rnd );
                        else
                        {
                            float3 Hlocal = ImportanceSampling::VNDF::GetRay( rnd, materialProps.roughness, Vlocal, gTrimLobe ? SPEC_LOBE_ENERGY : 1.0 );
                            r = reflect( -Vlocal, Hlocal );
                        }

                        // Transform to world space
                        r = Geometry::RotateVectorInverse( mLocalBasis, r );

                        // Importance sampling for direct lighting
                        // TODO: move direct lighting tracing into a separate pass:
                        // - currently AO and SO get replaced with useless distances to closest lights if IS is on
                        // - better separate direct and indirect lighting denoising

                        //   1. If IS enabled, check the ray in LightBVH
                        bool isMiss = false;
                        if( gDisableShadowsAndEnableImportanceSampling && maxSamplesNum != 1 )
                            isMiss = CastVisibilityRay_AnyHit( geometryProps.GetXoffset( geometryProps.N ), r, 0.0, INF, mipAndCone, gLightTlas, GEOMETRY_ALL, desc.rayFlags );

                        //   2. Count rays hitting emissive surfaces
                        if( !isMiss )
                            samplesNum++;

                        //   3. Save either the first ray or the current ray hitting an emissive
                        if( !isMiss || sampleIndex == 0 )
                            ray = r;
                    }
                }

                // Adjust throughput by percentage of rays hitting any emissive surface
                // IMPORTANT: do not modify throughput if there is no a hit, it's needed to cast a non-IS ray and get correct AO / SO at least
                if( samplesNum != 0 )
                    pathThroughput *= float( samplesNum ) / float( maxSamplesNum );

                // ( Optional ) Helpful insignificant fixes
                float a = dot( geometryProps.N, ray );
                if( !geometryProps.Has( FLAG_HAIR ) && a < 0.0 )
                {
                    if( isDiffuse )
                    {
                        // Terminate diffuse paths pointing inside the surface
                        pathThroughput = 0.0;
                    }
                    else
                    {
                        // Patch ray direction to avoid self-intersections: https://arxiv.org/pdf/1705.01263.pdf ( Appendix 3 )
                        float b = dot( geometryProps.N, materialProps.N );
                        ray = normalize( ray + materialProps.N * Math::Sqrt01( 1.0 - a * a ) / b );
                    }
                }

                // ( Optional ) Save sampling direction for the 1st bounce
                #if( NRD_MODE == SH || NRD_MODE == DIRECTIONAL_OCCLUSION )
                    if( bounce == 1 )
                    {
                        float3 psrRay = ray;
                        #if( USE_PSR == 1 )
                            psrRay = Geometry::RotateVectorInverse( mirrorMatrix, ray );
                        #endif

                        if( isDiffuse )
                            result.diffDirection += psrRay;
                        else
                            result.specDirection += psrRay;
                    }
                #endif

                // Update path throughput
                #if( NRD_MODE < OCCLUSION )
                    if( !geometryProps.Has( FLAG_HAIR ) )
                    {
                        float3 albedo, Rf0;
                        BRDF::ConvertBaseColorMetalnessToAlbedoRf0( materialProps.baseColor, materialProps.metalness, albedo, Rf0 );

                        float3 H = normalize( geometryProps.V + ray );
                        float VoH = abs( dot( geometryProps.V, H ) );
                        float NoL = saturate( dot( materialProps.N, ray ) );

                        if( isDiffuse )
                        {
                            float NoV = abs( dot( materialProps.N, geometryProps.V ) );
                            pathThroughput *= saturate( albedo * Math::Pi( 1.0 ) * BRDF::DiffuseTerm_Burley( materialProps.roughness, NoL, NoV, VoH ) );
                        }
                        else
                        {
                            float3 F = BRDF::FresnelTerm_Schlick( Rf0, VoH );
                            pathThroughput *= F;

                            // See paragraph "Usage in Monte Carlo renderer" from http://jcgt.org/published/0007/04/01/paper.pdf
                            pathThroughput *= BRDF::GeometryTerm_Smith( materialProps.roughness, NoL );
                        }

                        // Translucency
                        if( USE_TRANSLUCENCY && geometryProps.Has( FLAG_LEAF ) && isDiffuse )
                        {
                            if( Rng::Hash::GetFloat( ) < LEAF_TRANSLUCENCY )
                            {
                                ray = -ray;
                                geometryProps.X -= LEAF_THICKNESS * geometryProps.N;
                                pathThroughput /= LEAF_TRANSLUCENCY;
                            }
                            else
                                pathThroughput /= 1.0 - LEAF_TRANSLUCENCY;
                        }
                    }
                #endif

                // Abort if expected contribution of the current bounce is low
                #if( USE_RUSSIAN_ROULETTE == 1 )
                    /*
                    BAD PRACTICE:
                    Russian Roulette approach is here to demonstrate that it's a bad practice for real time denoising for the following reasons:
                    - increases entropy of the signal
                    - transforms radiance into non-radiance, which is strictly speaking not allowed to be processed spatially (who wants to get a high energy firefly
                    redistributed around surrounding pixels?)
                    - not necessarily converges to the right image, because we do assumptions about the future and approximate the tail of the path via a scaling factor
                    - this approach breaks denoising, especially REBLUR, which has been designed to work with pure radiance
                    */

                    // Nevertheless, RR can be used with caution: the code below tuned for good IQ / PERF tradeoff
                    float russianRouletteProbability = Color::Luminance( pathThroughput );
                    russianRouletteProbability = Math::Pow01( russianRouletteProbability, 0.25 );
                    russianRouletteProbability = max( russianRouletteProbability, 0.01 );

                    if( Rng::Hash::GetFloat( ) > russianRouletteProbability )
                        break;

                    pathThroughput /= russianRouletteProbability;
                #else
                    /*
                    GOOD PRACTICE:
                    - terminate path if "pathThroughput" is smaller than some threshold
                    - approximate ambient at the end of the path
                    - re-use data from the previous frame
                    */

                    if( THROUGHPUT_THRESHOLD != 0.0 && Color::Luminance( pathThroughput ) < THROUGHPUT_THRESHOLD )
                        break;
                #endif

                //=========================================================================================================================================================
                // Trace to the next hit
                //=========================================================================================================================================================

                geometryProps = CastRay( geometryProps.GetXoffset( geometryProps.N ), ray, 0.0, INF, mipAndCone, gWorldTlas, desc.instanceInclusionMask, desc.rayFlags );
                materialProps = GetMaterialProps( geometryProps );
            }

            //=============================================================================================================================================================
            // Hit point
            //=============================================================================================================================================================

            {
                //=============================================================================================================================================================
                // Lighting
                //=============================================================================================================================================================

                float4 Lcached = 0;
                if( !geometryProps.IsSky( ) )
                {
                    // L1 cache - reproject previous frame, carefully treating specular
                    Lcached = GetRadianceFromPreviousFrame( geometryProps, materialProps, desc.pixelPos, false );

                    // L2 cache - SHARC
                    GridParameters gridParameters = ( GridParameters )0;
                    gridParameters.cameraPosition = gCameraGlobalPos.xyz;
                    gridParameters.cameraPositionPrev = gCameraGlobalPosPrev.xyz;
                    gridParameters.sceneScale = SHARC_SCENE_SCALE;
                    gridParameters.logarithmBase = SHARC_GRID_LOGARITHM_BASE;

                    float3 Xglobal = GetGlobalPos( geometryProps.X );
                    uint level = GetGridLevel( Xglobal, gridParameters );
                    float voxelSize = GetVoxelSize( level, gridParameters );
                    float smc = GetSpecMagicCurve( materialProps.roughness );

                    float3x3 mBasis = Geometry::GetBasis( geometryProps.N );
                    float2 rndScaled = ( Rng::Hash::GetFloat2( ) - 0.5 ) * voxelSize * USE_SHARC_DITHERING;
                    Xglobal += mBasis[ 0 ] * rndScaled.x + mBasis[ 1 ] * rndScaled.y;

                    SharcHitData sharcHitData = ( SharcHitData )0;
                    sharcHitData.positionWorld = Xglobal;
                    sharcHitData.normalWorld = geometryProps.N;

                    SharcState sharcState;
                    sharcState.gridParameters = gridParameters;
                    sharcState.hashMapData.capacity = SHARC_CAPACITY;
                    sharcState.hashMapData.hashEntriesBuffer = gInOut_SharcHashEntriesBuffer;
                    sharcState.voxelDataBuffer = gInOut_SharcVoxelDataBuffer;

                    bool isSharcAllowed = gSHARC && NRD_MODE < OCCLUSION; // trivial
                    isSharcAllowed &= geometryProps.tmin > voxelSize; // voxel angular size is acceptable
                    isSharcAllowed &= Rng::Hash::GetFloat( ) > Lcached.w; // probabilistically estimate the need
                    isSharcAllowed &= isDiffuse || Rng::Hash::GetFloat( ) < smc || bounce == desc.bounceNum; // allowed for diffuse-like events or last bounce

                    float3 sharcRadiance;
                    if( isSharcAllowed && SharcGetCachedRadiance( sharcState, sharcHitData, sharcRadiance, false ) )
                        Lcached = float4( sharcRadiance, 1.0 );

                    // Cache miss - compute lighting, if not found in caches
                    if( Rng::Hash::GetFloat( ) > Lcached.w )
                    {
                        float3 L = GetShadowedLighting( geometryProps, materialProps );
                        Lcached.xyz = bounce < desc.bounceNum ? L : max( Lcached.xyz, L );
                    }
                }
                Lcached.xyz = max( Lcached.xyz, materialProps.Lemi );

                //=============================================================================================================================================================
                // Other
                //=============================================================================================================================================================

                // Accumulate lighting
                float3 L = Lcached.xyz * pathThroughput;
                Lsum += L;

                // ( Biased ) Reduce contribution of next samples if previous frame is sampled, which already has multi-bounce information
                pathThroughput *= 1.0 - Lcached.w;

                // Accumulate path length for NRD ( see "README/NOISY INPUTS" )
                /*
                REQUIREMENTS:
                    - hitT for the bounce after the primary hit or PSR must be provided "as is"
                    - hitT for subsequent bounces and for bounces before PSR must be adjusted by curvature and lobe energy dissipation on the application side

                IDEAL SOLUTION ( after PSR ):
                    hitDist = 0;
                    for( uint bounce = N; bounce > PSR + 1; bounce-- )
                    {
                        hitDist += hitT[ bounce ];
                        hitDist = ApplyThinLensEquation( hitDist, curvature[ bounce - 1 ] );
                        hitDist = ApplyLobeSpread( hitDist, bounce, isDiffuse ? 1.0 : roughness  );
                    }
                    hitDist += hitT[ PSR + 1 ];
                */
                float a = Color::Luminance( L );
                float b = Color::Luminance( Lsum ); // already includes L
                float importance = a / ( b + 1e-6 );

                importance *= 1.0 - Color::Luminance( materialProps.Lemi ) / ( a + 1e-6 );

                float diffuseLikeMotion = EstimateDiffuseProbability( geometryProps, materialProps, true );
                diffuseLikeMotion = lerp( diffuseLikeMotion, 1.0, Math::Sqrt01( materialProps.curvature ) );
                diffuseLikeMotion = isDiffuse ? 1.0 : diffuseLikeMotion;

                accumulatedHitDist += geometryProps.tmin * Math::SmoothStep( 0.2, 0.0, accumulatedDiffuseLikeMotion );
                accumulatedDiffuseLikeMotion += 1.0 - importance * ( 1.0 - diffuseLikeMotion );
            }
        }

        // Debug visualization: specular mip level at the end of the path
        if( gOnScreen == SHOW_MIP_SPECULAR )
        {
            float mipNorm = Math::Sqrt01( geometryProps.mip / MAX_MIP_LEVEL );
            Lsum = Color::ColorizeZucconi( mipNorm );
        }

        // Normalize hit distances for REBLUR and REFERENCE ( needed only for AO ) before averaging
        float normHitDist = accumulatedHitDist;
        if( gDenoiserType != DENOISER_RELAX )
            normHitDist = REBLUR_FrontEnd_GetNormHitDist( accumulatedHitDist, viewZ, gHitDistParams, isDiffusePath ? 1.0 : desc.materialProps.roughness );

        // Accumulate diffuse and specular separately for denoising
        if( !USE_SANITIZATION || NRD_IsValidRadiance( Lsum ) )
        {
            if( isDiffusePath )
            {
                result.diffRadiance += Lsum;
                result.diffHitDist += normHitDist;
                diffPathsNum++;
            }
            else
            {
                result.specRadiance += Lsum;

                #if( NRD_MODE < OCCLUSION )
                    NRD_FrontEnd_SpecHitDistAveraging_Add( result.specHitDist, normHitDist );
                #else
                    result.specHitDist += normHitDist;
                #endif
            }
        }
    }

    // Material de-modulation ( convert irradiance into radiance )
    float3 albedo, Rf0;
    BRDF::ConvertBaseColorMetalnessToAlbedoRf0( desc.materialProps.baseColor, desc.materialProps.metalness, albedo, Rf0 );

    float NoV = abs( dot( desc.materialProps.N, desc.geometryProps.V ) );
    float3 Fenv = BRDF::EnvironmentTerm_Rtg( Rf0, NoV, desc.materialProps.roughness );
    float3 diffDemod = ( 1.0 - Fenv ) * albedo * 0.99 + 0.01;
    float3 specDemod = Fenv * 0.99 + 0.01;

    // We can combine radiance ( for everything ) and irradiance ( for hair ) in denoising if material ID test is enabled
    if( desc.geometryProps.Has( FLAG_HAIR ) && NRD_NORMAL_ENCODING == NRD_NORMAL_ENCODING_R10G10B10A2_UNORM )
    {
        diffDemod = 1.0;
        specDemod = 1.0;
    }

    if( gOnScreen != SHOW_MIP_SPECULAR )
    {
        result.diffRadiance /= diffDemod;
        result.specRadiance /= specDemod;
    }

    // Radiance is already divided by sampling probability, we need to average across all paths
    float radianceNorm = 1.0 / float( desc.pathNum );
    result.diffRadiance *= radianceNorm;
    result.specRadiance *= radianceNorm;

    // Others are not divided by sampling probability, we need to average across diffuse / specular only paths
    float diffNorm = diffPathsNum == 0 ? 0.0 : 1.0 / float( diffPathsNum );
    #if( NRD_MODE == SH || NRD_MODE == DIRECTIONAL_OCCLUSION )
        result.diffDirection *= diffNorm;
    #endif
    result.diffHitDist *= diffNorm;

    float specNorm = pathNum == diffPathsNum ? 0.0 : 1.0 / float( pathNum - diffPathsNum );
    #if( NRD_MODE == SH || NRD_MODE == DIRECTIONAL_OCCLUSION )
        result.specDirection *= specNorm;
    #endif
    #if( NRD_MODE < OCCLUSION )
        NRD_FrontEnd_SpecHitDistAveraging_End( result.specHitDist );
    #else
        result.specHitDist *= specNorm;
    #endif

    return result;
}

//========================================================================================
// MAIN
//========================================================================================

void WriteResult( uint checkerboard, uint2 outPixelPos, float4 diff, float4 spec, float4 diffSh, float4 specSh )
{
    if( gTracingMode == RESOLUTION_HALF )
    {
        if( checkerboard )
        {
            gOut_Diff[ outPixelPos ] = diff;
            #if( NRD_MODE == SH )
                gOut_DiffSh[ outPixelPos ] = diffSh;
            #endif
        }
        else
        {
            gOut_Spec[ outPixelPos ] = spec;
            #if( NRD_MODE == SH )
                gOut_SpecSh[ outPixelPos ] = specSh;
            #endif
        }
    }
    else
    {
        gOut_Diff[ outPixelPos ] = diff;
        gOut_Spec[ outPixelPos ] = spec;
        #if( NRD_MODE == SH )
            gOut_DiffSh[ outPixelPos ] = diffSh;
            gOut_SpecSh[ outPixelPos ] = specSh;
        #endif
    }
}

[numthreads( 16, 16, 1 )]
void main( uint2 pixelPos : SV_DispatchThreadId )
{
    const float NaN = sqrt( -1 );

    // Pixel and sample UV
    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvRectSize;
    float2 sampleUv = pixelUv + gJitter;

    // Checkerboard
    uint2 outPixelPos = pixelPos;
    if( gTracingMode == RESOLUTION_HALF )
        outPixelPos.x >>= 1;

    uint checkerboard = Sequence::CheckerBoard( pixelPos, gFrameIndex ) != 0;

    // Do not generate NANs for unused threads
    if( pixelUv.x > 1.0 || pixelUv.y > 1.0 )
    {
        #if( USE_DRS_STRESS_TEST == 1 )
            WriteResult( checkerboard, outPixelPos, NaN, NaN, NaN, NaN );
        #endif

        return;
    }

    //================================================================================================================================================================================
    // Primary rays
    //================================================================================================================================================================================

    // Initialize RNG
    Rng::Hash::Initialize( pixelPos, gFrameIndex );

    // Primary ray
    float3 cameraRayOrigin = ( float3 )0;
    float3 cameraRayDirection = ( float3 )0;
    GetCameraRay( cameraRayOrigin, cameraRayDirection, sampleUv );

    GeometryProps geometryProps0 = CastRay( cameraRayOrigin, cameraRayDirection, 0.0, INF, GetConeAngleFromRoughness( 0.0, 0.0 ), gWorldTlas, ( gOnScreen == SHOW_INSTANCE_INDEX || gOnScreen == SHOW_NORMAL ) ? GEOMETRY_ALL : GEOMETRY_IGNORE_TRANSPARENT, 0 );
    MaterialProps materialProps0 = GetMaterialProps( geometryProps0 );

    // ViewZ
    float viewZ = Geometry::AffineTransform( gWorldToView, geometryProps0.X ).z;
    viewZ = geometryProps0.IsSky( ) ? Math::Sign( viewZ ) * INF : viewZ;

    gOut_ViewZ[ pixelPos ] = viewZ;

    // Motion
    float3 motion = GetMotion( geometryProps0.X, geometryProps0.Xprev );

    gOut_Mv[ pixelPos ] = float4( motion, viewZ * FP16_VIEWZ_SCALE );

    // Early out - sky
    if( geometryProps0.IsSky( ) )
    {
        gOut_DirectEmission[ pixelPos ] = materialProps0.Lemi;

        #if( USE_INF_STRESS_TEST == 1 )
            WriteResult( checkerboard, outPixelPos, NaN, NaN, NaN, NaN );
        #endif

        return;
    }

    // G-buffer
    uint materialID = geometryProps0.Has( FLAG_HAIR ) ? MATERIAL_ID_HAIR : ( materialProps0.metalness < 0.5 ? MATERIAL_ID_DEFAULT : MATERIAL_ID_METAL );

    #if( USE_SIMULATED_MATERIAL_ID_TEST == 1 )
        materialID = frac( geometryProps0.X ).x < 0.05 ? MATERIAL_ID_HAIR : materialID;
    #endif

    float3 N = materialProps0.N;
    if( geometryProps0.Has( FLAG_HAIR ) )
    {
        // Generate a better guide for hair
        float3 B = cross( geometryProps0.V, geometryProps0.T.xyz );
        float3 n = normalize( cross( geometryProps0.T.xyz, B ) );

        float pixelSize = gUnproject * lerp( abs( viewZ ), 1.0, abs( gOrthoMode ) );
        float f = NRD_GetNormalizedStrandThickness( STRAND_THICKNESS, pixelSize );
        f = lerp( 0.0, 0.25, f );

        N = normalize( lerp( n, N, f ) );
    }

    #if( USE_SHARC_DEBUG == 1 )
        N = geometryProps0.N;
    #endif

    gOut_Normal_Roughness[ pixelPos ] = NRD_FrontEnd_PackNormalAndRoughness( N, materialProps0.roughness, materialID );
    gOut_BaseColor_Metalness[ pixelPos ] = float4( Color::ToSrgb( materialProps0.baseColor ), materialProps0.metalness );

    // Debug
    if( gOnScreen == SHOW_INSTANCE_INDEX )
    {
        Rng::Hash::Initialize( geometryProps0.instanceIndex, 0 );

        uint checkerboard = Sequence::CheckerBoard( pixelPos >> 2, 0 ) != 0;
        float3 color = Rng::Hash::GetFloat4( ).xyz;
        color *= ( checkerboard && !geometryProps0.Has( FLAG_STATIC ) ) ? 0.5 : 1.0;

        materialProps0.Ldirect = color;
    }
    else if( gOnScreen == SHOW_UV )
        materialProps0.Ldirect = float3( frac( geometryProps0.uv ), 0 );
    else if( gOnScreen == SHOW_CURVATURE )
        materialProps0.Ldirect = sqrt( abs( materialProps0.curvature ) );
    else if( gOnScreen == SHOW_MIP_PRIMARY )
    {
        float mipNorm = Math::Sqrt01( geometryProps0.mip / MAX_MIP_LEVEL );
        materialProps0.Ldirect = Color::ColorizeZucconi( mipNorm );
    }

    // Unshadowed sun lighting and emission
    gOut_DirectLighting[ pixelPos ] = materialProps0.Ldirect;
    gOut_DirectEmission[ pixelPos ] = materialProps0.Lemi;

    //================================================================================================================================================================================
    // Secondary rays ( indirect and direct lighting from local light sources ) + potential PSR
    //================================================================================================================================================================================

    TraceOpaqueDesc desc = ( TraceOpaqueDesc )0;
    desc.geometryProps = geometryProps0;
    desc.materialProps = materialProps0;
    desc.pixelPos = pixelPos;
    desc.checkerboard = checkerboard;
    desc.pathNum = gSampleNum;
    desc.bounceNum = gBounceNum; // TODO: adjust by roughness?
    desc.instanceInclusionMask = GEOMETRY_IGNORE_TRANSPARENT;
    desc.rayFlags = 0;

    TraceOpaqueResult result = TraceOpaque( desc );

    #if( USE_SIMULATED_MATERIAL_ID_TEST == 1 )
        if( frac( geometryProps0.X ).x < 0.05 )
            result.diffRadiance = float3( 0, 10, 0 ) * Color::Luminance( result.diffRadiance );
    #endif

    #if( USE_SIMULATED_FIREFLY_TEST == 1 )
        const float maxFireflyEnergyScaleFactor = 10000.0;
        result.diffRadiance /= lerp( 1.0 / maxFireflyEnergyScaleFactor, 1.0, Rng::Hash::GetFloat( ) );
    #endif

    //================================================================================================================================================================================
    // Sun shadow ( after potential PSR )
    //================================================================================================================================================================================

    float2 rnd = GetBlueNoise( pixelPos, false );
    rnd = ImportanceSampling::Cosine::GetRay( rnd ).xy;
    rnd *= gTanSunAngularRadius;

    float3 sunDirection = normalize( gSunBasisX.xyz * rnd.x + gSunBasisY.xyz * rnd.y + gSunDirection.xyz );
    float3 Xoffset = desc.geometryProps.GetXoffset( sunDirection, SHADOW_RAY_OFFSET );
    float2 mipAndCone = GetConeAngleFromAngularRadius( desc.geometryProps.mip, gTanSunAngularRadius );

    float shadowTranslucency = ( Color::Luminance( desc.materialProps.Ldirect ) != 0.0 && !gDisableShadowsAndEnableImportanceSampling ) ? 1.0 : 0.0;
    float shadowHitDist = 0.0;

    while( shadowTranslucency > 0.01 )
    {
        GeometryProps geometryPropsShadow = CastRay( Xoffset, sunDirection, 0.0, INF, mipAndCone, gWorldTlas, GEOMETRY_ALL, 0 );

        // Update hit dist
        shadowHitDist += geometryPropsShadow.tmin;

        // Terminate on miss ( before updating translucency! )
        if( geometryPropsShadow.IsSky( ) )
            break;

        // ( Biased ) Cheap approximation of shadows through glass
        float NoV = abs( dot( geometryPropsShadow.N, sunDirection ) );
        shadowTranslucency *= lerp( geometryPropsShadow.Has( FLAG_TRANSPARENT ) ? 0.9 : 0.0, 0.0, Math::Pow01( 1.0 - NoV, 2.5 ) );

        // Go to the next hit
        Xoffset += sunDirection * ( geometryPropsShadow.tmin + 0.001 );
    }

    float penumbra = SIGMA_FrontEnd_PackPenumbra( shadowHitDist, gTanSunAngularRadius );
    float4 translucency = SIGMA_FrontEnd_PackTranslucency( shadowHitDist, shadowTranslucency );

    gOut_ShadowData[ pixelPos ] = penumbra;
    gOut_Shadow_Translucency[ pixelPos ] = translucency;

    //================================================================================================================================================================================
    // Output
    //================================================================================================================================================================================

    float4 outDiff = 0.0;
    float4 outSpec = 0.0;
    float4 outDiffSh = 0.0;
    float4 outSpecSh = 0.0;

    if( gDenoiserType == DENOISER_RELAX )
    {
    #if( NRD_MODE == SH )
        outDiff = RELAX_FrontEnd_PackSh( result.diffRadiance, result.diffHitDist, result.diffDirection, outDiffSh, USE_SANITIZATION );
        outSpec = RELAX_FrontEnd_PackSh( result.specRadiance, result.specHitDist, result.specDirection, outSpecSh, USE_SANITIZATION );
    #else
        outDiff = RELAX_FrontEnd_PackRadianceAndHitDist( result.diffRadiance, result.diffHitDist, USE_SANITIZATION );
        outSpec = RELAX_FrontEnd_PackRadianceAndHitDist( result.specRadiance, result.specHitDist, USE_SANITIZATION );
    #endif
    }
    else
    {
    #if( NRD_MODE == OCCLUSION )
        outDiff = result.diffHitDist;
        outSpec = result.specHitDist;
    #elif( NRD_MODE == SH )
        outDiff = REBLUR_FrontEnd_PackSh( result.diffRadiance, result.diffHitDist, result.diffDirection, outDiffSh, USE_SANITIZATION );
        outSpec = REBLUR_FrontEnd_PackSh( result.specRadiance, result.specHitDist, result.specDirection, outSpecSh, USE_SANITIZATION );
    #elif( NRD_MODE == DIRECTIONAL_OCCLUSION )
        outDiff = REBLUR_FrontEnd_PackDirectionalOcclusion( result.diffDirection, result.diffHitDist, USE_SANITIZATION );
    #else
        outDiff = REBLUR_FrontEnd_PackRadianceAndNormHitDist( result.diffRadiance, result.diffHitDist, USE_SANITIZATION );
        outSpec = REBLUR_FrontEnd_PackRadianceAndNormHitDist( result.specRadiance, result.specHitDist, USE_SANITIZATION );
    #endif
    }

    WriteResult( checkerboard, outPixelPos, outDiff, outSpec, outDiffSh, outSpecSh );
}
