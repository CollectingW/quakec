/*
	server/gamemodes/skull_ball.qc -- "Skull Ball" gamemode.

	A skull spawns on the floor at a random map location. One player picks it
	up and must carry it to a pedestal that appears elsewhere on the map.
	While carrying the skull the bearer cannot sprint and is slowed slightly.
	Zombies stream in continuously (Cranked-style waves, 999 per round) and
	difficulty ramps every 45 seconds.  Delivering the skull earns team points
	and relocates both the skull AND the pedestal to new positions.

	Copyright (C) 2024-2025 NZ:P Team
*/

// ---------------------------------------------------------------------------
// Tuneables
// ---------------------------------------------------------------------------
#define SB_TIER_SECS        45      // difficulty ramp interval (seconds)
#define SB_DELIVER_POINTS   500     // team points per delivery
#define SB_CARRY_SPEEDMULT  0.72    // bearer movement fraction
#define SB_SKULL_BOB_SPEED  2.0     // skull hover bob speed
#define SB_SKULL_BOB_AMP    6.0     // skull hover bob amplitude (qu)
#define SB_PICKUP_DIST      48      // distance to auto-pick up skull
#define SB_CATCH_DIST       110     // generous radius to CATCH a thrown skull (passing)
#define SB_DELIVER_DIST     72      // distance to deliver skull to pedestal
#define SB_MAX_ANCHORS      64

#define SB_THRALL_SECS      15      // how long a reanimated thrall fights for you
#define SB_THRALL_SPEED     26      // chase speed -- a sprinter (zombie run is ~13)
#define SB_THRALL_STEP      24      // movetogoal step per think (~240 u/s at 0.1s)
#define SB_THRALL_KILL_DIST 60      // melee reach -- zombies in range get mauled
#define SB_THRALL_HUNT_RANGE 1100   // only hunt zombies within this of the thrall
#define SB_THRALL_FLOOR_DZ  96      // only target zombies on roughly the same floor
#define SB_THRALL_ATTACK_CD 1.0     // seconds between swipes (rate-limit so it's not OP)
#define SB_THRALL_GLOW      70      // green dlight radius (light_lev)
#define SB_THRALL_KILL_PTS  10      // points awarded to the owner per thrall kill
#define SB_THROW_SPEED      850     // head throw velocity (grenade-like lob)
#define SB_THROW_GRACE      0.6     // seconds after a throw before it can be re-grabbed

#define SB_BUTCHER_INTERVAL 90      // seconds between Butcher miniboss appearances
#define SB_BUTCHER_HP_MULT  5       // Butcher health = z_health * this
#define SB_GOLD_POINTS      1000    // bounty for delivering the golden (butcher) head
#define SB_GOLD_DELIVER_DIST 120    // butcher body has a slightly larger delivery radius
#define SB_BUTCHER_POWERUPS 3       // random power-ups dropped at the Butcher Body delivery

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
float  skullball_tier_deadline;
float  skullball_setup_done;
float  skullball_deliveries;        // total deliveries this session
entity skullball_skull_ent;         // the floating skull entity
entity skullball_pedestal_ent;      // the glowing pedestal entity
entity skullball_carrier;           // player currently holding the skull (world = nobody)
float  skullball_skull_spawn_time;  // used for bobbing animation

vector skullball_anchors[SB_MAX_ANCHORS];
float  skullball_anchor_count;
float  skullball_anchors_ready;     // anchors collected once per map (survive restart)
float  skullball_last_skull_idx;
float  skullball_last_ped_idx;
float  skullball_last_bskull_idx;	// butcher head's current anchor (-1 = none)
float  skullball_last_bped_idx;		// butcher body's current anchor (-1 = none)

entity skullball_skull_indicator;
entity skullball_pedestal_indicator;

float  skullball_thralls_given;     // total thralls reanimated (-> "Back For Blood")
float  skullball_traitor_done;      // first thrall kill unlocked "Traitor" yet?
float  skullball_throw_grace;       // re-pickup lockout window after a throw
entity skullball_butcher;           // the promoted Butcher zombie (world = none)
float  skullball_butcher_next;      // earliest time the next Butcher may appear
float  skullball_gold_active;       // TRUE while the butcher skull/body objective is live
entity skullball_bskull_ent;        // the golden butcher head (carried on the LEFT hip)
entity skullball_bpedestal_ent;     // the "Butcher Body" delivery point
entity skullball_bcarrier;          // player carrying the butcher head (world = nobody)
entity skullball_bskull_indicator;
entity skullball_bpedestal_indicator;
entity skullball_butcher_indicator; // marker floating over the live Butcher

#define ACH_SB_BACK_FOR_BLOOD   22
#define ACH_SB_TRAITOR          23
#define SB_BACK_FOR_BLOOD_COUNT 50

// ---------------------------------------------------------------------------
// Anchor collection (reuse hardpoint's proven fallback chain)
// ---------------------------------------------------------------------------
void(vector org, float is_floor) SkullBall_AddAnchor =
{
	if (skullball_anchor_count >= SB_MAX_ANCHORS)
		return;

	// snap to floor
	traceline(org + '0 0 64', org - '0 0 4096', TRUE, world);
	if (trace_fraction < 1)
		org = trace_endpos + '0 0 2';

	skullball_anchors[skullball_anchor_count] = org;
	skullball_anchor_count = skullball_anchor_count + 1;
};

void(string cname) SkullBall_CollectClass =
{
	entity e = find(world, classname, cname);
	while (e != world) {
		vector org = e.origin;
		makevectors(e.angles);
		org = org + v_forward * 48; // spawn 48 units in front of the start point / machine
		SkullBall_AddAnchor(org, TRUE);
		e = find(e, classname, cname);
	}
};

void() SkullBall_LoadFile =
{
	float f = fopen(strcat(mappath, ".hpt"), FILE_READ);
	if (f == -1)
		return;

	string line = fgets(f);
	while (line != "") {
		vector org = stov(line);
		if (org != '0 0 0') {
			traceline(org + '0 0 64', org - '0 0 4096', TRUE, world);
			if (trace_fraction < 1)
				org = trace_endpos + '0 0 2';
			SkullBall_AddAnchor(org, TRUE);
		}
		line = fgets(f);
	}
	fclose(f);
};

void() SkullBall_OpenAllDoors =
{
	entity old_self = self;
	string classes[3];
	classes[0] = "door_nzp_cost";
	classes[1] = "door_nzp";
	classes[2] = "door_open";

	float i;
	for (i = 0; i < 3; i = i + 1) {
		entity d = find(world, classname, classes[i]);
		while (d != world) {
			entity nextd = find(d, classname, classes[i]);
			if (!d.isopen && d.state != STATE_TOP) {
				self = d;
				door_go_up();
			}
			d = nextd;
		}
	}
	self = old_self;
};

