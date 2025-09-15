const std = @import("std");
const EPS_F32 = 1e-6;

pub inline fn f32s_eq(a: f32, b: f32) bool {
    return @abs(a - b) <= EPS_F32;
}
pub inline fn f32s_neq(a: f32, b: f32) bool {
    return @abs(a - b) > EPS_F32;
}
pub inline fn f32s_lt(a: f32, b: f32) bool {
    return a < b - EPS_F32;
}
pub inline fn f32s_gt(a: f32, b: f32) bool {
    return a > b + EPS_F32;
}
pub inline fn f32s_lte(a: f32, b: f32) bool {
    return a <= b + EPS_F32;
}
pub inline fn f32s_gte(a: f32, b: f32) bool {
    return a >= b - EPS_F32;
}
