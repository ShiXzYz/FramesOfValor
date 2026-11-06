-- Parry calculations: whether a raised guard stops an incoming attack.
--
-- While guarding, the player tilts the sword in the plane of the screen. `tilt` is the
-- blade's angle from upright, in radians: 0 = point straight up, +90° = point to the
-- right, -90° = point to the left (flat across). To stop a swing the blade has to cross
-- the weapon's path, so the closer the blade is to perpendicular to the swing, the
-- better. Thrusts are knocked aside by a diagonal blade. Hits without a weapon to catch
-- (a slime's body or goo) only need the guard up.
--
-- Used by the server (server/Guard decides every hit) and the client (to show the
-- guard). Each result is one of:
--   "parry" - raised just in time at a good angle: no damage, and the attacker staggers
--   "block" - a decent angle, but not in the parry window: no damage, costs shield
--   "miss"  - the blade doesn't cross the attack: it gets through and knocks the guard down

local ParryRules = {}

ParryRules.MAX_TILT = math.rad(90)
ParryRules.PARRY_WINDOW = 0.3 -- seconds from raising the guard in which a hit can be parried
ParryRules.PARRY_TOLERANCE = math.rad(22) -- how far off the ideal angle still parries...
ParryRules.BLOCK_TOLERANCE = math.rad(40) -- ...and still blocks
ParryRules.THRUST_ANGLE = math.rad(45) -- a diagonal blade, leaning either way, turns a thrust aside

export type Profile = {
	kind: "swing" | "thrust" | "any",
	-- For swings: the way the weapon travels as it reaches the defender, as the attacker
	-- sees it (+X = the attacker's right, +Y = up).
	direction: Vector2?,
}

-- How each attack reaches the defender. Attacks not listed here count as "any".
ParryRules.ATTACKS = {
	GoblinChop = { kind = "swing", direction = Vector2.new(0, -1) }, -- straight down from overhead
	GoblinSlash = { kind = "swing", direction = Vector2.new(-1, -0.15).Unit }, -- its right to its left, dipping slightly
	GoblinStab = { kind = "thrust" },
	SlimeTackle = { kind = "any" },
	SlimeGoo = { kind = "any" },
} :: { [string]: Profile }

local ANY: Profile = { kind = "any" }

-- The blade's direction on screen (+X right, +Y up) for a tilt.
function ParryRules.bladeAxis(tilt: number): Vector2
	return Vector2.new(math.sin(tilt), math.cos(tilt))
end

-- How far the guard is from the ideal angle for this attack, 0 to 90° (in radians).
function ParryRules.angleError(profile: Profile, tilt: number): number
	if profile.kind == "thrust" then
		return math.abs(math.abs(tilt) - ParryRules.THRUST_ANGLE)
	elseif profile.kind == "swing" and profile.direction then
		-- Facing the attacker, its right is the defender's left, so mirror the swing.
		local swing = Vector2.new(-profile.direction.X, profile.direction.Y)
		local along = math.abs(ParryRules.bladeAxis(tilt):Dot(swing)) -- 0 = blade perpendicular to the swing
		return math.pi / 2 - math.acos(math.clamp(along, 0, 1))
	end
	return 0
end

-- Judges a hit landing on a raised guard. `sinceRaise` is seconds since the guard went up.
function ParryRules.judge(attackName: string, tilt: number, sinceRaise: number): ("parry" | "block" | "miss", number)
	local profile = ParryRules.ATTACKS[attackName] or ANY
	local angleError = ParryRules.angleError(profile, tilt)
	if sinceRaise <= ParryRules.PARRY_WINDOW and angleError <= ParryRules.PARRY_TOLERANCE then
		return "parry", angleError
	elseif angleError <= ParryRules.BLOCK_TOLERANCE then
		return "block", angleError
	end
	return "miss", angleError
end

return ParryRules