void() SkullBall_CollectAnchors =
{
	skullball_anchor_count = 0;

	// 1) Load .hpt file if available (this covers NDU's hardpoint coordinates)
	SkullBall_LoadFile();

	// 2) Load info_hardpoint entities if present
	entity e = find(world, classname, "info_hardpoint");
	while (e != world) {
		SkullBall_AddAnchor(e.origin, TRUE);
		e = find(e, classname, "info_hardpoint");
	}

	// 3) Only if no anchors were found (i.e. first two methods empty), use fallbacks
	if (skullball_anchor_count == 0) {
		SkullBall_CollectClass("info_player_start");
		SkullBall_CollectClass("info_player_1_spawn");
		SkullBall_CollectClass("info_player_2_spawn");
		SkullBall_CollectClass("info_player_3_spawn");
		SkullBall_CollectClass("info_player_4_spawn");
		SkullBall_CollectClass("perk_juggernog");
		SkullBall_CollectClass("perk_speed");
		SkullBall_CollectClass("perk_revive");
		SkullBall_CollectClass("perk_double");
	}

	// Always guarantee at least 2 anchors even on sparse maps
	if (skullball_anchor_count < 2) {
		SkullBall_AddAnchor('0 0 0', TRUE);
		SkullBall_AddAnchor('128 128 0', TRUE);
	}
};

// pick a random anchor index, avoiding up to 4 occupied slots (-1 = unused).
// Relaxes the constraint if the map has too few anchors.
float(float e0, float e1, float e2, float e3) SkullBall_PickAnchorFree =
{
	if (skullball_anchor_count <= 1)
		return 0;

	float idx;
	float attempt;

	// Phase 1: avoid ALL four occupied anchors (32 tries)
	for (attempt = 0; attempt < 32; attempt = attempt + 1) {
		idx = rint(random() * (skullball_anchor_count - 1));
		if (idx != e0 && idx != e1 && idx != e2 && idx != e3)
			return idx;
	}

	// Phase 2: relax to just the two primary conflicts (16 tries)
	for (attempt = 0; attempt < 16; attempt = attempt + 1) {
		idx = rint(random() * (skullball_anchor_count - 1));
		if (idx != e0 && idx != e1)
			return idx;
	}

	// Phase 3: last resort -- avoid only self (stop repeating own last spot)
	for (attempt = 0; attempt < 8; attempt = attempt + 1) {
		idx = rint(random() * (skullball_anchor_count - 1));
		if (idx != e0)
			return idx;
	}

	// Absolute fallback: anything goes (map has only 1 viable anchor)
	return rint(random() * (skullball_anchor_count - 1));
};

// ---------------------------------------------------------------------------
// Entity helpers
// ---------------------------------------------------------------------------
entity() SkullBall_SpawnSkull =
{
	entity e = spawn();
	e.classname = "skullball_skull";
	e.movetype  = MOVETYPE_NONE;
	e.solid     = SOLID_NOT;
	setmodel(e, "models/ai/zh^.mdl");	// the zombie HEAD you carry
	e.effects   = EF_REDLIGHT;		// soft red aura while on the ground (cleared while carried)
	e.light_lev = 48;			// SMALL radius -> glows on the head, not the whole floor
	return e;
};

entity() SkullBall_SpawnPedestal =
{
	entity e = spawn();
	e.classname = "skullball_pedestal";
	e.movetype  = MOVETYPE_NONE;
	e.solid     = SOLID_NOT;
	setmodel(e, "models/ai/zb%.mdl");	// the headless zombie BODY (delivery target)
	e.effects   = EF_REDLIGHT;		// soft red aura
	e.light_lev = 60;			// small radius (body is taller than the head)
	return e;
};

void(entity e, vector floorpos, float zoffset) SkullBall_PlaceAt =
{
	setorigin(e, floorpos + ('0 0 1' * zoffset));
	// tall bbox so a head whose origin sits below the floor still touches the
	// play-area leaf above it, otherwise the server PVS-culls it from close above.
	setsize(e, '-16 -16 0', '16 16 48');
};

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------
void() SkullBall_PlaceSkull =
{
	// Avoid all currently live spots: regular skull (self), pedestal, butcher head, butcher body
	float idx = SkullBall_PickAnchorFree(skullball_last_skull_idx, skullball_last_ped_idx, skullball_last_bskull_idx, skullball_last_bped_idx);
	skullball_last_skull_idx = idx;
	// clear any leftover throw physics, then drop it on the floor. (Do NOT touch
	// the butcher/gold objective here -- it's a separate entity now.)
	skullball_skull_ent.movetype  = MOVETYPE_NONE;
	skullball_skull_ent.solid     = SOLID_NOT;
	skullball_skull_ent.velocity  = '0 0 0';
	skullball_skull_ent.avelocity = '0 0 0';
	skullball_skull_ent.scale     = 1;
	// head model sits +26..+40 above its origin, so offset DOWN to rest on the floor
	SkullBall_PlaceAt(skullball_skull_ent, skullball_anchors[idx], -22);
	skullball_skull_ent.effects = EF_REDLIGHT;	// aura back on (was cleared while carried)
	skullball_skull_ent.light_lev = 48;
	skullball_skull_spawn_time = time;
	if (skullball_skull_indicator != world) {
		setmodel(skullball_skull_indicator, "models/sprites/skullball_arrow_b.spr");	// HEAD marker
		skullball_skull_indicator.effects = EF_HARDPOINT;
		setorigin(skullball_skull_indicator, skullball_skull_ent.origin + '0 0 66');
	}
};

void() SkullBall_PlacePedestal =
{
	vector old_org = skullball_pedestal_ent.origin;	// where it was, for the trail

	// Must differ from all currently occupied anchors
	float idx = SkullBall_PickAnchorFree(skullball_last_ped_idx, skullball_last_skull_idx, skullball_last_bskull_idx, skullball_last_bped_idx);
	skullball_last_ped_idx = idx;
	// body feet are -33 below its origin, so offset UP so it stands on the floor
	SkullBall_PlaceAt(skullball_pedestal_ent, skullball_anchors[idx], 33);

	// red ghost-trail line from the old spot to the new one (skip the first
	// placement, when it was parked off-map at z -16000).
	if (old_org_z > -10000) {
		float f;
		for (f = 0; f <= 1.0; f = f + 0.05) {
			vector p = old_org + (skullball_pedestal_ent.origin - old_org) * f;
			particle(p + '0 0 30', '0 0 18', 251, 6);	// 251 = bright red
		}
	}
	if (skullball_pedestal_indicator != world) {
		setmodel(skullball_pedestal_indicator, "models/sprites/skullball_arrow.spr");	// BODY marker (normal)
		skullball_pedestal_indicator.effects = EF_HARDPOINT;
		setorigin(skullball_pedestal_indicator, skullball_pedestal_ent.origin + '0 0 44');
	}
};

// ---------------------------------------------------------------------------
// Thrall -- feed a head to a body and it reanimates (head restored) as a
// short-lived ally that hunts and kills other zombies before collapsing.
// ---------------------------------------------------------------------------
entity() Thrall_FindTarget =
{
	entity best = world;
	float  bestd = SB_THRALL_HUNT_RANGE;
	entity z = find(world, classname, "ai_zombie");
	while (z != world) {
		// only live, in-bounds zombies (outside==FALSE excludes ones still
		// behind barricades / out of the play area) on roughly our floor.
		if (z.health > 0 && !z.deadflag && z.takedamage != DAMAGE_NO
		    && z.outside == FALSE
		    && !z.is_butcher				// thralls should NEVER one-shot the Butcher
		    && fabs(z.origin_z - self.origin_z) <= SB_THRALL_FLOOR_DZ) {
			float d = vlen(z.origin - self.origin);
			if (d < bestd) {
				// reachable in a straight line (no wall/floor between us)?
				traceline(self.origin + '0 0 24', z.origin + '0 0 24', TRUE, self);
				if (trace_fraction >= 0.92 || trace_ent == z) {
					bestd = d;
					best = z;
				}
			}
		}
		z = find(z, classname, "ai_zombie");
	}
	return best;
};

