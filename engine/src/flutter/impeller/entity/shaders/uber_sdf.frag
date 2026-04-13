// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

precision mediump float;

#include <impeller/color.glsl>
#include <impeller/types.glsl>

uniform FragInfo {
  vec4 color;
  vec2 center;
  vec2 size;
  float stroke_width;
  float stroke_join;
  float aa_pixels;
  float stroked;
  float type;
  vec4 radii;
}
frag_info;

out vec4 frag_color;

highp in vec2 v_position;

float distanceFromCircle(vec2 p, float radius) {
  return length(p) - radius;
}

float distanceFromRect(vec2 p, vec2 b) {
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float distanceFromChamferRect(vec2 p, vec2 b, float chamfer) {
  vec2 d = abs(p) - b;

  d = (d.y > d.x) ? d.yx : d.xy;
  d.y += chamfer;

  const float k = 1.0 - sqrt(2.0);
  if (d.y < 0.0 && d.y + d.x * k < 0.0) {
    return d.x;
  }

  if (d.x < d.y) {
    return (d.x + d.y) * sqrt(0.5);
  }

  return length(d);
}

float distanceFromRoundedRect(in vec2 p, in vec2 b, in vec4 r) {
  r.xy = (p.x > 0.0) ? r.xy : r.zw;
  r.x = (p.y > 0.0) ? r.x : r.y;
  vec2 q = abs(p) - b + r.x;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

float filledSDF(vec2 p) {
  if (frag_info.type < 0.5) {  // Circle
    return distanceFromCircle(p, frag_info.size.x);
  } else if (frag_info.type < 1.5) {  // Rect
    return distanceFromRect(p, frag_info.size);
  } else {  // Rounded Rect
    return distanceFromRoundedRect(p, frag_info.size, frag_info.radii);
  }
}

float strokedSDF(vec2 p) {
  float half_stroke = max(frag_info.stroke_width, 0.0) * 0.5;

  if (frag_info.type < 0.5) {  // Circle
    float outer = distanceFromCircle(p, frag_info.size.x + half_stroke);
    float inner = distanceFromCircle(p, frag_info.size.x - half_stroke);
    return max(outer, -inner);
  } else if (frag_info.type < 1.5) {  // Rect
    float outer;
    float inner;
    if (frag_info.stroke_join < 0.5) {  // Miter
      outer = distanceFromRect(p, frag_info.size + half_stroke);
    } else if (frag_info.stroke_join < 1.5) {  // Bevel
      outer =
          distanceFromChamferRect(p, frag_info.size + half_stroke, half_stroke);
    } else {  // Round
      outer = distanceFromRect(p, frag_info.size) - half_stroke;
    }
    inner = distanceFromRect(p, frag_info.size - half_stroke);
    return max(outer, -inner);
  } else {  // Rounded Rect
    float d = distanceFromRoundedRect(p, frag_info.size, frag_info.radii);
    return abs(d) - half_stroke;
  }
}

void main() {
  vec2 p = v_position - frag_info.center;

  float dist = (frag_info.stroked < 0.5) ? filledSDF(p) : strokedSDF(p);

  // Anti-aliasing
  // fwidth(dist) gives the change in SDF per pixel.
  float fade_size = fwidth(dist) * frag_info.aa_pixels * 0.5;

  float alpha = 1.0 - smoothstep(-fade_size, fade_size, dist);

  frag_color = vec4(frag_info.color.rgb, frag_info.color.a * alpha);
  frag_color = IPPremultiply(frag_color);
}
