# Design: SMB3 ROM → generated SMB3-style resource pack

Status: **research / design only, nothing implemented.** No gameplay code changes are proposed for the first milestone.

Scope: use a user-supplied, legitimate *Super Mario Bros. 3* (NES) ROM as an asset source. Generate a local, SMB3-themed resource pack that reskins the existing remaster. Gameplay stays the remaster's own.

```
SMB3 ROM ──► SMB3 decoder/extractor ──► mapping/recipe layer ──► user://…/resource_packs/SMB3Assets ──► existing ResourceSetterNew pipeline
```

## 0. Scope: game-wide, not per-mode

**`SMB3Assets` is a game-wide resource pack.** When enabled, it affects every mode and scene that resolves the same resource paths through the global resource-pack system:

- campaign play;
- Challenge;
- Boo Race;
- Marathon / Marathon Practice;
- Disco;
- Battle Mode;
- custom levels, where applicable (§0.2);
- menus and HUD elements that resolve the same paths;
- any future mode, automatically.

It is **not** a Battle Mode feature or a feature of any other mode.

**Hard rules**

1. **No mode-specific SMB3 code.**
   - No `GameMode` checks, no `current_game_mode` reads and no `SMB3` references in mode classes.
   - That includes `BattleScreen`, `BattlePreview*`, `BattleHandler`, `BooRaceHandler`, `LevelSelect`, `MarathonResults`, Disco, Challenge and custom-level code.
   - Modes inherit whatever packs are active.
2. **The only integration point is the global pack list** (`Settings.file.visuals.resource_packs`).
   - The importer writes a pack folder.
   - The existing pack menu enables or disables it.
   - Everything else is existing code.
3. **SMB3 code lives only in `Scripts/Classes/RomImport/**`, plus its import UI and two constants in `Global`.**
   - A test enforces this (§9 C4).
4. **Generated data must not use mode-keyed variations.** No `GameMode:` keys in SMB3 override JSONs.
   - None of the 249 sprite JSONs in `res://Assets/Sprites` use `GameMode:` keys today, and the SMB3 pack must not introduce them.
   - The same asset must be chosen regardless of mode.

### 0.1 Why this works with no per-mode code (repo-grounded)

- **Pack precedence is global and mode-independent.**
  - `ResourceSetterNew.get_resource()` walks `Settings.file.visuals.resource_packs`.
  - The pack list is persisted in settings and does not depend on `Global.current_game_mode`.
  - Enabling a pack in `ResourcePackContainer.select()` clears `ResourceSetter`/`ResourceSetterNew`/`ResourceGetter` caches and calls `Global.update_theme()`.
  - That applies to every subsequently loaded scene, in any mode.
- **Variation selection depends on level context, not mode.** `get_variation_json()` selects by theme, time, campaign, world/level, room, character, Boo colour and so on.
  - It *can* read a `GameMode:<name>` key, but no shipped sprite JSON uses one.
  - So a Challenge or Marathon run of SMB1 1-1 resolves exactly the same `Goomba.json` leaf as campaign 1-1.
- **All modes play the same level scenes.**
  - Challenge, Marathon and Marathon Practice reuse the campaign `.tscn` levels (`Scenes/Levels/SMB1/World1/1-1.tscn` …).
  - Boo Race has its own `Scenes/Levels/SMB1/YouVSBoo/*.tscn` scenes. They are SMB1-campaign levels built from the same prefabs.
  - All of these levels carry `ResourceSetterNew` nodes, including the terrain `TilesetTextureSetter` in `Scenes/Parts/Tiles.tscn`.
  - The HUD (`GameHUD`) and menus use the same component.
- **Custom campaigns compose correctly.**
  - `CampaignSelect.select()` `push_front`s a custom campaign's own `resource_pack` above the user's packs.
  - It only removes that same custom pack again, never others.
  - So a custom campaign pack overrides SMB3, and SMB3 still overrides `BaseAssets`. That is the intended "where applicable" behaviour.
- **Battle Mode inherits automatically.** Battle Mode lives on the unmerged branch `claude/youthful-tesla-99o9hl`.
  - **In-round gameplay** sets `GameMode.BATTLE` and `current_campaign = "SMB1"` (`BattleHandler.gd`). It loads normal level scenes, so `ResourceSetterNew` applies the pack.
  - **Opponent previews** use `BattlePreviewResolver`. That class deliberately re-implements only two rules:
    - pack precedence, read from the same `Settings.file.visuals.resource_packs` with the same `res://Assets` → `resource_packs/<pack>` mirroring;
    - the theme/time/campaign/link walk.
  - So SMB3 PNGs and override JSONs are picked up by previews **without any Battle change**, provided the SMB3 JSON uses only the portable subset in §4.1.1.

### 0.2 What "game-wide" still depends on: campaign filenames, not modes

Coverage varies by **campaign key**, not by mode. Many sheets have per-campaign files:

| Campaign | Example file |
|---|---|
| SMB1 | `Overworld.png` |
| SMBLL | `OverworldLL.png` |
| SMBANN | `OverworldANN.png`, `DiscoGoomba.png` |
| SMBS | `…SP.png` |

- **Implication.** If a mode runs SMB1-campaign levels, which includes Battle, custom levels by default and Boo Race, it sees whatever SMB3 covers for SMB1 filenames.
- **Gaps.** A mode running Lost Levels or ANN levels sees the SMB1 `BaseAssets` look for any LL/ANN/SP filename the SMB3 pack hasn't written.
- **Fix.** Close these gaps **in the generator**: write the same recipe output under each campaign's filename, or ship a campaign-agnostic override JSON. Never close them in mode code. Full campaign coverage is milestone step 7 (§11).

---

## 1. How the current SMB1 importer works (repo-grounded)

### 1.1 Files involved

| Piece | File | Role |
|---|---|---|
| ROM verification | `Scripts/UI/RomVerifier.gd` (`ROMVerifier`) | Accepts a ROM from the `-rom` CLI arg, a `.nes` file next to the executable, drag-drop, or a file dialog. Verifies its hash, copies it to `Global.ROM_PATH` (`<config>/baserom.nes`), then routes to the generator. |
| Startup check | `Global.check_for_rom()` (`Scripts/Classes/Singletons/Global.gd:283`) | Re-verifies `baserom.nes`. Reads `BaseAssets/pack_info.json`. If `version < ROM_ASSETS_VERSION` (currently `9`), trashes the pack and sets `ResourceGenerator.updating`. |
| Low-level ripper | `Scripts/Classes/RomAssetRipper.gd` (`AssetRipper`) | NES 2bpp planar tile decode (`load_tile`, `combine_bytes`), flips (`reverse_bits`), `draw_tile` with optional green chroma-key. |
| Generator | `Scripts/UI/RomResourceGenerator.gd` (`ResourceGenerator extends AssetRipper`) | Walks `SpriteList.json`, paints ROM tiles into template PNGs, and writes `BaseAssets`. |
| Authoring tool | `Scripts/UI/RomAssetEditor.gd` (`AssetEditor extends AssetRipper`) | Dev tool: shows the CHR atlas (512 tiles, 32 columns). Lets a developer click tiles onto a template and saves the per-sprite recipe JSON plus a green mask back into `res://Assets`. |
| Recipes | `Resources/AssetRipper/SpriteList.json`, `Resources/AssetRipper/Sprites/**.json` (161 files) | One recipe per generated PNG. |
| Palettes | `Resources/AssetRipper/Palettes/Default/*.json` (33 files) | Hand-authored RGB palettes, keyed by theme. |
| Pack metadata | `Resources/AssetRipper/ResourcePack/pack_info.json` | Name, author and description, plus `version` injected at generation time. |

### 1.2 What the SMB1 ROM contributes

**Only CHR tile pixels.** This is the most important finding for the SMB3 design.