void() Thrall_Think =
{
	self.nextthink = time + 0.1;

	// lifetime expired -> collapse into gibs
	if (time >= self.ltime) {
		float g;
		for (g = 0; g < 16; g = g + 1)
			particle(self.origin + '0 0 24', '0 0 40', 73, 8);	// dark red gib spray
		Zombie_PlaySoundType(ZOMBIE_SOUND_TYPE_DEATH);
		remove(self);
		return;
	}

	// mid-swing / cooldown: hold the swipe animation, don't attack again yet
	if (self.wait > time) {
		if (self.frame < 102 || self.frame >= 106)
			self.frame = 102;
		else
			self.frame = self.frame + 1;
		return;
	}

	entity tgt = Thrall_FindTarget();
	if (tgt == world) {
		self.frame = 0;		// nothing to hunt: idle
		return;
	}

	float d = vlen(tgt.origin - self.origin);
	if (d <= SB_THRALL_KILL_DIST) {
		// swipe: one-shot kill, reward the owner, then rate-limit the next swing
		self.angles_y = vectoyaw(tgt.origin - self.origin);
		DamageHandler(tgt, self, 100000, DMG_TYPE_ZOMBIESWIPE);
		Zombie_PlaySoundType(ZOMBIE_SOUND_TYPE_MELEE);
		if (self.owner != world && self.owner.classname == "player") {
			Player_AddScore(self.owner, SB_THRALL_KILL_PTS, false);
			
			float thk = cvar("nzp_thrall_kills") + 1;
			cvar_set("nzp_thrall_kills", ftos(thk));
			
			if (thk == 100) {
				GiveAchievement(28, self.owner);
				centerprint(self.owner, "No Strings Attached unlocked!\nPuppeteer ready in Loadout.");
			} else if (thk < 100 && thk == floor(thk / 10) * 10) {
				string s1 = strcat("No Strings Attached: ", ftos(thk));
				string s2 = strcat(s1, "/100");
				centerprint(self.owner, s2);
			}

			// Leveling up Puppeteer on total thrall kills:
			// Level 2: 250, Level 3: 450, Level 4 (Pro): 700.
			float oldlvl = cvar("nzp_puppet_level");
			if (oldlvl < 1) oldlvl = 1;
			float newlvl = 1;
			if (thk >= 700) newlvl = 4;
			else if (thk >= 450) newlvl = 3;
			else if (thk >= 250) newlvl = 2;

			if (newlvl > oldlvl && newlvl >= 2) {
				cvar_set("nzp_puppet_level", ftos(newlvl));
				centerprint(self.owner, strcat("Perk upgraded:\n", Puppeteer_LevelName(newlvl)));
			}
		}

		// "Traitor" -- a thrall kills its own kind for the first time
		if (!skullball_traitor_done) {
			skullball_traitor_done = TRUE;
			GiveAchievement(ACH_SB_TRAITOR, self.owner);
		}
		self.wait = time + SB_THRALL_ATTACK_CD;
		self.frame = 102;		// begin right-swipe animation
		return;
	}

	// chase using Quake's obstacle-aware monster movement -- it turns to find a
	// new direction when blocked instead of grinding straight into a wall.
	self.goalentity = tgt;
	self.ideal_yaw  = vectoyaw(tgt.origin - self.origin);
	movetogoal(SB_THRALL_STEP);
	self.frame = self.frame + 1;
	if (self.frame < 92 || self.frame > 101)
		self.frame = 92;	// run loop
};

void(vector org, entity master) Thrall_Spawn =
{
	entity t = spawn();
	t.classname  = "skullball_thrall";
	t.owner      = master;				// who gets the kill points
	t.movetype   = MOVETYPE_STEP;
	// Use SOLID_NOT so the thrall can't body-shove the player into geometry.
	// movetogoal only needs FL_MONSTER + MOVETYPE_STEP to navigate, not SOLID_SLIDEBOX.
	t.solid      = SOLID_NOT;
	t.flags      = FL_MONSTER;			// canonical walking-monster flag for movetogoal
	setmodel(t, "models/ai/zfull.mdl");

	if (map_compatibility_mode == MAP_COMPAT_BETA) {
		setsize(t, '-6 -6 -24', '6 6 22');
		setorigin(t, org + '0 0 24');
#ifdef FTE
		t.hull = 1;
#endif
	} else {
		setsize(t, '-8 -8 -32', '8 8 30');
		setorigin(t, org + '0 0 32');
	}

	t.effects    = EF_GREENLIGHT;		// friendly green aura
	t.light_lev  = SB_THRALL_GLOW;		// small radius so it glows on itself
	t.takedamage = DAMAGE_NO;			// invulnerable for its brief life
	t.health     = 100000;
	t.yaw_speed  = 32;					// turn speed for movetogoal/ChangeYaw
	t.ltime      = time + SB_THRALL_SECS;
	t.think      = Thrall_Think;
	t.nextthink  = time + 0.1;

	// "Back For Blood" -- gave 50 thralls their skulls back
	skullball_thralls_given = skullball_thralls_given + 1;
	if (skullball_thralls_given == SB_BACK_FOR_BLOOD_COUNT)
		GiveAchievement(ACH_SB_BACK_FOR_BLOOD, master);
};

// ---------------------------------------------------------------------------
// The Butcher -- a rare promoted-zombie miniboss: far tougher, gold-glowing,
// announced. Drops a golden head worth a big bounty with a larger delivery radius.
// ---------------------------------------------------------------------------
float(entity z) SkullBall_DistToNearestPlayer =
{
	float best = 999999;
	entity pl = find(world, classname, "player");
	while (pl != world) {
		float d = vlen(pl.origin - z.origin);
		if (d < best) best = d;
		pl = find(pl, classname, "player");
	}
	return best;
};

