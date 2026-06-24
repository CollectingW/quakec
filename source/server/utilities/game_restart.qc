/*
	server/utilities/game_restart.qc

	A utility for re-starting the game without going through the
    server unload procedure.

	Copyright (C) 2021-2024 NZ:P Team

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

	See the GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to:

		Free Software Foundation, Inc.
		59 Temple Place - Suite 330
		Boston, MA  02111-1307, USA

*/

void() PutClientInServer;
void() InitRounds;
void() func_door_nzp;
void(entity e) Light_None;
void() setup_perk;
void() touch_perk;
void(entity ent) MBOX_FreeEnt;
entity() MBOX_GetFreeEnt;
void() MBOX_Touch;

//
// GameRestart_CleanPowerUps()
// Cleans Power-Ups thrown about on the map,
// as well as a sanity check for their state.
//
void() GameRestart_CleanPowerUps =
{
    entity tempe;

    // Delete lingering PU entities
    tempe = find(world, classname, "item_powerup");
    while(tempe != world) {
        // Kill their sounds
        sound(tempe.owner, CHAN_VOICE, "sounds/null.wav", 1, ATTN_NORM);
	    sound(tempe, CHAN_AUTO, "sounds/null.wav", 1, ATTN_NONE);

        // Delete em
        remove(tempe.owner); // Sparkle
        remove(tempe);

        // Iterate to the next
        tempe = find(tempe, classname, "item_powerup");
    }

    // Turn off HUD icons
    tempe = find(world, classname, "player");
    while (tempe != world) {
        tempe.insta_icon = false;
        tempe.x2_icon = false;
        tempe = find(tempe, classname, "player");
    }

    // They're finished, stop doing the effects.
    instakill_finished = time;
    x2_finished = time;
}

//
// GameRestart_CleanWallSummons()
// Removes World models summoned from
// weapon_wall.
//
void() GameRestart_CleanWallSummons =
{
    entity tempe;

    tempe = find(world, classname, "weapon_wall");
    while (tempe != world) {
        // Check if it's model has been set, if it is undo the damage.
        if (tempe.enemy.model != "") {
			setmodel(tempe.enemy, "");
			tempe.enemy.boxstatus = 0;
			makevectors(tempe.angles);
			setorigin(tempe.enemy, tempe.origin + v_right*-4);
		}
            
        tempe = find(tempe, classname, "weapon_wall");
    }
}

//
// GameRestart_RepairBarricades()
// Resets the barricade health state.
//
void() GameRestart_RepairBarricades =
{
 	entity tempe;
	
	tempe = find(world, classname, "window");
    while (tempe != world) {
        if (tempe.health != -10) {
            tempe.health = 6;
            tempe.frame = 0;
        }

        tempe = find(tempe, classname, "window");
    }
}

//
// GameRestart_TurnPerkOff()
// Wrapper for turning off Perk lights.
//
void(string perk_classname) GameRestart_TurnPerkOff =
{
	entity tempe;

	tempe = find(world, classname, perk_classname);
	while(tempe != world) {
		setmodel(tempe, tempe.door_model_name);
		setorigin(tempe, tempe.oldorigin);
		setsize(tempe, VEC_HULL2_MIN, VEC_HULL2_MAX);

		Light_None(tempe);

		tempe.velocity = '0 0 0';
		tempe.touch = touch_perk;
		tempe.perk_purchase_count = 0;
		// .cnt (prone "loose change" claim) is reset in setup_perk, which this
		// re-runs via tempe.think below (.cnt isn't in scope in this file).
		// angles are already set

		// Run our initial setup function
		tempe.think = setup_perk;
		tempe.nextthink = time + 0.1;

		tempe = find(tempe, classname, perk_classname);
	}
}

//
// GameRestart_ResetPerkaColas()
// Make sure Perk-a-Colas are in their
// right states.
//
void() GameRestart_ResetPerkaColas =
{
	// Go on a reset spree!
	GameRestart_TurnPerkOff("perk_revive");		// Quick Revive
	GameRestart_TurnPerkOff("perk_juggernog");	// Jugger-Nog
	GameRestart_TurnPerkOff("perk_speed");		// Speed Cola
	GameRestart_TurnPerkOff("perk_double");		// Double Tap Root Beer
	GameRestart_TurnPerkOff("perk_flopper");	// PhD Flopper
	GameRestart_TurnPerkOff("perk_staminup");	// Stamin-Up
	GameRestart_TurnPerkOff("perk_deadshot");	// Deadshot Daiquiri
	GameRestart_TurnPerkOff("perk_mule");		// Mule Kick
}

