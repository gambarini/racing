// Spike #17: per-wheel numeric core (relaxed slip, combined-slip tire force, implicit Fx/Fy, stop
// limiter, wheel spin step) for 4 wheels as a GDExtension, written against the raw GDExtension C
// interface (gdextension_interface.h) so it builds with just a C++ compiler: no godot-cpp, no scons.
// Mirrors tools/bench/wheel_core_gd.gd (which calls the production TireModel/WheelSpin code).
// Class WheelCoreNative (RefCounted): step4(buf: PackedFloat64Array, dt: float) -> PackedFloat64Array.
#include "gdextension_interface.h"

#include <cmath>
#include <cstring>

static const int P_COUNT = 11, IN_STRIDE = 12, OUT_STRIDE = 5;

struct TP {
	double mu_peak, mu_slide, kappa_peak, alpha_peak, falloff, nominal_load, load_sens, relax_len,
			low_floor, min_relax;
};

static inline double sgn(double x) { return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0); }
static inline double clampd(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

static inline double shape(double x, const TP &p) {
	x = std::fabs(x);
	if (x <= 1.0) return std::sin(0.5 * M_PI * x);
	double r = p.mu_slide / p.mu_peak;
	double d = x - 1.0;
	return r + (1.0 - r) / (1.0 + p.falloff * d * d);
}
static inline double eff_mu(double fz, const TP &p) {
	double k = clampd(1.0 - p.load_sens * (fz - p.nominal_load) / p.nominal_load, 0.3, 1.5);
	return p.mu_peak * k;
}
static inline void compute(double kappa, double alpha, double fz, const TP &p, double &fx, double &fy) {
	fx = 0.0;
	fy = 0.0;
	if (fz <= 0.0) return;
	double sx = kappa / p.kappa_peak, sy = alpha / p.alpha_peak;
	double s = std::sqrt(sx * sx + sy * sy);
	if (s < 1e-9) return;
	double f = eff_mu(fz, p) * fz * shape(s, p);
	fx = f * sx / s;
	fy = -f * sy / s;
}
static inline double slip_ratio(double omega, double r, double vx, const TP &p) {
	double k = (omega * r - vx) / std::fmax(std::fabs(vx), p.low_floor);
	return clampd(k, -2.0, 2.0);
}
static inline double slip_angle(double vx, double vy, const TP &p) {
	return std::atan2(vy, std::fmax(std::fabs(vx), p.low_floor));
}
static inline double rate_of(double vx, const TP &p) {
	return std::fabs(vx) < p.low_floor ? p.min_relax : std::fabs(vx) / std::fmax(p.relax_len, 1e-4);
}
static inline double relax(double slip, double target, double vx, double dt, const TP &p) {
	return slip + (target - slip) * (1.0 - std::exp(-rate_of(vx, p) * dt));
}
static inline double spin_step(double omega, double td, double tb, double fx, double r, double I, double dt) {
	double fr = omega + (td - fx * r) / I * dt;
	double dw = std::fmax(tb, 0.0) / I * dt;
	if (std::fabs(fr) <= dw) return 0.0;
	return fr - sgn(fr) * dw;
}
static inline double implicit_fx(double fx0, double sw, double sv, double td, double r, double I,
		double m, double dt, double push) {
	double kw = std::fmax(sw, 0.0), kv = std::fmin(sv, 0.0);
	double denom = 1.0 + kw * dt * r / I - kv * dt / m;
	return (fx0 + kw * dt * td / I + kv * dt * push / m) / denom;
}
static inline double implicit_fy(double fy0, double sv, double m, double dt, double push) {
	double kv = std::fmin(sv, 0.0);
	return (fy0 + kv * dt * push / m) / (1.0 - kv * dt / m);
}
static inline double limit_to_stop(double force, double v, double m, double dt, double push) {
	if (force * v >= 0.0) return force;
	return sgn(force) * std::fmin(std::fabs(force), std::fmax(m * std::fabs(v) / dt + push * sgn(v), 0.0));
}

static void step4(const double *b, double dt, double *out) {
	TP p = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9]};
	double radius = b[10];
	for (int i = 0; i < 4; i++) {
		const double *w = b + P_COUNT + i * IN_STRIDE;
		double omega = w[0], kappa = w[1], alpha = w[2], vx = w[3], vy = w[4], fz = w[5];
		double td = w[6], brake = w[7], wi = w[8], m = w[9], push_x = w[10], push_y = w[11];
		kappa = relax(kappa, slip_ratio(omega, radius, vx, p), vx, dt, p);
		alpha = relax(alpha, slip_angle(vx, vy, p), vx, dt, p);
		double f0x, f0y;
		compute(kappa, alpha, fz, p, f0x, f0y);
		// WheelSpin.fx_slopes
		double gain = 1.0 - std::exp(-rate_of(vx, p) * dt);
		double dk = 0.01, ax, ay, bx, by;
		compute(kappa + dk, alpha, fz, p, ax, ay);
		compute(kappa - dk, alpha, fz, p, bx, by);
		double dfdk = (ax - bx) / (2.0 * dk);
		double dw = 0.05;
		double dkdw = (slip_ratio(omega + dw, radius, vx, p) - slip_ratio(omega - dw, radius, vx, p)) / (2.0 * dw);
		double dv = 0.05;
		double dkdv = (slip_ratio(omega, radius, vx + dv, p) - slip_ratio(omega, radius, vx - dv, p)) / (2.0 * dv);
		double slw = std::fmax(dfdk * dkdw * gain, 0.0), slv = std::fmin(dfdk * dkdv * gain, 0.0);
		double fx = implicit_fx(f0x, slw, slv, td, radius, wi, m, dt, push_x);
		if (brake > 0.0 && spin_step(omega, td, brake, fx, radius, wi, dt) == 0.0)
			fx = implicit_fx(f0x, 0.0, slv, td, radius, wi, m, dt, push_x);
		// WheelSpin.fy_slope
		double da = 0.01, cx, cy, ex, ey;
		compute(kappa, alpha + da, fz, p, cx, cy);
		compute(kappa, alpha - da, fz, p, ex, ey);
		double dfda = (cy - ey) / (2.0 * da);
		double dadv = (slip_angle(vx, vy + dv, p) - slip_angle(vx, vy - dv, p)) / (2.0 * dv);
		double sy = std::fmin(dfda * dadv * gain, 0.0);
		double fy = implicit_fy(f0y, sy, m, dt, push_y);
		if (td * fx <= 0.0) fx = limit_to_stop(fx, vx, m, dt, push_x);
		fy = limit_to_stop(fy, vy, m, dt, push_y);
		omega = spin_step(omega, td, brake, fx, radius, wi, dt);
		double *o = out + i * OUT_STRIDE;
		o[0] = kappa;
		o[1] = alpha;
		o[2] = omega;
		o[3] = fx;
		o[4] = fy;
	}
}

