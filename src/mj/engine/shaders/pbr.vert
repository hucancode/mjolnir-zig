#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    float time;
};

layout(push_constant) uniform Constants {
    mat4 world;
};

layout(location = 0) out vec3 outNormal;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec2 outUV;

void main() {
    outNormal = (world * vec4(inNormal, 1.0)).xyz;
    outColor = inColor;
    outUV = inUV;
    gl_Position = proj * view * world * vec4(inPosition + vec3(0.0, sin(time), 0.0), 1.0);
}
