#version 450
const uint MAX_LIGHTS = 10;
const int POINT_LIGHT = 0;
const int DIRECTIONAL_LIGHT = 1;
const int SPOT_LIGHT = 2;

struct Light {
    vec4 color;
    vec4 position;
    vec4 direction;
    uint kind;
    float angle;
    float radius;
    // padding x2
};

layout(std140, set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    Light lights[MAX_LIGHTS];
    uint lightCount;
    float time;
    // padding x2
};
layout(set = 1, binding = 0) uniform sampler2D albedoSampler;
layout(set = 1, binding = 1) uniform sampler2D metalicSampler;
layout(set = 1, binding = 2) uniform sampler2D roughnessSampler;

layout(location = 0) in vec3 normal;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 position;
layout(location = 0) out vec4 outColor;

vec3 calculateLighting(Light light, vec3 normal, vec3 position, vec3 viewDir, vec3 albedo) {
  const float ambientStrength = 0.1;
  const float specularStrength = 0.1;

  vec3 surfaceToLight;
  float attenuation = 1.0;
  if (light.kind == POINT_LIGHT) {
    surfaceToLight = normalize(light.position.xyz - position);
    float distance = length(light.position.xyz - position);
    attenuation = 1.0 / (distance / max(0.1, light.radius));
  } else if (light.kind == DIRECTIONAL_LIGHT) {
    surfaceToLight = -light.direction.xyz;
    attenuation = 0.01;
  } else if (light.kind == SPOT_LIGHT) {
    surfaceToLight = normalize(light.position.xyz - position);
    float theta = dot(surfaceToLight, -light.direction.xyz);
    float epsilon = light.angle*0.1;
    attenuation = clamp((theta - light.angle * 0.9) / epsilon, 0.0, 1.0);
  }
  vec3 diffuse = max(dot(normal, surfaceToLight), 0.0) * light.color.rgb * attenuation;
  vec3 ambient = ambientStrength * light.color.rgb;
  vec3 specular = light.color.rgb * pow(max(dot(normal, normalize(surfaceToLight + viewDir)), 0.0), specularStrength);
  return ambient + diffuse + specular;
}

void main() {
  vec3 cameraPosition = -inverse(view)[3].xyz;
  vec3 albedo = vec3(0.1);//vec3((5-position.z)*0.2);//texture(albedoSampler, uv).rgb;
  vec3 viewDir = normalize(cameraPosition.xyz - position);
  vec3 result = vec3(0.0);
  for (int i = 0; i < min(lightCount, MAX_LIGHTS); i++) {
    result += calculateLighting(lights[i], normal, position, viewDir, albedo);
  }
  result += albedo * 0.1;
  outColor = vec4(result, 1.0);
}
