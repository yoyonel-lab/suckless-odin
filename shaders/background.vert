#version 450 core

layout(location = 0) in vec3 in_position;

layout(location = 0) uniform mat4 m_inv_view_proj;

layout(location = 0) out vec3 RayDir;

void main()
{
	/* Set depth to 1.0 (w/w) after perspective division */
	gl_Position = vec4(in_position.xy, 1.0, 1.0);

	vec4 pos = m_inv_view_proj * vec4(in_position.xy, 1.0, 1.0);

	RayDir = pos.xyz / pos.w;
}
