/*
	server/gamemodes/cranked.qc -- "Cranked" gamemode.

	Zombies stream in continuously. Each kill raises your Cranked level (faster
	move/reload/fire, more damage). Go 10s without a kill and your level resets to
	0 and you enter Meltdown -- you bleed toward a self-implosion that downs you,
	and you're one-shottable until you score a kill.
*/

#define CRANKED_MAX_LEVEL	5
#define CRANKED_TIME		10		// flat kill window (seconds)
#define CRANKED_MELT_DPS	10		// meltdown bleed, hp/sec
#define CRANKED_TIER_SECS	30		// difficulty ramps every N seconds
#define CRANKED_PU_SECS		12		// powerup drop window reset

float cranked_tier_deadline;
float cranked_pu_deadline;

float() Gamemode_Cranked_Active =
{
	return Gamemode_CrankedActive();
};

float() Cranked_FastReload =
{
	return self.cranked_level >= 2 && Gamemode_CrankedActive();
};

float() Cranked_FastFire =
{
	return self.cranked_level >= 3 && Gamemode_CrankedActive();
};

void(entity p, float lv, float secs) Cranked_SendHUD =
{
	msg_entity = p;
	WriteByte(MSG_ONE, SVC_CRANKEDSTATUS);
	WriteByte(MSG_ONE, lv);
	WriteByte(MSG_ONE, secs);
};

void() Gamemode_Cranked_Init =
{
	cranked_tier_deadline = 0;
	cranked_pu_deadline = 0;
};

void() Gamemode_Cranked_PlayerSpawn =
{
	self.cranked_level = 0;
	self.cranked_started = 0;	// must earn Lv1 again before meltdown can trigger
	self.cranked_deadline = time + CRANKED_TIME;
	self.cranked_meltdown = 0;
	self.cranked_hud_lv = -1;
	self.cranked_hud_secs = -1;

	cranked_tier_deadline = time + CRANKED_TIER_SECS;
	cranked_pu_deadline = time + CRANKED_PU_SECS;
};

void(entity attacker, float death_style) Gamemode_Cranked_DieHandler =
{
	if (attacker.classname != "player")
		return;

	if (attacker.cranked_meltdown) {
		attacker.cranked_meltdown = 0;
		attacker.cranked_level = 1;
		GiveAchievement(21, attacker);
		centerprint(attacker, "CRANKED  Lv 1");
	} else if (attacker.cranked_level < CRANKED_MAX_LEVEL) {
		attacker.cranked_level = attacker.cranked_level + 1;
		centerprint(attacker, strcat("CRANKED  Lv ", ftos(attacker.cranked_level)));
		if (attacker.cranked_level == CRANKED_MAX_LEVEL)
			GiveAchievement(20, attacker);
	}

	attacker.cranked_started = TRUE;	// cranked up at least once -> meltdown now allowed
	attacker.cranked_deadline = time + CRANKED_TIME;

	if (attacker.weapons[0].weapon_id) {
		float cap = getWeaponAmmo(attacker.weapons[0].weapon_id);
		attacker.weapons[0].weapon_reserve = attacker.weapons[0].weapon_reserve + 2;
		if (attacker.weapons[0].weapon_reserve > cap)
			attacker.weapons[0].weapon_reserve = cap;
	}
};

void(entity p) Cranked_Explode =
{
	CallExplosion(p.origin);
	Sound_PlaySound(p, "sounds/weapons/grenade/explode.wav", SOUND_TYPE_ENV_VOICE, SOUND_PRIORITY_PLAYALWAYS);
	p.cranked_meltdown = 0;
	LastStand_Begin(p);
};

void() Gamemode_Cranked_PlayerPostThink =
{
	if (self.classname != "player" || self.downed || self.health <= 0)
		return;

	float dsecs;

	if (self.cranked_meltdown) {
		self.health_delay = time + 1;
		self.health = self.health - CRANKED_MELT_DPS * frametime;
		if (self.health <= 1) {
			self.health = 1;
			Cranked_Explode(self);
			return;
		}
		if (self.cranked_msg < time) {
			self.cranked_msg = time + 1;
			centerprint(self, "MELTDOWN!  GET A KILL");
		}
		dsecs = 255;
	} else if (!self.cranked_started) {
		// before the first kill: meltdown disarmed, timer idles (no countdown)
		self.cranked_deadline = time + CRANKED_TIME;
		dsecs = CRANKED_TIME;
	} else if (find(world, classname, "ai_zombie") == world) {
		// grace: don't tick the timer until zombies are actually present
		self.cranked_deadline = time + CRANKED_TIME;
		dsecs = CRANKED_TIME;
	} else if (time >= self.cranked_deadline) {
		self.cranked_level = 0;
		self.cranked_meltdown = 1;
		centerprint(self, "MELTDOWN!  GET A KILL");
		dsecs = 255;
	} else {
		dsecs = ceil(self.cranked_deadline - time);
		float remain = self.cranked_deadline - time;
		if (remain < 3 && self.cranked_msg < time) {
			self.cranked_msg = time + 1;
			centerprint(self, strcat("CRANK!  ", ftos(ceil(remain))));
		}
	}

	if (self.cranked_level != self.cranked_hud_lv || dsecs != self.cranked_hud_secs) {
		self.cranked_hud_lv = self.cranked_level;
		self.cranked_hud_secs = dsecs;
		Cranked_SendHUD(self, self.cranked_level, dsecs);
	}
};

void() Gamemode_Cranked_Frame =
{
	if (rounds < 1)
		return;

	if (!cranked_tier_deadline)
		cranked_tier_deadline = time + CRANKED_TIER_SECS;
	if (time >= cranked_tier_deadline) {
		cranked_tier_deadline = time + CRANKED_TIER_SECS;
		rounds = rounds + 1;
		set_z_health();
		if (zombie_spawn_delay > 0.12)
			zombie_spawn_delay = zombie_spawn_delay * 0.92;

		rounds_change = 6;
		blink_return = time + 2;
		Rounds_PlayTransition("sounds/rounds/nround.wav");
	}

	if (!cranked_pu_deadline)
		cranked_pu_deadline = time + CRANKED_PU_SECS;
	if (time >= cranked_pu_deadline) {
		cranked_pu_deadline = time + CRANKED_PU_SECS;
		totalpowerups = 0;
	}
};

float(float current_delay) Gamemode_Cranked_GetRoundDelay =
{
	return time + 0.2;
};

float(float count, float round, float type, float players) Gamemode_Cranked_GetZombieTotalForRound =
{
	return count + round * 2;
};
