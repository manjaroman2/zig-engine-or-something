// polygon_classifier.h
#ifndef POLYGON_CLASSIFIER_H
#define POLYGON_CLASSIFIER_H

#include <cstddef>
#include <cstdint>

#include <CGAL/Constrained_Delaunay_triangulation_2.h>
#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#include <CGAL/Triangulation_vertex_base_with_info_2.h>
#include <CGAL/mark_domain_in_triangulation.h>
#include <boost/property_map/property_map.hpp>

typedef CGAL::Exact_predicates_inexact_constructions_kernel K;
typedef CGAL::Triangulation_vertex_base_with_info_2<int, K> Vb;
typedef CGAL::Constrained_triangulation_face_base_2<K> Fb;
typedef CGAL::Triangulation_data_structure_2<Vb, Fb> TDS;
typedef CGAL::Constrained_Delaunay_triangulation_2<K, TDS, CGAL::Exact_predicates_tag> CDT;
typedef CDT::Face_handle Face_handle;
typedef CDT::Vertex_handle Vertex_handle;
typedef CDT::Point Point;

struct CPoint
{
    double x;
    double y;
};

struct Vertex
{
    int32_t x;
    int32_t y;
};

typedef size_t Index;

struct ReturnData
{
    Index *indices;
    size_t indices_count;
    size_t *indices_per_polygon;
    Vertex *vertices;
    size_t vertices_count;
    size_t *vertices_per_polygon;
    size_t polygon_count;
};

struct Context
{
    uint8_t context_state;

    CDT cdt;

    std::unordered_map<Face_handle, bool> in_domain_map;
    std::unordered_map<Face_handle, int> component_of;

    std::vector<std::vector<Face_handle>> polygon_faces;
    std::vector<std::unordered_map<int, int>> vertex_global_to_local; // per polygon: contour-point id -> local id
    std::vector<std::vector<int>> vertex_local_to_global;             // per polygon: local id -> contour-point id

    size_t contour_count;
    size_t *contour_lengths;
    CPoint *contour_points;
};

extern "C"
{
    Context *context_create(CPoint *contour_points, size_t *contour_lengths, size_t contour_count);
    void context_destroy(Context *ctx);
    /*
    writes triangle indices (which are indicies of ctx.contour_points) of delauney triangulation into 'out_indices'.
    writes polygon sizes into 'out_polygon_size'.
    for each polygon it writes the number of indices that make up that polygon into 'out_polygon_size'.
    writes number of polygons into 'out_polygon_count'

    caller is responsible for allocating enough space for 'out_indices', 'out_polygon_size' and 'out_polygon_count'.
    the caller will indicate the amount of space in the out-arrays through 'max_indices' and 'max_polygon_size'.
    in the case of not enough space in 'out_indices', the routine will not write anything.

    the routine returns the number of indicies in the full triangulation over all polygons. this number should
    be the size of 'out_indices'

    the recommended procedure would be to call the routine once, then allocate enough space in out_indices and then call
    the routine again.
       */
    void triangulate_polygons(Context *ctx, ReturnData *out, size_t max_indices, size_t max_vertices,
                              size_t max_polygons);
}
#endif