void() SkullBall_TryButcher =
{
	// one Butcher / one golden head at a time; wait if the skull is in transit
	if (skullball_gold_active) return;
	if (skullball_carrier != world) return;
	if (skullball_butcher != world && skullball_butcher.health > 0 && !skullball_butcher.deadflag)
		return;
	if (time < skullball_butcher_next) return;

	// pick a dog spawn point (these are crafted IN-BOUNDS) -- furthest from any
	// player so the Butcher has to come find you, like a dramatic dog entrance.
	entity sp = world;
	float  spd = -1;
	entity s = find(world, classname, "spawn_dog");
	while (s != world) {
		float nd = SkullBall_DistToNearestPlayer(s);
		if (nd > spd) { spd = nd; sp = s; }
		s = find(s, classname, "spawn_dog");
	}
	if (sp == world) return;	// map has no dog spawns -> no Butcher

	// grab any live, non-butcher zombie to become the Butcher (we relocate it, so
	// its current position / outside-state doesn't matter).
	entity z = find(world, classname, "ai_zombie");
	while (z != world) {
		if (z.health > 0 && !z.deadflag && z.takedamage != DAMAGE_NO && !z.is_butcher)
			break;
		z = find(z, classname, "ai_zombie");
	}
	if (z == world) return;

	// teleport it to the dog spawn with the electric entrance FX
	setorigin(z, sp.origin);
	z.outside    = FALSE;		// now in-bounds at the dog point
	z.goalentity = world;		// drop stale path; re-acquire from here
	z.enemy      = world;
	spawn_dog_lightning(sp);

	// promote to Butcher
	z.is_butcher = TRUE;
	z.butcher_hp = z_health * SB_BUTCHER_HP_MULT;
	z.health = z.butcher_hp;
	if (z.head != world) z.head.health = z.butcher_hp;	// damage is tracked on the head
	z.butcher_invuln = time + 5;					// 5s spawn protection
	z.takedamage = DAMAGE_NO;
	z.effects = z.effects | EF_ORANGELIGHT;			// gold glow
	z.light_lev = 90;
	skullball_butcher = z;
	skullball_butcher_next = time + SB_BUTCHER_INTERVAL;

	// marker floating over the Butcher so you can hunt him down
	if (skullball_butcher_indicator != world) {
		setmodel(skullball_butcher_indicator, "models/sprites/skullball_boss.spr");
		skullball_butcher_indicator.effects = EF_HARDPOINT;
		setorigin(skullball_butcher_indicator, z.origin + '0 0 80');
	}

	entity pp = find(world, classname, "player");
	while (pp != world) { centerprint(pp, "Butcher Spawned!"); pp = find(pp, classname, "player"); }
};

float(vector from) SkullBall_FurthestAnchor =
{
	float idx, besti = 0, bestd = -1;
	for (idx = 0; idx < skullball_anchor_count; idx = idx + 1) {
		float dd = vlen(skullball_anchors[idx] - from);
		if (dd > bestd) { bestd = dd; besti = idx; }
	}
	return besti;
};

// Called from Zombie_Death when a Butcher dies. Drops the golden butcher HEAD and
// a separate BUTCHER BODY delivery point, both far from the regular pedestal.
void(vector org) SkullBall_OnButcherDeath =
{
	skullball_butcher = world;
	// park the marker that was floating over him
	if (skullball_butcher_indicator != world) {
		skullball_butcher_indicator.effects = 0;
		setmodel(skullball_butcher_indicator, "");
		setorigin(skullball_butcher_indicator, '0 0 -16000');
	}
	if (skullball_bskull_ent == world || skullball_bpedestal_ent == world) return;
	if (skullball_gold_active) return;	// one butcher objective at a time

	skullball_gold_active = TRUE;

	// Golden head: avoid all four currently active spots so it never overlaps
	// the regular skull, regular pedestal, or (unlikely) a prior butcher spot.
	float hidx = SkullBall_PickAnchorFree(skullball_last_skull_idx, skullball_last_ped_idx, skullball_last_bskull_idx, skullball_last_bped_idx);
	skullball_last_bskull_idx = hidx;
	skullball_bskull_ent.movetype  = MOVETYPE_NONE;
	skullball_bskull_ent.solid     = SOLID_NOT;
	SkullBall_PlaceAt(skullball_bskull_ent, skullball_anchors[hidx], -22);
	skullball_bskull_ent.effects   = EF_ORANGELIGHT;
	skullball_bskull_ent.light_lev = 60;

	// Butcher body: avoid the golden head AND all regular spots
	float bidx = SkullBall_PickAnchorFree(skullball_last_bped_idx, hidx, skullball_last_skull_idx, skullball_last_ped_idx);
	skullball_last_bped_idx = bidx;
	SkullBall_PlaceAt(skullball_bpedestal_ent, skullball_anchors[bidx], 33);
	skullball_bpedestal_ent.effects   = EF_ORANGELIGHT;
	skullball_bpedestal_ent.light_lev = 70;

	if (skullball_bskull_indicator != world) {
		setmodel(skullball_bskull_indicator, "models/sprites/skullball_bhead.spr");
		skullball_bskull_indicator.effects = EF_HARDPOINT;
		setorigin(skullball_bskull_indicator, skullball_bskull_ent.origin + '0 0 66');
	}
	if (skullball_bpedestal_indicator != world) {
		setmodel(skullball_bpedestal_indicator, "models/sprites/skullball_bbody.spr");
		skullball_bpedestal_indicator.effects = EF_HARDPOINT;
		setorigin(skullball_bpedestal_indicator, skullball_bpedestal_ent.origin + '0 0 44');
	}

	entity pp = find(world, classname, "player");
	while (pp != world) { centerprint(pp, "Golden Head Dropped!"); pp = find(pp, classname, "player"); }
};

// Park the butcher head + body objective (after delivery / reset).
void() SkullBall_ClearGold =
{
	skullball_gold_active     = FALSE;
	skullball_last_bskull_idx = -1;	// free these anchor slots for future placements
	skullball_last_bped_idx   = -1;
	skullball_bcarrier = world;
	entity p = find(world, classname, "player");
	while (p != world) { p.skullball_carrying_b = 0; p = find(p, classname, "player"); }

	if (skullball_bskull_ent != world) {
		skullball_bskull_ent.effects = 0;
		setorigin(skullball_bskull_ent, '0 0 -16000');
	}
	if (skullball_bpedestal_ent != world) {
		skullball_bpedestal_ent.effects = 0;
		setorigin(skullball_bpedestal_ent, '0 0 -16000');
	}
	if (skullball_bskull_indicator != world) {
		skullball_bskull_indicator.effects = 0;
		setmodel(skullball_bskull_indicator, "");
		setorigin(skullball_bskull_indicator, '0 0 -16000');
	}
	if (skullball_bpedestal_indicator != world) {
		skullball_bpedestal_indicator.effects = 0;
		setmodel(skullball_bpedestal_indicator, "");
		setorigin(skullball_bpedestal_indicator, '0 0 -16000');
	}
};

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------
void(entity carrier) SkullBall_Deliver =
{
	skullball_deliveries = skullball_deliveries + 1;

	// credit ONLY the delivering player (others just get a notice) so co-op
	// deliveries have a reason to balance who delivers.
	if (carrier != world && carrier.classname == "player") {
		Player_AddScore(carrier, SB_DELIVER_POINTS, false);
		centerprint(carrier, "+500 Skull Delivered!");
		bprint(PRINT_HIGH, strcat(carrier.netname, " delivered the skull! (+500)\n"));
	}

	// release whoever was holding it (no-op for a thrown delivery)
	if (skullball_carrier != world)
		skullball_carrier.skullball_carrying = 0;
	skullball_carrier = world;

	// The body you just fed reanimates (head restored!) and fights for you.
	Thrall_Spawn(skullball_pedestal_ent.origin - '0 0 33', carrier);

	// Relocate both skull and pedestal
	SkullBall_PlaceSkull();
	SkullBall_PlacePedestal();

	// play the ching on a real player (world @ 0 0 0 attenuates to silence)
	if (carrier == world)
		carrier = find(world, classname, "player");
	if (carrier != world)
		Sound_PlaySound(carrier, "sounds/misc/ching.wav", SOUND_TYPE_ENV_CHING, SOUND_PRIORITY_PLAYALWAYS);
};