// ---- raw GDExtension plumbing -------------------------------------------------------------------
static GDExtensionInterfaceGetProcAddress get_proc;
static GDExtensionClassLibraryPtr library;
static GDExtensionInterfaceMemAlloc mem_alloc_fn;
static GDExtensionInterfaceMemFree mem_free_fn;
static GDExtensionInterfaceStringNameNewWithLatin1Chars sn_new;
static GDExtensionInterfaceStringNewWithLatin1Chars str_new;
static GDExtensionInterfaceClassdbConstructObject2 construct_object;
static GDExtensionInterfaceObjectSetInstance set_instance;
static GDExtensionInterfacePackedFloat64ArrayOperatorIndex pf64_index;
static GDExtensionInterfacePackedFloat64ArrayOperatorIndexConst pf64_index_const;
static GDExtensionInterfaceGetVariantToTypeConstructor to_type_ctor;
static GDExtensionInterfaceGetVariantFromTypeConstructor from_type_ctor;
static GDExtensionPtrConstructor pf64_ctor;
static GDExtensionPtrDestructor pf64_dtor;
static GDExtensionPtrBuiltInMethod pf64_resize;
static GDExtensionTypeFromVariantConstructorFunc variant_to_pf64, variant_to_float;
static GDExtensionVariantFromTypeConstructorFunc variant_from_pf64;

alignas(16) static unsigned char sn_class[16], sn_parent[16], sn_method[16], sn_arg0[16], sn_arg1[16],
		sn_empty_cls[16], sn_resize[16], str_empty[16];
#ifndef RESIZE_HASH
#define RESIZE_HASH 848867239 // PackedFloat64Array.resize in 4.6 (extension_api.json)
#endif

static void core_call(const double *in_buf, double dt, GDExtensionVariantPtr r_return) {
	alignas(16) unsigned char arr[16];
	pf64_ctor(arr, nullptr);
	int64_t n = 4 * OUT_STRIDE;
	const void *resize_args[1] = {&n};
	int64_t rv = 0;
	pf64_resize(arr, resize_args, &rv, 1);
	step4(in_buf, dt, pf64_index(arr, 0));
	variant_from_pf64(r_return, arr);
	pf64_dtor(arr);
}

static void method_varcall(void *, GDExtensionClassInstancePtr, const GDExtensionConstVariantPtr *args,
		GDExtensionInt argc, GDExtensionVariantPtr r_return, GDExtensionCallError *err) {
	if (argc != 2) {
		err->error = argc < 2 ? GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS : GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS;
		err->expected = 2;
		return;
	}
	alignas(16) unsigned char arr[16];
	variant_to_pf64(arr, (GDExtensionVariantPtr)args[0]);
	double dt = 0.0;
	variant_to_float(&dt, (GDExtensionVariantPtr)args[1]);
	core_call(pf64_index_const(arr, 0), dt, r_return);
	pf64_dtor(arr);
	err->error = GDEXTENSION_CALL_OK;
}

static void method_ptrcall(void *, GDExtensionClassInstancePtr, const GDExtensionConstTypePtr *args, GDExtensionTypePtr r_ret) {
	alignas(16) unsigned char out[16];
	pf64_ctor(out, nullptr);
	int64_t n = 4 * OUT_STRIDE, rv = 0;
	const void *ra[1] = {&n};
	pf64_resize(out, ra, &rv, 1);
	double dt = *(const double *)args[1];
	step4(pf64_index_const(args[0], 0), dt, pf64_index(out, 0));
	// r_ret is an uninitialised PackedFloat64Array slot: move our array bits in (single owner).
	std::memcpy(r_ret, out, 8);
}

