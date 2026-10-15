class_name BattlePreviewAtlas
extends SubViewport
## The one shared render target for all 34 opponent previews (doc 38, section 6). Each contestant
## owns a fixed 187x240 cell at 1:1 gameplay scale (240 = the classic camera band; 187 = 240 x the
## pane's aspect); the cells are laid out 7 x 5 with PAD texels around each, and the whole atlas is
## rendered once per frame. Panes only sample their own region, so there are no 34 viewports, no
## hidden games and no per-opponent render targets. The geometry is static and pure, so tests can
## check it without a renderer.

const CELL_PX := Vector2i(187, 240) ## internal preview resolution = classic gameplay scale
const COLUMNS := 7
const ROWS := 5
const PAD := 4 ## texels around every cell: room for the downsample taps (they are also clamped in the shader)
const BYTES_PER_PIXEL := 4 ## RGBA8

static func cell_count() -> int:
	return BattleHudLayout.OPPONENTS

static func size_px() -> Vector2i:
	return Vector2i(COLUMNS * (CELL_PX.x + PAD), ROWS * (CELL_PX.y + PAD))

## Pixel rect of cell `index` (0-based; contestant id - 1) in the atlas.
static func cell_rect(index: int) -> Rect2i:
	var col := index % COLUMNS
	var row := index / COLUMNS
	return Rect2i(Vector2i(col * (CELL_PX.x + PAD) + PAD / 2, row * (CELL_PX.y + PAD) + PAD / 2), CELL_PX)

## RGBA8 render target size in bytes (what the atlas costs in VRAM, before any driver padding).
static func memory_bytes() -> int:
	var s := size_px()
	return s.x * s.y * BYTES_PER_PIXEL

func _init() -> void:
	name = "PreviewAtlas"
	size = size_px()
	disable_3d = true
	transparent_bg = false
	snap_2d_transforms_to_pixel = true # previews are drawn 1:1; keep their texels on the pixel grid
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