// Deliver the golden BUTCHER head to the Butcher Body: big bounty + 3 power-ups.
void(entity carrier) SkullBall_DeliverButcher =
{
	skullball_deliveries = skullball_deliveries + 1;

	if (carrier != world && carrier.classname == "player") {
		Player_AddScore(carrier, SB_GOLD_POINTS, false);
		centerprint(carrier, "+1000 Butcher Head Delivered!");
		bprint(PRINT_HIGH, strcat(carrier.netname, " delivered the Butcher head! (+1000)\n"));
	}

	// drop 3 random power-ups at the butcher body
	vector where = skullball_bpedestal_ent.origin + '0 0 24';
	float i;
	for (i = 0; i < SB_BUTCHER_POWERUPS; i = i + 1)
		Spawn_Powerup(where + [(random()-0.5)*48, (random()-0.5)*48, 0], -1);

	// a thrall too, then park the whole butcher objective
	Thrall_Spawn(skullball_bpedestal_ent.origin - '0 0 33', carrier);
	SkullBall_ClearGold();

	if (carrier == world)
		carrier = find(world, classname, "player");
	if (carrier != world)
		Sound_PlaySound(carrier, "sounds/misc/ching.wav", SOUND_TYPE_ENV_CHING, SOUND_PRIORITY_PLAYALWAYS);
};

// ---------------------------------------------------------------------------
// Throwing heads: a grenade-like underhand lob along the player's horizontal
// facing at a ~30-degree arc (ignores pitch) so it never fires into the floor.
// ---------------------------------------------------------------------------
// Touch for a thrown/bowled head. A bowled head keeps ALL its momentum so it
// rolls along the ground and plows the horde; only a THROWN head damps to settle.
void() SkullBall_HeadTouch =
{
	if (self.skullball_bowling)
		return;
	self.velocity  = self.velocity  * 0.28;
	self.avelocity = self.avelocity * 0.5;
};

void(entity head, entity thrower) SkullBall_LaunchHead =
{
	vector throw_dir, start;

	makevectors(thrower.v_angle);
	throw_dir = v_forward;
	start     = thrower.origin + thrower.view_ofs - '0 0 14' + throw_dir * 16;

	head.movetype  = MOVETYPE_BOUNCE;
	head.solid     = SOLID_BBOX;
	setsize(head, '0 0 0', '0 0 0');			// zero bbox so it can't snag
	// clear FL_ONGROUND from the last landing -- SV_Physics_Toss won't move a
	// grounded entity, so without this every throw after the first is dead on arrival.
	head.flags     = head.flags - (head.flags & FL_ONGROUND);
	head.velocity  = throw_dir * SB_THROW_SPEED;
	head.avelocity = '300 -300 300';			// tumble/flail
	head.angles    = vectoangles(throw_dir);
	head.touch     = SkullBall_HeadTouch;
	head.origin    = start;
	setorigin(head, start);
	head.owner     = thrower;					// for thrown-delivery / bowl-kill credit
	head.ltime     = time + 8;					// anti-softlock: re-place if not recovered
	skullball_throw_grace = time + SB_THROW_GRACE;
	Sound_PlaySound(thrower, "sounds/weapons/grenade/throw.wav", SOUND_TYPE_WEAPON_OTHER, SOUND_PRIORITY_PLAYALWAYS);
};

void() SkullBall_ThrowStandard =
{
	if (!self.skullball_carrying || skullball_carrier != self || skullball_skull_ent == world)
		return;
	skullball_carrier = world;
	self.skullball_carrying = 0;
	SkullBall_LaunchHead(skullball_skull_ent, self);
	skullball_skull_ent.effects   = EF_REDLIGHT;
	skullball_skull_ent.light_lev = 48;
	skullball_skull_spawn_time = time;
	if (skullball_skull_indicator != world) {
		setmodel(skullball_skull_indicator, "models/sprites/skullball_arrow_b.spr");
		skullball_skull_indicator.effects = EF_HARDPOINT;
	}
	if (skullball_pedestal_indicator != world) {
		setmodel(skullball_pedestal_indicator, "models/sprites/skullball_arrow.spr");
		skullball_pedestal_indicator.effects = EF_HARDPOINT;
	}
};

void() SkullBall_ThrowGold =
{
	if (!self.skullball_carrying_b || skullball_bcarrier != self || skullball_bskull_ent == world)
		return;
	skullball_bcarrier = world;
	self.skullball_carrying_b = 0;
	SkullBall_LaunchHead(skullball_bskull_ent, self);
	skullball_bskull_ent.effects   = EF_ORANGELIGHT;
	skullball_bskull_ent.light_lev = 60;
	if (skullball_bskull_indicator != world) {
		setmodel(skullball_bskull_indicator, "models/sprites/skullball_bhead.spr");
		skullball_bskull_indicator.effects = EF_HARDPOINT;
	}
	if (skullball_bpedestal_indicator != world) {
		setmodel(skullball_bpedestal_indicator, "models/sprites/skullball_bbody.spr");
		skullball_bpedestal_indicator.effects = EF_HARDPOINT;
	}
};

// Perform the L-bumper action (throw or bowl, per skullball_bowl_mode) on the
// selected head, falling back to whichever head you actually hold.
void() SkullBall_DoAction =
{
	if (self.skullball_throw_sel) {
		if (self.skullball_carrying_b) { SkullBall_ThrowGold(); return; }
		if (self.skullball_carrying)   { SkullBall_ThrowStandard(); return; }
	} else {
		if (self.skullball_carrying)   { SkullBall_ThrowStandard(); return; }
		if (self.skullball_carrying_b) { SkullBall_ThrowGold(); return; }
	}
};

// L bumper (impulse 44): throw the selected head.
void() SkullBall_TryThrow =
{
	if (cvar("sv_gamemode") != GAMEMODE_SKULLBALL)
		return;
	SkullBall_DoAction();
};

// D-Pad Left (impulse 46): toggle which head you act on (standard <-> butcher).
void() SkullBall_ToggleHead =
{
	if (cvar("sv_gamemode") != GAMEMODE_SKULLBALL)
		return;
	self.skullball_throw_sel = !self.skullball_throw_sel;
	if (self.skullball_throw_sel)
		centerprint(self, "Selected: BUTCHER HEAD");
	else
		centerprint(self, "Selected: STANDARD SKULL");
};

