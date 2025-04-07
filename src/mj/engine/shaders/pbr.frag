#version 450

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    float time;
};
layout(set = 1, binding = 0) uniform sampler2D albedoSampler;
layout(set = 1, binding = 1) uniform sampler2D metalicSampler;
layout(set = 1, binding = 2) uniform sampler2D roughnessSampler;

layout(location = 0) in vec3 normal;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 position;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 lightPos = vec3(sin(time*0.23457), cos(time*0.543217), sin(time*0.766453))*20.0;
    vec3 lightDir = normalize(lightPos - position);
    float brightness = max(dot(normalize(normal), lightDir), 0.15);
    vec4 albedo = texture(albedoSampler, uv);
    vec4 shadedColor = brightness * brightness * albedo;
    outColor = shadedColor;
}
