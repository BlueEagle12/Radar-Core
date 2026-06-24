texture sTexture;
float2 sTextureSize = float2(1.0, 1.0);
float sFeather = 2.0;

sampler TextureSampler = sampler_state
{
	Texture = (sTexture);
	MinFilter = Linear;
	MagFilter = Linear;
	MipFilter = Linear;
	AddressU = Clamp;
	AddressV = Clamp;
};

float4 PixelShaderFunction(float2 textureCoordinate : TEXCOORD0) : COLOR0
{
	float4 color = tex2D(TextureSampler, textureCoordinate);
	float2 pixelPosition = textureCoordinate * sTextureSize;
	float2 center = sTextureSize * 0.5;
	float radius = min(sTextureSize.x, sTextureSize.y) * 0.5;
	float feather = max(sFeather, 0.001);
	float maskAlpha = saturate((radius - distance(pixelPosition, center)) / feather);

	color.a *= maskAlpha;
	return color;
}

technique CircleMask
{
	pass P0
	{
		PixelShader = compile ps_2_0 PixelShaderFunction();
	}
}

technique fallback
{
	pass P0
	{
	}
}