static GDExtensionObjectPtr create_instance(void *, GDExtensionBool) {
	GDExtensionObjectPtr obj = construct_object(sn_parent);
	set_instance(obj, sn_class, (GDExtensionClassInstancePtr)1);
	return obj;
}
static void free_instance(void *, GDExtensionClassInstancePtr) {}

static void init_level(void *, GDExtensionInitializationLevel level) {
	if (level != GDEXTENSION_INITIALIZATION_SCENE) return;
	auto reg_class = (GDExtensionInterfaceClassdbRegisterExtensionClass4)get_proc("classdb_register_extension_class4");
	auto reg_method = (GDExtensionInterfaceClassdbRegisterExtensionClassMethod)get_proc("classdb_register_extension_class_method");
	GDExtensionClassCreationInfo4 ci;
	std::memset(&ci, 0, sizeof(ci));
	ci.is_exposed = 1;
	ci.create_instance_func = create_instance;
	ci.free_instance_func = free_instance;
	reg_class(library, sn_class, sn_parent, &ci);

	GDExtensionPropertyInfo args[2];
	std::memset(args, 0, sizeof(args));
	args[0] = {GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, sn_arg0, sn_empty_cls, 0, str_empty, 6};
	args[1] = {GDEXTENSION_VARIANT_TYPE_FLOAT, sn_arg1, sn_empty_cls, 0, str_empty, 6};
	GDExtensionPropertyInfo ret = {GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, sn_arg0, sn_empty_cls, 0, str_empty, 6};
	GDExtensionClassMethodArgumentMetadata meta[2] = {GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE,
			GDEXTENSION_METHOD_ARGUMENT_METADATA_REAL_IS_DOUBLE};
	GDExtensionClassMethodInfo mi;
	std::memset(&mi, 0, sizeof(mi));
	mi.name = sn_method;
	mi.call_func = method_varcall;
	mi.ptrcall_func = method_ptrcall;
	mi.method_flags = GDEXTENSION_METHOD_FLAGS_DEFAULT;
	mi.has_return_value = 1;
	mi.return_value_info = &ret;
	mi.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	mi.argument_count = 2;
	mi.arguments_info = args;
	mi.arguments_metadata = meta;
	reg_method(library, sn_class, &mi);
}
static void deinit_level(void *, GDExtensionInitializationLevel) {}

extern "C" GDExtensionBool wheel_core_init(GDExtensionInterfaceGetProcAddress p_get_proc,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_init) {
	get_proc = p_get_proc;
	library = p_library;
	sn_new = (GDExtensionInterfaceStringNameNewWithLatin1Chars)get_proc("string_name_new_with_latin1_chars");
	str_new = (GDExtensionInterfaceStringNewWithLatin1Chars)get_proc("string_new_with_latin1_chars");
	construct_object = (GDExtensionInterfaceClassdbConstructObject2)get_proc("classdb_construct_object2");
	set_instance = (GDExtensionInterfaceObjectSetInstance)get_proc("object_set_instance");
	pf64_index = (GDExtensionInterfacePackedFloat64ArrayOperatorIndex)get_proc("packed_float64_array_operator_index");
	pf64_index_const = (GDExtensionInterfacePackedFloat64ArrayOperatorIndexConst)get_proc("packed_float64_array_operator_index_const");
	to_type_ctor = (GDExtensionInterfaceGetVariantToTypeConstructor)get_proc("get_variant_to_type_constructor");
	from_type_ctor = (GDExtensionInterfaceGetVariantFromTypeConstructor)get_proc("get_variant_from_type_constructor");
	auto get_ctor = (GDExtensionInterfaceVariantGetPtrConstructor)get_proc("variant_get_ptr_constructor");
	auto get_dtor = (GDExtensionInterfaceVariantGetPtrDestructor)get_proc("variant_get_ptr_destructor");
	auto get_method = (GDExtensionInterfaceVariantGetPtrBuiltinMethod)get_proc("variant_get_ptr_builtin_method");
	pf64_ctor = get_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, 0);
	pf64_dtor = get_dtor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY);
	variant_to_pf64 = to_type_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY);
	variant_to_float = to_type_ctor(GDEXTENSION_VARIANT_TYPE_FLOAT);
	variant_from_pf64 = from_type_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY);
	sn_new(sn_class, "WheelCoreNative", 0);
	sn_new(sn_parent, "RefCounted", 0);
	sn_new(sn_method, "step4", 0);
	sn_new(sn_arg0, "buf", 0);
	sn_new(sn_arg1, "dt", 0);
	sn_new(sn_empty_cls, "", 0);
	sn_new(sn_resize, "resize", 0);
	str_new(str_empty, "");
	pf64_resize = get_method(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, sn_resize, RESIZE_HASH);
	r_init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_init->initialize = init_level;
	r_init->deinitialize = deinit_level;
	return 1;
}
