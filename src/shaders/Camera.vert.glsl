#version 450

layout(std140, binding = 0, set = 1) uniform UniformBlock
{
    mat4 CameraMatrix;   // 128 Bytes  
    vec4 CameraPosition; // 32 Bytes
};

layout(location = 0) in vec3 inWorldPos;
layout(location = 1) in uvec4 inColor;

out gl_PerVertex
{
    vec4 gl_Position;
    float gl_ClipDistance[1];
};
layout(location = 0) out vec4 fragColor;

vec3 rotate(vec3 v, vec4 q)
{
    vec3 t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

vec3 invrotate(vec3 v, vec4 q)
{
    vec3 t = 2.0 * cross(q.xyz, v);
    return v - q.w * t + cross(q.xyz, t);
}

void main()
{
    // vec3 O = c - d * k_;
    // vec3 PA = c + d / dot(A - c, k_) * (A - c);
    // 2 * (dot(PA - O, i_) / width) = (2 * d / width * x_e) / z_e

    // vec3 A = inWorldPos;
    // vec3 c = CameraPosition.xyz;
    // vec4 q = CameraQuaternion;
    // float d = CameraPosition.w;
    // float width = 3.0;
    // float height = 3.0;
    //
    // vec3 i_ = rotate(vec3(1, 0, 0), q);
    // vec3 j_ = rotate(vec3(0, 1, 0), q);
    // vec3 k_ = rotate(vec3(0, 0, 1), q);
    //
    // float x_e = dot(i_, (A - c));
    // float y_e = dot(j_, (A - c));
    // float z_e = dot(k_, (A - c));
    //
    //
    // float z_c = (100.0 + 0.1) / (100.0 - 0.1) * z_e + 2 * 100.0 * 0.1 / (100.0 - 0.1);
    //
    // gl_Position = vec4(2 * d / width * (x_e / z_e), -2 * d / height * (y_e / z_e), z_c, 1.0);
    
    gl_Position = vec4(inWorldPos.x, inWorldPos.y, inWorldPos.z, 2.0);
    fragColor = vec4(inColor) / 255.0;
}

