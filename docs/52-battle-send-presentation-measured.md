# 52 — Battle: the send presentation, measured directly from the reference video

Status: implemented on top of `3cccc53` (doc 51). This session **could** reach `reference.mp4` locally (the container
limitation that blocked doc 51 did not apply here) and used it directly, frame by frame at the source 60 fps, with
`tools/reference/extract_frames.py` contact sheets viewed under the public-video exception (doc 47 §0.1). Doc 47's own
measurements (10 fps) are kept as context; this document corrects the one place direct 60 fps inspection showed
something different.

> **Corrected by [doc 54](54-battle-presentation-measured-from-video.md)**: the "hold ~0.18 s at the window then snap" finding of section 1 was a misreading of coarse contact sheets. At 60 fps (53 of 53 flights) the bracket starts at exactly (240.0, 120.0) and moves in a straight line at **constant speed** for **15 frames = 0.25 s** to the pane's centre. The WATCH OUT! "pulse" of section 2 is a white flash that repeats every 59 frames (doc 54 section 4), and the endpoint of the lines is the pill, not the bar's left end.

## 0. Scope

This is a presentation-only pass on top of doc 51's architecture (`BattleSendStyle`, `BattleAttackFlight`,
`BattleAttackGeometry`, `BattleTargetReticle`). Nothing about targeting, recipients, RNG, send counts, the incoming
queue, spawn placement, bot simulation, the timer or coin economy, or round outcome was touched. The round-end field
freeze from `3cccc53` (results-pane fix) was verified unchanged and still passes (`battle_round_lifecycle_test`).

## 1. What the video actually shows for the player's send

Two independent sends were inspected at the source 60 fps, both named in doc 51 §11:

* `t=515.8 → L22 at t=516.1` (contact sheets `send-515.8_*`, plus a tighter `--window 515.75 516.15` pass)
* `t=527.6 → L12 at t=527.9` (contact sheets `send-527.6_*`, plus a tighter `--window 527.55 527.95` pass)

