# 45 — Battle: physical incoming enemies in the real player's game (architecture)

Status: **design only**, on top of `7de7c06` (docs 42–44). Nothing in the game is changed. The one piece of code is an isolated spike,
`tests/tools/battle_incoming_spawn_spike.gd` (prototype, not wired into gameplay), whose results are quoted below.

The rule this design keeps: **`BattleSession` decides what attacks exist. The real game only materialises an ACTIVE attack aimed at the real
player as a real enemy, and reports that enemy's real fate back.** No attack is created, chosen, timed out or ordered by the game side.

## 0. The design in brief

* A per-level **bridge**, `BattleIncomingSpawner` (a child of `BattleHandler`), reconciles the session's ACTIVE player attacks with real enemy nodes.
  It works through three pure helpers: `BattleIncomingPlan` (order and pacing), `BattleSpawnPlacer` (where) and `BattleEnemyFactory` (the game's own prefab).
* **Real prefabs**, unchanged: `Goomba.tscn` and `GreenKoopaTroopa.tscn`, spawned with the same metas the game's own block and pipe spawners set
  (`block_item`, `no_persist`). The spike shows they walk, collide, animate, are stomped through real physics and die normally.
* **Identity** is one metadata value on the enemy, `battle_incoming = PackedInt64Array[session uid, seq, sender]`. It survives every state change, and
  `Node.duplicate()` copies it to the Koopa that wakes up from a shell (spike).
* **Native and incoming are told apart explicitly.** `Enemy.report_battle_defeat` passes the tag (empty = native) to the session. **An incoming enemy's
  death resolves its attack and never sends.** That is the recommended re-send rule; SMB35's one-hop re-send is a single policy switch away (section 6).
* **Koopa:** the attack resolves when the Koopa becomes a shell (the moment a native Koopa counts as defeated). The shell is ordinary level residue.
  The Koopa that wakes from it is tagged residue and can never send or resolve anything.
* **Spawn:** on a real floor inside the camera view, scanned with live physics point queries. It prefers the right edge, at least 80 px ahead of Mario
  and walking toward him, then the left edge, at least 112 px behind. It never spawns over a pit, inside terrain, on another enemy or under the HUD.
* **Pacing:** strict sequence order; 1.5 s grace after a level becomes playable; at least 1.0 s between spawns; only while Mario is in normal play.
  At most `MAX_ACTIVE` (3) are alive, by construction.
* **Resolution** comes only from real outcomes. Kill paths report as they do today. Pits, leaving the screen and vanishing are detected by the bridge
  from camera geometry, because these prefabs never free themselves off screen (spike). There is no timer.
* **Level transition** (recommended change): spawned enemies resolve `LEVEL_TRANSITION`. ACTIVE attacks that were **never spawned carry into the next
  level**, like QUEUED ones already do. The session learns about spawning through one new fact, `report_player_incoming_spawned(seq)` → `INCOMING_SPAWNED`.
  That fact also gives the strip "arriving" versus "in level", and makes "one node per seq" authoritative.
* **Pause bug** (doc 44 §12.8): the presentation clock advances only while the tree is not paused and the game window is not frozen. That is the same
  condition that stops the Battle clock.

## 1. What the repo and the spike establish

Run the spike with: `xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --fixed-fps 60 -s tests/tools/battle_incoming_spawn_spike.gd`.
Under `--headless` the CPU numbers are valid, but enemies never activate (see the first row).

| Question | Finding | Evidence |
|---|---|---|
| Do enemies run headless? | **No.** `VisibleOnScreenEnabler2D` never fires without rendering, so every enemy, native ones included, stays `DISABLED`. Physical tests need GL (xvfb), or a hook that switches the spawned enemy on | spike, headless vs GL runs |
| Can the real prefab be spawned at runtime into the Battle level? | **Yes.** A Goomba added under the level's `Enemies` node at the right edge walked **31.5 px in 1 s**, stood on the floor, played `Walk`, processed, and was on screen | spike `runtime Goomba at the right edge` |
| Is there a spawn factory? | **No shared one.** Every spawner repeats instantiate → position/direction → `add_sibling`. The closest recipe to ours is `BlockClass.dispense_item` (`BlockClass.gd:48-49`: `block_item` + `no_persist` metas) and `PipeGenerator.gd:26,37` | agent survey, `Scripts/Parts/PipeGenerator.gd` |
| Why `block_item` / `no_persist`? | `LevelPersistance` keys an entity by `level path + global_position` and **frees** a newly entered entity whose key was recorded (`Goomba.tscn:188`, `enabled → queue_free`). `block_item` makes the component free itself (`LevelPersistance.gd:18`); `no_persist` stops recording (`:28`) | `LevelPersistance.gd`, `battle_attack_game_test.gd:211-213` |
| Real stomp through physics | Mario dropped on a tagged runtime Goomba: **stomped, reported, freed after its squish** | spike `real physics stomp` |
| Koopa → shell → wake | The shell is **not** tagged (`summon_shell` copies no meta to it). `shell.old_entity = self.duplicate()` (`KoopaTroopa.gd:92`) **keeps the tag with the same value**, plus `block_item` / `no_persist`; `_battle_defeat_reported` is reset; runtime signal connections are **not** copied. After waking (`ShellClass.gd:131-140`), the Koopa is back in the tree **carrying the tag**, and stomping it **sends again today** | spike `koopa stomped`, `shell woke` |
| Off screen | Goomba and Koopa have **no** `OffScreenDespawner` (only BulletBill, HomingBill and Spiny do). Walking off the left edge, the Goomba is **frozen at x = −272 (view left −256), never freed**. Spawned 40 px beyond the right edge, it is **frozen until the camera reaches it** | spike, agent survey |
| Pits | There is **no enemy kill plane** (only the player dies at y > 64, `States/Player/Normal.gd:33-39`). A Goomba dropped into 1-1's first gap fell to **y = 60 (view bottom 32) and froze there, still in the tree** | spike `dropped into the pit` |
| The shell | It frees itself on `screen_exited` of a 256x256 rect (`GreenKoopaShell.tscn:184`) | scene |
| Camera | Never scrolls left unless the back-scroll setting is on (`CameraHandler.gd:118`). The right limit comes from `CameraRightLimit` / `EndCastle`. The view is `GameViewport` camera `get_screen_center_position() ± (128, 120)`; vertically it is [−208, 32] with the default `vertical_height` | agent survey, `CameraHandler.gd:195-225` |
| Geometry | Terrain is TileSet physics layer value 2. Blocks are bodies on layers 2+3 (value 6). Pipes are terrain tiles. A point query with mask 2 sees all of them, live (broken bricks included); lava, water and the camera walls (layer 1) are excluded | `Tiles.tscn:1628-1650`, `project.godot:597-607`, spike ASCII probes |
| Sub-areas | 1-1's bonus room is a **separate scene** (`1-1a.tscn`). Entering a pipe frees the 1-1 Level, so `BattleHandler._exit_tree` runs (today: `LEVEL_TRANSITION`). Returning loads a **new** 1-1 | `Player.gd:1530-1551`, agent survey |
| Death | `Player.die` pauses the tree (`Player.gd:1296-1299`). In Battle there is no reload; the next round replaces the level | agent survey |
| Node cost | One Goomba instance = **22 nodes**, a Koopa = **24**. 1-1 has 17 native enemies (666 nodes with their components); only those on screen run | spike census |

The spike's ASCII probes, as printed (`#` = mask-2 solid, `M` = Mario, one cell = 16 px):

```
start of 1-1, view x -256..0                 1-1's first pit, view x 964..1220
 -128 .................                      -128 ....########...##     <- brick / ? rows
  -64 ................#   <- first ? block    -64 .###.............
  -16 ...M.............                       -16 .......M.........
    0 #################   <- ground (y = 0)     0 ##########...####     <- 3-cell gap, x 1120..1168
```

## 2. Ownership

```
BattleSession / BattleAttackSystem      authoritative: which attacks exist, their order, ACTIVE / RESOLVED, causes
        │  read: get_incoming(PLAYER_ID)          ▲  write (facts only): report_player_incoming_spawned(seq),
        ▼                                         │  resolve_player_incoming(seq, cause), report_enemy_kill(..., origin)
BattleIncomingSpawner (Node, per level, child of BattleHandler, pausable)      the bridge: reconciles, never decides
   ├─ BattleIncomingPlan     (RefCounted, pure)  which pending seq may spawn now: order, grace, gap, hold, relax
   ├─ BattleSpawnPlacer      (static, pure)      where: a floor cell from a solid(cell) / blocked(rect) probe
   └─ BattleEnemyFactory     (static)            Kind -> the game's own PackedScene, metas, tag, parent
Real Goomba / Koopa nodes (unchanged prefabs)    physics, AI, animation, interactions, deaths
Enemy.report_battle_defeat (existing hook)       passes the tag (origin) along with the kill, in Battle only
BattleAttribution (existing, dependency-free)    + origin helpers: tag_incoming(node, ...), origin_of(node)
```

| Layer | Owns | Never does |
|---|---|---|
| `BattleSession` / `BattleAttackSystem` | attacks, order, activation, the `MAX_ACTIVE` slots, resolution, the re-send policy, the new `spawned_tick` fact | touch nodes |
| `BattleIncomingSpawner` | the `seq → node` map of *this level*, delivery timing, despawn detection (pits, off screen, vanished), freeing the incoming nodes it despawns | choose targets, create attacks, resolve on a timer, touch native enemies |
| `BattleIncomingPlan` / `BattleSpawnPlacer` | pure decisions from plain inputs (rows, clocks, a probe) | see the scene tree |
| `BattleEnemyFactory` | the Kind → prefab table (a new `prefab` column in `BattleEnemyType.DATA`), the PackedScene cache, instantiation | gameplay |
| Enemy prefabs and scripts | everything physical, exactly as in Classic | know about Battle (only `Enemy.gd`'s existing Battle-only hook changes, one argument) |
| `BattleScreen` / presentation | showing QUEUED / arriving / in-level (from events) | spawning, resolving |

**Why under `BattleHandler`:** it is already *the* Battle piece in the level, created only in Battle (`LevelClass.gd:119-120`), bound to one session (`bound_session`),
and it leaves with the level. A child spawner inherits all of that. Its nodes live under the level's `Enemies` node, so **nothing can outlive the level**. There are no statics
apart from the factory's PackedScene cache (resources, cleared with the other Battle caches in `BattleScreen._exit_tree`). Not `Enemy.gd` (it would put authority in game objects),
not `BattleScreen` (it sits outside the level, and lives across levels and rounds), not the presentation or previews (read-only by contract, doc 44 §2).

## 3. Data flow

```
session.step()  QUEUED -> ACTIVE (send order, MAX_ACTIVE)                       [existing]
   │ INCOMING_ACTIVATED(seq)
   ▼
spawner._physics_process (game time; frozen by pause, pre-round, death, win)
   1 rows = session.get_incoming(0)         plan.sync(rows): pending = ACTIVE with spawned_tick < 0, in seq order
   2 watch live nodes -> despawn rules       -> session.resolve_player_incoming(seq, DESPAWNED); free the node
   3 seq = plan.next_due(clock, deliverable) (head of pending only; grace, gap)
   4 spot = BattleSpawnPlacer.place(view, mario, kind, probe)   none -> hold (retry every 0.25 s, relax after 3 s)
   5 node = BattleEnemyFactory.create(kind, spot); BattleAttribution.tag_incoming(node, session.uid, seq, sender); add under Enemies
   6 session.report_player_incoming_spawned(seq)  -> spawned_tick, INCOMING_SPAWNED(seq)     (refused => free node: never two)
   7 plan.on_spawned(seq); map[seq] = node
real play ...
   kill path -> Enemy.report_battle_defeat(cause) -> BattleSession.report_enemy_kill(path, source, origin=tag)
             -> origin non-empty: resolve seq (DEFEATED_BY_PLAYER if source == PLAYER else OTHER); no ENEMY_DEFEATED, no SENT
   next frame: rows no longer list seq as ACTIVE -> plan/map drop it (the squishing Goomba is residue)
level leaves the tree -> BattleHandler._exit_tree -> session.resolve_player_spawned(LEVEL_TRANSITION)   (pending ones stay ACTIVE)
player out -> TARGET_OUT (all) / round over -> ROUND_ENDED (all)                                       [existing]
```

**Reconciliation, not event replay.** The bridge re-reads the session's ACTIVE list every physics frame (at most 3 active plus a few queued, read as copies). It is never
out of step after a level reload, a missed event or a second bridge: the session is the truth, and the bridge makes the world match it.
Every kill path reports before it frees (Goomba stomp reports, then squishes for 0.5 s; `summon_shell` reports before `queue_free`; `die*` report first).
So **"node gone while its attack is still ACTIVE" can only mean "not a kill"**. That is how DESPAWNED is safe.

## 4. Attack identity: the tag

* `BattleAttribution.ORIGIN_META := "battle_incoming"`, value `PackedInt64Array([session_uid, seq, sender])`. Absent = a native enemy.
  `tag_incoming(node, uid, seq, sender)` and `origin_of(node) -> PackedInt64Array` (empty for native).
  It lives in `BattleAttribution` because that class is already Enemy's dependency-free Battle helper (doc 43 §5): no new class is reachable from `Enemy.gd`, so no load-order risk (doc 42 §3).
* **Metadata**, because the repo identifies spawned things this way (`block_item`, `no_persist`, `IsPlayerProjectile`, `is_red`), and because it lives on the node itself.
  It survives Goomba `Angry` / `Stomped`, Koopa wing loss, direction changes, and `Node.duplicate()` (spike: the woken Koopa has it, same value).
  `PackedInt64Array` is a value type: a duplicate cannot share or mutate the original's tag.
* **`session_uid`**: `seq` restarts at 0 every round. A new `BattleSession.uid` (a static counter assigned in `_init`, not part of the snapshot) makes a report from a node of an
  earlier round impossible to confuse with this round's attack. (No such node can survive the level replace; this is defence in depth, and tested.)
* Not positional matching, not a node name, not a child component (a component would be duplicated with lost script state, and adds 1 node per enemy).
  The bridge's `seq → node` map is a cache. The tag and the session decide, so the map can be rebuilt or discarded at any time.

## 5. Native vs incoming, and the kill routing

The only change to game code: `Enemy.report_battle_defeat` (`Enemy.gd:23-27`), inside its existing Battle-only branch, passes `BattleAttribution.origin_of(self)` as a third argument:

```gdscript
BattleSession.report_enemy_kill((get_script() as Script).resource_path, BattleAttribution.of(cause), BattleAttribution.origin_of(self))
```

`BattleSession.report_enemy_kill(script_path, source, origin := PackedInt64Array())`:

* **origin empty (native):** unchanged (doc 43): `note_kill(source)`, and a send only for `source == PLAYER` and a supported kind.
* **origin = [uid, seq, sender] (incoming):** counted in a new `attacks.incoming_kill_sources[source]` (not in `defeat_sources`, which keeps meaning "native kills").
  * If `uid == session.uid` and attack `seq` is ACTIVE and spawned: resolve it, `DEFEATED_BY_PLAYER` if `source == PLAYER` (stomp, star, hammer, player fireball,
    player-kicked shell, player-bumped block: the doc 43 matrix), otherwise `OTHER` (another enemy, an unkicked shell, a hazard, an explosion, `die()` with no cause).
    `INCOMING_RESOLVED` carries `source` as an extra field.
  * Otherwise it is **residue** (already resolved, e.g. a woken Koopa or a squishing Goomba) or **stale** (another round): counted, nothing else.
  * **Never** an `ENEMY_DEFEATED`, never a `SENT`, never a `player_rng` draw. The player's defeat count and targeting stream are untouched.

## 6. Re-send rule (recommendation: an incoming enemy's death never sends)

**SMB35** (for reference, not assumed): defeating an "enemy clone" sends a clone onward ([Super Mario Wiki, Enemy clone](https://www.mariowiki.com/Enemy_clone), via search; not verified first-hand).
There, all 35 contestants are real players who must also deal with what they receive.

**Here** the bots never kill what they receive: their incoming enemies add hazard and `EXPIRE` (`BattleAttackSystem.step`), and their sends come from progress (`generate_bot_defeats`).
So a re-send rule would give **only the real player** a second source of sends, proportional to how often they are attacked. With about 23 attacks per match on the player (doc 43 §2),
that could nearly double the player's output, and being targeted would become a resource. Real recursion cannot happen with bots: no chain bot → player → bot → player exists,
because bot sends never depend on what they receive. The risk is balance and farming, not an infinite loop.

Recommended rule, **R0**: **a send is caused only by the defeat of a native enemy; an incoming enemy's death resolves its attack and sends nothing.**
* Testable invariant: every `SENT` from the player follows an `ENEMY_DEFEATED` with the same `defeat` number, and that kill had an empty origin. One defeat gives at most one send.
* Kills the woken-Koopa farm structurally (spike: stomping it sends again today).
* Killing an attacker is still worth it: it removes the danger and frees one of the player's `MAX_ACTIVE` slots.

If SMB35 behaviour is wanted later (**R1**), the plumbing is already there. Set `BattleAttackSystem.RESEND_INCOMING_KILLS := true`. A PLAYER kill of an ACTIVE, spawned incoming
enemy then also calls `report_defeat(PLAYER, kind)`, and the new attack stores `origin_seq = seq` and `generation = 1`. Generation is capped at 1 (a re-sent enemy is never re-sent again),
so chains are bounded and traceable. Residue (resolved tags) never re-sends under either rule.

## 7. Koopa and shell (recommended rule)

1. **The KOOPA attack resolves when the Koopa is turned into a shell.** `KoopaTroopa.summon_shell` → `report_battle_defeat(cause)` (`KoopaTroopa.gd:86`) is exactly where a native Koopa counts as defeated.
   It resolves `DEFEATED_BY_PLAYER` for a stomp or a player-bumped block, `OTHER` otherwise. A Koopa killed outright (fireball, star, hammer, shell) resolves through `die_from_object` / `die_from_hammer`.
2. **The shell is not part of the attack.** It is untagged (spike), untracked, never a sendable kind (shells map to `NONE`, `BattleEnemyType.kind_for_script`), and it lives by native rules:
   kick, combo, and freeing itself on `screen_exited`.
3. **A kill made with that shell follows the victim's origin**, never the shell's. A native victim of a player-kicked shell is a native player kill and sends (doc 43).
   An incoming victim resolves its own attack and sends nothing.
4. **The Koopa that wakes from that shell is residue.** It carries the tag (spike), but its attack is RESOLVED, so its death sends nothing and resolves nothing.
   If it walks off screen it freezes like a native Koopa and goes with the level.

Rejected: keeping the attack ACTIVE while the shell exists. A parked shell would hold one of the player's three slots indefinitely: hold three shells and nothing more can activate.
Also, "stomped = defeated" is SMB's own semantics. Rejected: tagging the shell. No outcome depends on it, and it needs a change in `summon_shell`.
Shell is not made a sendable type.

## 8. Spawn position (`BattleSpawnPlacer`)

Inputs:
* `view`: the GameViewport camera rect, `get_screen_center_position() ± (128, 120)`.
* `mario`: the feet position.
* `kind`: sets the headroom (Goomba 16 px, Koopa 24 px → 2 cells).
* A probe of two callables, `solid(cell: Vector2i) -> bool` and `blocked(rect: Rect2) -> bool`. Live, they are physics point and shape queries: mask 2 for solid, enemy and shell layers 16|32 for blocked.
  In tests they are an ASCII grid.

Constants: `TILE = 16`, `HUD_BAND = 32`, `MIN_AHEAD = 80`, `MIN_BEHIND = 112`, `SEPARATION = 32`, `RETRY = 0.25 s`, `RELAX_AFTER = 3 s`.

1. **Sides.**
   * *Ahead*: columns from the last one fully inside the right edge, moving inward, while the column centre is at least `mario.x + MIN_AHEAD`. The enemy faces −1 (toward Mario).
   * *Behind*, only if ahead yields nothing: columns from the first one fully inside the left edge, moving inward, while the centre is at most `mario.x − MIN_BEHIND`. The enemy faces +1.
   * Ahead is the default because the camera only scrolls right: it is where native enemies appear from, and where the player looks.
     Behind exists for camera-limit screens (level end, `CameraRightLimit`, fixed-camera rooms like 1-1a), where Mario can stand near the right edge.
2. **Floor in a column.** A cell that is `solid`, with the two cells above it empty. Its surface y must lie within `[view.top + HUD_BAND + 32, view.bottom]`
   (fully visible, and not standing in or above the HUD). Of several floors, take the one nearest Mario's feet y; on a tie, the lower one.
   **A column with no floor (a pit, a wall's interior) is skipped, so nothing ever spawns over a pit.**
3. **Footing.** The next column toward Mario has a floor at the same surface y. This avoids landing on a lip and dropping straight into a gap.
4. **Clearance.**
   * `blocked(Rect2(x−12, y−22, 24, 20))` is false: no enemy or shell body there.
   * No live incoming enemy within `SEPARATION` px on the same floor. This catches one spawned last frame that physics has not seen yet.
   * Mario is excluded by the distance rule; the camera walls are layer 1, not in the masks.
5. **First candidate that passes wins** (a fixed order, so deterministic). The position is `(cx·16 + 8, surface_y)`; the prefab's origin is the feet (`Goomba.tscn`: sprite at −8, collision at −6).
   `direction` is toward Mario, then `reset_physics_interpolation()` (physics interpolation is on, `project.godot:611-612`).
6. **No candidate.** Nothing spawns; the head attack stays pending. Retry every `RETRY`. After `RELAX_AFTER` of holding the head attack:
   `MIN_AHEAD 48`, `MIN_BEHIND 80`, footing off. A floor, visibility and clearance are still required. **It is never discarded.**

Why this is fair:
* The earliest contact from ahead is at least 80 px away. A Goomba walks 32 px/s; a running Mario closes about 120 px/s, which is the same reaction window native enemies give.
* On 1-1's first screen the rule picks x = −8, about 200 px ahead of Mario.
* Spawning **inside** the view is required, not cosmetic: beyond the edge the prefab stays frozen (spike), and behind the camera it would never be met.

It does not handle: moving platforms that are not on mask 2 (not floors, skipped), and water levels (the sea floor counts as a floor). Coin heaven has no floors, so attacks are held, then carried.
None of these occur in 1-1 / 1-2; see section 15.

## 9. Delivery pacing (`BattleIncomingPlan`)

| Rule | Value | Why |
|---|---|---|
| Order | strict seq order; a later seq never spawns before an earlier pending one | the authoritative order is send order (`BattleAttackSystem.step`), and it is not altered |
| Level grace | the first spawn waits 1.5 s of bridge time after the level becomes deliverable (1-1: after `GO!`) | no enemy on the first frame of 1-2 or of a sub-area |
| Gap | at least 1.0 s between two spawns | a burst of three activations (one tick) arrives at t, t+1, t+2: about 32 px apart at walking speed |
| Deliverable | `player.state_machine.state.name` in {Normal, WallSlide, Climb}, not `is_dead`, not `in_cutscene`, level not completing (`BattleHandler.level_completed`) | holds during Pipe, FlagPole, LevelExit, Dead, PipeCutscene, Freeze |
| Clock | the bridge's own sum of `_physics_process` deltas (pausable) | freezes in the pause menu, pre-round, death and win, like the Battle clock; deterministic under `--fixed-fps` |
| Live cap | at most `MAX_ACTIVE` (3), by construction: only ACTIVE attacks spawn, and each seq once. Asserted | no extra cap needed (section 12) |
| Never dropped | a held attack stays ACTIVE-pending (and carries over at a transition) until spawned, the player is out, or the round ends | "do not silently discard" |

**Exposed state.** `INCOMING_SPAWNED(seq)` and `spawned_tick` make three states readable from the session: QUEUED, ACTIVE-arriving (not spawned) and ACTIVE-in-level (spawned).
`BattleAttackPresentation` adds `spawned` to `player_incoming()` rows, and the strip can draw "arriving" (lit, blinking edge) apart from "in level" (lit, solid).
Typical latency from activation to spawn is 0 s for a lone attack; a burst spreads by the gap.

## 10. Resolution: real outcomes only

| Real outcome | Detected by | Cause |
|---|---|---|
| stomp, star, hammer, player fireball, player-kicked shell, player-bumped block | the existing kill paths → `report_enemy_kill(..., origin)` | `DEFEATED_BY_PLAYER` |
| killed by anything else (an enemy, an unkicked shell, a hazard, an explosion, `die()`) | the same path, `source != PLAYER` | `OTHER` |
| Koopa stomped or bumped into its shell | `summon_shell` (the same path) | `DEFEATED_BY_PLAYER` / `OTHER`, at that moment |
| fell into a pit | bridge: feet below `view.bottom + 8` | `DESPAWNED`, and the bridge frees it |
| left behind | bridge: more than 16 px left of the view for 0.5 s (with back-scroll on: 6 s) | `DESPAWNED`, freed |
| walked ahead off screen, never caught | bridge: more than 16 px right of the view for 6 s | `DESPAWNED`, freed (a slot cannot be held forever) |
| vanished without a kill report | bridge: invalid, out of the tree or queued for deletion while still ACTIVE, level not completing | `DESPAWNED` |
| level ends (flag, castle, a pipe to a sub-area, a warp, round restart) | `BattleHandler._exit_tree` → `resolve_player_spawned` | `LEVEL_TRANSITION` (spawned only) |
| player eliminated (death, time out) | the session, as today | `TARGET_OUT` (all) |
| round over (win, match finished) | the session, as today | `ROUND_ENDED` (all) |

The bridge's off-screen rules use **camera geometry, never notifier signals**, so they behave the same headless and under GL.
After `level_complete_begin`, `Enemy.flag_die` frees on-screen enemies (`EndFlagpole.gd:28`). The bridge ignores that, and they resolve `LEVEL_TRANSITION` when the level leaves.
**No timer resolves a spawned attack.**

## 11. Level transitions (recommendation: carry what was never spawned)

| Attack state at the transition | Today | Recommended |
|---|---|---|
| QUEUED | carries | carries (unchanged) |
| ACTIVE, spawned (a node in the dying level) | `LEVEL_TRANSITION` | `LEVEL_TRANSITION` |
| ACTIVE, **not yet spawned** | `LEVEL_TRANSITION` | **carries, keeps its slot and its order, and is delivered first** in the next level (after the grace) |

Why:
* An attack that was never materialised has not been in the level that ended. Resolving it throws away an attack nobody saw, just with a recorded cause.
* The 1-1 bonus room is a separate scene, so **every pipe trip is a transition**. Today's rule would let a pipe dive erase up to three pending attacks.
* Spawned enemies physically belong to the freed level (in SMB they do not follow you through a pipe), so ending them is honest. Diving into a pipe to shed spawned enemies costs time, which is fine.

The cost is small:
* `BattleAttack.spawned_tick` (in `to_dict` and the snapshot), and `report_player_incoming_spawned(seq)`, which is refused unless the attack is aimed at the player, ACTIVE, not yet spawned, and the round is open.
* `resolve_player_spawned(cause)`. `BattleHandler._exit_tree` switches to it; `resolve_player_active` stays for tools and tests.
* The next level gets at most `MAX_ACTIVE`, spaced by the gap. That is the same load QUEUED carry-over already produces: queued attacks whose delay has passed activate on the next level's first tick.

`resolve_player_incoming(seq, cause)` stays as permissive as today (existing tests call it on unspawned attacks). The game can only report outcomes for spawned enemies anyway, since only those carry a tag.

## 12. Death, timeout, win, next round, Quit, Classic

* **Death / timeout:** `on_player_died` → `report_ko` → `TARGET_OUT` for everything (existing). The tree is paused, so the bridge stops.
  Spawned nodes stay where they are (the death picture) as residue: no report from them can resolve anything (not ACTIVE; next round: a different uid).
* **Win:** `_finish` → `end_round` → `ROUND_ENDED`. `BattleScreen` freezes the game viewport, so the bridge stops.
* **Next round:** `start_match` → LevelTransition → a new 1-1. `replace_game_scene` frees the old level, with every spawned node under its `Enemies` node, the old handler and the old spawner.
  The new session brings a new uid, seq from 0, and a new spawner under the new handler. Nothing is static. Test: no node anywhere in the tree carries a tag from an earlier uid.
* **Quit:** the session is cleared and the level freed by the title transition. The factory cache clears with the Battle caches.
* **Classic:** no `BattleHandler`, so no spawner. `Enemy.report_battle_defeat` returns at its mode check before reading the tag. No prefab, enemy script, level, spawn or AI behaviour changes.
  Test: a Classic run with a stale session and a *hand-tagged* Goomba reports nothing and spawns nothing.

## 13. Performance

Measured by the spike (headless with the enemies switched on by hand, so this is CPU only; 300 frames; two runs). The extra Goombas were packed 5 px apart and pushing each other, which is a worst case.

| Extra live Goombas | Wall ms per frame (whole Battle screen + level) | Δ |
|---|---|---|
| 0 | 2.13 / 2.27 (again later: 2.35 / 2.05) | — |
| 3 | 3.01 / 2.92 (again later: 2.86 / 2.50) | **+0.5 to 0.8 ms** |
| 10 | 4.93 / 3.70 | +1.5 to 2.8 ms |
| 30 | 7.84 / 7.91 | +5.7 ms (about 0.19 ms each) |

Spawn frame:
* The first `load()` of the prefab takes 2.7 ms (Goomba) / 3.2 ms (Koopa); a cached `load()` takes 6–7 µs. So the factory **preloads when the spawner is created**.
* instantiate + `add_child` + `_ready` (the ResourceSetter theme pass) is a median of **1.07 ms / 1.52 ms**. The gap guarantees at most one per frame.

Under xvfb software GL the frame is about 72 ms, dominated by rasterisation; the enemy delta is lost in it.

**Cap:** the physical concurrency is `MAX_ACTIVE` = 3 by construction, at most 72 extra nodes and under 1 ms. That is in line with what SMB1 already runs on one screen (2–4 enemies in 1-1).
**No separate cap is needed**; assert `live ≤ MAX_ACTIVE`. Revisit only if `MAX_ACTIVE` is raised (10 live ≈ +2 ms).

## 14. Pause: attack flights freeze (doc 44 §12.8)

`BattleScreen` is `PROCESS_MODE_ALWAYS` (`BattleScreen.gd:128`) and advances the presentation with wall-clock `delta` (`:436`).
Fix (one line): `attack_view.update(0.0 if get_tree().paused or game_frozen else minf(delta, MAX_PRESENTATION_STEP))`.
This is the condition that also stops the Battle clock, because `BattleHandler` is pausable. It covers the pause menu, the death and power-up freezes, the pre-round and the win hold.
Lines, target marks, strip flashes and the strip's icon animation all read `attack_view.clock`, so all of them freeze and resume where they were.
Between levels (LevelTransition) the tree is not paused, so lines keep landing. Test: pause mid-flight → `flight.progress(clock)` is unchanged after 60 frames → it resumes.

## 15. Files

| File | Change |
|---|---|
| `Scripts/Classes/Battle/BattleIncomingSpawner.gd` (new) | the bridge (Node) |
| `Scripts/Classes/Battle/BattleIncomingPlan.gd` (new) | pacing and bookkeeping (pure) |
| `Scripts/Classes/Battle/BattleSpawnPlacer.gd` (new) | the placement rule (pure, probe callables) |
| `Scripts/Classes/Battle/BattleEnemyFactory.gd` (new) | the prefab cache, `create(kind, pos, dir)`, metas, parenting under `Enemies` |
| `Scripts/Classes/Battle/BattleEnemyType.gd` | a `prefab` column: `Goomba.tscn`, `GreenKoopaTroopa.tscn` |
| `Scripts/Classes/Battle/BattleAttribution.gd` | `ORIGIN_META`, `tag_incoming`, `origin_of` |
| `Scripts/Classes/Battle/BattleAttack.gd` | `spawned_tick` |
| `Scripts/Classes/Battle/BattleAttackSystem.gd` | `mark_spawned`, `resolve_all(..., spawned_only)`, `incoming_kill_sources`, `RESEND_INCOMING_KILLS := false`; snapshot |
| `Scripts/Classes/Battle/BattleSession.gd` | `uid`; `EventType.INCOMING_SPAWNED` (**appended**, so existing values are unchanged); `report_player_incoming_spawned`; `resolve_player_spawned`; `report_enemy_kill(..., origin)` |
| `Scripts/Classes/Battle/BattleHandler.gd` | creates the spawner in `_ready` (when attacks are on and `BattleIncomingSpawner.enabled`); `_exit_tree` → `resolve_player_spawned` |
| `Scripts/Classes/Entities/Enemy.gd` | passes `origin_of(self)` (Battle branch only) |
| `Scripts/Classes/Battle/BattleAttackPresentation.gd`, `BattleIncomingStrip.gd` | `INCOMING_SPAWNED` → `spawned`; arriving vs in-level |
| `Scripts/Classes/Battle/BattleScreen.gd` | the pause fix; clear the factory cache on exit |
| tests | new suites (section 16); updates to `battle_attack_game_test` (it expects "nothing spawned" and the old transition rule), `battle_attack_screen_test` ("no enemy is spawned"), `battle_attack_test` (transition rule), `battle_attack_view_test` (the new event) |

No change to Goomba.gd, KoopaTroopa.gd, ShellClass.gd, the prefabs, LevelClass.gd, Player.gd, the camera or the level scenes.
`BattleIncomingSpawner.enabled` (a static switch, default true, like `BattleScreen.live_previews` / `BattleSession.default_attacks_enabled`) lets the view-only tests keep testing the strip alone.

## 16. Tests to implement

**Pure, headless** (`tests/battle_incoming_plan_test.gd`):
* *Plan:* an ACTIVE row → pending; spawn order = seq order; head-of-line hold; grace; gap; a burst of 3 → 0 / 1 / 2 s; never more than `MAX_ACTIVE` live; a resolved seq leaves pending and live;
  `on_spawned` twice is ignored; hold states; relax after 3 s; over whole simulated matches (scripted outcomes) the pending list equals the session's ACTIVE-unspawned list at every step (**nothing dropped**).
* *Placer on ASCII maps:* flat ground → the right-edge column; Mario at a camera limit → the behind side; pit columns skipped; a 1-wide lip rejected by footing; a pipe top accepted, a pipe interior rejected;
  wall and block rows with headroom; the HUD band; an occupied box → the next column; separation from another incoming enemy; nothing valid → fail with a reason; relax;
  determinism (the same input → the same output, over 1,000 random maps twice).
* *Session:* the `report_player_incoming_spawned` accept / refuse matrix (unknown, bot target, QUEUED, already spawned, resolved, round ended); the `INCOMING_SPAWNED` event;
  `resolve_player_spawned` resolves spawned only, while pending ones stay ACTIVE in order; `report_enemy_kill` with an origin: PLAYER → `DEFEATED_BY_PLAYER`, otherwise `OTHER`,
  no `ENEMY_DEFEATED` / `SENT`, no `player_rng` draw, `defeats` unchanged; residue and stale uid → nothing; the R0 invariant over full matches; twin-session snapshot determinism.

**Real game, headless** (`tests/battle_incoming_game_test.gd`, `--headless --fixed-fps 60`; a test hook switches spawned enemies on where they must move):
* An ACTIVE attack → **exactly one** node, with the right script (Goomba.gd / KoopaTroopa.gd), the tag (uid, seq, sender), under `Enemies`, `block_item` / `no_persist`; the event logged.
* The spawn point is in the view, on a floor, at least `MIN_AHEAD` from Mario, with no solid or enemy overlap (physics query at the point).
* Three at once: three nodes, in seq order, at least 60 physics frames apart, at distinct positions.
* The kill matrix on spawned enemies (doc 43's paths → `DEFEATED_BY_PLAYER`; enemy / hazard / `die()` → `OTHER`): **no send** for any of them.
* Despawn: left behind → `DESPAWNED` after 0.5 s and freed; dropped into 1-1's first gap (x 1120–1168) → `DESPAWNED`.
* Koopa: a stomp resolves at the shell moment; the shell is untagged; the shell kicked into a native Goomba → a native send; into an incoming Goomba → that one resolves, no send;
  wake → the woken Koopa is tagged, and stomping it gives no send and no resolution.
* Transition: pending attacks carry and are spawned in the next level in order; spawned ones → `LEVEL_TRANSITION`; a pipe into 1-1a does the same.
* Player death with incoming enemies live → `TARGET_OUT`, nothing spawned afterwards; the next round has no tagged node, an empty map and a new uid.
* Win → `ROUND_ENDED`; Quit → nothing left.
* **No duplicate:** a second spawner instance or a level reload never makes a second node for a seq (the session refuses the second spawned report).
* **Classic:** a hand-tagged Goomba with a stale session → no report, no spawner.
* **Repeatability:** the same seed (`BattleHandler.seed_source`) and the same scripted input, twice → identical spawn logs (seq, kind, physics frame, position, direction) and snapshots.

**GL, xvfb** (`tests/battle_incoming_render_test.gd`): the enabler path (a spawned enemy activates on screen and walks toward Mario); a **real physics stomp** resolves `DEFEATED_BY_PLAYER`;
contact hurts Mario like a native enemy; the left-edge freeze is still despawned by the bridge; the enemy's pixels are in the game window; the strip shows arriving vs in-level; pause freezes the lines.

## 17. Smallest implementation milestone (M6a)

**Goal:** one ACTIVE attack on the real player becomes one real Goomba or Koopa in the real level, and its real fate resolves the attack.

1. Session facts:
   * `uid`, `spawned_tick`, `INCOMING_SPAWNED`, `report_player_incoming_spawned`, `resolve_player_spawned` (plus the `BattleHandler._exit_tree` switch).
   * `report_enemy_kill(..., origin)` with R0, and the one-argument change in `Enemy.gd`.
2. The tag helpers in `BattleAttribution`; `BattleEnemyFactory` with the `prefab` column (Goomba and Koopa: the Koopa rules of section 7 need no extra code, only tests).
3. `BattleIncomingPlan` (order, grace, gap, hold, relax) and `BattleSpawnPlacer` (sections 8 and 9 as written).
4. `BattleIncomingSpawner` with the despawn rules of section 10.
5. The one-line pause fix (section 14).
6. Tests: the pure suite, the headless real-game suite, a minimal GL test (enabler + real stomp); update the four existing suites.

**Deferred to M6b:**
* the strip's arriving / in-level drawing (M6a only exposes the `spawned` field);
* any arrival telegraph or visual distinction;
* R1;
* tuning the constants by playtest;
* other enemy types;
* back-scroll-specific polish.

## 18. Unresolved risks

1. **Headless tests cannot move enemies** (the notifier never fires). Physical behaviour needs xvfb GL tests, which are slower. The bridge avoids notifier signals so its logic is testable headless with a switch-on hook.
2. **Placement beyond 1-1 / 1-2 is unverified:** castles with lava floors (lava is not mask 2, so it is not a floor: correct, but long lava screens hold delivery), moving lifts (not floors), water levels, coin heaven (holds).
   The rule degrades to "hold, then carry", never to an unfair spawn, but feel is unknown.
3. **Pacing constants are first guesses** (1.5 s grace, 1.0 s gap, 80 / 112 px, 0.5 s / 6 s despawn). They need a playtest.
4. **Difficulty changes for real:** incoming enemies hurt, shrink and kill Mario through native code. Combined with `MAX_ACTIVE` refilling as the player kills them, the effective pressure is unmeasured.
5. **`SecondQuestReplacer`** (in `Goomba.tscn`) would swap a Goomba for a Buzzy Beetle and drop the tag. Battle forces `second_quest = false`, so it is inert; if that ever changes it shows up as `DESPAWNED`.
6. **The camera rect can be one frame stale** (`CameraHandler.handle_camera` is deferred); the margins absorb it.
7. **The transition rule change** alters existing semantics, and three existing suites need updated expectations.
8. **Spawn hitch:** about 1.1–1.5 ms on the spawn frame (instantiate + theme setup). It is acceptable at one per frame and must not be allowed to batch.
9. **Residue:** a woken Koopa or a frozen squish is never despawned by the bridge (it is not an attack any more). It is harmless and level-scoped, like a native Koopa.

## 19. Decisions for you before implementation

1. **Re-send rule:** R0 (an incoming enemy's death never sends; recommended), or R1 (SMB35-like one-hop re-send)?
2. **Level transitions:** carry ACTIVE-unspawned attacks (recommended; needs `spawned_tick` / `INCOMING_SPAWNED`), or keep today's rule (every ACTIVE attack resolves `LEVEL_TRANSITION`, no session change, but a pipe dive erases pending attacks)?
3. **Sub-areas:** deliver into bonus rooms such as 1-1a (recommended, otherwise a pipe becomes a shelter), or hold there and deliver on return?
4. **Look:** should incoming enemies look different from native ones (SMB35 clones did)? Recommended for M6a: no permanent change. In M6b: a short arrival blink plus the strip.
5. **Constants:** accept the starting values in sections 8–10 for M6a, to be tuned by playtest?
