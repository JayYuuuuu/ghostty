#version 430 core

// These are common definitions to be shared across shaders, the first
// line of any shader that needs these should be `#include "common.glsl"`.
//
// Included in this file are:
// - The interface block for the global uniforms.
// - Functions for unpacking values.
// - Functions for working with colors.

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
layout(binding = 1, std140) uniform Globals {
    uniform mat4 projection_matrix;
    uniform vec2 screen_size;
    uniform vec2 cell_size;
    uniform uint grid_size_packed_2u16;
    uniform vec4 grid_padding;
    uniform uint padding_extend;
    uniform float min_contrast;
    uniform float scroll_offset;
    uniform uint cursor_pos_packed_2u16;
    uniform uint cursor_color_packed_4u8;
    uniform uint bg_color_packed_4u8;
    uniform uint bools;
};

// Bools
const uint CURSOR_WIDE = 1u;
const uint USE_DISPLAY_P3 = 2u;
const uint USE_LINEAR_BLENDING = 4u;
const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
const uint EXTEND_LEFT = 1u;
const uint EXTEND_RIGHT = 2u;
const uint EXTEND_UP = 4u;
const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.
//       If this ever becomes a problem... oh dear!

uvec4 unpack4u8(uint packed_value) {
    return uvec4(
        uint(packed_value >> 0) & uint(0xFF),
        uint(packed_value >> 8) & uint(0xFF),
        uint(packed_value >> 16) & uint(0xFF),
        uint(packed_value >> 24) & uint(0xFF)
    );
}

uvec2 unpack2u16(uint packed_value) {
    return uvec2(
        uint(packed_value >> 0) & uint(0xFFFF),
        uint(packed_value >> 16) & uint(0xFFFF)
    );
}

ivec2 unpack2i16(int packed_value) {
    return ivec2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(vec3 color) {
    return dot(color, vec3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(vec3 color1, vec3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio.
//
// The check uses the color the glyph actually shows: a translucent (faint)
// fg is composited over the bg first. A failing color keeps its hue: it is
// scaled toward black (or mixed toward white on dark backgrounds) just far
// enough to reach the ratio, so dim hints stay lighter than body text and
// colored text stays colored. Only when even black/white cannot reach the
// ratio does it fall back to black or white.
//
// Takes colors in linear RGB space, fg premultiplied by its alpha.
vec4 contrasted_color(float min_ratio, vec4 fg, vec4 bg) {
  vec3 shown = fg.rgb + bg.rgb * (1.0 - fg.a);
  if (contrast_ratio(shown, bg.rgb) >= min_ratio) return fg;

  float bg_lum = luminance(bg.rgb);
  float shown_lum = luminance(shown);
  float white_ratio = contrast_ratio(vec3(1.0), bg.rgb);
  float black_ratio = contrast_ratio(vec3(0.0), bg.rgb);
  if (white_ratio > black_ratio) {
    float target = min_ratio * (bg_lum + 0.05) - 0.05;
    if (target >= 1.0 || shown_lum >= 1.0) return vec4(1.0);
    float t = clamp((target - shown_lum) / (1.0 - shown_lum), 0.0, 1.0);
    return vec4(mix(shown, vec3(1.0), t), 1.0);
  } else {
    float target = (bg_lum + 0.05) / min_ratio - 0.05;
    if (target <= 0.0 || shown_lum <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
    return vec4(shown * clamp(target / shown_lum, 0.0, 1.0), 1.0);
  }
}

// Converts a color from sRGB gamma encoding to linear.
vec4 linearize(vec4 srgb) {
    bvec3 cutoff = lessThanEqual(srgb.rgb, vec3(0.04045));
    vec3 higher = pow((srgb.rgb + vec3(0.055)) / vec3(1.055), vec3(2.4));
    vec3 lower = srgb.rgb / vec3(12.92);

    return vec4(mix(higher, lower, cutoff), srgb.a);
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
vec4 unlinearize(vec4 linear) {
    bvec3 cutoff = lessThanEqual(linear.rgb, vec3(0.0031308));
    vec3 higher = pow(linear.rgb, vec3(1.0 / 2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear.rgb * vec3(12.92);

    return vec4(mix(higher, lower, cutoff), linear.a);
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// `linear` controls whether the returned color is linear or gamma encoded.
vec4 load_color(
    uvec4 in_color,
    bool linear
) {
    // 0 .. 255 -> 0.0 .. 1.0
    vec4 color = vec4(in_color) / vec4(255.0f);

    // Linearize if necessary.
    if (linear) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

//----------------------------------------------------------------------------//