// ---------------------------------------------------------------------------
// Per-frame pickup / delivery checks
// ---------------------------------------------------------------------------
void() SkullBall_CheckInteractions =
{

	// --- Thrown-head remote delivery: a head in flight (MOVETYPE_TOSS) that
	// reaches its matching body auto-completes the delivery for the thrower. ---
	if (skullball_carrier == world && skullball_skull_ent != world
	    && skullball_skull_ent.movetype == MOVETYPE_BOUNCE && skullball_pedestal_ent != world
	    && vlen(skullball_skull_ent.origin - skullball_pedestal_ent.origin) <= SB_DELIVER_DIST) {
		SkullBall_Deliver(skullball_skull_ent.owner);
	}
	if (skullball_gold_active && skullball_bcarrier == world && skullball_bskull_ent != world
	    && skullball_bskull_ent.movetype == MOVETYPE_BOUNCE && skullball_bpedestal_ent != world
	    && vlen(skullball_bskull_ent.origin - skullball_bpedestal_ent.origin) <= SB_GOLD_DELIVER_DIST) {
		SkullBall_DeliverButcher(skullball_bskull_ent.owner);
	}

	// --- Anti-softlock: a thrown head that's been stranded (15s, no player near
	// it) is re-placed at a fresh reachable anchor so you can never lose it. ---
	if (skullball_carrier == world && skullball_skull_ent != world
	    && skullball_skull_ent.movetype == MOVETYPE_BOUNCE && skullball_skull_ent.ltime
	    && time > skullball_skull_ent.ltime) {
		skullball_skull_ent.ltime = 0;
		SkullBall_PlaceSkull();
	}
	if (skullball_gold_active && skullball_bcarrier == world && skullball_bskull_ent != world
	    && skullball_bskull_ent.movetype == MOVETYPE_BOUNCE && skullball_bskull_ent.ltime
	    && time > skullball_bskull_ent.ltime) {
		skullball_bskull_ent.ltime = 0;
		skullball_bskull_ent.movetype  = MOVETYPE_NONE;
		skullball_bskull_ent.solid     = SOLID_NOT;
		skullball_bskull_ent.velocity  = '0 0 0';
		skullball_bskull_ent.avelocity = '0 0 0';
		float ri = SkullBall_PickAnchorFree(skullball_last_skull_idx, skullball_last_ped_idx, skullball_last_bped_idx, skullball_last_bskull_idx);
		skullball_last_bskull_idx = ri;
		SkullBall_PlaceAt(skullball_bskull_ent, skullball_anchors[ri], -22);
		skullball_bskull_ent.effects   = EF_ORANGELIGHT;
		skullball_bskull_ent.light_lev = 60;
		if (skullball_bskull_indicator != world) {
			setmodel(skullball_bskull_indicator, "models/sprites/skullball_bhead.spr");
			skullball_bskull_indicator.effects = EF_HARDPOINT;
		}
	}

	// --- Bobbing animation for the skull when unclaimed ---
	if (skullball_carrier == world && skullball_skull_ent != world) {
		// Spin upright at rest. Force pitch/roll to 0 so leftover throw-tumble
		// angles can't make a freshly (re)placed head spin around a tilted axis.
		if (skullball_skull_ent.movetype == MOVETYPE_NONE) {
			skullball_skull_ent.angles_x = 0;
			skullball_skull_ent.angles_z = 0;
			skullball_skull_ent.angles_y = skullball_skull_ent.angles_y + 60 * frametime;
		}
		// keep the beacon tracking it (it may have been thrown and rolled away)
		if (skullball_skull_indicator != world)
			setorigin(skullball_skull_indicator, skullball_skull_ent.origin + '0 0 66');
	}

	// --- Same for the unclaimed butcher (golden) head ---
	if (skullball_gold_active && skullball_bcarrier == world && skullball_bskull_ent != world) {
		skullball_bskull_ent.angles_x = 0;
		skullball_bskull_ent.angles_z = 0;
		skullball_bskull_ent.angles_y = skullball_bskull_ent.angles_y + 60 * frametime;
		if (skullball_bskull_indicator != world)
			setorigin(skullball_bskull_indicator, skullball_bskull_ent.origin + '0 0 66');
	}

	entity p = find(world, classname, "player");
	while (p != world) {

		if (!p.downed && p.health > 0) {

			// --- Pickup ---
			if (skullball_carrier == world && skullball_skull_ent != world) {
				// horizontal-only distance: the head origin sits below the floor, so a
				// full 3D check against the player's mid-body would miss. Gate Z loosely.
				vector d = p.origin - skullball_skull_ent.origin;
				// Z gate: 56u allows uneven terrain while blocking floor-above grabs
				// (inter-floor gap >= 80u here, so d_z > 60 from above).
				float catchdist = SB_PICKUP_DIST;
				float catchz = 56;
				if (skullball_skull_ent.movetype == MOVETYPE_BOUNCE) { catchdist = SB_CATCH_DIST; catchz = 80; }
				// Catch assist: thrown skull gets a generous radius (passing); only the
				// thrower waits out the grace so a teammate can catch instantly.
				float graceok = (time >= skullball_throw_grace) || (p != skullball_skull_ent.owner);
				if (graceok && fabs(d_z) <= catchz && vlen([d_x, d_y, 0]) <= catchdist) {
					skullball_carrier = p;
					p.skullball_carrying = 1;
					// stop any throw physics so it rides the hip cleanly
					skullball_skull_ent.movetype  = MOVETYPE_NONE;
					skullball_skull_ent.solid     = SOLID_NOT;
					skullball_skull_ent.velocity  = '0 0 0';
					skullball_skull_ent.avelocity = '0 0 0';
					skullball_skull_ent.effects = 0;	// no dlight while carried (don't wash the viewmodel)
					centerprint(p, "Skull Grabbed!");
					// head is on your hip: hide its beacon, bold the delivery beacon. Clear
					// EF_HARDPOINT too, else the PVS bypass keeps drawing it through walls.
					if (skullball_skull_indicator != world) {
						skullball_skull_indicator.effects = 0;
						setmodel(skullball_skull_indicator, "");
						setorigin(skullball_skull_indicator, '0 0 -16000');
					}
					if (skullball_pedestal_indicator != world) {
						setmodel(skullball_pedestal_indicator, "models/sprites/skullball_arrow_bold.spr");
						skullball_pedestal_indicator.effects = EF_HARDPOINT;
						setorigin(skullball_pedestal_indicator, skullball_pedestal_ent.origin + '0 0 44');
					}
				}
			}

			// --- Carrier: skull rides on the right hip ---
			if (skullball_carrier == p) {
				// bottom-right of the body model (3rd person); shows at the player's
				// side in first person too. Positioned via the player's yaw.
				makevectors([0, p.angles_y, 0]);
				// head geometry is +26..+40 above origin, so drop the origin to bring
				// the head down to the hip/waist.
				setorigin(skullball_skull_ent, p.origin + v_right * 11 + v_forward * 2 + '0 0 -36');
				skullball_skull_ent.angles = [0, p.angles_y, 0];

				// Delivery check
				if (skullball_pedestal_ent != world) {
					if (vlen(p.origin - skullball_pedestal_ent.origin) <= SB_DELIVER_DIST) {
						SkullBall_Deliver(skullball_carrier);
						break;
					}
				}
			}

			// --- Drop skull if carrier dies / downs ---
			if (skullball_carrier == p && (p.downed || p.health <= 0)) {
				skullball_carrier = world;
				p.skullball_carrying = 0;
				// Drop the head on the floor at the player's feet
				SkullBall_PlaceAt(skullball_skull_ent, p.origin, -22);
				skullball_skull_ent.effects = EF_REDLIGHT;	// aura back on
				skullball_skull_spawn_time = time;
				// restore HEAD beacon, revert delivery beacon to normal
				if (skullball_skull_indicator != world) {
					setmodel(skullball_skull_indicator, "models/sprites/skullball_arrow_b.spr");
					skullball_skull_indicator.effects = EF_HARDPOINT;
					setorigin(skullball_skull_indicator, skullball_skull_ent.origin + '0 0 66');
				}
				if (skullball_pedestal_indicator != world) {
					setmodel(skullball_pedestal_indicator, "models/sprites/skullball_arrow.spr");
					skullball_pedestal_indicator.effects = EF_HARDPOINT;
				}
				centerprint(p, "Skull Dropped!");
			}

			// === BUTCHER (golden) HEAD -- independent objective, rides the LEFT hip ===
			if (skullball_gold_active) {
				// Pickup (generous Z gate -- the head can sit a floor off the marker)
				if (skullball_bcarrier == world && skullball_bskull_ent != world) {
					vector bd = p.origin - skullball_bskull_ent.origin;
					// honor the post-throw grace so a thrown butcher head isn't
					// re-grabbed the instant it leaves your hand.
					float bcatchdist = SB_PICKUP_DIST;
					float bcatchz = 64;
					if (skullball_bskull_ent.movetype == MOVETYPE_BOUNCE) { bcatchdist = SB_CATCH_DIST; bcatchz = 88; }
					float bgraceok = (time >= skullball_throw_grace) || (p != skullball_bskull_ent.owner);
					if (bgraceok && fabs(bd_z) <= bcatchz && vlen([bd_x, bd_y, 0]) <= bcatchdist) {
						skullball_bcarrier = p;
						p.skullball_carrying_b = 1;
						// stop any throw physics so it rides the hip cleanly
						skullball_bskull_ent.movetype  = MOVETYPE_NONE;
						skullball_bskull_ent.solid     = SOLID_NOT;
						skullball_bskull_ent.velocity  = '0 0 0';
						skullball_bskull_ent.avelocity = '0 0 0';
						skullball_bskull_ent.effects = 0;
						centerprint(p, "Butcher Head Grabbed!");
						if (skullball_bskull_indicator != world) {
							skullball_bskull_indicator.effects = 0;
							setmodel(skullball_bskull_indicator, "");
							setorigin(skullball_bskull_indicator, '0 0 -16000');
						}
						if (skullball_bpedestal_indicator != world) {
							setmodel(skullball_bpedestal_indicator, "models/sprites/skullball_bbody.spr");
							skullball_bpedestal_indicator.effects = EF_HARDPOINT;
							setorigin(skullball_bpedestal_indicator, skullball_bpedestal_ent.origin + '0 0 44');
						}
					}
				}

				// Carrier: rides on the LEFT hip (regular skull is on the right)
				if (skullball_bcarrier == p) {
					makevectors([0, p.angles_y, 0]);
					setorigin(skullball_bskull_ent, p.origin + v_right * -11 + v_forward * 2 + '0 0 -36');
					skullball_bskull_ent.angles = [0, p.angles_y, 0];
					if (skullball_bpedestal_ent != world
					    && vlen(p.origin - skullball_bpedestal_ent.origin) <= SB_GOLD_DELIVER_DIST) {
						SkullBall_DeliverButcher(skullball_bcarrier);
						break;
					}
				}

				// Drop on down/death
				if (skullball_bcarrier == p && (p.downed || p.health <= 0)) {
					skullball_bcarrier = world;
					p.skullball_carrying_b = 0;
					SkullBall_PlaceAt(skullball_bskull_ent, p.origin, -22);
					skullball_bskull_ent.effects = EF_ORANGELIGHT;
					if (skullball_bskull_indicator != world) {
						setmodel(skullball_bskull_indicator, "models/sprites/skullball_bhead.spr");
						skullball_bskull_indicator.effects = EF_HARDPOINT;
						setorigin(skullball_bskull_indicator, skullball_bskull_ent.origin + '0 0 66');
					}
					if (skullball_bpedestal_indicator != world) {
						setmodel(skullball_bpedestal_indicator, "models/sprites/skullball_bbody.spr");
						skullball_bpedestal_indicator.effects = EF_HARDPOINT;
					}
					centerprint(p, "Butcher Head Dropped!");
				}
			}
		}
		p = find(p, classname, "player");
	}
};

