## Nearby-car readout (#29): filled in place by `RaceManager.query()` so the AI reads the car
## ahead / behind without allocating or scanning the scene tree. Distances are along the centre
## line (m, between car centres); lateral values are metres from the centre line, + = right of travel.
class_name Proximity
extends RefCounted

var own_lat := 0.0
var own_speed := 0.0
var ahead := -1  ## car id of the nearest car in front within range, -1 = none
var ahead_gap := 0.0  ## m
var ahead_gap_s := 0.0  ## seconds at own speed (floored by RaceManager.min_gap_speed)
var ahead_lat := 0.0
var ahead_speed := 0.0
var behind := -1
var behind_gap := 0.0  ## m (positive)
var behind_gap_s := 0.0  ## seconds at the follower's speed
var behind_lat := 0.0
var behind_speed := 0.0
