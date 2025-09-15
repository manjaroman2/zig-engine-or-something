#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;
layout(location = 3) in int inLayer;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;
layout(location = 2) out vec3 WorldPos;
layout(location = 3) flat out int Layer;

layout(set = 1, binding = 0) uniform Proj {
    mat4 projection;
};

void main() {
    gl_Position = projection * vec4(inPosition, 1.0);
    fragUV = inUV;
    fragColor = inColor;
    WorldPos = inPosition;
    Layer = inLayer;
}
