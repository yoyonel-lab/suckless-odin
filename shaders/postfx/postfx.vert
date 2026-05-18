#version 450 core

// Fullscreen triangle vertex shader for post-processing.
// Uses a single oversized triangle to cover the entire screen.

layout(location = 0) in vec2 in_position;

layout(location = 0) out vec2 TexCoords;

void main()
{
	gl_Position = vec4(in_position, 0.0, 1.0);
	// Map clip-space [-1,1] to UV [0,1]
	TexCoords = in_position * 0.5 + 0.5;
}
