class_name BattleSendStyle
extends RefCounted
## Every tunable of the player's send animation in one place (doc 51 / doc 52): the reticle's trip from the
## game window to the recipient's pane. Doc 47 B35-TARGET-003 recorded this from the reference at 10 fps and could
## only say it "lands 0.2-0.3 s after it leaves"; this file's HOLD_SECONDS / SECONDS split was unmeasured in doc 51
## because the session that wrote it could not reach the video.
##
## Doc 52 re-measured it directly, frame by frame at the source 60 fps, on two independent sends (t=515.8-516.1 and
## t=527.6-527.9, both in `docs/51-battle-send-presentation.md` section 11). In both, after the bracket leaves its old
## pane it is visible, stationary-ish (it drifts a little inside the window, most likely with the camera/kill scene,
## not with a fixed screen point; doc 47's own off-centre samples are consistent with this and not with a steady glide),
## for about 10-12 frames (0.17-0.2 s) before the NEXT sampled frame already shows it settled on the recipient's pane.
## There is no frame in either clip that shows it part-way across the gold frame or over a pane it is not landing on:
## the crossing itself is at most 1-2 frames (<=0.03 s), i.e. a cut, not a visible glide across the screen. So the
## 0.2-0.3 s doc 47 measured is overwhelmingly a HOLD at the window, with a near-instant snap onto the recipient pane
## at the end of it, not one continuous tween the whole way (what doc 51 shipped, and what commit 3cccc53 built).
## This is the one thing this pass corrects; the window-centre origin question (section 0 below) is left as before.
const SECONDS := 0.22 ## leaves its pane -> lands on the recipient's, doc 52 average of 0.183 s and 0.233 s (doc 47: 0.2-0.3 s)
## The origin is the middle of the game window (BattleAttackGeometry.send_start). Doc 47: 8 of the 10 sampled sends show the
## bracket at the exact window centre (1080p 960,480); the other two are off-centre. Doc 52's two 60 fps clips show the
## bracket drifting a little inside the window while it holds there (consistent with a camera- or kill-anchored point, not
## a fixed screen point) -- this would also explain doc 47's off-centre samples without needing a mid-flight glide, since
## doc 52 found no glide. That reading is not certain enough from two clips to justify the extra hand-off from
## `Enemy.report_battle_defeat` (doc 47's alternative, still not built): the origin stays the window's centre until Zack
## confirms this from more of the video, or the "for Zack" list below is answered.
## Seconds the bracket holds at the origin (visible in the window) before it snaps to the recipient's pane. Doc 52:
## ~10-12 of ~13-14 total frames in both measured sends (about 80-85% of SECONDS), so the remainder is the snap.
const HOLD_SECONDS := 0.18
## The bracket's size at the origin as a multiple of the recipient pane's. UNMEASURED (1: the pane's own size all the way).
const START_SCALE := 1.0
## Doc 47 says "eased"; doc 52 found the snap portion is only 1-2 frames, too short for any curve to read as a glide at
## 60 fps, so the exact curve barely matters now. Kept as ease-out (fast leave, soft landing) pending a sharper measurement.
static func ease(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u
## How long the recipient's pane punches when the bracket lands (the arrival emphasis). UNMEASURED: doc 52's contact
## sheets are not fine enough to confirm or rule out a punch at the moment of landing.
const LANDING_PUNCH_SECONDS := 0.3
