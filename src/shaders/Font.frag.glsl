#version 450 

layout(location = 0) smooth in vec2 fragUV;
layout(location = 1) in vec4 fragColor;
layout(location = 2) in vec3 WorldPos;

layout(set = 2, binding = 0) uniform sampler2D FontTexture;
layout(set = 2, binding = 1) uniform sampler2D GradientTexture;

layout(set = 3, binding = 0) uniform Globals {
    vec4 gradientMin;
    vec4 gradientMax;
    float time;
    float speed;
    float period;
    float _pad;
};

layout (location = 0) out vec4 outColor;

float triangle_wave(float x, float speed, float period) {
    float h = (x - time * speed) / period;
    return 2 * abs(h - floor(h + 0.5));
}

const float PI = 3.14159265359;
const float PI_2 = PI * 2;
const float PI_HALF = PI / 2;

float sin_wave(float x, float speed, float period) {

  return 0.5 * sin(PI_2 / period * (x - speed * time) - PI_HALF) + 0.5;
}

void main() {
    float alpha = texture(FontTexture, fragUV).a;

    float tx = (WorldPos.x - gradientMin.x) / (gradientMax.x - gradientMin.x);
    tx = clamp(tx, 0.0, 1.0);

    tx = triangle_wave(tx, speed, period);
    vec3 col = texture(GradientTexture, vec2(tx, 0)).rgb;
    outColor = vec4(col, fragColor.a * alpha);
}
