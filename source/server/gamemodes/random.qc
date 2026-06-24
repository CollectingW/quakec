/*
	server/gamemodes/random.qc

	"Random" gamemode: RNG twist on any map -- random start gun, random wall-buys,
	random de-duplicated perks. Everything is precached in Gamemode_Random_Init so
	a mid-game setmodel can't crash the host.

	Copyright (C) 2021-2024 NZ:P Team
*/

// weapon pool for the start gun and wall-buys (normal guns only)
#define RANDOM_WEAPON_POOL 16

float(float i) Random_WeaponSlot =
{
	switch(i) {
		case 0:  return W_KAR;
		case 1:  return W_THOMPSON;
		case 2:  return W_MP40;
		case 3:  return W_STG;
		case 4:  return W_BAR;
		case 5:  return W_MG;
		case 6:  return W_DB;
		case 7:  return W_SAWNOFF;
		case 8:  return W_M1A1;
		case 9:  return W_GEWEHR;
		case 10: return W_M1;
		case 11: return W_TYPE;
		case 12: return W_PPSH;
		case 13: return W_FG;
		case 14: return W_357;
		case 15: return W_BROWNING;
		default: return W_KAR;
	}
};

float() Random_PickWeapon =
{
	return Random_WeaponSlot(rint(random() * (RANDOM_WEAPON_POOL - 1)));
};

// de-duplicated wall-buy picker: each wall gets a distinct weapon until the pool recycles
float random_wall_used[RANDOM_WEAPON_POOL];

float() Random_PickWallWeapon =
{
	float i, used = 0;
	for (i = 0; i < RANDOM_WEAPON_POOL; i = i + 1)
		used = used + random_wall_used[i];
	if (used >= RANDOM_WEAPON_POOL)            // pool exhausted -> recycle
		for (i = 0; i < RANDOM_WEAPON_POOL; i = i + 1)
			random_wall_used[i] = 0;

	float tries = 0;
	while (tries < 64) {
		float idx = rint(random() * (RANDOM_WEAPON_POOL - 1));
		if (!random_wall_used[idx]) {
			random_wall_used[idx] = 1;
			return Random_WeaponSlot(idx);
		}
		tries = tries + 1;
	}
	return Random_WeaponSlot(rint(random() * (RANDOM_WEAPON_POOL - 1)));
};

// perk pool; random_perks_used is a bitmask so machines don't double up until all are dealt
float random_perks_used;

float(float i) Random_PerkId =
{
	switch(i) {
		case 0: return P_REVIVE;
		case 1: return P_JUG;
		case 2: return P_SPEED;
		case 3: return P_DOUBLE;
		case 4: return P_STAMIN;
		case 5: return P_FLOP;
		case 6: return P_DEAD;
		case 7: return P_MULE;
		default: return P_JUG;
	}
};

float(float i) Random_PerkSkin =
{
	switch(i) {
		case 0: return 1;
		case 1: return 2;
		case 2: return 3;
		case 3: return 4;
		case 4: return 5;
		case 5: return 6;
		case 6: return 7;
		case 7: return 8;
		default: return 2;
	}
};

string(float i) Random_PerkModel =
{
	switch(i) {
		case 0: return PERK_QUICKREVIVE_DEFAULT_MODEL;
		case 1: return PERK_JUGGERNOG_DEFAULT_MODEL;
		case 2: return PERK_SPEEDCOLA_DEFAULT_MODEL;
		case 3: return PERK_DOUBLETAP_DEFAULT_MODEL;
		case 4: return PERK_STAMINUP_DEFAULT_MODEL;
		case 5: return PERK_PHDFLOPPER_DEFAULT_MODEL;
		case 6: return PERK_DEADSHOT_DEFAULT_MODEL;
		case 7: return PERK_MULEKICK_DEFAULT_MODEL;
		default: return PERK_JUGGERNOG_DEFAULT_MODEL;
	}
};

// Pick a perk slot not yet used this map; reset the pool if all are taken.
float() Random_PickPerkSlot =
{
	float tries = 0;
	float slot;
	while (tries < 64) {
		slot = rint(random() * 7);
		if (!(random_perks_used & Random_PerkId(slot))) {
			random_perks_used = random_perks_used | Random_PerkId(slot);
			return slot;
		}
		tries = tries + 1;
	}
	// Everything used -> start a fresh cycle.
	slot = rint(random() * 7);
	random_perks_used = Random_PerkId(slot);
	return slot;
};

// pick a random unused perk into random_pick_* globals for Perk_InitMachine; TRUE if overrode
float() Random_OverridePerkMachine =
{
	if (!Gamemode_RandomActive())
		return FALSE;

	float slot = Random_PickPerkSlot();
	random_pick_model = Random_PerkModel(slot);
	random_pick_id = Random_PerkId(slot);   // the perk actually granted on buy
	random_pick_skin = Random_PerkSkin(slot); // drink animation skin
	return TRUE;
};

// wonder weapon for the rare "mystery" wall-buy (outside the normal pool)
float() Random_MysteryWeapon =
{
	switch (rint(random() * 2)) {
		case 0:  return W_RAY;		// Ray Gun
		case 1:  return W_TESLA;	// Wunderwaffe DG-2
		default: return W_RAYMK2;	// Ray Gun Mark II
	}
};

// shared wall-buy roll: ~8% mystery wonder weapon, else a de-duplicated pool weapon
float() Random_RollWallWeapon =
{
	if (random() < 0.08)
		return Random_MysteryWeapon();
	return Random_PickWallWeapon();
};

// assign a wall a random weapon and match its chalk/prop frame
void() Random_OverrideWallWeapon =
{
	if (!Gamemode_RandomActive())
		return;

	float w = Random_RollWallWeapon();
	self.weapon = w;
	self.sequence = w - 1; // prop model is GetWeaponModel(sequence + 1, 1)
};

// Gamemode_Random_Init(): runs at worldspawn -- precache everything that can be
// randomly given out (whole weapon pool + every perk model) since precache is load-only.
void() Gamemode_Random_Init =
{
	random_perks_used = 0;

	float i;
	for (i = 0; i < RANDOM_WEAPON_POOL; i = i + 1)
		random_wall_used[i] = 0;

	for (i = 0; i < RANDOM_WEAPON_POOL; i = i + 1) {
		float w = Random_WeaponSlot(i);
		precache_extra(w);
		precache_model(GetWeaponModel(w, 0));
		precache_model(GetWeaponModel(w, 1));
	}

	for (i = 0; i < 8; i = i + 1) {
		precache_model(Random_PerkModel(i));
	}

	// mystery wall-buy wonder weapons
	precache_extra(W_RAY);    precache_model(GetWeaponModel(W_RAY, 0));    precache_model(GetWeaponModel(W_RAY, 1));
	precache_extra(W_TESLA);  precache_model(GetWeaponModel(W_TESLA, 0));  precache_model(GetWeaponModel(W_TESLA, 1));
	precache_extra(W_RAYMK2); precache_model(GetWeaponModel(W_RAYMK2, 0)); precache_model(GetWeaponModel(W_RAYMK2, 1));
};

// hand the player a random starting gun
void() Gamemode_Random_PlayerSpawn =
{
	float w = Random_PickWeapon();
	Weapon_AssignWeapon(0, w, getWeaponMag(w), getWeaponAmmo(w), 0);
};
