/*
	server/entities/mg42_turret.qc

	Buyable MG42 auto-turret trap. Hold Use to buy; after a warmup it auto-aims
	at the nearest visible zombie/hellhound for TURRET_DURATION, then resets.
	Flat damage (doesn't scale with round). Spawned hardcoded on nzp_kinodertoten.

	Copyright (C) 2021-2024 NZ:P Team
*/

#define TURRET_COST				1250
#define TURRET_WARMUP			3		// seconds calibrating before it fires
#define TURRET_DURATION			60		// seconds of active firing
#define TURRET_DAMAGE			40		// flat per-shot damage (does NOT scale) -- reduced from 100
#define TURRET_FIRE_INTERVAL	0.1		// seconds between shots (MG42 is fast)
#define TURRET_RANGE			1500	// max target distance
#define TURRET_ARC_HALF			70		// +/- degrees from facing (140 total cone)
#define TURRET_KILL_COOLDOWN	4		// seconds the turret idles after each kill
#define TURRET_KILL_SCORE		10		// points awarded to owner per turret kill
#define USEPRINT_TURRET			24		// engine SCR_UsePrint case

.float	turret_phase;		// 0 = idle/buyable, 1 = active (warmup + firing)
.float	turret_warmup_end;	// time warmup finishes and firing begins
.float	turret_endtime;		// time the turret deactivates
.float	turret_fire_next;	// next allowed shot time
.float	turret_kill_cd;		// time the post-kill cooldown ends (hold fire until)
.float	turret_count_sent;	// last countdown value pushed to clients
.vector	turret_rest;		// resting angles to return to when idle

// push the bottom-right countdown to clients via svc_turrettimer
void(float secs) MG42Turret_SendCount =
{
	entity p = find(world, classname, "player");
	while (p != world) {
		msg_entity = p;
		WriteByte(MSG_ONE, SVC_TURRETTIMER);
		WriteByte(MSG_ONE, secs);
		p = find(p, classname, "player");
	}
};

// nearest visible zombie/hellhound in range, or world
entity(entity turret) MG42Turret_FindTarget =
{
	entity	best = world;
	float	bestdist = TURRET_RANGE;
	vector	muzzle = turret.origin + '0 0 20';
	float	pass;
	entity	e;

	for (pass = 0; pass < 2; pass = pass + 1) {
		if (pass == 0)	e = find(world, classname, "ai_zombie");
		else			e = find(world, classname, "ai_dog");

		while (e != world) {
			if (e.health > 0) {
				vector tc = e.origin + '0 0 16';
				float d = vlen(tc - muzzle);
				if (d < bestdist) {
					// Firing-arc limit: ignore targets outside +/- TURRET_ARC_HALF
					// of the mount's facing, so it can't spin a full 180 behind it.
					vector taim = vectoangles(tc - muzzle);
					float yawdiff = taim_y - turret.turret_rest_y;
					while (yawdiff > 180)  yawdiff = yawdiff - 360;
					while (yawdiff < -180) yawdiff = yawdiff + 360;

					if (yawdiff <= TURRET_ARC_HALF && yawdiff >= (0 - TURRET_ARC_HALF)) {
						traceline(muzzle, tc, TRUE, turret);
						if (trace_fraction == 1) {
							best = e;
							bestdist = d;
						}
					}
				}
			}

			if (pass == 0)	e = find(e, classname, "ai_zombie");
			else			e = find(e, classname, "ai_dog");
		}
	}

	return best;
};

// point the gun model at a world position
void(entity turret, vector tc) MG42Turret_AimAt =
{
	vector muzzle = turret.origin + '0 0 20';
	turret.angles = vectoangles(tc - muzzle);
	turret.angles_x = turret.angles_x * -1;		// .mdl pitch convention is flipped
};

// one round at the target: aim, muzzle sound, flat damage
void(entity turret, entity targ) MG42Turret_Fire =
{
	MG42Turret_AimAt(turret, targ.origin + '0 0 16');

	Sound_PlaySound(turret, "sounds/weapons/mg42/shoot.wav", SOUND_TYPE_WEAPON_FIRE, SOUND_PRIORITY_PLAYALWAYS);

	// credit the buyer but DMG_TYPE_OTHER so rapid fire doesn't spam per-hit score
	entity atk = turret.owner;
	if (atk.classname != "player")
		atk = world;

	float prehealth = targ.health;
	DamageHandler(targ, atk, TURRET_DAMAGE, DMG_TYPE_OTHER);

	// on kill: award points and force a cooldown (main balance lever)
	if (prehealth > 0 && targ.health <= 0) {
		turret.turret_kill_cd = time + TURRET_KILL_COOLDOWN;
		if (atk.classname == "player")
			Player_AddScore(atk, TURRET_KILL_SCORE, true);
	}
};

