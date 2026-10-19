//  Archery target: arrows stick into the target and can be pulled out.
//  Alt + LMB toggles the mode: competition / training.

#define ARCHERY_RINGS            10     // number of rings (score 1-10)
#define ARCHERY_RING_WIDTH       3      // ring width in px
#define ARCHERY_RADIUS           (ARCHERY_RINGS * ARCHERY_RING_WIDTH) // 30 px
#define ARCHERY_MAX_SKILL        6      // scale 0..6 (SKILL_LEVEL / 10)
#define ARCHERY_SPLIT_CHANCE     1      // % chance to split an arrow (competition mode)
#define ARCHERY_OVERLAP_PX       3      // distance at which arrows "touch"
#define ARCHERY_PULL_RANGE_PX    4      // max click distance from an arrow to pull it

#define ARCHERY_MODE_TRAINING    0
#define ARCHERY_MODE_COMPETITION 1

// ---------- Spread formula ----------
// Hit distribution is Rayleigh; sigma decreases with skill.
/proc/archery_sigma(skill)
	var/k = 1 - clamp(skill, 0, ARCHERY_MAX_SKILL) / ARCHERY_MAX_SKILL
	return 3 + 27 * k // skill 0 -> sigma 30 px, max skill -> sigma 3 px

/proc/archery_cdf(r, sigma)
	if(r <= 0)
		return 0
	return 1 - exp(-(r * r) / (2 * sigma * sigma))

/proc/archery_score_for_distance(d)
	if(d > ARCHERY_RADIUS)
		return 0
	if(d <= 0)
		return ARCHERY_RINGS
	var/ring = ceil(d / ARCHERY_RING_WIDTH)
	return ARCHERY_RINGS + 1 - ring

/proc/archery_chance(score, sigma)
	if(score <= 0)
		return 1 - archery_cdf(ARCHERY_RADIUS, sigma)
	var/ring = ARCHERY_RINGS + 1 - score
	var/inner_r = (ring - 1) * ARCHERY_RING_WIDTH
	var/outer_r = ring * ARCHERY_RING_WIDTH
	return archery_cdf(outer_r, sigma) - archery_cdf(inner_r, sigma)

// Archery skill level scaled to 0..ARCHERY_MAX_SKILL
/proc/get_archery_skill(mob/M)
	if(!M)
		return 0
	var/level = GET_MOB_SKILL_VALUE_OLD(M, /datum/attribute/skill/combat/bows)
	return round(level / 10)

// ---------- Stuck arrow ----------
/datum/archery_stuck
	var/obj/item/arrow
	var/image/visual
	var/px = 0
	var/py = 0
	var/score = 0
	var/mob/shooter

/datum/archery_stuck/Destroy()
	arrow = null
	visual = null
	shooter = null
	return ..()

// ---------- Target ----------
/obj/structure/archery_target
	name = "archery target"
	desc = "A wooden archery target. Arrows stick in it firmly, but they can be pulled out."
	icon = 'icons/roguetown/weapons/32/bows.dmi' // TEMPORARY: replace with a 64x64 target sprite
	icon_state = "bow"
	density = TRUE
	anchored = TRUE
	var/mode = ARCHERY_MODE_TRAINING
	var/list/datum/archery_stuck/stuck = list()

/obj/structure/archery_target/Destroy()
	for(var/datum/archery_stuck/S in stuck)
		if(S.arrow)
			S.arrow.forceMove(get_turf(src))
		qdel(S)
	stuck.Cut()
	return ..()

/obj/structure/archery_target/bullet_act(obj/projectile/P, def_zone, piercing_hit = FALSE)
	if(istype(P, /obj/projectile/bullet/reusable/arrow) && !istype(P, /obj/projectile/bullet/reusable/arrow/pyro) && !istype(P, /obj/projectile/bullet/reusable/arrow/vial) && !istype(P, /obj/projectile/bullet/reusable/arrow/water))
		playsound(src, P.hitsound, 30, TRUE)
		receive_arrow(P, P.firer)
		return BULLET_ACT_HIT
	return ..()

// Alt + LMB: toggle mode
/obj/structure/archery_target/AltClick(mob/user, list/modifiers)
	mode = (mode == ARCHERY_MODE_TRAINING) ? ARCHERY_MODE_COMPETITION : ARCHERY_MODE_TRAINING
	var/mode_name = (mode == ARCHERY_MODE_COMPETITION) ? "competition" : "training"
	to_chat(user, span_notice("The target is switched to [mode_name] mode."))
	return TRUE

