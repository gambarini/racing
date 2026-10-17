## Auto-clutch engagement (#11): a pure function of the speed the driveline asks the engine to
## run at. Slip/lock bookkeeping lives in the Powertrain facade.
class_name Clutch
extends RefCounted


## 0..1 engagement from the larger of engine and driveline rpm: open at launch revs, closed when
## the driveline itself already turns fast (after a shift).
static func engagement(d: PowertrainDefinition, rpm_: float) -> float:
	return clampf((rpm_ - d.clutch_start_rpm) / maxf(d.clutch_full_rpm - d.clutch_start_rpm, 1.0), 0.0, 1.0)


## Torque capacity (Nm) at that engagement.
static func capacity(d: PowertrainDefinition, engagement_: float) -> float:
	return d.clutch_capacity * engagement_