//
// GameRestart_ResetMysteryBox
// Clean-Up the Mystery Box.
//
void() GameRestart_ResetMysteryBox =
{
	// Check if there is a Mystery Box in the map
	entity mystery_box = find(world, classname, "mystery");

	if (mystery_box.boxstatus == 0 && mystery_box.frame == 0 && mystery_box.spins == 0)
		return;

	if (mystery_box != world) {
		mystery_box.boxstatus = 0;
		mystery_box.frame = 0;
		mystery_box.spins = 0;

		if (mystery_box.goaldummy != world)
			mystery_box.goaldummy.frame = 0;

		if (mystery_box.boxweapon)
			MBOX_FreeEnt(mystery_box.boxweapon);

		// If the Mystery Box is not in its original
		// location.
		if (mystery_box.origin != mystery_box_start_origin) {
			mystery_box.model = "models/props/teddy.mdl";
			mystery_box.frame = 2;
			mystery_box.classname = "mystery_box_tp_spot";
			mystery_box.touch = SUB_Null;
			mystery_box.angles_y -= 90;

			if (mystery_box.goaldummy != world)
				MBOX_FreeEnt(mystery_box.goaldummy);

			// This isn't the normal spawn position
			if (mystery_box.origin != mystery_box_start_origin) {
				// Find the original spot
				entity original_box = find(world, classname, "mystery_box_tp_spot");
				while (original_box != world) {
					if (original_box.origin == mystery_box_start_origin)
						break;
					
					original_box = find(original_box, classname, "mystery_box_tp_spot");
				}

				// Spawn the Box Glow if permitted
				if (!(mystery_box.spawnflags & 2)) {
					entity light = MBOX_GetFreeEnt();
					light.classname = "mystery_glow";
					original_box.goaldummy = light;

					setmodel(light, mystery_box_glow_model);
					setorigin(light, original_box.origin);
					light.angles = original_box.angles;

#ifdef FTE

					light.alpha = 0.5;

#endif // FTE

				}

				original_box.touch = MBOX_Touch;
				original_box.solid = SOLID_TRIGGER;
				original_box.classname = "mystery";
				setorigin(original_box, original_box.origin);
				setmodel(original_box, mystery_box_model);
				setsize (original_box, VEC_HULL2_MIN, VEC_HULL2_MAX);
			}

			Light_None(mystery_box);
			setmodel(mystery_box, mystery_box.model);
		}
	}
}

//
// GameRestart_RestoreFakeRemovals()
// Puts back everything "removed" using Ent_FakeRemove().
//
void() GameRestart_RestoreFakeRemovals =
{
	entity ent = findfloat(world, entity_removed, true);
	while(ent != world) {
		ent.entity_removed = false;
		ent.model = ent.oldmodel;
		ent.origin = ent.oldorigin;
		ent.mins = ent.bbmins;
		ent.maxs = ent.bbmaxs;
		ent.solid = ent.sprintflag;
		setsize(ent, ent.mins, ent.maxs);
		setmodel(ent, ent.model);

		ent = findfloat(world, entity_removed, true);
	}
}

//
// GameRestart_OpenClosedDoors()
// Restores doors that were previously opened in last session.
//
void() GameRestart_OpenClosedDoors =
{
	// Grab every open door.
	entity door = findfloat(world, isopen, true);
	entity temp_ent;

	while(door) {
		setmodel(door, door.oldmodel);
		door.solid = SOLID_BSP;
		setorigin(door, door.oldorigin);
		door.isopen = false;

		// Run the spawn function again.
		temp_ent = self;
		self = door;
		func_door_nzp();
		self = temp_ent;

#ifndef FTE
		// re-block the spawn graph (door_go_up opened it with Open_Waypoint when bought),
		// else zombies keep spawning behind doors that are locked again this game.
		if (door.wayTarget != "")
			Close_Waypoint(door.wayTarget);
#endif

		door = findfloat(world, isopen, true);
	}
}

//
// GameRestart_ResetPower()
// Turns off Power and resets Power Switch state.
//
void() GameRestart_ResetPower =
{
	entity power_switch;
	power_switch = find(world, classname, "power_switch");

	if (power_switch) {
		isPowerOn = false;
		power_switch.frame = 0;
		power_switch.activated = false;

		if (!(power_switch.spawnflags & 1)) {
			power_switch.boxweapon.angles = power_switch.angles;
		}
	}
};

