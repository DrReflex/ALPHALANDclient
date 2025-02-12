#include "common.h"

//#define PIN_SOFT_PARTICLES 1

TEX_DECLARE2D(tex, 0);
TEX_DECLARE2D(cstrip, 1);
TEX_DECLARE2D(astrip, 2);
TEX_DECLARE2D(depthTex, 3);

uniform float4 throttleFactor; // .x = alpha cutoff, .y = alpha boost (clamp), .w - additive/alpha ratio for Crazy shaders
uniform float4 modulateColor;
uniform float4 zOffset;
uniform float4 halfPixelDepth; // .xy = half-pixel offset for 

#define SOFT_PARTICLE_DENSITY  (1.0f)

struct VS_INPUT
{
    float4 pos : POSITION;
	ATTR_INT4 scaleRotLife : TEXCOORD0; // transform matrix
	ATTR_INT2 disp : TEXCOORD1; // .xy = corner, either (0,0), (1,0), (0,1), or (1,1)
	ATTR_INT2 cline : TEXCOORD2; // .x = color line [0...32767]
};

struct VS_OUTPUT
{
    float4 pos : POSITION;
    float3 uvFog : TEXCOORD0;
    float2 colorLookup : TEXCOORD1;
#ifdef PIN_SOFT_PARTICLES
    float4 screen : TEXCOORD3;
#endif
};

float4 rotScale(float4 scaleRotLife)
{
    float cr = cos(scaleRotLife.z);
    float sr = sin(scaleRotLife.z);

    float4 r;
    r.x = cr * scaleRotLife.x;
    r.y = -sr * scaleRotLife.x;
    r.z = sr * scaleRotLife.y;
    r.w = cr * scaleRotLife.y;
	
    return r;
}

// vs
float3 screenCoord(float4 vsout)
{
    float3 screen;
    screen.xy = vsout.xy / vsout.w;
#ifndef GLSL
    screen.xy = float2(0.5f, -0.5f) * screen.xy + 0.5f;
#else
    screen.xy = float2( 0.5f,  0.5f ) * screen.xy + 0.5f;
#endif

#if defined(GLSL) || defined(DX11)
#else
    screen.xy += halfPixelDepth.xy;
#endif
    screen.z = min(vsout.w - zOffset.x, GBUFFER_MAX_DEPTH * 0.99f);
    return screen;
}

// ps
float softFactor(float3 screen, float density)
{
    float4 depthBuf = tex2D(depthTex, screen.xy);
    float backDepth = (depthBuf.z * (1.0f / 256.0f) + depthBuf.w) * GBUFFER_MAX_DEPTH;
    //float factor = 1 - saturate( exp( -density * abs(backDepth - screen.z) ) );
    float factor = saturate(density * (backDepth - screen.z));
    return factor;
}



VS_OUTPUT vs(VS_INPUT input)
{
    VS_OUTPUT o;
	
    float4 pos = float4(input.pos.xyz, 1);
    float2 disp = input.disp.xy * 2 - 1; // -1..1

    float4 scaleRotLifeFlt = (float4) input.scaleRotLife * float4(1.0f / 256.0f, 1.0f / 256.0f, 2.0 * 3.1415926f / 32767.0f, 1.0f / 32767.0f);
    scaleRotLifeFlt.xy += 127.0f;
	
    float4 rs = rotScale(scaleRotLifeFlt);

    pos += G(ViewRight) * dot(disp, rs.xy);
    pos += G(ViewUp) * dot(disp, rs.zw);

    float4 pos2 = pos + G(ViewDir) * zOffset.x; // Z-offset position in world space

    o.pos = mul(G(ViewProjection), pos);
	
    o.uvFog.xy = input.disp.xy;
    o.uvFog.y = 1 - o.uvFog.y;
    o.uvFog.z = (G(FogParams).z - o.pos.w) * G(FogParams).w;
	
    o.colorLookup.x = 1 - max(0, min(1, scaleRotLifeFlt.w));
    o.colorLookup.y = (float) input.cline.x * (1.0 / 32767.0f);


    pos2 = mul(G(ViewProjection), pos2); // Z-offset position in clip space
    o.pos.z = pos2.z * o.pos.w / pos2.w; // Only need z

#ifdef PIN_SOFT_PARTICLES
    o.screen.xyz = screenCoord( o.pos );
    o.screen.w   = 1.0f/scaleRotLifeFlt.x;
#endif

    return o;
}


float4 psAdd(VS_OUTPUT input) : COLOR0 // #0
{
    float4 texcolor = tex2D(tex, input.uvFog.xy);
    float4 vcolor = tex2D(cstrip, input.colorLookup.xy);
    vcolor.a = tex2D(astrip, input.colorLookup.xy).r;

    float sfact = 1;
#ifdef PIN_SOFT_PARTICLES
    sfact = softFactor( input.screen.xyz, SOFT_PARTICLE_DENSITY * input.screen.w );
#endif
           
    float4 result;

    result.rgb = (texcolor.rgb + vcolor.rgb) * modulateColor.rgb;
    result.a = texcolor.a * vcolor.a;
    result.rgb *= result.a * sfact;

    result.rgb = lerp(0.0f.xxx, result.rgb, saturate(input.uvFog.zzz));
    return result;
}

