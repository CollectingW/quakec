/*
	client/grenade_trajectory.qc

	Third-person grenade trajectory preview.
	Draws a simulated arc (dotted ribbon) + red translucent impact circle
	while the local player is holding a primed frag grenade in chase-cam mode.

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

#ifdef FTE

//
// Constants
//
#define GTRAJ_GRAVITY		800.0		// Should match sv_gravity (default)
#define GTRAJ_SPEED			1400.0		// Matches nade.velocity = v_forward * 1400
#define GTRAJ_TIMESTEP		0.04		// Simulation step (seconds) - ~25 steps/second
#define GTRAJ_MAXSTEPS		60			// Max simulation steps (~2.4 sec)
#define GTRAJ_DOT_RADIUS	3.0			// Half-width of arc ribbon (world units)
#define GTRAJ_IMPACT_SEGS	24			// Segments for impact circle
#define GTRAJ_IMPACT_RADIUS	50.0		// Radius of impact zone circle (world units)

// GrenadeTrajectory_DrawCircle(origin, normal, radius): flat circle at a world
// position, oriented to the surface normal, via R_BeginPolygon line-loops.
void(vector org, vector surf_normal, float radius) GrenadeTrajectory_DrawCircle =
{
	// Build a local coordinate frame on the surface plane
	vector right, fwd;
	if (fabs(surf_normal_z) < 0.9)
		right = normalize(crossproduct(surf_normal, '0 0 1'));
	else
		right = normalize(crossproduct(surf_normal, '1 0 0'));
	fwd = crossproduct(right, surf_normal);

	// Filled translucent red disc (triangle fan)
	R_BeginPolygon("", DRAWFLAG_TWOSIDED | DRAWFLAG_ADD);
	int i;
	float angle_step = 360.0 / GTRAJ_IMPACT_SEGS;
	vector center_rgba = '1 0 0';	// RGB red
	float disc_alpha = 0.20;

	// Centre vertex
	R_PolygonVertex(org + surf_normal * 2, '0.5 0.5', center_rgba, disc_alpha);

	for (i = 0; i <= GTRAJ_IMPACT_SEGS; i++) {
		float a = i * angle_step * (M_PI / 180.0);
		vector rim = org + surf_normal * 2
		           + right * (cos(a) * radius)
		           + fwd   * (sin(a) * radius);
		R_PolygonVertex(rim, [cos(a) * 0.5 + 0.5, sin(a) * 0.5 + 0.5], center_rgba, disc_alpha);
	}
	R_EndPolygon();

	// Bright red rim outline (line loop)
	R_BeginPolygon("", DRAWFLAG_LINES | DRAWFLAG_TWOSIDED);
	for (i = 0; i <= GTRAJ_IMPACT_SEGS; i++) {
		float a = i * angle_step * (M_PI / 180.0);
		vector rim = org + surf_normal * 2
		           + right * (cos(a) * radius)
		           + fwd   * (sin(a) * radius);
		R_PolygonVertex(rim, [0, 0], '1 0.1 0.1', 0.9);
	}
	R_EndPolygon();
};

// GrenadeTrajectory_Draw(): entry point from CSQC_UpdateView (after renderscene),
// only when chase_active is true and the player holds a primed grenade.
void() GrenadeTrajectory_Draw =
{
	// Only show when in third-person and holding a primed FRAG (not betty)
	if (!cvar("chase_active"))
		return;
	if (!getstatf(STAT_HOLDING_GRENADE))
		return;

	// --- Calculate throw direction accounting for camera offset ---
	vector player_angles = getproperty(VF_ANGLES);
	vector eye_org = playerOrigin + [0, 0, getstatf(STAT_VIEWHEIGHT)];
	vector throw_dir;
	vector target_point;

	// Calculate camera position (matching chase.c and server-side logic)
	vector cam_angles, cam_forward, cam_right, cam_up, cam_pos;
	float back_val, up_val, right_val;
	float chase_side, is_left;

	cam_angles_x = player_angles_x * 0.5;
	cam_angles_y = player_angles_y;
	cam_angles_z = 0;
	makevectors(cam_angles);
	cam_forward = v_forward;
	cam_right = v_right;
	cam_up = v_up;

	chase_side = cvar("chase_side");
	is_left = (chase_side < 0) ? 1 : 0;

	// Camera offsets (must match chase.c values)
	back_val = 70;
	up_val = 14;
	right_val = is_left ? -15 : 18;

	up_val = up_val + (player_angles_x / 90.0) * 20;

	cam_pos = eye_org - cam_forward * back_val + cam_right * right_val;
	cam_pos_z = cam_pos_z + up_val;

	// Trace from camera to find target point (where crosshair is aiming)
	makevectors(player_angles);
	traceline(cam_pos, cam_pos + v_forward * 4096, MOVE_NOMONSTERS, world);
	target_point = trace_endpos;

	// Calculate throw direction from player position to target
	throw_dir = normalize(target_point - eye_org);

	// Launch point: player eye origin offset in throw direction
	vector launch_pos = eye_org + throw_dir * 12;

	vector vel = throw_dir * GTRAJ_SPEED;

	vector prev_pos = launch_pos;
	vector hit_pos  = launch_pos;
	vector hit_norm = '0 0 1';
	float  hit_frac = 1.0;

	int step;
	int total_steps = 0;

	// Store arc vertices for ribbon drawing
	// (max GTRAJ_MAXSTEPS + 1 points)
	vector arc_pts[GTRAJ_MAXSTEPS + 1];
	arc_pts[0] = prev_pos;

	for (step = 1; step <= GTRAJ_MAXSTEPS; step++) {
		// Advance physics: semi-implicit euler
		vel_z -= GTRAJ_GRAVITY * GTRAJ_TIMESTEP;
		vector next_pos = prev_pos + vel * GTRAJ_TIMESTEP;

		// Trace this segment
		traceline(prev_pos, next_pos, MOVE_NOMONSTERS, world);

		arc_pts[step] = trace_endpos;
		total_steps = step;

		if (trace_fraction < 1.0) {
			// Hit something -- stop here
			hit_pos  = trace_endpos;
			hit_norm = trace_plane_normal;
			hit_frac = trace_fraction;
			break;
		}

		prev_pos = next_pos;
	}

	if (total_steps < 1)
		return;

	// draw the arc as a ribbon of quads: extrude a narrow quad sideways per
	// point-pair via R_BeginPolygon (two tris per segment).
	R_BeginPolygon("", DRAWFLAG_TWOSIDED | DRAWFLAG_ADD);

	float arc_alpha_base = 0.85;
	vector arc_color = '1 0.6 0.1';	// orange-yellow

	// Build right-vector relative to viewer for ribbon orientation
	// VF_RIGHT is not available; derive from the current camera angles.
	makevectors(player_angles);
	vector view_right = v_right;

	int s;
	for (s = 0; s < total_steps; s++) {
		vector p0 = arc_pts[s];
		vector p1 = arc_pts[s + 1];

		// Step progress 0..1 for fade
		float t0 = s       / (float)total_steps;
		float t1 = (s + 1) / (float)total_steps;

		// Fade color: orange near launch -> red near impact
		vector c0 = arc_color * (1 - t0) + '1 0 0' * t0;
		vector c1 = arc_color * (1 - t1) + '1 0 0' * t1;

		float a0 = arc_alpha_base * (1 - t0 * 0.5);
		float a1 = arc_alpha_base * (1 - t1 * 0.5);

		// Draw as a billboarded quad (two triangles)
		// Extrude along view_right to create visible thickness
		vector off = view_right * GTRAJ_DOT_RADIUS;

		// Tri 1: p0-off, p0+off, p1+off
		R_PolygonVertex(p0 - off, '0 0', c0, a0);
		R_PolygonVertex(p0 + off, '1 0', c0, a0);
		R_PolygonVertex(p1 + off, '1 1', c1, a1);
		R_EndPolygon();

		// Tri 2: p0-off, p1+off, p1-off
		R_BeginPolygon("", DRAWFLAG_TWOSIDED | DRAWFLAG_ADD);
		R_PolygonVertex(p0 - off, '0 0', c0, a0);
		R_PolygonVertex(p1 + off, '1 1', c1, a1);
		R_PolygonVertex(p1 - off, '0 1', c1, a1);
		R_EndPolygon();

		if (s < total_steps - 1)
			R_BeginPolygon("", DRAWFLAG_TWOSIDED | DRAWFLAG_ADD);
	}

	// --- Draw impact circle ---
	if (hit_frac < 1.0) {
		GrenadeTrajectory_DrawCircle(hit_pos, hit_norm, GTRAJ_IMPACT_RADIUS);

		// Small pulsing dot at impact centre
		float pulse = 0.6 + sin(cltime * 6) * 0.3;
		dynamiclight_add(hit_pos + hit_norm * 4, 40 * pulse, '1 0 0');
	}
};

#endif // FTE
