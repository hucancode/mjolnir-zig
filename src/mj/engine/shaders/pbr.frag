#version 450
const uint MAX_LIGHTS = 10;
const int POINT_LIGHT = 0;
const int DIRECTIONAL_LIGHT = 1;
const int SPOT_LIGHT = 2;

struct Light {
    vec4 color;
    vec4 position;
    vec4 direction;
};

// expected: rgbixyzaxyzt
// actual  : __xyz

layout(std140, set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    float time;
    float light_count;
    // padding 1
    // padding 2
    Light lights[MAX_LIGHTS];
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
  const float specularStrength = 10.1;

  vec3 surfaceToLight;
  float attenuation = 1.0;
  // if (light.type == POINT_LIGHT) {
    surfaceToLight = normalize(light.position.xyz - position);
    float distance = length(light.position.xyz - position);
    attenuation = - distance/10.0;
  // } else if (light.type == DIRECTIONAL_LIGHT) {
  //   surfaceToLight = -light.direction;
  // } else if (light.type == SPOT_LIGHT) {
  //   surfaceToLight = normalize(light.position - position);
  //   float theta = dot(surfaceToLight, -light.direction);
  //   float epsilon = light.spotLightAngle*0.1;
  //   attenuation = clamp((theta - light.spotLightAngle * 0.9) / epsilon, 0.0, 1.0);
  // }
  vec3 diffuse = max(dot(normal, surfaceToLight), 0.0) * light.color.rgb;// * attenuation;
  vec3 ambient = ambientStrength * light.color.rgb;
  vec3 specular = light.color.rgb * pow(max(dot(normal, normalize(surfaceToLight + viewDir)), 0.0), specularStrength);
  return ambient + diffuse + specular;
}

void main() {
  vec3 cameraPosition = -inverse(view)[3].xyz;
  vec3 albedo = vec3(0.1);//vec3((5-position.z)*0.2);//texture(albedoSampler, uv).rgb;
  vec3 viewDir = normalize(cameraPosition.xyz - position);
  vec3 result = vec3(0.0);
  for (int i = 0; i < min(1, MAX_LIGHTS); i++) {
    result += calculateLighting(lights[i], normal, position, viewDir, albedo);
  }
  result += albedo * 0.1;
  outColor = vec4(result, 1.0);
}