float4 psModulate(VS_OUTPUT input) : COLOR0 // #1
{

    float4 texcolor = tex2D(tex, input.uvFog.xy);
    float4 vcolor = tex2D(cstrip, input.colorLookup.xy) * modulateColor;
    vcolor.a = tex2D(astrip, input.colorLookup.xy).r * modulateColor.a;

    float sfact = 1;
#ifdef PIN_SOFT_PARTICLES
    sfact = softFactor( input.screen.xyz, SOFT_PARTICLE_DENSITY * input.screen.w );
#endif

    float4 result;

    result.rgb = texcolor.rgb * vcolor.rgb;
    result.a = texcolor.a * vcolor.a * sfact;
	
    result.rgb = lerp(G(FogColor).rgb, result.rgb, saturate(input.uvFog.zzz));
    return result;
}

	
// - this shader is crazy
// - used instead of additive particles to help see bright particles (e.g. fire) on top of extremely bright backgrounds 
// - requires ONE | INVSRCALPHA blend mode, useless otherwise
// - does not use color strip texture
// - outputs a blend between additive blend and alpha blend in fragment alpha
// - ratio multiplier is in throttleFactor.w
float4 psCrazy(VS_OUTPUT input) : COLOR0
{
    float4 texcolor = tex2D(tex, input.uvFog.xy);
    float4 vcolor = float4(1, 0, 0, 0); //tex2D( cstrip, input.colorLookup.xy ); // not actually used
    vcolor.a = tex2D(astrip, input.colorLookup.xy).r;
    float blendRatio = throttleFactor.w; // yeah yeah

    float sfact = 1;
#ifdef PIN_SOFT_PARTICLES
    sfact = softFactor( input.screen.xyz, SOFT_PARTICLE_DENSITY * input.screen.w );
#endif
	
    float4 result;

    result.rgb = (texcolor.rgb) * modulateColor.rgb * vcolor.a * texcolor.a * sfact;
    result.a = blendRatio * texcolor.a * vcolor.a * sfact;

    result = lerp(0.0f.xxxx, result, saturate(input.uvFog.zzzz));
    return result;
}

float4 psCrazySparkles(VS_OUTPUT input) : COLOR0
{
    float4 texcolor = tex2D(tex, input.uvFog.xy);
    float4 vcolor = tex2D(cstrip, input.colorLookup.xy);
    vcolor.a = tex2D(astrip, input.colorLookup.xy).r;
    float blendRatio = throttleFactor.w;
	
    float4 result;

    if (texcolor.a < 0.5f)
    {
        result.rgb = vcolor.rgb * modulateColor.rgb * (2 * texcolor.a);
    }
    else
    {
        result.rgb = lerp(vcolor.rgb * modulateColor.rgb, texcolor.rgb, 2 * texcolor.a - 1);
    }
	
	//vcolor.a   *= modulateColor.a;
    result.rgb *= vcolor.a;
    result.a = blendRatio * texcolor.a * vcolor.a;
	
    result = lerp(0.0f.xxxx, result, saturate(input.uvFog.zzzz));
    return result;
}


///////////////////////////////////////////////////////////////////////////////////

struct VS_INPUT2
{
    float4 pos : POSITION;
	ATTR_INT4 scaleRotLife : TEXCOORD0; // transform matrix
	ATTR_INT2 disp : TEXCOORD1; // .xy = corner, either (0,0), (1,0), (0,1), or (1,1)
	ATTR_INT2 cline : TEXCOORD2; // .x = color line [0...32767]
	ATTR_INT4 color : TEXCOORD3; // .xyzw
};

struct VS_OUTPUT2
{
    float4 pos : POSITION;
    float3 uvFog : TEXCOORD0;
    float4 color : TEXCOORD1;
#ifdef PIN_SOFT_PARTICLES
    float4 screen : TEXCOORD3;
#endif
};


VS_OUTPUT2 vsCustom(VS_INPUT2 input)
{
    VS_OUTPUT2 o;
	
    float4 pos = input.pos;
    float2 disp = input.disp.xy * 2 - 1; // -1..1

    float4 scaleRotLifeFlt = (float4) input.scaleRotLife * float4(1.0 / 256.0f, 1.0 / 256.0f, 2.0 * 3.1415926f / 32767.0, 1.0 / 32767.0f);
    scaleRotLifeFlt.xy += 127.0f;

    float4 rs = rotScale(scaleRotLifeFlt);

    pos += G(ViewRight) * dot(disp, rs.xy);
    pos += G(ViewUp) * dot(disp, rs.zw);
	
    float4 pos2 = pos + G(ViewDir) * zOffset.x; // Z-offset position in world space

    o.pos = mul(G(ViewProjection), pos);
	
    o.uvFog.xy = input.disp.xy;
    o.uvFog.y = 1 - o.uvFog.y;
    o.uvFog.z = (G(FogParams).z - o.pos.w) * G(FogParams).w;
	
    o.color = input.color * (1 / 255.0f);
       
    pos2 = mul(G(ViewProjection), pos2); // Z-offset position in clip space
    o.pos.z = pos2.z * o.pos.w / pos2.w; // Only need z
        
#ifdef PIN_SOFT_PARTICLES
    o.screen.xyz = screenCoord( o.pos );
    o.screen.w   = 1.0f/scaleRotLifeFlt.x;
#endif        
    return o;
}

float4 psCustom(VS_OUTPUT2 input) : COLOR0 // #1
{
    float4 texcolor = tex2D(tex, input.uvFog.xy);
    
    float sfact = 1;
#ifdef PIN_SOFT_PARTICLES
    sfact = softFactor( input.screen.xyz, SOFT_PARTICLE_DENSITY * input.screen.w );
#endif
  
    //return float4(sfact.xxx,1);
  
    //sfact = 1;
   
    float4 vcolor = input.color;

    float blendRatio = throttleFactor.w; // yeah yeah
	
    float4 result;

    result.rgb = texcolor.rgb * vcolor.rgb * vcolor.a * texcolor.a * sfact;
    result.a = blendRatio * texcolor.a * vcolor.a * sfact;

    result = lerp(0.0f.xxxx, result, saturate(input.uvFog.zzzz));
    return result;
}