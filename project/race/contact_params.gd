class_name ContactParams
extends Resource
## Contact penalty heuristic thresholds (issue #175), one data resource: see
## res://race/contact_params.tres. All values are estimates (Core Loop and Race Format).

@export var min_impulse := 400.0  ## N*s (estimate): attacker impulse needed to count as a hit
@export var min_time_loss := 1.5  ## s (estimate): victim time lost vs its pre-contact pace
@export var window := 3.0  ## s: look-ahead after the contact for time loss and positions gained
@export var pace_window := 1.0  ## s: victim's mean speed before the contact is its pace
@export var min_pace := 3.0  ## m/s: a victim slower than this before the hit has no pace to lose
@export var min_positions_gained := 1  ## attacker positions gained within the window
@export var penalty_seconds := 3.0  ## s (estimate)
@export var cooldown := 5.0  ## s (estimate): max 1 contact penalty per attacker/victim pair
@export var merge_gap := 0.25  ## s: contacts of one pair closer than this are one multi-frame contact
@export var zone_cos := 0.7071  ## |normal . victim forward| above this is rear/front, else side
@export var body_contact_distance := 4.4  ## m centre distance for the body-mode contact estimator
@export var body_min_closing := 0.5  ## m/s closing speed that arms the body-mode estimator
