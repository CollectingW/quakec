/*
	server/gamemodes/hardpoint.qc

	"Hardpoint" gamemode: earn points only inside the active zone (spend anywhere).
	All doors open at start; the zone relocates each round. Zones come from
	info_hardpoint entities (key "count" = radius), else auto-placed on spawns/perks.
	Beacon drawn through walls via EF_HARDPOINT, swapping pre-coloured sprites.

	Copyright (C) 2021-2024 NZ:P Team
*/

#define HARDPOINT_DEFAULT_RADIUS 160
// tight vertical capture window so you can't camp a catwalk above/below the floor
#define HARDPOINT_VTOP    64
#define HARDPOINT_VBOT    48
#define HARDPOINT_DOTS    16

#define HP_ARROW_GREY "models/sprites/hardpoint_arrow.spr"
#define HP_ARROW_BLUE "models/sprites/hardpoint_arrow_b.spr"
#define HP_DOT_GREY   "models/sprites/hardpoint_dot.spr"
#define HP_DOT_BLUE   "models/sprites/hardpoint_dot_b.spr"

vector hardpoint_origin;
float  hardpoint_radius;        // radius of the ACTIVE zone
float  hardpoint_round;
float  hardpoint_last_index;
float  hardpoint_setup_done;
float  hardpoint_occ_state; // -1 = unknown, forces first model set (init in _Init)

entity hardpoint_arrow;
entity hardpoint_dots[HARDPOINT_DOTS];

// NEXT POINT preview: 7s before the zone swaps, show where it's heading.
#define HARDPOINT_NEXT_LEAD 7
entity hardpoint_next_arrow;
float  hardpoint_pending;
float  hardpoint_swap_at;
float  hardpoint_msg_at;
vector hardpoint_next_org;
float  hardpoint_next_rad;
float  hardpoint_next_idx;

#define HARDPOINT_MAX_ANCHORS 64
vector hardpoint_anchors[HARDPOINT_MAX_ANCHORS];
float  hardpoint_anchor_radius[HARDPOINT_MAX_ANCHORS];
float  hardpoint_anchor_count;

// info_hardpoint -- inert map marker that defines a hardpoint location. Needs a
// spawn function so the engine keeps it. Optional "count" key = radius.
void() info_hardpoint =
{
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_NONE;
	setmodel(self, "");
};

void(vector org, float radius) Hardpoint_AddAnchor =
{
	if (hardpoint_anchor_count >= HARDPOINT_MAX_ANCHORS)
		return;
	hardpoint_anchors[hardpoint_anchor_count] = org;
	hardpoint_anchor_radius[hardpoint_anchor_count] = radius;
	hardpoint_anchor_count = hardpoint_anchor_count + 1;
};

void(string cname, float radius) Hardpoint_CollectClass =
{
	entity e = find(world, classname, cname);
	while (e != world) {
		Hardpoint_AddAnchor(e.origin, radius);
		e = find(e, classname, cname);
	}
};

// read anchors from maps/<mapname>.hpt, one "X Y Z" per line (from `viewpos`)
void() Hardpoint_LoadFile =
{
	float f = fopen(strcat(mappath, ".hpt"), FILE_READ);
	if (f == -1)
		return;

	string line = fgets(f);
	while (line != "") {
		vector org = stov(line);            // first 3 tokens -> x y z
		if (org != '0 0 0') {               // skip blank/garbage lines
			// viewpos Z is unreliable (often captured noclipping); snap to floor under X/Y
			traceline(org + '0 0 64', org - '0 0 4096', TRUE, world);
			if (trace_fraction < 1)
				org = trace_endpos + '0 0 32';   // ~standing player origin height
			Hardpoint_AddAnchor(org, HARDPOINT_DEFAULT_RADIUS);
		}
		line = fgets(f);
	}
	fclose(f);
};

