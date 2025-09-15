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

pub const ZERO_U64: u64 = 0;
pub const ONE_U64: u64 = 1;
pub const Point = @Vector(2, i64);
pub const Point_MIN = .{ std.math.minInt(i64), std.math.minInt(i64) };
pub const Point_MAX = .{ std.math.maxInt(i64), std.math.maxInt(i64) };

pub inline fn PointEqual(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub inline fn PointZero(a: Point) bool {
    return a[0] == 0 and a[0] == 0;
}

pub inline fn PointInterpolate(a: Point, b: Point) Point {
    return .{ @divFloor(a[0] + b[0], 2), @divFloor(a[1] + b[1], 2) };
}

pub inline fn dotProduct(a: Point, b: Point) i64 {
    return @reduce(.Add, a * b);
}

pub inline fn length(a: Point) f32 {
    return @sqrt(@as(f32, @floatFromInt(@reduce(.Add, a * a))));
}

pub inline fn signedAngle(a: Point, b: Point) f32 {
    return std.math.atan2(@as(f32, @floatFromInt(a[0] * b[1] - a[1] * b[0])), @as(f32, @floatFromInt(a[0] * b[0] + a[1] * b[1])));
}

pub inline fn cross(a: Point, b: Point) i64 {
    return a[0] * b[1] - a[1] * b[0];
}

pub inline fn isInHalfplaneCCW(a: Point, b: Point) bool {
    return cross(a, b) > 0;
}

pub inline fn isInHalfplaneCW(a: Point, b: Point) bool {
    return cross(a, b) < 0;
}

pub inline fn lengthSq(a: Point) i64 {
    return a[0] * a[0] + a[1] * a[1];
}

pub inline fn delauneyConditionDeterminant(a: Point, b: Point, c: Point, q: Point) i64 {
    const aqx = a[0] - q[0];
    const aqy = a[1] - q[1];
    const bqx = b[0] - q[0];
    const bqy = b[1] - q[1];
    const cqx = c[0] - q[0];
    const cqy = c[1] - q[1];
    const aq_length_sq = aqx * aqx + aqy * aqy;
    const bq_length_sq = bqx * bqx + bqy * bqy;
    const cq_length_sq = cqx * cqx + cqy * cqy;
    return (aqx * bqy * cq_length_sq + aqy * bq_length_sq * cqx + aq_length_sq * bqx * cqy) - //
        (cqx * bqy * aq_length_sq + cqy * bq_length_sq * aqx + cq_length_sq * bqx * aqy);
}

//
// returns true if q is outside or on the circumcircle of the triangle abc.
// Conversely returns false if q is strictly (!) inside the circumcircle.
//
pub inline fn delauneyConditionCCW(a: Point, b: Point, c: Point, q: Point) bool {
    return delauneyConditionDeterminant(a, b, c, q) <= 0;
}
pub inline fn delauneyConditionCW(a: Point, b: Point, c: Point, q: Point) bool {
    return delauneyConditionDeterminant(a, b, c, q) >= 0;
}

pub const PointF = @Vector(2, f32);
pub const PointF_MIN = .{ std.math.floatMin(f32), std.math.floatMin(f32) };
pub const PointF_MAX = .{ std.math.floatMax(f32), std.math.floatMax(f32) };

pub inline fn PointFfromInt(int: anytype) PointF {
    return @as(PointF, @floatFromInt(int));
}
pub inline fn rotate(point: PointF, degree: f32) PointF {
    const t = std.math.degreesToRadians(degree);
    const v: @Vector(2, f32) = .{ @cos(t), -@sin(t) };
    const u: @Vector(2, f32) = .{ @sin(t), @cos(t) };
    return .{
        @reduce(.Add, v * point),
        @reduce(.Add, u * point),
    };
}

pub inline fn orthogonal(p: PointF) PointF {
    return .{ -p[1], p[0] };
}

pub inline fn scaledOrthogonal(point: PointF, scalar: f32) PointF {
    return .{ -point[1] * scalar, point[0] * scalar };
}

pub inline fn magnitude(point: PointF) f32 {
    return @sqrt(@reduce(.Add, point * point));
}

pub inline fn halfCrossProduct(a: PointF, b: PointF) f32 {
    return a[1] * b[0] - a[0] * b[1];
    // return @reduce(.Add, a * orthogonal(b));
}

pub inline fn barycentric(p: PointF, a: PointF, b: PointF, c: PointF) PointF {
    const scalar = 1.0 / (halfCrossProduct(c, b) + (b - c) * orthogonal(a));
    const p_orthogonal = orthogonal(p);
    const s = scalar * (halfCrossProduct(a, c) + (c - a) * p_orthogonal);
    const t = scalar * (halfCrossProduct(b, a) + (a - b) * p_orthogonal);
    return .{ s, t };
}

pub inline fn planarPointWithinTriangle(p: PointF, a: PointF, b: PointF, c: PointF) bool {
    const st = barycentric(p, a, b, c);
    const s = st[0];
    const t = st[1];
    return (-s <= EPS_F32 and -t <= EPS_F32 and s + t - 1 <= EPS_F32);
}

pub inline fn sign(p1: PointF, p2: PointF, p3: PointF) bool {
    return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1]);
}

pub inline fn pointInTriangle(p: PointF, a: PointF, b: PointF, c: PointF) bool {
    const b1 = sign(p, a, b) < 0;
    const b2 = sign(p, b, c) < 0;
    const b3 = sign(p, c, a) < 0;
    return (b1 == b2) and (b2 == b3);
}

pub inline fn isConvex(a: PointF, b: PointF, c: PointF) bool {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 0;
}

pub fn geometricMedian(points: []const Point, max_iters: usize, eps: f32) Point {
    // start with centroid as initial guess
    var sum: Point = .{ 0, 0 };
    for (points) |p| {
        sum += p;
    }
    var xy = @divFloor(sum, @as(Point, @splat(@intCast(points.len))));
    var i: usize = 0;
    while (i < max_iters) : (i += 1) {
        var num_xy: @Vector(2, f32) = .{ 0, 0 };
        var denom: f32 = 0;

        for (points) |p| {
            const dxy = xy - p;
            const dist = @sqrt(@as(f32, @floatFromInt(@reduce(.Add, dxy * dxy))));

            if (dist < eps) {
                return p;
            }

            const w = 1.0 / dist;
            num_xy = @mulAdd(@Vector(2, f32), @floatFromInt(p), @splat(w), num_xy);
            denom += w;
        }

        const new_xy: Point = @intFromFloat(num_xy / @as(@Vector(2, f32), @splat(denom)));

        if (@reduce(.And, @as(Point, @intCast(@abs(new_xy - xy))) <= @as(Point, @splat(0)))) {
            break;
        }

        xy = new_xy;
    }

    return xy;
}