// Pulling an arrow: LMB on the target with an empty hand, at the spot of the stuck arrow
/obj/structure/archery_target/attack_hand(mob/user, list/modifiers)
	if(!stuck.len || user.get_active_held_item())
		return ..()

	var/cx = text2num(LAZYACCESS(modifiers, ICON_X)) - 32 // 32 = half of the 64px sprite
	var/cy = text2num(LAZYACCESS(modifiers, ICON_Y)) - 32

	var/datum/archery_stuck/best
	var/best_dist = ARCHERY_PULL_RANGE_PX
	for(var/datum/archery_stuck/S in stuck)
		var/d = sqrt((S.px - cx) ** 2 + (S.py - cy) ** 2)
		if(d < best_dist)
			best_dist = d
			best = S

	if(!best)
		return ..()

	stuck -= best
	overlays -= best.visual
	var/obj/item/ammo_casing/caseless/arrow/A = new(get_turf(user))
	user.put_in_hands(A)
	user.visible_message(span_notice("[user] pulls an arrow out of the target."))
	qdel(best)
	return TRUE

// Receiving an arrow from the projectile (called from arrow.dm -> on_hit)
/obj/structure/archery_target/proc/receive_arrow(obj/projectile/arrow_projectile, mob/shooter)
	if(!arrow_projectile)
		return

	// 1. Roll the hit position
	var/sigma = archery_sigma(get_archery_skill(shooter))
	var/u = max(rand(), 0.000001)
	var/d_raw = sigma * sqrt(-2 * log(u))
	var/angle = rand() * 360
	var/px = round(d_raw * cos(angle))
	var/py = round(d_raw * sin(angle))
	var/dist = sqrt(px * px + py * py)
	var/score = archery_score_for_distance(dist)

	// 2. Competition mode: chance to split an arrow that is already stuck
	if(mode == ARCHERY_MODE_COMPETITION)
		for(var/datum/archery_stuck/old in stuck)
			var/gap = sqrt((old.px - px) ** 2 + (old.py - py) ** 2)
			if(gap <= ARCHERY_OVERLAP_PX && prob(ARCHERY_SPLIT_CHANCE))
				split_arrow(old)
				break

	// 3. Stick the arrow: the arrow object is not created here, so the projectile's visual is used
	var/datum/archery_stuck/S = new
	S.arrow = null
	S.px = px
	S.py = py
	S.score = score
	S.shooter = shooter
	S.visual = image(arrow_projectile.icon, arrow_projectile.icon_state)
	S.visual.pixel_x = px
	S.visual.pixel_y = py
	overlays += S.visual
	stuck += S

	// 4. Messages
	if(mode == ARCHERY_MODE_COMPETITION)
		var/sigma_now = archery_sigma(get_archery_skill(shooter))
		var/chance_ten = archery_chance(ARCHERY_RINGS, sigma_now)
		var/chance_this = archery_chance(score, sigma_now)
		var/msg = span_notice("<b>[shooter ? shooter.name : "Someone"]</b> shoots at the target. Chance for 10 points: [round(chance_ten * 100, 0.1)]%. Score: [score] points (chance for this score: [round(chance_this * 100, 0.1)]%).")
		for(var/mob/M in view(7, src))
			to_chat(M, msg)
	else if(shooter)
		to_chat(shooter, span_notice("You hit the target."))

// An older arrow is split in half by a new one
/obj/structure/archery_target/proc/split_arrow(datum/archery_stuck/old)
	stuck -= old
	overlays -= old.visual
	var/turf/T = get_turf(src)
	new /obj/item/archery_arrow_half(T)
	new /obj/item/archery_arrow_half(T)
	if(old.shooter)
		to_chat(old.shooter, span_warning("Your arrow was split in half by another arrow!"))
	for(var/mob/M in view(7, src))
		to_chat(M, span_warning("An arrow stuck in the target is split in half!"))
	qdel(old)

// ---------- Split arrow ----------
/obj/item/archery_arrow_half
	name = "split arrow"
	desc = "A piece of an arrow, split in half."
	icon = 'icons/roguetown/weapons/ammo.dmi'
	icon_state = "arrow"
	w_class = WEIGHT_CLASS_TINY