// think loop while live: countdown, warmup, targeting, firing
void() MG42Turret_Active =
{
	if (time >= self.turret_endtime) {
		self.turret_phase = 0;
		self.angles = self.turret_rest;
		MG42Turret_SendCount(0);
		self.turret_count_sent = 0;
		self.think = SUB_Null;
		self.nextthink = -1;
		return;
	}

	// Update the HUD countdown (cap at DURATION so the warmup shows the full time).
	float remaining = ceil(self.turret_endtime - time);
	if (remaining > TURRET_DURATION)
		remaining = TURRET_DURATION;
	if (remaining != self.turret_count_sent) {
		MG42Turret_SendCount(remaining);
		self.turret_count_sent = remaining;
	}

	// Warmup: hold facing forward (calibrating) but hold fire.
	if (time < self.turret_warmup_end) {
		self.angles = self.turret_rest;
		self.nextthink = time + 0.05;
		return;
	}

	// Post-kill cooldown: idle (hold fire) so it can't chain-kill instantly.
	if (time < self.turret_kill_cd) {
		self.nextthink = time + 0.05;
		return;
	}

	entity targ = MG42Turret_FindTarget(self);
	if (targ != world) {
		if (time >= self.turret_fire_next) {
			MG42Turret_Fire(self, targ);
			self.turret_fire_next = time + TURRET_FIRE_INTERVAL;
		} else {
			// keep tracking between shots
			MG42Turret_AimAt(self, targ.origin + '0 0 16');
		}
	}

	self.nextthink = time + 0.05;
};

// charge the buyer and arm the turret
void(entity buyer) MG42Turret_Purchase =
{
	Player_RemoveScore(buyer, TURRET_COST);

	self.owner = buyer;
	self.turret_phase = 1;
	self.turret_warmup_end = time + TURRET_WARMUP;
	self.turret_endtime = self.turret_warmup_end + TURRET_DURATION;
	self.turret_fire_next = 0;
	self.turret_kill_cd = 0;
	self.turret_count_sent = -1;

	Sound_PlaySound(self, "sounds/weapons/mg42/charge.wav", SOUND_TYPE_WEAPON_OTHER, SOUND_PRIORITY_PLAYALWAYS);

	self.think = MG42Turret_Active;
	self.nextthink = time + 0.05;
};

// buy prompt + purchase while idle
void() MG42Turret_Touch =
{
	if (other.classname != "player")
		return;
	if (self.turret_phase != 0)
		return;

	// this turret sits above the FG42 wall-buy, so a player at ground level wants the
	// FG42 -- don't show the turret prompt; reach it from the turret's own level.
	if (other.origin_z < self.origin_z - 40)
		return;

	Player_UseprintWithWait(other, self, USEPRINT_TURRET, TURRET_COST, 0);

	if (Player_UseButtonPressed(other, self) && !(other.semi_actions & SEMIACTION_USE)) {
		other.semi_actions |= SEMIACTION_USE;
		if (other.points >= TURRET_COST) {
			MG42Turret_Purchase(other);
		} else {
			centerprint(other, STR_NOTENOUGHPOINTS);
			Sound_PlaySound(other, "sounds/misc/denybuy.wav", SOUND_TYPE_ENV_CHING, SOUND_PRIORITY_PLAYALWAYS);
		}
	}
};

// place a turret at org facing yaw
void(vector org, float yaw) MG42Turret_Spawn =
{
	precache_model("models/weapons/mg/g_mg.mdl");
	precache_sound("sounds/weapons/mg42/shoot.wav");
	precache_sound("sounds/weapons/mg42/charge.wav");

	entity t = spawn();
	t.classname = "mg42_turret";
	setmodel(t, "models/weapons/mg/g_mg.mdl");
	setorigin(t, org);
	t.angles = [0, yaw, 0];
	t.turret_rest = t.angles;
	t.movetype = MOVETYPE_NONE;
	t.solid = SOLID_TRIGGER;
	setsize(t, '-40 -40 -64', '40 40 64');	// generous so it's easy to reach
	t.touch = MG42Turret_Touch;
	t.turret_phase = 0;
	t.owner = world;
};