void() Hardpoint_CollectAnchors =
{
	hardpoint_anchor_count = 0;

	// 1) Map-authored locations win -- full control + per-spot radius (count).
	entity e = find(world, classname, "info_hardpoint");
	while (e != world) {
		float r = e.count;
		if (r <= 0)
			r = HARDPOINT_DEFAULT_RADIUS;
		Hardpoint_AddAnchor(e.origin, r);
		e = find(e, classname, "info_hardpoint");
	}
	// 1b) User-editable text file (maps/<mapname>.hpt). Stacks with info_hardpoint.
	Hardpoint_LoadFile();

	if (hardpoint_anchor_count > 0)
		return;

	// 2) Fallback: open interior gameplay entities.
	Hardpoint_CollectClass("info_player_start",   HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("info_player_1_spawn", HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("info_player_2_spawn", HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("info_player_3_spawn", HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("info_player_4_spawn", HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_juggernog", HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_speed",     HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_revive",    HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_double",    HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_staminup",  HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_mule",      HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_flopper",   HARDPOINT_DEFAULT_RADIUS);
	Hardpoint_CollectClass("perk_deadshot",  HARDPOINT_DEFAULT_RADIUS);
};

float(entity who) Hardpoint_PlayerInZone =
{
	if (hardpoint_anchor_count == 0)
		return FALSE;
	if (fabs(who.origin_x - hardpoint_origin_x) > hardpoint_radius)
		return FALSE;
	if (fabs(who.origin_y - hardpoint_origin_y) > hardpoint_radius)
		return FALSE;
	if (who.origin_z - hardpoint_origin_z > HARDPOINT_VTOP)
		return FALSE;
	if (hardpoint_origin_z - who.origin_z > HARDPOINT_VBOT)
		return FALSE;
	return TRUE;
};

vector(vector org) Hardpoint_FloorAt =
{
	traceline(org + '0 0 40', org - '0 0 700', TRUE, world);
	if (trace_fraction < 1)
		return trace_endpos + '0 0 2';
	return org;
};

float(vector floorpt) Hardpoint_Standable =
{
	tracebox(floorpt + '0 0 34', PLAYER_MINS_STANDING, PLAYER_MAXS_STANDING,
			 floorpt + '0 0 34', TRUE, world);
	return !trace_startsolid && !trace_allsolid;
};

void() Hardpoint_PositionMarkers =
{
	if (hardpoint_arrow != world)
		setorigin(hardpoint_arrow, hardpoint_origin + '0 0 144'); // raised above eye level so you don't stare into it

	float i;
	for (i = 0; i < HARDPOINT_DOTS; i = i + 1) {
		if (hardpoint_dots[i] == world)
			continue;

		float side = floor(i / 4);
		float t = (i - side*4) / 4;
		float a = -hardpoint_radius + (t * 2 * hardpoint_radius);
		vector off;
		off_z = 0;
		if (side == 0)      { off_x = a;                off_y = -hardpoint_radius; }
		else if (side == 1) { off_x = hardpoint_radius; off_y = a;                 }
		else if (side == 2) { off_x = a * -1;           off_y = hardpoint_radius;  }
		else                { off_x = -hardpoint_radius; off_y = a * -1;           }

		// walk inward from the radius; accept the first marker with clear LoS and floor near the zone height
		vector pos = hardpoint_origin;
		float frac;
		for (frac = 1.0; frac > 0.12; frac = frac - 0.12) {
			vector cand = hardpoint_origin + off * frac;
			// wall between centre and candidate?
			traceline(hardpoint_origin + '0 0 24', cand + '0 0 24', TRUE, world);
			if (trace_fraction < 1)
				continue;
			// ground near the zone's level right under the candidate?
			traceline(cand + '0 0 24', cand - '0 0 64', TRUE, world);
			if (trace_fraction >= 1)
				continue;                 // nothing solid close below -> over a drop, pull in
			pos = trace_endpos + '0 0 2';
			break;
		}

		setorigin(hardpoint_dots[i], pos + '0 0 6');
	}
};

void() Hardpoint_Relocate =
{
	if (hardpoint_anchor_count <= 0)
		return;

	// pick a uniformly random anchor (avoid repeating the last one). Anchors are valid
	// by construction, so trust them and just snap to the floor (re-rolling biased picks).
	float idx = hardpoint_last_index, attempt;
	for (attempt = 0; attempt < 16; attempt = attempt + 1) {
		idx = rint(random() * (hardpoint_anchor_count - 1));
		if (!(idx == hardpoint_last_index && hardpoint_anchor_count > 1))
			break;
	}

	hardpoint_last_index = idx;
	hardpoint_origin = Hardpoint_FloorAt(hardpoint_anchors[idx]);
	hardpoint_radius = hardpoint_anchor_radius[idx];
	if (hardpoint_radius <= 0)
		hardpoint_radius = HARDPOINT_DEFAULT_RADIUS;
	Hardpoint_PositionMarkers();
};

// pick the NEXT zone (don't activate it yet) and raise its preview arrow
void() Hardpoint_PickNext =
{
	if (hardpoint_anchor_count <= 0)
		return;
	float idx = hardpoint_last_index, attempt;
	for (attempt = 0; attempt < 16; attempt = attempt + 1) {
		idx = rint(random() * (hardpoint_anchor_count - 1));
		if (idx != hardpoint_last_index || hardpoint_anchor_count <= 1)
			break;
	}
	hardpoint_next_idx = idx;
	hardpoint_next_org = Hardpoint_FloorAt(hardpoint_anchors[idx]);
	hardpoint_next_rad = hardpoint_anchor_radius[idx];
	if (hardpoint_next_rad <= 0)
		hardpoint_next_rad = HARDPOINT_DEFAULT_RADIUS;
	if (hardpoint_next_arrow != world)
		setorigin(hardpoint_next_arrow, hardpoint_next_org + '0 0 144');
};

// commit the previewed zone as the active one
void() Hardpoint_ApplyNext =
{
	hardpoint_last_index = hardpoint_next_idx;
	hardpoint_origin = hardpoint_next_org;
	hardpoint_radius = hardpoint_next_rad;
	hardpoint_occ_state = -1;	// force marker colour refresh
	Hardpoint_PositionMarkers();
	if (hardpoint_next_arrow != world)
		setorigin(hardpoint_next_arrow, '0 0 -16000');	// hide preview arrow
};

void() Hardpoint_OpenAllDoors =
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

entity(string spr) Hardpoint_SpawnMarker =
{
	entity m = spawn();
	m.classname = "hardpoint_marker";
	m.movetype = MOVETYPE_NONE;
	m.solid = SOLID_NOT;
	setmodel(m, spr);
	m.effects = EF_HARDPOINT;
	setorigin(m, '0 0 -16000');
	return m;
};

void() Gamemode_Hardpoint_Init =
{
	precache_model(HP_ARROW_GREY);
	precache_model(HP_ARROW_BLUE);
	precache_model(HP_DOT_GREY);
	precache_model(HP_DOT_BLUE);

	hardpoint_arrow = Hardpoint_SpawnMarker(HP_ARROW_GREY);
	hardpoint_next_arrow = Hardpoint_SpawnMarker(HP_ARROW_GREY);
	float i;
	for (i = 0; i < HARDPOINT_DOTS; i = i + 1)
		hardpoint_dots[i] = Hardpoint_SpawnMarker(HP_DOT_GREY);

	hardpoint_pending = FALSE;
	hardpoint_last_index = -1;
	hardpoint_round = 0;
	hardpoint_radius = HARDPOINT_DEFAULT_RADIUS;
	hardpoint_occ_state = -1;
	hardpoint_setup_done = FALSE;
};

// Swap to grey or blue marker models on occupancy change (no per-frame work).
void() Hardpoint_SetMarkerState =
{
	float f = FALSE;
	entity p = find(world, classname, "player");
	while (p != world) {
		if (!p.downed && Hardpoint_PlayerInZone(p)) {
			f = TRUE;
			p = world;
		} else {
			p = find(p, classname, "player");
		}
	}

	if (f == hardpoint_occ_state)
		return;
	hardpoint_occ_state = f;

	if (hardpoint_arrow != world)
		setmodel(hardpoint_arrow, f ? HP_ARROW_BLUE : HP_ARROW_GREY);
	float i;
	for (i = 0; i < HARDPOINT_DOTS; i = i + 1)
		if (hardpoint_dots[i] != world)
			setmodel(hardpoint_dots[i], f ? HP_DOT_BLUE : HP_DOT_GREY);
};

// Soft_Restart re-closes doors but doesn't re-run setup, so clear the flag to make
// Gamemode_Hardpoint_Frame re-open doors and re-pick a zone (else: zone behind a locked door).
void() Gamemode_Hardpoint_OnRestart =
{
	hardpoint_setup_done = FALSE;
	hardpoint_pending = FALSE;
	if (hardpoint_next_arrow != world)
		setorigin(hardpoint_next_arrow, '0 0 -16000');
};

void() Gamemode_Hardpoint_Frame =
{
	if (!hardpoint_setup_done) {
		if (rounds < 1)
			return;
		Hardpoint_CollectAnchors();
		Hardpoint_OpenAllDoors();
		hardpoint_round = rounds;
		Hardpoint_Relocate();
		hardpoint_setup_done = TRUE;
		return;
	}

	// round changed -> begin a 7s NEXT POINT preview (current zone stays live)
	if (rounds != hardpoint_round) {
		hardpoint_round = rounds;
		if (!hardpoint_pending) {
			Hardpoint_PickNext();
			hardpoint_swap_at = time + HARDPOINT_NEXT_LEAD;
			hardpoint_msg_at = 0;
			hardpoint_pending = TRUE;
		}
	}

	if (hardpoint_pending) {
		if (time >= hardpoint_swap_at) {
			Hardpoint_ApplyNext();
			hardpoint_pending = FALSE;
		} else if (time >= hardpoint_msg_at) {
			hardpoint_msg_at = time + 1;
			float secs = ceil(hardpoint_swap_at - time);
			entity p = find(world, classname, "player");
			while (p != world) {
				centerprint(p, strcat("NEXT POINT  ", ftos(secs)));
				p = find(p, classname, "player");
			}
		}
	}

	Hardpoint_SetMarkerState();
};
