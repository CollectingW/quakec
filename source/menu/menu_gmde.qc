// Gamemodes Menu

string menu_gamemodes_buttons[] = {
	"gm_classic", "gm_gungame", "gm_hardcore", "gm_wildwest", "gm_sticks", "gm_festive", "gm_random", "gm_hardpoint", "gm_cranked", "gm_skullball", "gm_back"
};

float current_gamemode;

string() Menu_Gamemodes_GetCurrentModeName =
{
	switch(current_gamemode) {
		case 0: return "Classic";
		case 2: return "Gun Game";
		case 3: return "Hardcore";
		case 4: return "Wild West";
		case 5: return "Sticks and Stones";
		case 6: return "Festive";
		case 7: return "Random";
		case 8: return "Hardpoint";
		case 9: return "Cranked";
		case 10: return "Skull Ball";
		default: return "Classic";
	}
	return "Classic";
};

void(float mode) Menu_Gamemodes_SetMode =
{
	current_gamemode = mode;
	cvar_set("sv_gamemode", ftos(mode));
	Menu_PlaySound(MENU_SND_ENTER);
};

void() Menu_Gamemodes_Init =
{
	static float initialized;
	if (!initialized)
	{
		current_gamemode = cvar("sv_gamemode");
		initialized = true;
	}
};

void() Menu_Gamemodes =
{
	Menu_Gamemodes_Init();

	Menu_DrawBackground();
	Menu_DrawTitle("GAMEMODES");

	// Show current mode
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, 80], MENU_TEXT_SMALL, sprintf("Current: %s", Menu_Gamemodes_GetCurrentModeName()), [1, 1, 0], 1, 0);

	Menu_Button(1, "gm_classic", "CLASSIC", "Standard Zombies survival mode.") ? Menu_Gamemodes_SetMode(0) : 0;
	Menu_Button(2, "gm_gungame", "GUN GAME", "Progress through weapons by getting kills.") ? Menu_Gamemodes_SetMode(2) : 0;
	Menu_Button(3, "gm_hardcore", "HARDCORE", "Increased difficulty with tougher zombies.") ? Menu_Gamemodes_SetMode(3) : 0;
	Menu_Button(4, "gm_wildwest", "WILD WEST", "Western-themed weapon loadout.") ? Menu_Gamemodes_SetMode(4) : 0;
	Menu_Button(5, "gm_sticks", "STICKS AND STONES", "Ballistic Knife and Crossbow only.") ? Menu_Gamemodes_SetMode(5) : 0;
	Menu_Button(6, "gm_festive", "FESTIVE", "Holiday-themed mode.") ? Menu_Gamemodes_SetMode(6) : 0;
	Menu_Button(7, "gm_random", "RANDOM", "RNG: random start gun, wall-buys and perks.") ? Menu_Gamemodes_SetMode(7) : 0;
	Menu_Button(8, "gm_hardpoint", "HARDPOINT", "Earn points only inside the moving hardpoint zone.") ? Menu_Gamemodes_SetMode(8) : 0;
	Menu_Button(9, "gm_cranked", "CRANKED", "Kill fast to stay Cranked. Run out of time and you bleed.") ? Menu_Gamemodes_SetMode(9) : 0;
	Menu_Button(10, "gm_skullball", "SKULL BALL", "Carry a random skull to the pedestal to score points.") ? Menu_Gamemodes_SetMode(10) : 0;

	Menu_DrawDivider(11);
	Menu_Button(11.25, "gm_back", "BACK", "Return to Main Menu.") ? current_menu = MENU_MAIN : 0;

	sui_pop_frame();
};

#define NEXTBUTTON_FUNC(fn, arr) 				\
string(string prev_id) fn ## _GetNextButton =	\
{ 												\
	if (prev_id == "") 							\
		return arr[0]; 							\
												\
	string ret = arr[0];						\
												\
	for(float i = 0; i < arr.length; i++) {		\
		if (arr[i] == prev_id) {				\
			if (i + 1 >= arr.length)			\
				break;							\
												\
			ret = arr[i + 1];					\
			break;								\
		}										\
	}											\
												\
	return ret;									\
};

NEXTBUTTON_FUNC(Menu_Gamemodes, menu_gamemodes_buttons)

#undef NEXTBUTTON_FUNC

#define PREVBUTTON_FUNC(fn, arr) 					\
string(string next_id) fn ## _GetPreviousButton =	\
{													\
	if (next_id == "")								\
		return arr[arr.length - 1];					\
													\
	string ret = arr[arr.length - 1];				\
													\
	for(float i = arr.length - 1; i > 0; i--) {		\
		if (arr[i] == next_id) {					\
			if (i - 1 < 0)							\
				break;								\
													\
			ret = arr[i - 1];						\
			break;									\
		}											\
	}												\
													\
	return ret;										\
};

PREVBUTTON_FUNC(Menu_Gamemodes, menu_gamemodes_buttons)

#undef PREVBUTTON_FUNC
