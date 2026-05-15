#version 440 core

layout(location = 0) out vec4 FragColor;

layout(location = 0) in vec3 WorldPos;
flat layout(location = 1) in vec3 SphereCenter;
flat layout(location = 2) in float SphereRadius;

uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_cam_pos;
uniform vec3 u_albedo;
uniform vec3 u_light_dir;
uniform vec3 u_light_color;

// Ray-sphere intersection (ISO port from suckless-ogl billboard frag)
bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius,
                     out float t, out vec3 normal)
{
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;

    if (h < 0.0)
        return false;

    h = sqrt(h);
    float t1 = -b - h;
    float t2 = -b + h;

    if (t1 >= 0.0)
        t = t1;
    else if (t2 >= 0.0)
        t = t2;
    else
        return false;

    vec3 hitPos = ro + t * rd;
    normal = normalize(hitPos - center);
    return true;
}

void main()
{
    // Ray from camera through this fragment's world position
    vec3 rayDir = normalize(WorldPos - u_cam_pos);

    float t;
    vec3 N;
    bool hit = intersectSphere(u_cam_pos, rayDir, SphereCenter, SphereRadius, t, N);

    if (!hit)
        discard;

    // Correct depth buffer for the actual sphere hit point
    vec3 hitPos = u_cam_pos + t * rayDir;
    vec4 clipPos = u_projection * u_view * vec4(hitPos, 1.0);
    float ndc_depth = clipPos.z / clipPos.w;
    gl_FragDepth = ndc_depth * 0.5 + 0.5;  // NDC [-1,1] → depth [0,1]

    // Blinn-Phong shading
    vec3 L = normalize(-u_light_dir);
    vec3 V = normalize(u_cam_pos - hitPos);
    vec3 H = normalize(L + V);

    float ambient  = 0.08;
    float diffuse  = max(dot(N, L), 0.0);
    float specular = pow(max(dot(N, H), 0.0), 64.0);

    vec3 color = u_albedo * (ambient + diffuse * u_light_color)
               + specular * u_light_color * 0.5;

    // Simple tone mapping
    color = color / (color + vec3(1.0));

    FragColor = vec4(color, 1.0);
}