void() Soft_Restart = {
	entity who, oldself, endgame, game_over;
	self = find(world,classname,"player");
	oldself = self;
	
	//remove all zombies
	who = find(world,classname,"ai_zombie");
	while(who != world)
	{
		if(who.health)
		{
			self = who;
			self.th_die();

			// hide bodies
			setmodel(self, "");
			if (self.head)
				setmodel(self.head, "");
			if (self.larm)
				setmodel(self.larm, "");
			if (self.rarm)
				setmodel(self.rarm, "");

			self = oldself;
		}
		
		who = find(who,classname,"ai_zombie");
	}

	// remove leftover dogs (ai_dog) -- they weren't cleared and leaked into the fresh game
	who = find(world,classname,"ai_dog");
	while (who != world)
	{
		entity nextdog = find(who,classname,"ai_dog");
		remove(who);
		who = nextdog;
	}

	// nuke lingering revive triggers from the previous game -- if one survives the
	// restart it will "revive" a now-healthy player and freeze their movement.
	entity rt = find(world, classname, "revive_trigger");
	while (rt != world) {
		entity nextrt = find(rt, classname, "revive_trigger");
		remove(rt);
		rt = nextrt;
	}

    GameRestart_CleanPowerUps();		// Get rid of any Power-Ups that were spawned and left.
    GameRestart_CleanWallSummons();		// Delete residual wall weapon spawns from our last game.
	GameRestart_RepairBarricades();		// Make sure all barricades are fully repaired.
	GameRestart_ResetPerkaColas(); 		// Turn all of the Perk-a-Cola lights off, reset states.
	GameRestart_ResetMysteryBox();		// Clean up the Mystery Box, delete floating weapon, etc.
	GameRestart_RestoreFakeRemovals();	// Puts back everything "removed" using Ent_FakeRemove().
	GameRestart_OpenClosedDoors(); 		// Restores doors that were previously opened in last session.
	GameRestart_ResetPower();			// Turns off Power and resets Power Switch state.
	Gamemode_Hardpoint_OnRestart();		// Hardpoint: re-open all doors at round 1 (else a zone can lock behind a shut door = softlock).

	//reset buyable ending
	endgame = find(world, classname, "func_ending");
	if (endgame) {
		endgame.activated = false;
	}

	// Restart End Game sequence
	game_over = find(world, classname, "gameover_watcher");
	if (game_over) {
		remove(game_over);
	}

	//reset teleporters
	local entity tp;
	tp = find(world, classname, "func_teleporter_entrance");

	if (tp) {
		tp.activated = false;
		tp.isLinked = false;
		tp.cooldown = false;
		tp.waitLink = false;
		tp.think = SUB_Null;
	}

	// Global (once) resets.
	in_endgame_sequence = false;
	rounds = 0;
	player_count = 0;
	InitRounds();
	Gamemode_Cranked_Init();	// clear Cranked tier/powerup timers so a restart starts fresh
	Gamemode_SkullBall_OnRestart();	// re-arm Skull Ball setup (reopen doors, re-place skull) at round 1

	// players who bled out became spectators -- the loop below only finds "player",
	// so fold them back into the player set first or they're never respawned.
	entity sp = find(world, classname, "spectator");
	while (sp != world) {
		entity nextsp = find(sp, classname, "spectator");
		sp.classname = "player";
		sp.is_spectator = false;
		sp.spec_viewtarget = world;
		sp = nextsp;
	}

	// reset AND respawn EVERY player, not just the first found -- the original code
	// only respawned the host, so co-op joiners were left with no view/model.
	entity p = find(world, classname, "player");
	while (p != world) {
		entity nextp = find(p, classname, "player");

		self = p;
		self.downed = 0;
		// clear any leftover revive linkage/penalty so a respawned player
		// isn't stuck "being revived" or movement-locked after the restart.
		self.beingrevived = false;
		self.firer = world;
		self.speed_penalty = 0;
		self.speed_penalty_time = 0;
		self.progress_bar = 0;
		self.progress_bar_time = 0;
		self.progress_bar_percent = 0;
		self.isBuying = false;
		self.style = 0;
		self.score = 0;
		self.points = 0;
		self.kills = 0;

		for(float i = 0; i < MAX_PLAYER_WEAPONS; i++) {
			self.weapons[i].weapon_id = 0;
		}

		// naievil -- clear betty
		self.secondary_grenades = 0;
		self.grenades = 1;
		self.pri_grenade_state = 0;

		PutClientInServer();

		p = nextp;
	}

	nzp_screenflash(world, SCREENFLASH_COLOR_BLACK, 1, SCREENFLASH_FADE_OUT);
}