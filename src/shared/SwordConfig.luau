-- Tuning values shared by the client (hit detection) and server (validation + damage).
local SwordConfig = {
	BladeLength = 5,

	-- Speed (studs/second) of the blade at the point of contact.
	-- Slower than MinHitSpeed doesn't count as a hit; MaxHitSpeed and above deals MaxDamage.
	MinHitSpeed = 22,
	MaxHitSpeed = 90,
	MinDamage = 4,
	MaxDamage = 35,

	-- Seconds before the same dummy can be hit again by the same player.
	HitCooldown = 0.3,

	-- Server-side sanity check: max distance from the player's root to the reported hit point.
	MaxReach = 14,
}

function SwordConfig.damageForSpeed(speed: number): number
	local alpha = math.clamp(
		(speed - SwordConfig.MinHitSpeed) / (SwordConfig.MaxHitSpeed - SwordConfig.MinHitSpeed),
		0,
		1
	)
	return math.floor(SwordConfig.MinDamage + (SwordConfig.MaxDamage - SwordConfig.MinDamage) * alpha + 0.5)
end

return SwordConfig
