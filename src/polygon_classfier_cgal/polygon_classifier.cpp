#include "polygon_classifier.h"

#include <queue>
#include <unordered_map>
#include <vector>

Context *context_create(CPoint *contour_points, size_t *contour_lengths, size_t contour_count)
{
    auto *ctx = new Context;
    ctx->contour_count = contour_count;
    ctx->contour_lengths = contour_lengths;
    ctx->contour_points = contour_points;
    ctx->context_state = 0;
    return ctx;
}

void context_destroy(Context *ctx)
{
    delete ctx;
}

namespace
{
enum StateBit : unsigned
{
    ConstraintsPopulated = 1u << 7,
    DomainMarked = 1u << 6,
    TrianglesCounted = 1u << 5,
    PolygonsRecovered = 1u << 4,
    VerticesIndexed = 1u << 3,
    IndicesPerPolygonWritten = 1u << 2,
    VerticesPerPolygonWritten = 1u << 1,
    MeshDataWritten = 1u << 0,
};
} // namespace

void triangulate_polygons(Context *ctx, ReturnData *out, size_t max_indices, size_t max_vertices, size_t max_polygons)
{
    auto has = [&](unsigned bit) { return (ctx->context_state & bit) == bit; };
    auto set = [&](unsigned bit) { ctx->context_state |= bit; };

    if (!has(ConstraintsPopulated))
    {
        size_t offset = 0;
        for (size_t c = 0; c < ctx->contour_count; c++)
        {
            size_t contour_length = ctx->contour_lengths[c];
            if (contour_length < 3)
            {
                offset += contour_length;
                continue;
            }

            std::vector<Vertex_handle> handles;
            handles.reserve(contour_length);
            for (size_t i = 0; i < contour_length; i++)
            {
                const CPoint &p = ctx->contour_points[offset + i];
                Vertex_handle v = ctx->cdt.insert(Point(p.x, p.y));
                v->info() = static_cast<int>(offset + i);
                handles.push_back(v);
            }
            for (size_t i = 0; i < contour_length; i++)
                ctx->cdt.insert_constraint(handles[i], handles[(i + 1) % contour_length]);
            offset += contour_length;
        }
        set(ConstraintsPopulated);
    }

    boost::associative_property_map<std::unordered_map<Face_handle, bool>> in_domain(ctx->in_domain_map);
    if (!has(DomainMarked))
    {
        CGAL::mark_domain_in_triangulation(ctx->cdt, in_domain);
        set(DomainMarked);
    }

    if (!has(TrianglesCounted))
    {
        size_t triangle_count = 0;
        for (Face_handle f : ctx->cdt.finite_face_handles())
            if (get(in_domain, f))
                triangle_count++;
        out->indices_count = triangle_count * 3;
        set(TrianglesCounted);
    }

    // Recover polygons AND remember each polygon's faces in a stable, fixed order.
    if (!has(PolygonsRecovered))
    {
        for (Face_handle seed : ctx->cdt.finite_face_handles())
        {
            if (!get(in_domain, seed))
                continue;
            if (ctx->component_of.count(seed))
                continue;

            int polygon_id = out->polygon_count++;
            ctx->component_of[seed] = polygon_id;
            ctx->polygon_faces.emplace_back();
            ctx->polygon_faces[polygon_id].push_back(seed);

            std::queue<Face_handle> q;
            q.push(seed);
            while (!q.empty())
            {
                Face_handle f = q.front();
                q.pop();
                for (int i = 0; i < 3; i++)
                {
                    if (ctx->cdt.is_constrained(CDT::Edge(f, i)))
                        continue;
                    Face_handle neighbor = f->neighbor(i);
                    if (ctx->cdt.is_infinite(neighbor))
                        continue;
                    if (!get(in_domain, neighbor))
                        continue;
                    if (ctx->component_of.count(neighbor))
                        continue;
                    ctx->component_of[neighbor] = polygon_id;
                    ctx->polygon_faces[polygon_id].push_back(neighbor);
                    q.push(neighbor);
                }
            }
        }
        set(PolygonsRecovered);
    }

    // Build per-polygon local vertex ids: global contour-point id -> local id within that polygon.
    if (!has(VerticesIndexed))
    {
        ctx->vertex_local_to_global.resize(out->polygon_count);
        ctx->vertex_global_to_local.resize(out->polygon_count);

        for (size_t pid = 0; pid < ctx->polygon_faces.size(); pid++)
        {
            auto &g2l = ctx->vertex_global_to_local[pid];
            auto &l2g = ctx->vertex_local_to_global[pid];
            for (Face_handle f : ctx->polygon_faces[pid])
            {
                for (int i = 0; i < 3; i++)
                {
                    int global_id = f->vertex(i)->info();
                    auto res = g2l.try_emplace(global_id, static_cast<int>(l2g.size()));
                    if (res.second)
                        l2g.push_back(global_id);
                }
            }
        }
        set(VerticesIndexed);
    }

    if (!has(IndicesPerPolygonWritten) && max_polygons >= out->polygon_count)
    {
        for (size_t pid = 0; pid < ctx->polygon_faces.size(); pid++)
            out->indices_per_polygon[pid] = ctx->polygon_faces[pid].size() * 3;
        set(IndicesPerPolygonWritten);
    }

    if (!has(VerticesPerPolygonWritten) && max_polygons >= out->polygon_count)
    {
        size_t total_vertices = 0;
        for (size_t pid = 0; pid < ctx->vertex_local_to_global.size(); pid++)
        {
            out->vertices_per_polygon[pid] = ctx->vertex_local_to_global[pid].size();
            total_vertices += ctx->vertex_local_to_global[pid].size();
        }
        out->vertices_count = total_vertices;
        set(VerticesPerPolygonWritten);
    }

    // Write flat indices + vertices grouped per polygon, matching how Zig slices them.
    if (!has(MeshDataWritten) && max_indices >= out->indices_count && max_vertices >= out->vertices_count)
    {
        size_t index_offset = 0;
        size_t vertex_offset = 0;
        for (size_t pid = 0; pid < ctx->polygon_faces.size(); pid++)
        {
            const auto &g2l = ctx->vertex_global_to_local[pid];
            for (Face_handle f : ctx->polygon_faces[pid])
                for (int i = 0; i < 3; i++)
                    out->indices[index_offset++] = static_cast<Index>(g2l.at(f->vertex(i)->info()));

            for (int global_id : ctx->vertex_local_to_global[pid])
            {
                const CPoint &p = ctx->contour_points[global_id];
                out->vertices[vertex_offset++] = Vertex{
                    static_cast<int32_t>(p.x),
                    static_cast<int32_t>(p.y),
                };
            }
        }
        set(MeshDataWritten);
    }
}
