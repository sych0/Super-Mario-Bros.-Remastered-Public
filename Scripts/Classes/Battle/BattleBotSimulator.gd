class_name BattleBotSimulator
extends RefCounted
## Abstract per-second bot model. No gameplay AI: bots are stepped numbers.

const BASE_SPEED := 1.0 / 90.0 # levels per second for an average bot
const BASE_RISK := 0.012 # hazard chance per second for an average bot
const ESCALATION_TICKS := 200.0 # hazard roughly doubles after this many seconds
const POWER_CHANCE := 0.35 # chance of gaining a power state on level clear

## Advances `c` by one second. Returns the KoCause if it was knocked out this step.
## `pressure` is the extra hazard from enemies sent to this bot that are active right now (the sum
## of their weights): the hazard is multiplied by (1 + pressure). 0 leaves the bot exactly as it was.
static func step_bot(c: BattleContestant, tick: int, rng: RandomNumberGenerator, pressure := 0.0) -> BattleSession.KoCause:
	c.time_left -= 1
	if c.time_left <= 0:
		return BattleSession.KoCause.TIME
	c.progress += BASE_SPEED * lerpf(0.7, 1.3, c.skill) * rng.randf_range(0.8, 1.2)
	var risk := BASE_RISK * lerpf(1.6, 0.4, c.skill) * (1.0 + tick / ESCALATION_TICKS) * (1.0 + pressure)
	if rng.randf() < risk:
		if c.power > 0:
			c.power -= 1
		else:
			return BattleSession.KoCause.HAZARD
	if c.progress >= 1.0:
		c.levels_cleared += 1
		c.progress = 0.0
		if rng.randf() < POWER_CHANCE and c.power < 2:
			c.power += 1
	return BattleSession.KoCause.NONE