- `ResourceGenerator._ready()` does `chr_rom = rom.slice(16 + prg_rom_size)`. It never reads PRG.
- `load_tile(index)` reads 16 bytes at `16 * index` from CHR. Indices 0–511 cover SMB1's single 8 KB CHR bank.
- `ROMVerifier.get_hash()` hashes bytes 16 to 40,976 (32 KB PRG + 8 KB CHR, which is SMB1's NROM-256 size). It base64-encodes them and SHA-256s the text, then compares against two accepted hashes. The repo does not label which dumps those two hashes are.

**Not from the ROM:**

- **Palettes.** They are authored RGB values in JSON (for example `Tile.json` → `default: ["00000000","ffd9b2","ba6111","1f1f1f"]`). Each palette has one entry per *remaster* theme (Underground, Castle, Underwater, Desert, Jungle, Snow, Volcano, Autumn, Beach, Mountain, Space, Bonus…), and most of those themes do not exist in SMB1.
- **Sprite-sheet layout, animation frames, frame rects and timing.** These are authored in `res://Assets/**.json`.
- **Fonts.** `Assets/Sprites/UI/Font.fnt` / `Font.png` / `ScoreFont.*` are shipped and are not in `SpriteList.json`.
- **All audio.** `Assets/Audio/BGM` / `SFX` hold 94 `.mp3` and 117 `.wav` files, plus `.bgm` JSON loop descriptors, all shipped in the repo. Nothing audio-related reads the ROM.
- **Around 630 of 788 sprite PNGs** are fully authored remaster art: Editor, most UI, most Backgrounds, most Blocks, particles, SMB3/SMW-style blocks and so on. Only 156 unique PNGs are ROM-generated. By folder: Tilesets 81, Backgrounds 23, Enemies 15, Items 15, Players 11, UI 8, Blocks 2, Particles 2.

### 1.3 How palettes are reconstructed

They aren't reconstructed from the ROM. Each recipe names palette files and palette ids:

```
"palettes": {"SpriteTile": ["default","Underground","Castle",…]}   // or a bare array → palette_base
```

`paste_sprite()` iterates palette files × palette ids. For each id it loads `Palettes/Default/<file>.json`, falls back to `PREVIEW_PALETTE` if the id is missing, and paints the same tile list at a grid offset. The offset advances by `sheet_size.x` per column and wraps after `columns`. **So one PNG holds every theme's recolour of the same sprite as a grid of sub-sheets.** Individual tiles can override their palette file with `"palette"`, which is how multi-palette sprites such as terrain are done.

### 1.4 How sheets and tiles are assembled

1. The repo ships a **template PNG** at the final `res://Assets/Sprites/...` path. The template's pixels are either:
   - **pure green `#00FF00`**: a silhouette mask of where ROM pixels go; or
   - **authored remaster pixels**: extra frames, padding or new art that is kept as-is.
2. The recipe's `tiles` maps `Vector2(x, y)` to `{index, flip_h, flip_v, palette?}` in 8×8 units.
3. `draw_tile(chroma_key=true, …)` writes a decoded pixel only where the template pixel is green. Colour index 0 maps to transparent.
4. The result is saved to `<config>/resource_packs/BaseAssets/<same relative path>`. If any recipe fails, the whole pack is trashed.

Measured examples:

| Template | Size | Green px | Notes |
|---|---|---|---|
| `Enemies/Goomba.png` | 192×64 | 8,206 / 8,283 | `sheet_size` 48×16 × 4 columns × 13 themes |
| `Players/Mario/Small.png` | 256×96 | 4,074 / 4,545 | 32×32 cells; sprite bottom-centred at x 8–24 |
| `Players/Mario/Big.png` | 256×96 | 8,641 / 9,469 | 32×32 cells; 16×32 body at x 8–24 |
| `Tilesets/Terrain/Overworld.png` | 256×256 | 45,151 / 49,926 | 16×16 atlas, many palette files |
| `Tilesets/Terrain/OverworldLL.png` | 256×256 | 32,020 / 49,491 | about a third authored (Lost Levels approximations) |
| `Blocks/QuestionBlock.png` | 64×112 | 100% | 4 columns = animation frames via palette cycling (`default1/2/3`) |

### 1.5 How generated assets are laid out in `BaseAssets`

The layout is a mirror of `res://Assets/`:

```
<config>/resource_packs/BaseAssets/
  pack_info.json           {"name","author","description","version":9}
  Sprites/Enemies/Goomba.png
  Sprites/Players/Mario/Small.png
  Sprites/Tilesets/Terrain/Overworld.png
  …
```

- `BaseAssets` contains **PNGs only**. The JSON descriptors that consume them stay in `res://Assets`.
- It is hidden from the pack menu (`ResourcePackLoader` skips `ROM_PACK_NAME`).
- It is force-appended to the pack list by `ResourceSetterNew.safety_check()`.

### 1.6 How `ResourceSetterNew` picks resources at runtime

`Scripts/Classes/Components/ResourceSetterNew.gd`:

1. **Pack precedence: first match wins in list order.** For a `res://Assets/...json` path it walks `Settings.file.visuals.resource_packs` in order. `get_resource_pack_path()` maps `res://Assets` to `<config>/resource_packs/<pack>` and keeps the first path that exists.
   - Enabling a pack in the menu does `push_front`, which makes it the highest priority.
   - `BaseAssets` is appended last as the floor.
   - Edge case: `RomResourceGenerator.done()` *inserts* `BaseAssets` at index 0 when it is missing, which would give it top priority. In practice it is present from the settings defaults.
2. **Variation resolution.** The JSON's `variations` tree is resolved in `get_variation_json()` by these keys: `config:` options, `flag:`, level theme (fallback `default`), time, campaign (fallback `SMB1`), `choices`, `sequence`, `WorldN`, `LevelN`, `Quest:`, `RoomType:`, `GameMode:`, `Character:`, `RaceBoo:`, `Metadata:`, `LevelMetadata:`.
3. **Source path.** The resolved node's `source` filename is resolved **again** across the pack list. So a pack can override the JSON, the PNG, or both, independently.
4. **Rects and animations.** `rect` produces an `AtlasTexture`. `animations` (name → `frames` as `[x,y,w,h]` rects, `speed`, `loop`) produces `SpriteFrames`. A variation can patch individual animations with `animation_overrides`.
5. **Other modes.** `AUDIO` (via `AudioManager.import_stream`: `.bgm`, `.mp3`, `.ogg`, `.wav`, `.json`) and `FONT` (`FontFile.load_bitmap_font` for pack paths). **Packs can therefore already replace audio and fonts.**
6. **Terrain.** `Scenes/Parts/Tiles.tscn` binds `Tilesets/Terrain/TerrainTiles.json` into a `TilesetTextureSetter`. That swaps `TileSetAtlasSource` 0's texture, a 256×256 atlas of 16×16 cells with around 243 defined tiles carrying collision and terrain/autotile data.

### 1.7 What is tightly coupled to SMB1 dimensions and layout

- `ROMVerifier` assumes NROM: a fixed 40,976-byte hash window and only SMB1 hashes. `Global.check_for_rom()` calls it statically for `baserom.nes`.
- `AssetRipper.load_tile` treats CHR as one flat array, so an index is an absolute tile number. That works with any CHR size, but the editor wraps indices at 512 (`wrapi(…, 0, 512)`) and displays 32 columns: one 8 KB bank.
- Templates encode **SMB1 silhouettes** as green masks. An SMB3 sprite with a different shape (SMB3 Goomba, Koopa, Mario's proportions) cannot be painted through an SMB1 mask without clipping.
- Sheet layouts encode **SMB1 frame counts**: small Mario `Move` has 3 frames, `Swim` 6, `Climb` 2. Question blocks animate by **palette** cycling over one tile. SMB3 animates them by **CHR bank swap**, giving four different tiles.
- The terrain atlas is a fixed 256×256 grid whose cell semantics (collision, autotile peering) are baked into `Tiles.tscn`. Any reskin must keep that cell layout.
- Palettes are per *remaster theme*. SMB1 and SMB3 both have only a subset of those themes natively.
- `RomResourceGenerator.generate_resource_pack()` hard-codes `res://Assets/` → `ROM_ASSETS_PATH` and the single `Default` palette group.

### 1.8 Reusable as-is

| Reusable unchanged | Why |
|---|---|
| `ResourceSetterNew` precedence and variations | Pack overlay semantics are exactly what an SMB3 pack needs: sparse overrides with BaseAssets as the floor. |
| Pack directory convention, `pack_info.json`, pack menu (`ResourcePackLoader`, `ResourcePackContainer`) | A generated `SMB3Assets` folder with `pack_info.json` automatically appears as a toggleable pack. |
| JSON `animations` / `rect` / `animation_overrides` schema | Lets the SMB3 pack ship its own frame counts and rects without code changes. |
| `AudioManager.import_stream` and the `.bgm` format | A future audio milestone can write `.wav` plus `.bgm` loop descriptors into the pack. |
| 2bpp planar decode (`load_tile`, `combine_bytes`, `reverse_bits`) | Same NES tile format. Reuse the *algorithm*. Whether to share the *class* is discussed in §4. |
| `TilesetTextureSetter` / terrain atlas binding | Unchanged, provided the SMB3 terrain PNG respects the atlas grid. |

### 1.9 Needs a separate SMB3-specific implementation

- ROM identification: headerless SHA-1 against No-Intro hashes, and MMC3 / 256 KB PRG / 128 KB CHR checks.
- A banked CHR address space: 128 × 1 KB banks.
- PRG table readers for palettes, player frame tables and metatile layouts. SMB1 never reads PRG.
- 8×16 sprite composition. The player and enemies are built from 8×16 OAM sprites.
- Recipe format that **builds a canvas** instead of painting through an SMB1 mask.
- NES-index → RGB conversion through a master palette.
- The SMB3 theme ↔ remaster theme mapping.

---

## 2. SMB3 NES ROM: what an importer needs to know

**Sources**

- **Southbird's disassembly** (github.com/captainsouthbird/smb3), cited as **SB**. It reassembles byte-for-byte to **US PRG1 (Rev 1)**.
- **SMB3-Foundry** (github.com/mchlnix/SMB3-Foundry), cited as **Foundry**. Its defaults are "vanilla US SMB3" and it has a JP palette fallback.
- **No-Intro hashes** from libretro-database's NES DAT.

**What was verified.** I checked these directly in SB:

- the header directives;
- `PT2_Anim: .byte $60,$62,$64,$66`;
- `Player_PUpRootPage: .byte $50,$54,$54,$00,$50,$40,$44`;
- `Level_BG_Pages1`;
- the README's "US (PRG1)" claim.

**What was not reachable.** Data Crystal, TCRF and the nesdev wiki were not reachable from the research sandbox. Claims sourced only from their search snippets are marked *unverified*.

**Offsets.** No offset below should be trusted from this document. Every offset must be re-derived from SB labels (or confirmed in Foundry) and pinned in a per-revision profile, with a test asserting the bytes at that offset (§9).

### 2.1 Container, mapper and banking

- iNES mapper 4 (MMC3). `.inesprg 16` / `.ineschr 16` gives **256 KB PRG (32 × 8 KB)** and **128 KB CHR (128 × 1 KB)**. Retail dump size is 393,232 bytes headered and 393,216 headerless.
- File offsets:
  - PRG bank *b*, CPU address *a*: `0x10 + b*0x2000 + (a − bank_base)`.
  - CHR 1 KB bank *n*: `0x40010 + n*0x400`. Foundry uses the same constants.
- MMC3 CHR has two 2 KB windows (BG at PPU $0000 and $0800) and four 1 KB windows (sprites at $1000, $1400, $1800, $1C00). SB keeps the six selections in `PatTable_BankSel` ($0719–$071E).
- **Implication:** there is no single "tile sheet". Any image is defined by a **(bank selection, tile index)** pair. The importer should address tiles as `(chr_bank_1k, tile_in_bank)` or as an absolute tile `bank*64 + tile`.
- Sprites are **8×16** (PPU_CTL1 `%10101000`). In 8×16 mode, bit 0 of the tile index selects the pattern table. This is general PPU behaviour.
- **Animation is CHR bank swapping.** `PT2_Anim` cycles the BG $0800 window through banks $60/$62/$64/$66 every 8 frames, and the P-Switch forces $3E. So **? blocks, bricks' shine, coins, munchers and similar tiles have one 2 KB bank pair per animation frame**. To get frame *k* of an animated block, render the same tile index from bank `$60 + 2k`.

### 2.2 CHR organisation

- `Level_BG_Pages1` and `Level_BG_Pages2` are indexed by level header byte 7 bits 0–4. They give each tileset's two BG 2 KB banks: Plains $08 plus the animated $60, Fortress $10, Underground $1C, Desert $30, Ice $18, Sky $38, Water/Plant $58, Airship $34, and so on.
- **Status bar** CHR is banks $5C–$5F, swapped in by the scanline-192 IRQ (SB prg031 `StatusBarCHR_*`).
- **Player** CHR is 4 × 1 KB per suit starting at the root page (Small $50, Big/Fire $54, Raccoon $00, Frog $50, Tanooki $40, Hammer $44) plus a per-frame page offset.
- **Enemy and item** CHR: sprite slot $1400 is normally bank $04 (Foundry calls the enemy/item set `0x4C`). Individual objects request slot 5 or 6 banks per frame through `ObjectGroupXX_PatTableSel`. Enemy graphics are therefore **switched per object, not per level**.
- Which exact bank holds the Goomba, mushroom or Koopa is **unverified**. The plan is to derive it from each object's `PatTableSel` entry plus its `PatternSets` tile list, not from memory.

### 2.3 Palettes

- Palettes live in PRG bank 27. `Palette_By_Tileset` points to per-tileset `PalSet_*` tables of **8 BG + 4 sprite palette sets × 16 bytes**. The level header picks which BG and sprite set are loaded.
- Values are **NES master-palette indices** (for example `$0F,$30,$16,$36`), not RGB. The importer needs a master palette (§4.4).
- **Fire Mario is a palette swap of Big Mario** using the same CHR root $54. `PowerUp_Palettes` (prg008) holds 3 colours per suit: Mario, Luigi, Fire, Frog, Tanooki, Hammer, Statue. Luigi is also a palette swap.
- Foundry hard-codes a **different palette-table offset for the Japanese ROM**. That is direct evidence that PRG offsets differ between regions.

### 2.4 Mario animation frames and composite sprites

- `SPPF_Table` (prg029) holds **81 player frames × 6 tile bytes**. Each frame is a **3×2 grid of 8×16 sprites**: up to 24×32 px, with `$F1` meaning an empty slot. `Player_FramePageOff` adds 0–3 to the suit root page.
- Named frames (SB constants):

| Action | Small | Big / Fire / Hammer | Raccoon / Tanooki |
|---|---|---|---|
| Walk | $3E–$3F (**2 frames**) | $0C–$0E (3 frames) | $00–$02 (3 frames) |
| Skid | $41 | $30 | |
| Jump | $40 | $4E / $4F | $50 |
| Swim | $46–$49 (4 frames) | $34–$36, $3C–$3D | |
| Other | Die $4B; Kick $42 / $2D; in-pipe $32 / $05 / $43 / $18; grow mid-frames $0B / $27; tail swipe $03–$05 | | |

  The exact frame→action mapping must be confirmed by rendering. Do not assume it.
- Objects use 2 sprites for 16×16, 3×2 grids, "wide" 48×16 draws, and Bowser's 4×3. The per-object tile lists are `ObjectGroupXX_PatternSets` in prg001–prg005.

### 2.5 Terrain, metatiles and backgrounds

- Blocks are 16×16 metatiles.
  - `TileLayout_ByTileset` (prg030) points to per-tileset `Tile_Layout_TSx`. Each is **1 KB: 4 planes × 256 bytes** (UL, LL, UR, LR 8×8 tile ids). Several tilesets share layouts.
  - A block's palette is its top 2 bits: blocks $00/$40/$80/$C0 begin palettes 0–3.
  - Each layout lives at the start of its tileset's $A000 PRG bank. Plains `Tile_Layout_TS1` is in bank 15.
- **Rendering any block** therefore needs four things: the layout table, two BG CHR 2 KB banks, the tileset's BG palette set, and the block id. This is well defined and needs no per-block hand mapping.
- Levels are object streams of 3/4-byte generator records after a 9-byte header. **The importer does not need to parse levels.** It only renders blocks.
- **Backgrounds** (hills, bushes, clouds) are ordinary BG-layer blocks. There is no parallax: the only raster split is the status-bar IRQ.
- So the remaster's 512×512 parallax `Backgrounds/Hills/*.png` have **no direct SMB3 source image**. They would have to be composed from blocks.

### 2.6 HUD and font

- The status bar sits at the bottom of the screen using CHR $5C–$5F. Drawing code is in prg026. Exact digit and letter tile ids are **unverified**: render banks $5C–$5F and read the status-bar tables.
- SMB3's status bar has digits and a **limited** letter set. The remaster's `Font.fnt` has 365 glyphs on a 256×256 page, so an SMB3 font can only ever be a partial glyph replacement.

### 2.7 Music and SFX

- The engine is in bank 28 (SFX, segment headers, patches), part of bank 29 (music segments) and fixed bank 31 (track players, DMC tables). There are 9 DMC drum samples in bank 31, plus some in bank 10.
- Songs come in Set 1, Set 2A and Set 2B (chained segments with loop tables).
  - Each segment header has 7 bytes: a rest-table base, a data pointer, and per-channel offsets.
  - Track bytes: notes, rests and duration/patch bytes.
  - The time-up "hurry" version uses a shifted rest table.
- Feasibility:
  - **(a) Sequence → note events → synth:** feasible but lossy (envelopes, sweeps, duty, DMC mapping).
  - **(b) Emulate the sound engine:** a 6502 plus 2A03 APU running the user's banks 28/29/31(+10), NSF-style, rendered to WAV. This is exact, but it is a new runtime dependency or a substantial new GDScript subsystem.
- Library licences: Game_Music_Emu is LGPL-2.1; NSFPlay has a permissive custom notice; Mesen2 is GPL-3.0. nsf2wav and NotSoFatso licences are unverified.
- **This is structurally unlike graphics.** The current pipeline has no ROM-audio path at all: all audio is shipped recordings. See §7.

### 2.8 Regions and revisions

No-Intro hashes, headerless (`rom[16:]`, 393,216 bytes):

| Dump | CRC32 | SHA-1 |
|---|---|---|
| USA | A0B0B742 | A611B90B4833B20A364BF06EE3BE3B9093EA4DF9 |
| **USA (Rev 1)** | 2E6301ED | **BB894D104C796F69BA16587EB66C0275F5C2FC02** |
| USA (Rev 1) (Virtual Console) | F4DFA033 | 30C2A90638307120D902AC509705ECAC97EC0F77 |
| Europe | 1ED5C801 | 31144C7C436CC78D7FD3AC42B224EEE3A6C2BABC |
| Japan | E7DDFEE3 | EC90C560A5CE5C0CF7FCBE9C6AF422540F8BE10E |
| Japan (Rev 1) | 52E2B5E0 | E250DA736512E431146750CB71FEB2C37B327F32 |

- Known region differences are gameplay changes and **PRG offsets shift**: Foundry's JP palette table is at a different address.
- PRG0 vs PRG1 differences (reportedly ending text) and PAL timing/tempo patches are *unverified at ROM level*.
- Virtual Console dumps are distinct binaries.
- **Hash the headerless image.** Headers vary between dumpers. The SMB1 verifier's base64/SHA-256 scheme should **not** be copied; use standard SHA-1 so the values can be checked against No-Intro.

---

## 3. Asset mapping (SMB3 → remaster schema)

**Classification legend**

- **D**: direct mapping. Same cell size, a straight tile copy and palette.
- **R**: mapping with resizing or recomposition. Different sheet layout, frame count or cell placement; needs a JSON override or canvas recomposition.
- **S**: requires synthesised or remixed artwork composed from SMB3 parts.
- **N**: no sensible SMB3 equivalent.
- **F**: needs a remaster-specific fallback. In this design that means "leave the file out of the pack" so `BaseAssets` (SMB1) shows through, unless noted.

| Remaster asset (`res://Assets/Sprites/…`) | SMB3 source | Class | Notes: sizes and frames |
|---|---|---|---|
| `Players/Mario/Small.png` (256×96, 32×32 cells, bottom-centred 16 px) | `SPPF_Table` frames, root $50, `PowerUp_Palettes[0]` | **R** | SMB3 small Mario is 16 px wide in a 3×2 grid of 8×16. Blit the composite bottom-centred into the 32×32 cell. **Frame counts differ**: SMB3 walk has 2 frames vs the remaster's 3, and SMB3 swim has 4 vs `SwimUp` 6. Ship an overriding `Small.json` with SMB3 counts, or repeat frames. `Climb` and `FaceForward` need confirming in the ROM, else **F**. |
| `Players/Mario/Big.png` | root $54, walk $0C–$0E | **R** | 16×32 fits the 32×32 cells. Walk has 3 frames, which matches. `Attack` can use the SMB3 fireball-throw frame. `Grow` uses mid-frames $0B/$27. `Pose` is unverified. |
| `Players/Mario/Fire.png` | Big frames + `PowerUp_Palettes[2]` | **D** (once Big exists) | Same frames as Big, different 3-colour palette. |
| `Players/Luigi/*` | same frames + Luigi palette | **D** (after Mario) | SMB3 Luigi is a palette swap of Mario. |
| `Players/Mario/Superball.png` | none | **F** | Keep SMB1. |
| Raccoon / Frog / Tanooki / Hammer | exist in ROM | **N** | No remaster power state to map them to. Out of scope; that would be a gameplay change. |
| `Enemies/Goomba.png` (48×16 sheet: walk ×2, stomped) | object tile list + enemy CHR bank | **D/R** | 16×16, walk animation, squashed frame. Likely direct cell-for-cell, but SMB3's silhouette differs from the SMB1 green mask, so a **canvas recipe is needed, not the SMB1 template**. Per-theme recolours: see the palette strategy in §4.4. |
| `Enemies/KoopaTroopa.png` (96×32 per theme; walk 16×32 ×2 plus shell frames) | Koopa object tiles | **R** | SMB3 Koopa is a 16-wide, 2-sprite-tall composite. It fits 16×32 cells; anchor at the bottom. Shell idle and spin: SMB3 shell spin frame count is **unverified**. The remaster uses 4 spin frames; override `animations.Spin` if SMB3 has fewer. |
| `GreenKoopaShell` / `RedKoopaShell` | same sheet | **R** | Same as Koopa. Red is a sprite-palette variant. |
| `Blocks/QuestionBlock.png` (4 frame columns × 7 theme rows) | BG block, banks $60/$62/$64/$66 | **R** | SMB1 animates by palette and SMB3 by CHR swap. Each column must be rendered from a different bank. The recipe needs a per-cell `chr_bank` override. Frame timing differs; override `animations.default` in the pack JSON. |
| `Tilesets/Terrain/BrickBlock.json` → terrain atlas cell (0,64) | Plains block (animated bank) | **D** | One 16×16 block rendered via the metatile layout. Animated shine is optional. |
| Terrain pipes (atlas cells) | Plains pipe blocks | **D** | Several 16×16 pipe blocks map onto pipe cells. Other pipe colours (`BluePipe`, `RedPipe`, …) come from recolour (§4.4). |
| Ground / terrain atlas `Overworld.png` (256×256, about 243 cells with autotile semantics) | Plains blocks via `Tile_Layout_TS1` | **R + F** | Fill the cells that have a sensible SMB3 block: top edge, fill, sides, corners, and slopes where the Hills tileset has them. **Underlay the rest from the user's generated `BaseAssets` atlas** (§4.3) so no cell is left empty. |
| Other terrain themes | Underground → Hills/Under; Castle → Fortress; Underwater → Water; Desert → Desert; Snow → Ice; Sky → Sky; Airship → Airship | **R + F** | Volcano, Autumn, Beach, Garden, Mountain, Space, GhostHouse and Bonus have no SMB3 tileset → **F**. Later milestones only. |
| `Tilesets/FlagPole.png`, `Flag.png`, `CastleFlag.png` | none (SMB3 ends with the goal card roulette) | **N → F** | Keep SMB1. A later option is to **S**ynthesise a pole from SMB3 pipe or block parts. Not worth it early. |
| Castle (`EndingCastleSprite`, `SmallCastle`, castle tiles) | Fortress blocks exist; no end-of-level castle | **S / F** | A castle could be composed from Fortress blocks. Default to **F**. |
| Clouds (`CloudPlatform.png`, cloud cells in the terrain atlas, `Deco` cloud tiles) | Plains/Sky cloud blocks | **R** | Clouds are 16×16 blocks. The remaster cloud decos are multi-cell compositions, so recompose. `CloudOverlays` are remaster-only → **F**. |
| `Backgrounds/Hills/*.png` (512×512 parallax) | Plains background hill/bush blocks | **S** | No SMB3 image exists, so it would have to be composed from blocks. Defer; **F** for now. Skies are flat colours and can be **S** from the tileset BG colour. |
| `Items/StaticCoin.png`, `UI/CoinIcon.png` | animated coin block (banks $60–$66) / status bar coin | **D/R** | Coin block frames come from the 4 animated banks. CoinIcon is 8×8 from the status-bar CHR (unverified). |
| `Items/SpinningCoin.png` (4 frames) | coin-from-block sprite object | **R** | Frame count unverified; override if it differs. |
| `Items/SuperMushroom.png`, `1UP.png`, `PoisonMushroom.png` | mushroom sprite + palettes | **D** / **D** / **F** | 16×16. Poison has no SMB3 equivalent. |
| `Items/FireFlower.png` | fire flower sprite | **D/R** | Animation method (palette flash vs. frames) unverified. |
| `Items/SuperStar.png` | starman sprite | **D/R** | Same caveat. |
| Leaf, P-Switch, Note block, Munchers, Donut, wood blocks, … | exist in ROM | (bonus) **D/R** | The remaster already has authored equivalents (`Blocks/NoteBlock.png`, `FrozenMuncher.png`, `DonutBlock.png`, …) that are *not* ROM-generated today. These are natural later wins. |
| HUD font and digits (`UI/Font.fnt` + `Font.png`, 256×256, 365 glyphs) | status bar CHR $5C–$5F | **R + F** | Generate `Font.png` by copying the repo font page and overwriting the digit glyph cells (and any letters SMB3 has) with SMB3 8×8 tiles. Keep `Font.fnt` metrics unchanged. Glyphs with no SMB3 source keep the authored look. |
| `UI/TitleSMB1.png` | SMB3 title is a large PPU-buffer image | **N/F** | The remaster's title logo is per campaign. Out of scope. |
| Common SFX (jump, coin, stomp, bump, powerup, pipe, 1-up, fireball) | SMB3 SFX engine | **separate track** | Feasible only through engine emulation (§7). The asset type is `.wav` via the pack's `Audio/SFX`. |
| Music (overworld, underground, castle, underwater, star, hurry variants) | SMB3 music sets | **separate track** | Rendered audio + `.bgm` descriptors with loop points. The hurry variant uses a shifted rest table. Not in the first milestone. |

---

## 4. Architecture

### 4.1 Resource-pack strategy: recommendation

**Recommendation: B, implemented with a small, additive slice of C.**

**B.** A separate generated pack, **`SMB3Assets`**, written to `<config>/resource_packs/SMB3Assets/`. It sits above `BaseAssets` via the normal pack list.

**C-lite.** New ROM-import code lives in its own namespace and is ROM-agnostic where that is free: iNES parsing, banked CHR decoding, the master palette and a recipe executor. It stays independent of the SMB1 classes.

**The SMB1 importer is not modified.**

Why not the other options:

- **A (replace BaseAssets): rejected.** `BaseAssets` is the guaranteed floor that every `res://Assets` JSON assumes exists. Replacing it would break every asset with no SMB3 mapping and couple SMB3 to `ROM_ASSETS_VERSION` invalidation.
- **Full C now (rewrite SMB1 onto a generic system): rejected for now.** It is a high-risk refactor of working code for no user-visible gain. Converge later only if the new code proves itself (§10, step 8).

What B gives for free:

- **User choice of SMB1 vs SMB3 visuals.** `ResourcePackLoader` lists any folder with `pack_info.json` except `BaseAssets`, and toggling it calls `push_front`. "SMB3 visuals" means enabling the SMB3 pack; "SMB1 visuals" means disabling it.
- **Graceful partial coverage.** Any file the SMB3 pack omits resolves to `BaseAssets`. So the pack can start with eight sprites and grow.
- **Composability.** User packs can sit above or below `SMB3Assets` in the order.

Pack contents, in three tiers:

1. **Drop-in PNG (preferred).** Same relative path, same canvas size, same frame cells as the SMB1 sheet. The existing `res://Assets/**.json` keeps working. Examples: Goomba, QuestionBlock, StaticCoin, terrain atlas.
2. **PNG + overriding JSON.** Used when frame counts or rects differ: Small Mario walk 2 frames, swim 4, question-block timing. The JSON is **remaster-authored data** (rects and timings) and lives in the repo under `Resources/RomImport/SMB3/overrides/`. It is copied into the pack at generation time. Each overriding JSON must provide every theme and campaign key it wants to cover, or `link` to `default`, because a pack JSON replaces the whole `variations` tree.
3. **Omitted.** Falls back to SMB1 `BaseAssets`.

**Campaign caveat.** Variations key on campaign: `SMB1`, `SMBLL` (`OverworldLL.png`), `SMBANN`, `SMBS` (`…SP.png`). A drop-in `Overworld.png` reskins every mode that plays SMB1-campaign levels, but not LL/ANN/SP levels. The first milestone targets SMB1-campaign filenames only. Later, the generator writes the `LL`/`SP`/`ANN` filenames from the same recipe (§0.2). That is campaign coverage, not mode coverage.

#### 4.1.1 Portable JSON subset for SMB3 overrides

Every override JSON the SMB3 pack ships must be resolvable by **every resolver in the game**, not just `ResourceSetterNew`. Today that also means Battle's `BattlePreviewResolver`. It interprets only these keys:

- theme / `default`
- time
- campaign (fallback `SMB1`)
- `link`
- `source`
- `rect`
- `animations`
- `animation_overrides`
- the fixed `World1` / `Level1` / `Quest:1` / `RoomType:*` / `GameMode:Campaign` / `Character:*` descent

Rules for SMB3 override JSONs:

- **Allowed keys** are only those above. No `config:`, `flag:`, `choices`, `sequence`, `Metadata:`, `LevelMetadata:` or `GameMode:` keys.
- **Keep every animation name** that the `res://` original defines. Change frame *counts* and rects, but never remove an animation. For example, Battle previews look up `Idle`, `Move`, `Skid`, `Jump`, `Climb`, `Die` and `Grow` on Mario. Repeat frames where SMB3 has no equivalent.
- **Keep `source` filenames identical** to the `res://` originals wherever possible. Tier 1 drop-in PNGs then need no JSON override at all, which is the most portable option.

These rules are enforced by schema test A4. They are a constraint on generated **data**, so no resolver or mode needs SMB3 awareness.

### 4.2 Proposed classes and files

All new; nothing existing is edited except the optional small hook in step 6 of §10.

```
Scripts/Classes/RomImport/
  NesRom.gd                 # iNES/NES2.0 header parse, mapper, PRG/CHR bank views, headerless SHA-1/CRC32
  NesChr.gd                 # 2bpp planar decode; tile(bank_1k, idx) / tile_abs(n); 8x16 pair helper; flips
  NesMasterPalette.gd       # NES index (0x00-0x3F) -> Color, loaded from a repo JSON
  CanvasRecipeExecutor.gd   # builds an Image from a recipe (cells, composites, palettes, underlay)
  GeneratedPackWriter.gd    # writes pack_info.json, PNGs, copied override JSONs; atomic temp-dir + rename
Scripts/Classes/RomImport/SMB3/
  SMB3RomProfile.gd         # hash -> revision profile (bank ids + PRG offsets), loaded from JSON
  SMB3Verifier.gd           # MMC3 + sizes + SHA-1 in profile list; never touches baserom.nes
  SMB3Extractor.gd          # reads PRG tables: PowerUp_Palettes, PalSet_*, SPPF_Table, Player_FramePageOff,
                            #   TileLayout tables, BG page tables; exposes render_block(), render_player_frame(),
                            #   render_sprite(tiles,bank,…)
  SMB3PackGenerator.gd      # orchestrates recipes -> SMB3Assets; progress signals
Scripts/UI/SMB3PackImport.gd + Scenes/Levels/SMB3PackImport.tscn
                            # file picker / drop / progress; reachable from the global resource-pack menu, not from boot
                            # and not from any game-mode screen

# Explicitly NOT touched: BattleScreen, BattlePreview*, BattleHandler, BooRaceHandler, LevelSelect,
# MarathonResults, CampaignSelect, CustomLevelMenu, Player, LevelClass, ResourceSetterNew,
# BattlePreviewResolver. Modes inherit the pack through Settings.file.visuals.resource_packs.

Resources/RomImport/
  NesMasterPalette.json     # 64 RGB entries (repo-authored or permissively licensed; see §6)
  SMB3/profiles/usa_rev1.json   # sha1, crc32, chr_root_pages, prg offsets — facts, no ROM bytes
  SMB3/theme_map.json       # remaster theme -> SMB3 tileset/palette set (or "fallback")
  SMB3/recipes/*.json       # one per generated output (see 4.3)
  SMB3/overrides/**.json    # remaster-authored runtime JSONs (frame rects/timing) copied into the pack
  SMB3/pack_info.json       # {"name":"Super Mario Bros. 3 Style (from your ROM)","author":"Nintendo (generated locally)",…}
```

`Global` gets constants only: `SMB3_PACK_NAME := "SMB3Assets"` and `SMB3_ASSETS_VERSION := 1`. These are kept separate from `ROM_ASSETS_*`. `check_for_rom()` is not touched.

Version invalidation for the SMB3 pack is checked by the SMB3 import screen. The pack menu could optionally do it too. Stale generated packs are marked "needs regeneration"; they are not auto-trashed at boot.

### 4.3 Recipe format: build a canvas, don't paint through a mask

SMB1 recipes paint into green silhouettes stored in shipped PNGs. That fails for SMB3 because the shapes differ. It also means shipping silhouettes of Nintendo sprites. SMB3 recipes instead describe the output canvas directly:

```jsonc
{
  "output": "Sprites/Enemies/Goomba.png",
  "canvas": [192, 64],
  "underlay": null,                      // or "BaseAssets" / "res" to start from an existing image
  "palette_rows": {"from": "theme_map", "palette_kind": "sprite", "row_height": 16, "columns": 4, "cell": [48,16]},
  "cells": [
    {"at": [0,0],  "kind": "sprite", "tiles": [[0,0,"T_GOOMBA_L"],[8,0,"T_GOOMBA_R"]], "bank": "$enemy_bank"},
    {"at": [16,0], "kind": "sprite", "tiles": "…", "flip_h": true},
    {"at": [32,8], "kind": "sprite", "tiles": "…"}
  ]
}
```

Supported `kind`s:

- **`sprite`:** explicit 8×16 tiles, a CHR bank and a palette.
- **`player_frame`:** `{suit, frame_id, anchor:"bottom_center", cell:[32,32]}`. Reads `SPPF_Table` and `Player_FramePageOff` **from the ROM**, so the repo needs no per-tile player mapping.
- **`block`:** `{tileset, block_id, bg_banks?, anim_frame?}`. Rendered through the ROM's metatile layout and BG palette.
- **`chr_tile`:** an 8×8 tile, for font and HUD.
- **`underlay`:** copies the corresponding file from the user's generated `BaseAssets`, or the repo PNG for authored fonts, before painting. This is how the terrain atlas and font get full coverage without blanks.

Symbolic names such as `T_GOOMBA_L` and `$enemy_bank` resolve through the revision profile. Recipes stay revision-independent; only the profile carries offsets, bank ids and tile ids.

### 4.4 Palettes

- Introduce `NesMasterPalette.json` (64 colours). Recommended source: **author it in-repo**. Start from the remaster's existing SMB1 RGB choices for the indices SMB1 uses (for example `F73910`/`FFb762`/`8C7318` for Mario) so both packs share a colour language, and fill the rest from a permissively licensed NES palette. Record its provenance in the file.
- SMB3 colours are read **from the ROM** as indices (`PalSet_*`, `PowerUp_Palettes`) and mapped through the master palette. This is more faithful than SMB1's authored RGB and keeps the repo free of any game-specific colour tables.
- **Remaster themes with no SMB3 tileset** (Volcano, Autumn, Beach, Space, Mountain, Garden, GhostHouse, Bonus) are handled by `theme_map.json`, which chooses one of:
  - `"use": "<SMB3 tileset>"`, the nearest SMB3 set;
  - `"recolor": <authored palette JSON in the existing Palettes format>`, which reuses the SMB1 theme recolours applied to SMB3 shapes. The existing `Palettes/Default/*.json` files can be referenced, since they are remaster-authored;
  - `"fallback"`, which skips that sheet row. This needs underlay to keep the row filled, so for per-theme sheets the default is `recolor`.

### 4.5 Data flow

```
user picks file
  → NesRom.open(bytes)                              # parse header, strip, split PRG/CHR
  → SMB3Verifier.identify(rom) → SMB3RomProfile      # SHA-1 of rom[16:] ∈ profiles; mapper==4; sizes
  → SMB3Extractor(rom, profile)                      # lazily reads tables, caches decoded banks
  → for recipe in Resources/RomImport/SMB3/recipes:
        img = CanvasRecipeExecutor.build(recipe, extractor, master_palette, theme_map)
        GeneratedPackWriter.add_png(recipe.output, img)
  → copy overrides/**.json, write pack_info.json {version, source_sha1, profile_id, base_assets_version}
  → atomic rename tmp → resource_packs/SMB3Assets
  → (optional) offer to enable: Settings.file.visuals.resource_packs.push_front("SMB3Assets")
```

Failure policy: any recipe error aborts and deletes the temp directory. A half-written pack is never visible. This is stricter than today's SMB1 path, which writes in place.

---

## 5. ROM-version strategy

**Start with exactly one revision: USA (Rev 1) / "PRG1"**, headerless SHA-1 `BB894D104C796F69BA16587EB66C0275F5C2FC02`.

Why Rev 1:

- Southbird's disassembly rebuilds that exact image, and Foundry's defaults target US. Every label used here can be checked against a byte-exact source.
- Region differences are known to move PRG tables. A JP palette-table offset already differs in Foundry.

Expansion path:

1. **USA Rev 0.** Write a profile and confirm each PRG offset by signature search: match the bytes at the Rev 1 offset, then search for them. Profiles are data, so this needs no code.
2. **Optimisation.** Hash the **CHR region separately** (`rom[0x40010:]`). If revisions share identical CHR, CHR-only recipes (font, blocks with known tile ids) work across them, and only PRG-table recipes need per-revision offsets. Measure this; don't assume it.
3. **Europe and Japan** later, each with its own profile. Japanese ROMs are **not** supported in the POC because the palette table is known to move.
4. **Virtual Console dumps:** separate hashes; treat as separate profiles.

An unknown hash gets a clear error ("unsupported SMB3 revision: <sha1>"). There is no best-effort guessing.

---

## 6. Legal and distribution boundary

The design keeps the current model: no Nintendo assets in the repo, the user supplies their own ROM, and assets are generated locally.

Decisions that protect that boundary:

1. **Recipes contain only facts and remaster-authored data.** That means coordinates, symbolic names, bank and tile *numbers*, offsets, hashes, frame rects and timings. No pixel data. Unlike SMB1, **no SMB3 silhouette PNGs** are shipped. The canvas recipe (§4.3) removes the need for green masks entirely.
2. **Colours come from the ROM at runtime.** Only a generic NES master palette is in the repo.
3. **The generated pack lives only in the user config dir** (`<config>/resource_packs/SMB3Assets`), the same as `BaseAssets`. Nothing under `res://` is written.
   - The SMB1 `RomAssetEditor` writes into `res://Assets` and `res://Resources`. Any SMB3 authoring tool must write recipes only, never images, into the repo.
4. **The SMB3 ROM is not copied by default.** Store only `source_sha1` in `pack_info.json`; regeneration asks for the file again. If convenience wins later, copy it to `<config>/smb3.nes`, **never** to `baserom.nes`.
5. **`.gitignore` guard.** Add `*.nes`, `/test_output/` and `**/SMB3Assets/` so local test runs can't be committed by accident.
6. **Tests never contain ROM bytes or decoded pixels.** They hold hashes of generated output, dimensions and counts (§9). Hashes of derived images are not the images.
7. **Licence hygiene for references.**
   - Southbird's disassembly has **no licence file** and embeds Nintendo data. Use it as documentation only; do not vendor any of it.
   - SMB3-Foundry is **GPL-3.0**. This repo's `LICENSE` is also **GPL-3.0**, so porting Foundry logic is licence-compatible with attribution. Still prefer re-deriving offsets as facts in our own profile JSON, because Foundry's constants may embed tables computed from ROM data.
   - Audio libraries: libgme (LGPL-2.1) and NSFPlay (permissive) are both compatible with GPL-3.0, and so is Mesen2 (GPL-3.0) code. The binding constraint is shipping native GDExtension builds, not licensing.
8. **Pack metadata** clearly says "generated locally from your ROM". The import UI says a legitimate cartridge dump is required, mirroring the SMB1 flow.
9. **Sharing.** A user who exports or shares `SMB3Assets` is distributing Nintendo-derived art. The import screen should say so. `ResourcePackTemplateCreator`-style tooling should not copy `SMB3Assets` into new templates. Today it already references `BaseAssets`; check it before allowing SMB3 here.

---

## 7. Graphics vs audio

**Recommendation: graphics first. Audio is a separate later track, and possibly never.**

- The current pipeline has **zero ROM-derived audio**. Every BGM and SFX is a shipped recording. For SMB1 this was a product choice: remastered audio rather than ripped audio.
- SMB3 audio needs a different kind of machinery:
  - A 6502 CPU, a 2A03 APU (with DMC) and an NSF-style driver to call the engine. Or a lossy sequence-to-synth converter.
  - Then an offline renderer to `.wav`. `AudioStreamWAV.save_to_wav` exists in Godot 4. Godot cannot encode OGG/MP3 at runtime.
  - Then `.bgm` loop-point descriptors for Normal and Hurry.
- None of this shares code with tile decoding.
- Options, in increasing cost:
  1. A pure-GDScript APU + 6502 run offline. Slow but self-contained.
  2. A GDExtension wrapping NSFPlay (permissive) or libgme (LGPL). Native builds for every export target; CI currently exports Windows, Linux x86 and Linux arm64.
  3. Sequence parsing with a simple synth. Cheaper, but loses the "authentic" point.
- Once audio is rendered, the delivery side is already supported. A pack can contain `Audio/BGM/Overworld.wav` plus `Overworld.bgm`, and `ResourceSetterNew` in `AUDIO` mode picks it up.
- Suggested gate: run a separate spike to render one SMB3 SFX (coin) to WAV, and only then decide.

---

## 8. Technical risks

| Risk | Impact | Mitigation |
|---|---|---|
| Offsets wrong or revision-specific | Garbage graphics | Profiles pinned by SHA-1; byte-signature assertions at each offset in tests; Rev 1 only at first. |
| Enemy CHR bank ambiguity (per-object `PatTableSel`, slot 5/6) | Wrong tiles for Goomba/Koopa | Resolve from each object's `PatTableSel` + `PatternSets`, not by eyeballing. Develop with a debug "render bank N" dump that is local-only and never committed. |
| Frame count and shape mismatches (Mario walk 2 vs 3, swim 4 vs 6, shell spin) | Odd animation | Tier-2 JSON overrides with SMB3 counts. The runtime already supports arbitrary `frames` arrays. |
| Hitbox / visual mismatch (SMB3 sprites drawn differently within 16 px) | Looks off, but gameplay is unaffected | Bottom-centre anchoring matches the remaster (measured: small Mario at x 8–24, y 16–32 in 32×32 cells). Hitboxes are not changed. |
| Terrain atlas autotile semantics | Wrong edges or corners | Map only cells with a clear SMB3 counterpart; underlay the rest from `BaseAssets`. Review visually in 1-1. |
| Pack JSON overrides replace the entire `variations` tree | Themes or campaigns silently lose variants | Overrides use `link` and `default`. A schema test checks every override resolves for every theme in `themes`. |
| Mixed look (SMB3 Goomba next to SMB1 Koopa) | Aesthetic only | Expected during rollout. The pack description can say "partial". |
| `BaseAssets` regenerated (version bump) → SMB3 underlay is stale | Stale cells | Store `base_assets_version` in SMB3 `pack_info`; mark stale and offer regeneration. |
| Godot `Image` performance in GDScript | Slow generation | Decode each 1 KB bank once into an index buffer and cache; mostly irrelevant at POC scale. |
| Mode-specific creep: someone "fixes" an SMB3 issue inside Battle or Challenge code | Divergent behaviour per mode | Rule 0.1–0.4, plus static guard test C4. Fix gaps in generated data or generic code only. |
| Override JSON uses a key that a secondary resolver (`BattlePreviewResolver`) doesn't interpret | Battle previews fall back to placeholders while gameplay shows SMB3 | Portable JSON subset (§4.1.1), schema test A4, and cross-resolver test C3. |
| Mode-local art caches don't notice a pack toggle (for example `BattlePreviewAssets._cache` on the Battle branch is keyed by scene, theme and campaign, not by pack list) | Stale SMB1 art in that mode until restart | Not SMB3-specific: it affects *any* pack. Fix generically when Battle merges, for example by clearing it from the same place `ResourcePackContainer.select()` clears the other caches, or with a global "packs changed" signal. No SMB3 code. |
| Campaign filename gaps (LL/ANN/SP) | Some modes and levels look SMB1 | Close in the generator (§0.2), never per mode. |
| Legal drift (someone commits a generated PNG or silhouette) | Distribution problem | `.gitignore` guard, no mask PNGs, a review checklist item, and a CI grep for `*.nes`. |

---

## 9. Test plan (no copyrighted data committed)

The repo has no unit-test framework today (only a manual `testLevel.tscn`; CI only exports builds). Proposal: a small headless runner, `tests/rom_import/run.gd`, run with `godot --headless -s`, so no new addon is needed. Tests are split by whether they need a ROM.

**A. No ROM needed (always run, CI-safe)**

1. **`NesChr` decode on synthetic bytes.** Hand-built 16-byte tiles (for example plane0 = `0xFF`, plane1 = `0x00` → all index 1) checked for expected indices, flips and 8×16 pairing.
2. **`NesRom` header parsing** on synthetic headers (mapper 4/0, sizes, NES 2.0 flag), and rejection of zip, short or odd files.
3. **Synthetic SMB3-shaped ROM.** Programmatically build a 393,232-byte image with an iNES mapper-4 header and patterned PRG/CHR, with tables planted at profile offsets. Run the full generator against a **test profile** keyed to that image's hash. This exercises recipes, the executor, the pack writer and the atomic rename end to end without Nintendo bytes.
4. **Recipe and pack schema validation.** Every recipe has an output under `Sprites/`, an in-bounds canvas, valid kinds, and symbols present in every shipped profile. Every override JSON parses, has `animations` rects inside the declared canvas, and resolves for every remaster theme and the SMB1 campaign through `ResourceSetterNew.get_variation_json` with `force_properties`. `addons/JSON_Schema_Validator` is already in the repo.
5. **Fallback behaviour.** With a fake pack containing only `Goomba.png`, `get_resource_pack_path` returns the SMB3 path for Goomba and the `BaseAssets` path for Koopa. With an empty or broken override JSON, the existing `ignore_resource_from` logic falls through.
6. **Master palette:** 64 entries, valid hex.

**C. Game-wide resolution (no ROM needed, CI-safe)**

These tests prove that one generated SMB3 asset is resolved identically in campaign play and in non-campaign modes, with no mode-specific code.

**Fixture.** They run against a **fixture `SMB3Assets` pack**: the output of the synthetic-ROM run from A3, written to a temporary `Global.config_path`.

- Its `Sprites/Enemies/Goomba.png` and terrain `Overworld.png` contain a distinctive synthetic pattern.
- Its pack list is `["SMB3Assets", "BaseAssets"]`.
- Expected values are the fixture PNG's SHA-256 and the fixture path. No Nintendo pixels are involved.

**C1. Resolver level, every mode.**

- Set:
  - theme `Overworld`, time `Day`, campaign `SMB1`;
  - World 1 / Level 1;
  - room `MainRoom`;
  - character Mario.
- For **each value of `Global.GameMode`**, iterating the enum rather than a hand-written list:
  - set `Global.current_game_mode`;
  - clear the `ResourceSetterNew` caches;
  - resolve `res://Assets/Sprites/Enemies/Goomba.json` and `res://Assets/Sprites/Tilesets/Terrain/TerrainTiles.json` through a detached `ResourceSetterNew` (`mode = SPRITE_FRAMES` / `TEXTURE`).
- Assert:
  - `current_resource_pack == "SMB3Assets"`;
  - the resolved atlas image hashes to the fixture PNG;
  - the frame rects equal the fixture override, if one exists.
- Then assert that **all modes produced byte-identical results**.
- Because it iterates the enum, **Battle (`GameMode.BATTLE`, once merged) and any future mode are covered automatically**. This explicitly includes `CAMPAIGN` and `CHALLENGE`.

**C2. Scene level: campaign vs Challenge.** Load `Scenes/Levels/SMB1/World1/1-1.tscn` headless twice:

1. with `current_game_mode = CAMPAIGN`;
2. with `current_game_mode = CHALLENGE`, configured the way `LevelSelect` would start a Challenge run.

After one frame, check two things in each run:

- the first Goomba's `AnimatedSprite2D.sprite_frames` frame-0 atlas image;
- the `Tiles` layer's `TileSetAtlasSource` 0 texture.

Assert that both hash to the fixture images in both runs, and that the runs match each other. This covers the real node path (`ResourceSetterNew` on scene instances, `TilesetTextureSetter`), not just the resolver.

**C3. Battle (activates when Battle Mode is merged).**

- Call `BattlePreviewResolver.resolve("res://Assets/Sprites/Enemies/Goomba.json", "Overworld", "Day", "SMB1")` with the fixture pack list.
- Assert `source` is the fixture `SMB3Assets/…/Goomba.png` and the rect matches C1.
- Run the same check over every SMB3 override JSON, to verify the portable subset.
- Then repeat C2 with `GameMode.BATTLE` using the same 1-1 scene.
- The test is skipped (with a message) while `BattlePreviewResolver` doesn't exist on the branch. It is test code only, and needs no runtime Battle changes.

**C4. No-mode-code guard (static).**

- Fail if any `.gd` or `.tscn` outside `Scripts/Classes/RomImport/**`, `Scripts/UI/SMB3PackImport.gd`, its scene and the `Global` constants references `SMB3Assets`, `SMB3_PACK_NAME` or `class_name SMB3*`.
- Also fail if any SMB3 override JSON contains a `GameMode:` key.

**C5. Pack toggle is global.**

- With the fixture pack **disabled** (removed from the list), C1 resolves `BaseAssets`/`res://` for every mode.
- With it re-enabled via the same code path as `ResourcePackContainer.select()`, every mode resolves `SMB3Assets` again.
- No mode needs re-initialisation beyond the existing cache clear.

**B. ROM-gated (skipped unless `SMB3_ROM=/path` is set; run locally, never in CI)**

1. **Hash identity:** SHA-1 of `rom[16:]` equals the profile value; CRC32 is `2E6301ED`.
2. **Offset signatures:** bytes at each profile offset match the expected short signatures. The facts are copied from SB labels, for example `Player_PUpRootPage` = `50 54 54 00 50 40 44`.
3. **Known-tile hashes:** SHA-256 of selected decoded **index buffers** (not RGB) for named tiles and blocks, such as the Plains ? block in frames 0–3 and status-bar digit "0". The expected hashes are recorded once from a reviewed run.
4. **Dimensions:** every generated PNG matches its recipe canvas, and drop-in PNGs equal the `res://` original's size.
5. **Palette values:** for example, Fire Mario's 3 colours equal `master[$27], master[$36], master[$16]` (from `PowerUp_Palettes[2]`). The test checks index → RGB, not stored pixels.
6. **Frame counts:** small Mario walk resolves to 2 frames, and the overriding `Small.json` declares the same.
7. **Deterministic output:** generating twice yields byte-identical PNGs; the pack-level SHA-256 manifest (written to `pack_info.json`) is stable.
8. **No-mapping fallback:** after generation, `FlagPole.png` is absent from `SMB3Assets` and resolves to `BaseAssets`.
9. **Real-ROM game-wide check:** re-run C1 and C2 against the real generated pack. Expected hashes are the deterministic hashes from B7, so no ROM-derived pixels are committed.

---

## 10. Smallest proof-of-concept milestone

> **Given a USA Rev 1 SMB3 ROM, generate `SMB3Assets` containing SMB3 Small Mario, Goomba, ground, brick, question block, pipe, coin and HUD digits. Enable it through the normal resource-pack menu, and load SMB1 World 1-1 in campaign play *and* in Challenge mode. Both must show the same SMB3 assets, with no mode-specific code.**

POC acceptance criteria:

- **Tests:** C1 (all `GameMode` values, including `CAMPAIGN` and `CHALLENGE`), C2 (scene-level campaign vs Challenge), C4 (static guard) and C5 (toggle) pass on the fixture pack. B9 passes locally on a real ROM.
- **Battle:** if Battle Mode has merged by then, C3 must also pass. A failure there is fixed in generated data, or generically in the shared cache/resolver path, never with SMB3 logic in Battle classes.
- **Diff scope:** the change touches no file in the "explicitly not touched" list of §4.2.

Scope controls:

- **Theme:** `default` (Overworld) rows and cells only. Other theme rows in per-theme sheets (Goomba, QuestionBlock) are filled by the `recolor` route from existing SMB1 palettes, or by underlay from `BaseAssets`.
- **Campaign:** SMB1 only. Big and Fire Mario intentionally fall back to SMB1, showing that partial packs work.
- **Terrain:** the SMB3 ground top, fill, brick, ? (static frame 0 in the atlas cell) and the 4 pipe blocks over a `BaseAssets` underlay of `Overworld.png`.
- **Animated question block:** 4 columns from banks $60/$62/$64/$66, plus an override JSON with SMB3 timing.
- **Coin:** `StaticCoin.png` default row from the animated banks.
- **HUD digits:** `Font.png` = the repo font page underlay + SMB3 digits overwritten. `Font.fnt` is copied unchanged. This exercises the `FONT` path. If digit tile ids prove hard to pin, swap in `UI/CoinIcon.png` and keep digits for the next step.
- **Small Mario:** idle, walk (2), jump, skid and die from `SPPF_Table`, plus a `Small.json` override. Remaining animations repeat the idle frame.
- **UI:** a dev-only entry point (`-smb3rom <path>` CLI flag, or the debug menu) is enough. A polished menu entry comes later.

What it proves:

- PRG table reads (player frames, palettes, metatiles) and banked CHR decoding.
- Canvas recipes, including size and anchor handling.
- Pack writing, overrides and underlay.
- `ResourceSetterNew` precedence with partial coverage.
- Mixed frame counts at runtime.

Estimate: a focused 1–2 weeks, most of it pinning tile and bank ids.

---

## 11. Recommended implementation sequence

1. **Profile and verifier.**
   - `NesRom`, `SMB3Verifier` and `usa_rev1.json` with SHA-1 and a handful of offset signatures.
   - ROM-gated tests B1–B2.
   - No UI.
2. **Decoder.**
   - `NesChr` (banked, 8×16), `NesMasterPalette`.
   - A local-only debug dump of any 1 KB bank as a PNG, written to the scratch/config dir and gitignored.
   - Tests A1, A2 and A6.
3. **Extractor primitives.**
   - `render_block(tileset, id, anim_frame)` via `Tile_Layout` + BG pages + `PalSet`.
   - `render_player_frame(suit, frame)` via `SPPF_Table`.
   - `read_powerup_palette(i)`.
   - Tests B3 and B5.
4. **Recipe executor and pack writer.**
   - Canvas recipes, underlay, atomic write, `pack_info` manifest.
   - Synthetic-ROM end-to-end test A3, schema tests A4 and A5.
5. **POC recipes and overrides.**
   - The §10 assets.
   - Hand-verify World 1-1 in campaign **and** Challenge.
   - Tests B4 and B6–B9, plus the game-wide tests C1, C2, C4 and C5 (and C3 if Battle is merged).
6. **Entry point.**
   - A CLI flag and debug import scene.
   - Then the pack-menu "Import SMB3 ROM…" button. That is the only touch to existing UI, and it is additive. It goes in the **global** resource-pack menu, never in a mode's menu.
7. **Breadth.**
   - Big/Fire/Luigi.
   - Koopa and shells.
   - Items.
   - Remaining Overworld terrain cells.
   - Then other SMB3-native themes (Underground, Fortress, Water, Desert, Ice, Sky, Airship).
   - SMB3-native remaster blocks (note block, muncher, donut, P-switch).
   - Campaign filename coverage (LL/ANN/SP variants) so LL/ANN-based modes and levels get SMB3 art too (§0.2).
   - Each new asset is added to the C1 fixture set, so cross-mode resolution stays verified as coverage grows.
8. **Optional convergence.**
   - If the new modules are stable, consider pointing SMB1's generator at `NesRom`/`NesChr` internally.
   - Only with byte-identical `BaseAssets` output verified before and after.
9. **Additional revisions.** USA Rev 0, then EU/JP, as profiles.
10. **Audio spike** (§7), as a separate decision.

---

## Appendix: open questions to resolve during implementation

- Exact CHR bank and tile ids for Goomba, Koopa, mushroom, flower, star, coin sprite and status-bar digits. Derive them from the `PatTableSel`/`PatternSets` and prg026 tables.
- Whether SMB3 small Mario has usable climb and front-facing frames.
- Shell spin frame count.
- Whether US Rev 0 and Rev 1 CHR are byte-identical.
- PRG0/PRG1 and PAL differences at ROM level. TCRF, Data Crystal and nesdev were unreachable during this research; check them manually.
- Licensing is settled: the repo `LICENSE` is GPL-3.0 (see §6.7).
