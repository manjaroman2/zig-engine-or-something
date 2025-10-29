const std = @import("std");

// f32 safe math
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

pub const TWO_PI = 2 * std.math.pi;

// u64 constants
pub const ZERO_U64: u64 = 0;
pub const ONE_U64: u64 = 1;

// Point i64
pub const Point = [2]i64;
pub const Point_MIN = Point{ std.math.minInt(i64), std.math.minInt(i64) };
pub const Point_MAX = Point{ std.math.maxInt(i64), std.math.maxInt(i64) };
pub const Point_ZERO = Point{ 0, 0 };

pub inline fn PointfromFloat(a: PointF) Point {
    return .{ @as(i64, @intFromFloat(a[0])), @as(i64, @intFromFloat(a[1])) };
}

pub inline fn PointSubtract(a: Point, b: Point) Point {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub inline fn PointAdd(a: Point, b: Point) Point {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub inline fn PointMax(a: Point, b: Point) Point {
    return .{
        @max(a[0], b[0]),
        @max(a[1], b[1]),
    };
}

pub inline fn PointMin(a: Point, b: Point) Point {
    return .{
        @min(a[0], b[0]),
        @min(a[1], b[1]),
    };
}

pub inline fn PointNegate(a: Point) Point {
    return .{ -a[0], -a[1] };
}

pub inline fn PointEqual(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub inline fn PointGreaterThan(a: Point, b: Point) bool {
    return a[0] > b[0] and a[1] > b[1];
}

pub inline fn PointLessThan(a: Point, b: Point) bool {
    return a[0] < b[0] and a[1] < b[1];
}

pub inline fn PointLessThanEqual(a: Point, b: Point) bool {
    return a[0] <= b[0] and a[1] <= b[1];
}

pub inline fn PointZero(a: Point) bool {
    return a[0] == 0 and a[1] == 0;
}

pub inline fn PointInterpolate(a: Point, b: Point) Point {
    return .{ @divFloor(a[0] + b[0], 2), @divFloor(a[1] + b[1], 2) };
}

pub inline fn PointDotProduct(a: Point, b: Point) i64 {
    return a[0] * b[0] + a[1] * b[1];
}

pub inline fn PointLength(a: Point) f32 {
    return @sqrt(@as(f32, @floatFromInt(PointDotProduct(a, a))));
}

pub inline fn PointSignedAngle(a: Point, b: Point) f32 {
    return std.math.atan2(@as(f32, @floatFromInt(PointCross(a, b))), @as(f32, @floatFromInt(PointDotProduct(a, b))));
}

pub inline fn PointCross(a: Point, b: Point) i64 {
    return a[0] * b[1] - a[1] * b[0];
}

pub inline fn PointIsInHalfplaneCCW(a: Point, b: Point) bool {
    return PointCross(a, b) > 0;
}

pub inline fn PointIsInHalfplaneCW(a: Point, b: Point) bool {
    return PointCross(a, b) < 0;
}

pub inline fn PointDelauneyConditionDeterminant(a: Point, b: Point, c: Point, q: Point) i64 {
    const aq = PointSubtract(a, q);
    const bq = PointSubtract(b, q);
    const cq = PointSubtract(c, q);
    const aq_length_sq = PointDotProduct(aq, aq);
    const bq_length_sq = PointDotProduct(bq, bq);
    const cq_length_sq = PointDotProduct(cq, cq);
    return (aq[0] * bq[1] * cq_length_sq + aq[1] * bq_length_sq * cq[0] + aq_length_sq * bq[0] * cq[1]) - //
        (cq[0] * bq[1] * aq_length_sq + cq[1] * bq_length_sq * aq[0] + cq_length_sq * bq[0] * aq[1]);
}

//
// returns true if q is outside or on the circumcircle of the triangle abc.
// Conversely returns false if q is strictly (!) inside the circumcircle.
//
pub inline fn PointDelauneyConditionCCW(a: Point, b: Point, c: Point, q: Point) bool {
    return PointDelauneyConditionDeterminant(a, b, c, q) <= 0;
}
pub inline fn PointDelauneyConditionCW(a: Point, b: Point, c: Point, q: Point) bool {
    return PointDelauneyConditionDeterminant(a, b, c, q) >= 0;
}

pub const PointF = [2]f32;
pub const PointF_ZERO: PointF = .{ 0, 0 };
pub const PointF_MIN: PointF = .{ std.math.floatMin(f32), std.math.floatMin(f32) };
pub const PointF_MAX: PointF = .{ std.math.floatMax(f32), std.math.floatMax(f32) };

pub inline fn PointFfromInt(a: Point) PointF {
    return .{ @as(f32, @floatFromInt(a[0])), @as(f32, @floatFromInt(a[1])) };
}

pub inline fn PointFSubtract(a: PointF, b: PointF) PointF {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub inline fn PointFDotProduct(a: PointF, b: PointF) f32 {
    return a[0] * b[0] + a[1] * b[1];
}

pub inline fn PointFRotate(p: PointF, degree: f32) PointF {
    const t = std.math.degreesToRadians(degree);
    const sint = @sin(t);
    const cost = @cos(t);
    return .{
        PointFDotProduct(.{ cost, -sint }, p),
        PointFDotProduct(.{ sint, cost }, p),
    };
}

pub inline fn PointFLength(p: PointF) f32 {
    return @sqrt(PointFDotProduct(p, p));
}

pub inline fn PointFCross(a: PointF, b: PointF) f32 {
    return a[1] * b[0] - a[0] * b[1];
}

pub inline fn PointFOrthogonal(p: PointF) PointF {
    return .{ -p[1], p[0] };
}

pub inline fn PointFBarycentric(p: PointF, a: PointF, b: PointF, c: PointF) PointF {
    const scalar = 1.0 / (PointFCross(c, b) + PointSubtract(b, c) * PointFOrthogonal(a));
    const p_orthogonal = PointFOrthogonal(p);
    const s = scalar * (PointFCross(a, c) + PointSubtract(c, a) * p_orthogonal);
    const t = scalar * (PointFCross(b, a) + PointSubtract(a, b) * p_orthogonal);
    return .{ s, t };
}

pub inline fn PointFWithinTriangle(p: PointF, a: PointF, b: PointF, c: PointF) bool {
    const st = PointFBarycentric(p, a, b, c);
    const s = st[0];
    const t = st[1];
    return f32s_lte(0, s) and f32s_lte(0, t) and f32s_lte(s + t, 1);
}