In both, after the bracket leaves its old pane it appears inside the game window and is visible there for **9–12
consecutive 60 fps frames (0.15–0.2 s)** — the next sampled frame after that already shows it fully formed on the
recipient's pane. There is **no frame in either clip that shows the bracket part-way across the gold frame or over
a pane it does not land on**: the crossing itself is at most 1–2 frames (≤0.03 s). So the 0.2–0.3 s doc 47 measured
at 10 fps (which can't distinguish a hold from a glide) is overwhelmingly a **hold at the window**, ending in a
**near-instant snap** onto the recipient's pane — not one continuous tween the whole way across the screen.

This is the one concrete, two-example-confirmed correction this pass makes.

### 1.1 What 3cccc53 got wrong

`3cccc53` (doc 51) built the one number doc 47 gave (0.2–0.3 s "leaves → lands") as a **continuous 0.25 s eased
tween** from the window's middle to the recipient's pane (`BattleSendStyle.SECONDS = 0.25`, `HOLD_SECONDS = 0.0`,
i.e. it started moving at once). Doc 51 said plainly that the hold/flight split was unmeasured because the video
was unreachable in that session. It is measured now: the bracket does **not** glide across the screen — it holds,
then snaps. The infrastructure for a hold already existed (`BattleAttackFlight.eased()` already subtracted
`HOLD_SECONDS` before applying the curve); only the constants were wrong.

### 1.2 Exact measured timings

| Send | old pane last seen | first seen in window | last seen in window | landed on new pane |
|---|---|---|---|---|
| t≈515.8 | 515.817 | 515.833 | 515.983 | 516.017 |
| t≈527.6 | 527.617 | 527.633 | 527.833 | 527.850 |

Leave-to-land: 0.183 s and 0.233 s (average 0.208 s; doc 47: 0.2–0.3 s — consistent). Window dwell as a fraction of
the total: ~83–86%. The cut itself: ≤1–2 frames in both clips.

**Built**: `BattleSendStyle.SECONDS = 0.22` (leave → land, within doc 47's 0.2–0.3 s and this session's 0.183–0.233 s),
`BattleSendStyle.HOLD_SECONDS = 0.18` (the dwell at the window), leaving ~0.04 s (≈2–3 frames at 60 fps) for the snap
— short enough that any easing curve over it is imperceptible, matching what both clips show.

### 1.3 Geometry: origin

Doc 47's "window centre" reading stands, **with a caveat this session could not resolve**. Watching the bracket's
in-window position across the ~10 held frames of each clip, it is not perfectly stationary: it drifts a little
(more toward the top-right early, settling lower-left as Mario/the camera moves) rather than sitting dead still at
(240, 120). This is consistent with either (a) a fixed window-centre point that is hard to pin to the exact pixel
in compressed 60 fps footage at this scale, or (b) a point anchored to the camera/kill position that happens to be
near the window's middle because SMB35's camera keeps Mario centred. Doc 47's own off-centre samples (1080p
722,385 and 1254,534) would also be explained by (b) without needing a mid-flight glide, now that a glide is ruled
out. **This was not resolved**: two clips at this resolution are not enough to justify building the
`Enemy.report_battle_defeat` kill-position hand-off doc 47 flagged as the alternative (itself still unbuilt, and a
bigger change than this pass's scope). `BattleAttackGeometry.send_start` stays the window's middle. See section 10.

### 1.4 Trajectory / easing

With the crossing compressed to ≤2 frames, the exact easing curve is now nearly unobservable — any curve over 2–3
frames reads the same. `BattleSendStyle.ease` is left as ease-out (unchanged), documented as no longer load-bearing
for how the motion *looks* (it only affects whether 1 or 2 frames show a partial overlap).

### 1.5 Bracket scale and arrival emphasis

No contrary evidence: the bracket's size while held in the window looked comparable to a normal pane bracket in
both clips, consistent with `START_SCALE = 1.0` (unchanged). `LANDING_PUNCH_SECONDS` (0.3 s) is unverified either
way — the contact sheets are not fine enough to confirm or rule out a punch at the instant of landing — left
unchanged (honestly still UNMEASURED).

### 1.6 Rapid consecutive sends

Not independently re-measured this session (doc 51's architecture — one flight per send, independent, in send
order, each landing on its own recipient — is unchanged and still covered by `test_simultaneous_sends`). The video
was not inspected for two overlapping holds in this pass; this remains as doc 51 left it.

## 2. Opponent → player attack

Confirmed by direct inspection (`attacker-517.6` contact sheets, zoomed): a thin, straight red line from the
sender's pane to the left end of the incoming bar, coincident with a **pulsing** WATCH OUT! pill (it blinks on/off
rather than staying lit solid — current code shows it solid for the hold; this is a minor, unmeasured-duration
difference not corrected this pass, since doc 47/51 already flagged the WATCH OUT trigger/duration as only
Strongly inferred and it is outside this pass's primary ask). No other change found; doc 51's line geometry and
endpoint look right by eye.

## 3. Bot → bot

Not re-confirmed by fresh inspection this pass (no frame showed pane-to-pane traffic in any contact sheet taken,
consistent with doc 47/51). Left removed, as before.

## 4. Incoming bar

Spot-checked (`bar-746-754` contact sheets): zones, a diagonal red attacker line into the bar, and a flashing WATCH
OUT! pill are all visible; icon motion in the narrow crop used was not conclusively resolved frame to frame at this
sampling. Not touched this pass — no clear, measurable difference was established strongly enough to justify a
change, and this was not the primary ask.

## 5. KO presentation

Spot-checked against `ko-524.4-527.3` contact sheets by eye: a pane visibly changes through this window (flash-like
brightening, a card forming) consistent with doc 50's already-built 0.8 s sequence. Nothing was measured precisely
enough (at this contact-sheet resolution) to justify changing doc 50's numbers, and the accepted-state note for this
task says KO presentation was not the identified problem. Not changed.

## 6. Files changed

* `Scripts/Classes/Battle/BattleSendStyle.gd` — `SECONDS` 0.25 → 0.22, `HOLD_SECONDS` 0.0 → 0.18, updated doc
  comments with the measurement basis. `START_SCALE`, `ease()`, `LANDING_PUNCH_SECONDS` unchanged (still
  unmeasured, documented as such).
* `Scripts/Classes/Battle/BattleAttackFlight.gd`, `BattleTargetReticle.gd` — doc-comment corrections only (no
  behaviour change beyond what the new constants already produce through the existing hold/ease machinery).
* `tests/battle_attack_view_test.gd` — `test_flights_from_sends` and `test_flight_timing` rewritten to assert the
  hold-then-snap shape (progress is exactly 0 through `HOLD_SECONDS`, then increases to 1 by `SECONDS`) instead of
  the old "past half at half duration" assumption; the hard-coded `0.25` check is now a range check consistent with
  doc 47 (0.2–0.3 s). Added a `SS` (`BattleSendStyle`) loader, matching the file's existing `load()` pattern for
  global classes (needed because the GL/headless class cache in this checkout had never indexed `BattleSendStyle`
  as a global class until this session ran the editor once to rebuild `.godot/global_script_class_cache.cfg` —
  pre-existing environment gap, not part of the code change).
* `tests/battle_attack_render_test.gd` — `test_player_send` rewritten to sample two moments (inside the hold; past
  it) instead of one mid-flight sample at a fixed time fraction that assumed linear progress; the mid-flight
  overlap assertion (bracket is visually between the window and the pane) is dropped because that moment is now
  ≤2 frames and not a reliable thing to poll for over real wall-clock frames.
* `tests/battle_incoming_game_test.gd` — one comment updated (no assertion change).
* `docs/52-battle-send-presentation-measured.md` — this document.

## 7. Tests

Headless (`godot --headless --fixed-fps 60 --path . -s tests/<suite>.gd`), run individually:

| Suite | Result |
|---|---|
| `battle_attack_view_test` | **pass** (rewritten send-timing assertions) |
| `battle_ui_test` | pass |
| `battle_hud_test` | pass |
| `battle_round_test` | pass |
| `battle_round_lifecycle_test` | pass (results-field freeze from `3cccc53` verified intact) |
| `battle_screen_test` | pass |
| `battle_session_test` | pass |
| `battle_attack_test` | pass |
| `battle_targeting_test` | pass |
| `battle_incoming_plan_test` | pass |
| `battle_incoming_view_test` | pass |
| `battle_incoming_game_test` | pass |
| `battle_arrival_game_test` | pass |
| `battle_attack_game_test` | pass |
| `battle_preview_atlas_test` | pass |
| `battle_preview_test` | pass |
| `battle_attack_screen_test` | pass (run alone; doc 51 already notes it is timing-sensitive under heavy parallel load) |

GL (`godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1920x1080
--fixed-fps 60 -s tests/<suite>.gd`; this machine has no `xvfb`, but a real GL context is available directly — no
`xvfb-run` wrapper was needed or used):

| Suite | Result |
|---|---|
| `battle_attack_render_test` | **pass** on the send-related checks (rewritten `test_player_send`); 3 unrelated failures remain (preview halo-pixel count, an ACTIVE-flash icon sample, one dim-icon sample) — all in incoming-bar/preview code this pass did not touch |
| `battle_incoming_render_test` | pass |
| `battle_arrival_render_test` | pass |
| `battle_preview_render_test` | 1 unrelated failure (720p fractional preview-cell bleed) |
| `battle_screen_render_test` | 2 unrelated failures (win-fade dimming the window / its corners) |

**The 6 unrelated failures were confirmed pre-existing**, not introduced by this pass: `BattleAttackFlight.gd`,
`BattleSendStyle.gd`, `BattleTargetReticle.gd` and the touched tests were stashed and `battle_attack_render_test`
was re-run against the untouched baseline. The baseline run **also failed on the send test** (`its bracket is drawn
on screen where the flight says (0.78 of the way: 0 of 4 corners red)` — the exact kind of frame-timing flakiness
this pass's `wait_flight`-based rewrite fixes) and showed the same halo-pixel and ACTIVE-flash failures. None of the
remaining 6 failures touch `BattleSendStyle`, `BattleAttackFlight`, `BattleTargetReticle`, `BattleAttackGeometry` or
`BattleAttackLayer`; they are in preview-cell rendering and the window's results-fade, both out of this pass's scope
and present before this pass's changes. They are reported here, not fixed.

A stale `.godot/global_script_class_cache.cfg` (missing `BattleSendStyle` and others) blocked every suite until the
editor was run once (`godot --headless --editor --quit --path .`) to rebuild it — an environment gap in this
checkout, unrelated to any code change.

## 8. Build / install

No build, sign, install or launch was performed (none of this project's test scripts need it for headless/GL
verification; this is a GDScript project run directly by the Godot binary, not a native Apple build).

## 9. Unchanged, verified

`BattleSession`, `BattleAttackSystem`, targeting policies, bot simulation, spawn placement, the timer and coin
code: not touched. `battle_session_test`, `battle_attack_test`, `battle_targeting_test` pass unchanged.
`battle_attack_view_test`'s own replay-determinism checks (same match, same deltas ⇒ identical presented sequence)
still pass with the new constants plugged in. The results-field freeze (`3cccc53`) is unchanged and its test still
passes (`battle_round_lifecycle_test.test_results_field_frozen`); the known edge case it left open (a KO within the
last ~2 s of a round can freeze mid-death-animation, since previews trail the session by ~2 s) was not touched or
re-investigated this pass — fixing it would mean changing when the preview driver stops trailing, which is a
lifecycle change, not a presentation-only one, and was not asked for.

## 10. Open questions for Zack

* Confirm or correct the hold/snap finding by eye against the two timestamp pairs in section 11 below — this is
  the one thing this pass changed.
* The origin point (window centre vs. a camera/kill-anchored point, section 1.3): unresolved with two clips. If
  Zack can tell by eye whether the bracket is dead-still at the window's exact middle or visibly drifts with Mario
  while it holds, that answers it without needing the `Enemy.report_battle_defeat` hand-off.
* The WATCH OUT! pill: this pass noticed it pulses in the reference rather than staying solid; not corrected
  (unmeasured duration/rate, and outside the primary ask).

## 11. For Zack: exact timestamps to compare

* **The send (the thing this pass changed)**: watch 515.8–516.1 and 527.6–527.9 frame by frame (or scrub a 60 fps
  player). The bracket should sit still-ish in the window for about 0.15–0.2 s, then snap onto the recipient's pane
  within 1–2 frames — not glide smoothly across the screen.
* Everything else in doc 51 §11 (sends at 526.7–526.9, 528.5–528.7; the centred appearances at 536.7, 537.6, 548.7,
  561.9, 607.7, 618.7; the retarget sweep 163.60–163.70; attacker lines/WATCH OUT! at 517.6 and 1000; the incoming
  bar at 512–523 and 746–754; the KO at 524.4–527.3) was not re-measured to doc-51-closing precision this pass and
  stands as before.
