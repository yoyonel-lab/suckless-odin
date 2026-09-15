#version 450 core

layout(local_size_x = 16, local_size_y = 4, local_size_z = 1) in;

layout(binding = 0) uniform samplerCube envMap;
layout(binding = 1, rgba16f) restrict writeonly uniform imageCube irradianceMap;

layout(location = 0) uniform float clamp_threshold;
layout(location = 1) uniform int u_offset_y;
layout(location = 2) uniform int u_max_y;

const float PI = 3.14159265359;
const float TWO_PI = 2.0 * PI;

// Convertit les coordonnées UV d'une face de cubemap en direction 3D unitaire
// Convention OpenGL matching cubemap_face_view_matrix
vec3 face_uv_to_dir(vec2 uv, uint face)
{
	vec2 sc_tc = uv * 2.0 - 1.0;
	float sc = sc_tc.x;
	float tc = sc_tc.y;
	vec3 dir;
	switch (face) {
	case 0u: dir = vec3( 1.0, -tc, -sc); break; // +X
	case 1u: dir = vec3(-1.0, -tc,  sc); break; // -X
	case 2u: dir = vec3(  sc,  1.0,  tc); break; // +Y
	case 3u: dir = vec3(  sc, -1.0, -tc); break; // -Y
	case 4u: dir = vec3(  sc, -tc,  1.0); break; // +Z
	case 5u: dir = vec3( -sc, -tc, -1.0); break; // -Z
	default: dir = vec3(0.0, 0.0, 1.0);  break;
	}
	return normalize(dir);
}

void OrthonormalBasis(vec3 n, out vec3 t, out vec3 b)
{
	vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
	t = normalize(cross(up, n));
	b = cross(n, t);
}

vec3 soft_clamp_smoothstep(vec3 color)
{
	float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
	float transition_start = clamp_threshold;
	float transition_end = clamp_threshold * 1.5;

	if (lum <= transition_start)
		return color;
	if (lum >= transition_end)
		return color * (transition_end / lum);

	float t =
	    (lum - transition_start) / (transition_end - transition_start);
	float blend = 1.0 - smoothstep(0.0, 1.0, t) * 0.5;
	return color * blend;
}

void main(void)
{
	ivec2 outSize = imageSize(irradianceMap);
	ivec2 pos = ivec2(gl_GlobalInvocationID.x,
	                  gl_GlobalInvocationID.y + u_offset_y);
	uint face = gl_GlobalInvocationID.z;

	if (pos.x >= outSize.x || pos.y >= outSize.y || pos.y >= u_max_y || face >= 6u)
		return;

	// Coordonnées UV centrées demi-texel
	vec2 uv = (vec2(pos) + 0.5) / vec2(outSize);
	vec3 N = face_uv_to_dir(uv, face);

	vec3 irradiance = vec3(0.0);
	vec3 up, right;
	OrthonormalBasis(N, right, up);

#ifndef SAMPLE_DELTA
#define SAMPLE_DELTA 0.025
#endif
	float sampleDelta = SAMPLE_DELTA;
	float nrSamples = 0.0;

	for (float phi = 0.0; phi < TWO_PI; phi += sampleDelta) {
		for (float theta = 0.0; theta < 0.5 * PI;
		     theta += sampleDelta) {
			// Spherical to cartesian (tangent space)
			vec3 tangentSample =
			    vec3(sin(theta) * cos(phi), sin(theta) * sin(phi),
			         cos(theta));
			// Tangent to world space
			vec3 sampleVec = tangentSample.x * right +
			                 tangentSample.y * up +
			                 tangentSample.z * N;

			// Échantillonnage cubemap direct
			vec3 env_color =
			    textureLod(envMap, sampleVec, 0.0).rgb;

			/* Sanitize Input */
			if (any(isnan(env_color)) || any(isinf(env_color)))
				env_color = vec3(0.0);
			env_color =
			    max(env_color, vec3(0.0)); /* No negative light */

			env_color = soft_clamp_smoothstep(env_color);

			irradiance += env_color * cos(theta) * sin(theta);
			nrSamples++;
		}
	}

	irradiance = PI * irradiance * (1.0 / nrSamples);

	/* Sanitize Output */
	if (any(isnan(irradiance)) || any(isinf(irradiance)))
		irradiance = vec3(0.0);
	irradiance = max(irradiance, vec3(0.0));

	imageStore(irradianceMap, ivec3(pos, face), vec4(irradiance, 1.0));
}
