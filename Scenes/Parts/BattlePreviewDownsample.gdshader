shader_type canvas_item;
// Battle opponent panes: smooth downsample of one full-size preview cell out of the shared atlas.
// 4 bilinear taps spread over this screen pixel's footprint in the atlas (about a box filter over
// up to 4x4 texels), so a 187x240 picture shrinks into a 32x41 pane without mipmaps (Godot 4.6
// cannot generate them for viewport textures) and without shimmering when the pane or the picture
// moves. Every tap is clamped into this pane's own cell, so neighbouring atlas cells can never
// bleed in, whatever the display scale.
uniform vec4 region; // this cell's UV rect (x, y, w, h) in the atlas, inset by half a texel

vec4 tap(sampler2D tex, vec2 uv) {
	return texture(tex, clamp(uv, region.xy, region.xy + region.zw));
}

void fragment() {
	vec2 o = fwidth(UV) * 0.25;
	COLOR = 0.25 * (tap(TEXTURE, UV + vec2(-o.x, -o.y)) + tap(TEXTURE, UV + vec2(o.x, -o.y))
		+ tap(TEXTURE, UV + vec2(-o.x, o.y)) + tap(TEXTURE, UV + vec2(o.x, o.y)));
}