// ---------------------------------------------------------------------------
// Speed modifier for carrier (called from player_core)
// ---------------------------------------------------------------------------
float(float current_speed) Gamemode_SkullBall_GetCarrierSpeed =
{
	// carrying one OR both skulls applies the SAME single slowdown (don't stack)
	if (self.skullball_carrying || self.skullball_carrying_b)
		return current_speed * SB_CARRY_SPEEDMULT;
	return current_speed;
};

// ---------------------------------------------------------------------------
// Core gamemode hooks
// ---------------------------------------------------------------------------
void() Gamemode_SkullBall_Init =
{
	skullball_tier_deadline = 0;
	skullball_setup_done    = FALSE;
	skullball_anchors_ready = FALSE;	// fresh map -> recollect anchors
	skullball_deliveries    = 0;
	skullball_carrier       = world;
	skullball_last_skull_idx  = -1;
	skullball_last_ped_idx    = -1;
	skullball_last_bskull_idx = -1;
	skullball_last_bped_idx   = -1;

	precache_model("models/ai/zh^.mdl");	// zombie head (carried)
	precache_model("models/ai/zb%.mdl");	// headless zombie body (pedestal)
	precache_model("models/ai/zfull.mdl");	// reanimated thrall (head restored)
	precache_model("models/sprites/skullball_arrow.spr");
	precache_model("models/sprites/skullball_arrow_b.spr");
	precache_model("models/sprites/skullball_arrow_bold.spr");
	precache_model("models/sprites/skullball_bhead.spr");
	precache_model("models/sprites/skullball_bbody.spr");
	precache_model("models/sprites/skullball_boss.spr");
	precache_sound("sounds/misc/ching.wav");

	skullball_skull_ent    = SkullBall_SpawnSkull();
	skullball_pedestal_ent = SkullBall_SpawnPedestal();

	skullball_skull_indicator = spawn();
	skullball_skull_indicator.classname = "skullball_indicator";
	skullball_skull_indicator.movetype  = MOVETYPE_NONE;
	skullball_skull_indicator.solid     = SOLID_NOT;
	skullball_skull_indicator.scale     = 0.5;	// shrink the floating marker
	// parked & hidden until round 1 places it -- no model/EF_HARDPOINT or the PVS
	// bypass would draw it through walls down in the void.
	setorigin(skullball_skull_indicator, '0 0 -16000');

	skullball_pedestal_indicator = spawn();
	skullball_pedestal_indicator.classname = "skullball_indicator";
	skullball_pedestal_indicator.movetype  = MOVETYPE_NONE;
	skullball_pedestal_indicator.solid     = SOLID_NOT;
	skullball_pedestal_indicator.scale     = 0.5;	// shrink the floating marker
	setorigin(skullball_pedestal_indicator, '0 0 -16000');

	// --- Butcher objective: golden head + Butcher Body + their markers (parked
	// until a Butcher dies) ---
	skullball_butcher       = world;
	skullball_gold_active   = FALSE;
	skullball_bcarrier      = world;

	skullball_bskull_ent = spawn();
	skullball_bskull_ent.classname = "skullball_bskull";
	skullball_bskull_ent.movetype  = MOVETYPE_NONE;
	skullball_bskull_ent.solid     = SOLID_NOT;
	setmodel(skullball_bskull_ent, "models/ai/zh^.mdl");
	setorigin(skullball_bskull_ent, '0 0 -16000');

	skullball_bpedestal_ent = spawn();
	skullball_bpedestal_ent.classname = "skullball_bpedestal";
	skullball_bpedestal_ent.movetype  = MOVETYPE_NONE;
	skullball_bpedestal_ent.solid     = SOLID_NOT;
	setmodel(skullball_bpedestal_ent, "models/ai/zb%.mdl");
	setorigin(skullball_bpedestal_ent, '0 0 -16000');

	skullball_bskull_indicator = spawn();
	skullball_bskull_indicator.classname = "skullball_indicator";
	skullball_bskull_indicator.movetype  = MOVETYPE_NONE;
	skullball_bskull_indicator.solid     = SOLID_NOT;
	skullball_bskull_indicator.scale     = 0.5;
	setorigin(skullball_bskull_indicator, '0 0 -16000');

	skullball_bpedestal_indicator = spawn();
	skullball_bpedestal_indicator.classname = "skullball_indicator";
	skullball_bpedestal_indicator.movetype  = MOVETYPE_NONE;
	skullball_bpedestal_indicator.solid     = SOLID_NOT;
	skullball_bpedestal_indicator.scale     = 0.5;
	setorigin(skullball_bpedestal_indicator, '0 0 -16000');

	skullball_butcher_indicator = spawn();
	skullball_butcher_indicator.classname = "skullball_indicator";
	skullball_butcher_indicator.movetype  = MOVETYPE_NONE;
	skullball_butcher_indicator.solid     = SOLID_NOT;
	skullball_butcher_indicator.scale     = 0.5;
	setorigin(skullball_butcher_indicator, '0 0 -16000');

	// Park both off-map until round 1
	setorigin(skullball_skull_ent,    '0 0 -16000');
	setorigin(skullball_pedestal_ent, '0 0 -16000');
};

