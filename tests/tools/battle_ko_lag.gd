extends SceneTree
## Development tool (doc 53): how far does an opponent's KO card trail the session's own KO, and how many opponents are
## "dead in the session, no card yet" at any instant? The previews run BattlePreviewDriver.LAG session-seconds behind the
## session and the card waits for the preview's death animation (BattlePreviewCell.marked), while everything the HUD shows from
## the session (the alive badge) is never delayed. This prints the size of that gap over a few whole matches, headless:
##   godot --headless --fixed-fps 60 --path . -s tests/tools/battle_ko_lag.gd
## Output: the card-minus-KO delay in session seconds (measured at quarter-second resolution), and per session tick how many
## opponents the session has out whose card is not up yet (those are the panes a round end would freeze mid-death, doc 51).
## Read-only: it only steps sessions and reads the preview tracks.

const SEEDS := [1, 5, 19, 42, 77, 303, 1234]
const MAX_TICKS := 260
const SUBSTEPS := 4 ## preview updates per session tick

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	var S = load("res://Scripts/Classes/Battle/BattleSession.gd")
	var D = load("res://Scripts/Classes/Battle/BattlePreviewDriver.gd")
	var lags: Array[float] = []
	var pending_samples: Array[int] = []
	var dead_samples: Array[int] = []
	var without_card := 0
	for seed_value in SEEDS:
		var s = S.new(seed_value)
		var d = D.create(s, range(1, 35), 188.0)
		var ko_tick := {} # opponent id -> the session tick of its KO
		var card_at := {} # opponent id -> session time when its preview first showed the KO
		for tick in MAX_TICKS:
			s.step()
			for e in s.events:
				if e.type == S.EventType.KO and e.id != S.PLAYER_ID and not ko_tick.has(e.id):
					ko_tick[e.id] = e.tick
			for k in SUBSTEPS:
				var alpha := float(k) / SUBSTEPS
				d.update(alpha)
				for id in d.tracks:
					if not card_at.has(id) and d.tracks[id].frame.ko_overlay:
						card_at[id] = float(s.tick_count) + alpha
			var dead := 0
			var pending := 0
			for id in range(1, S.CONTESTANT_COUNT):
				if not s.contestants[id].alive:
					dead += 1
					if not (card_at.has(id) and float(card_at[id]) <= float(s.tick_count)):
						pending += 1
			dead_samples.append(dead)
			pending_samples.append(pending)
			if s.finished:
				break
		for id in ko_tick:
			if card_at.has(id):
				lags.append(float(card_at[id]) - float(ko_tick[id]))
			else:
				without_card += 1
	lags.sort()
	var n := lags.size()
	print("preview LAG %.1f s; %d seeds; KOs with a card: %d; KOs whose card had not shown when the run ended: %d" % [D.LAG, SEEDS.size(), n, without_card])
	if n > 0:
		print("card minus session KO (session seconds): min %.2f  p10 %.2f  median %.2f  p90 %.2f  max %.2f" % [lags[0], lags[int(n * 0.1)], lags[n / 2], lags[int(n * 0.9)], lags[n - 1]])
	var total := 0
	var worst := 0
	var some := 0
	var dead_total := 0
	for i in pending_samples.size():
		total += pending_samples[i]
		worst = maxi(worst, pending_samples[i])
		if pending_samples[i] > 0:
			some += 1
		dead_total += dead_samples[i]
	var ticks := maxi(pending_samples.size(), 1)
	print("opponents out in the session with no card yet, per tick: mean %.2f  max %d  ticks with at least one: %d of %d  (mean out in the session %.1f)" % [float(total) / ticks, worst, some, ticks, float(dead_total) / ticks])
	quit(0)
