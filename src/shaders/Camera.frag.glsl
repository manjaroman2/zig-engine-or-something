#version 450

layout(location = 0) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    // float steps = 4.0;
    // vec3 quantized = floor(fragColor.rgb * steps) / steps;
    // outColor = vec4(quantized, fragColor.a);
    outColor = fragColor;
}