// called from Soft_Restart: re-arm the one-time setup (reopen doors, re-place the
// skull/pedestal) and clear the carrier, else setup_done stays TRUE and doors stay locked.
void() Gamemode_SkullBall_OnRestart =
{
	entity p;

	skullball_setup_done     = FALSE;
	skullball_tier_deadline  = 0;
	skullball_carrier        = world;
	skullball_deliveries     = 0;
	skullball_last_skull_idx  = -1;
	skullball_last_ped_idx    = -1;
	skullball_last_bskull_idx = -1;
	skullball_last_bped_idx   = -1;
	// actually remove the Butcher -- the zombie-kill loop skips him while invuln, so he
	// otherwise survives the restart into the fresh game
	if (skullball_butcher != world) {
		if (skullball_butcher.head != world) remove(skullball_butcher.head);
		remove(skullball_butcher);
	}
	skullball_butcher        = world;
	skullball_gold_active    = FALSE;
	skullball_butcher_next   = time + SB_BUTCHER_INTERVAL;

	// park entities off-map until the Frame re-places them next round
	if (skullball_skull_ent != world)          setorigin(skullball_skull_ent, '0 0 -16000');
	if (skullball_pedestal_ent != world)       setorigin(skullball_pedestal_ent, '0 0 -16000');
	// hide markers fully (clear model+EF_HARDPOINT) so the PVS bypass doesn't draw
	// them through walls in the void; Frame re-places + re-arms them next round.
	if (skullball_skull_indicator != world) {
		skullball_skull_indicator.effects = 0;
		setmodel(skullball_skull_indicator, "");
		setorigin(skullball_skull_indicator, '0 0 -16000');
	}
	if (skullball_pedestal_indicator != world) {
		skullball_pedestal_indicator.effects = 0;
		setmodel(skullball_pedestal_indicator, "");
		setorigin(skullball_pedestal_indicator, '0 0 -16000');
	}

	// park the whole butcher objective (head/body/markers, carrier flags)
	SkullBall_ClearGold();
	if (skullball_butcher_indicator != world) {
		skullball_butcher_indicator.effects = 0;
		setmodel(skullball_butcher_indicator, "");
		setorigin(skullball_butcher_indicator, '0 0 -16000');
	}

	// clear any leftover carry flag AND prone/stance state so the player
	// doesn't spawn clipped underground after a game-over in last-stand
	p = find(world, classname, "player");
	while (p != world) {
		p.skullball_carrying   = 0;
		p.skullball_carrying_b = 0;
		// force stance back to standing so PutClientInServer doesn't inherit the
		// prone view_ofs from LastStand_Begin (which clips the player into the floor).
		p.stance    = 0;	// PLAYER_STANCE_STAND
		p.view_ofs  = '0 0 22';	// standard standing eye height
		p.downed    = 0;
		p = find(p, classname, "player");
	}

	// remove any thralls still roaming from the previous run
	entity t = find(world, classname, "skullball_thrall");
	while (t != world) {
		entity nxt = find(t, classname, "skullball_thrall");
		remove(t);
		t = nxt;
	}
};

void() Gamemode_SkullBall_PlayerSpawn =
{
	self.skullball_carrying = 0;
};

void() Gamemode_SkullBall_Frame =
{
	if (rounds < 1)
		return;

	// One-time setup
	if (!skullball_setup_done) {
		// collect anchors ONCE per map -- re-loading the .hpt on restart fails and
		// drops to the perk/spawn fallback, so keep the good set across restarts.
		if (!skullball_anchors_ready) {
			SkullBall_CollectAnchors();
			skullball_anchors_ready = TRUE;
		}
		SkullBall_PlaceSkull();
		SkullBall_PlacePedestal();
		SkullBall_OpenAllDoors();
		skullball_tier_deadline = time + SB_TIER_SECS;
		skullball_butcher_next  = time + SB_BUTCHER_INTERVAL;
		skullball_setup_done = TRUE;
	}

	// The Butcher miniboss
	SkullBall_TryButcher();
	if (skullball_butcher != world && skullball_butcher.health > 0 && !skullball_butcher.deadflag) {
		// keep his marker floating over him while he lives
		if (skullball_butcher_indicator != world)
			setorigin(skullball_butcher_indicator, skullball_butcher.origin + '0 0 80');
		// drop spawn protection once the window passes
		if (skullball_butcher.takedamage == DAMAGE_NO && time >= skullball_butcher.butcher_invuln)
			skullball_butcher.takedamage = DAMAGE_YES;
	}

	// Difficulty ramp (every 45 seconds)
	if (!skullball_tier_deadline)
		skullball_tier_deadline = time + SB_TIER_SECS;

	if (time >= skullball_tier_deadline) {
		skullball_tier_deadline = time + SB_TIER_SECS;
		rounds = rounds + 1;
		set_z_health();
		if (zombie_spawn_delay > 0.12)
			zombie_spawn_delay = zombie_spawn_delay * 0.92;

		rounds_change = 6;
		blink_return = time + 2;
		Rounds_PlayTransition("sounds/rounds/nround.wav");
	}

	SkullBall_CheckInteractions();
};

float(float current_delay) Gamemode_SkullBall_GetRoundDelay =
{
	// Instant round transitions (continuous spawning like Cranked)
	return time + 0.2;
};

float(float count, float round, float type, float players) Gamemode_SkullBall_GetZombieTotalForRound =
{
	// Cranked-style: 999 cap per wave
	float total = count + round * 2;
	if (total > 999)
		total = 999;
	return total;
};
