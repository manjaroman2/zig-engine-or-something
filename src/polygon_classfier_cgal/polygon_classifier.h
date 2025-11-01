#ifndef POLYGON_CLASSIFIER_H
#define POLYGON_CLASSIFIER_H

#include <CGAL/Exact_predicates_exact_constructions_kernel.h>
#include <CGAL/General_polygon_set_2.h>
#include <CGAL/Gps_segment_traits_2.h>
#include <CGAL/Constrained_Delaunay_triangulation_2.h>
#include <CGAL/Triangulation_face_base_with_info_2.h>
#include <vector>

typedef CGAL::Exact_predicates_exact_constructions_kernel Kernel;
typedef CGAL::Gps_segment_traits_2<Kernel> Traits_2;
typedef Traits_2::Polygon_2 Polygon_2;
typedef Traits_2::Polygon_with_holes_2 Polygon_with_holes_2;
typedef Kernel::Point_2 Point_2;

// Input: vector of contours, each contour is a vector of points
typedef std::vector<std::vector<Point_2>> ContourList;

// Output: vector of polygons with holes
typedef std::vector<Polygon_with_holes_2> PolygonalDomains;

// Main function: classify contours into polygonal domains
PolygonalDomains classify_contours(const ContourList& contours);

// triangulation
struct FaceInfo {
    bool in_domain;
};
typedef CGAL::Triangulation_vertex_base_2<Kernel> Vb;
typedef CGAL::Triangulation_face_base_with_info_2<FaceInfo, Kernel> Fbb;
typedef CGAL::Constrained_triangulation_face_base_2<Kernel, Fbb> Fb;
typedef CGAL::Triangulation_data_structure_2<Vb, Fb> TDS;
typedef CGAL::Exact_predicates_tag Itag;
typedef CGAL::Constrained_Delaunay_triangulation_2<Kernel, TDS, Itag> CDT;


// Simple C API for Zig
extern "C" {
    Point_2 create_point(double x, double y);
    Polygon_with_holes_2** classify_contours_simple(const Point_2* points, const size_t* contour_sizes, size_t num_contours, size_t* out_size);
    size_t get_outer_boundary_size_simple(const Polygon_with_holes_2* pwh);
    void get_outer_boundary_point_simple(const Polygon_with_holes_2* pwh, size_t idx, double* x, double* y);
    size_t get_num_holes_simple(const Polygon_with_holes_2* pwh);
    size_t get_hole_size_simple(const Polygon_with_holes_2* pwh, size_t hole_idx);
    void get_hole_point_simple(const Polygon_with_holes_2* pwh, size_t hole_idx, size_t point_idx, double* x, double* y);
    void free_domains_simple(Polygon_with_holes_2** domains, size_t size);
    Polygon_with_holes_2** classify_contours_from_doubles(const double* x_coords, const double* y_coords, const size_t* contour_sizes, size_t num_contours, size_t* out_size);

    // triangulation
    void* triangulate_polygon_with_holes(const Polygon_with_holes_2* pwh);
    size_t get_triangulation_num_triangles(void* cdt_ptr);
    void get_triangle_vertices(void* cdt_ptr, size_t triangle_idx, 
                               double* x0, double* y0,
                               double* x1, double* y1, 
                               double* x2, double* y2);
    void free_triangulation(void* cdt_ptr);

    Polygon_with_holes_2* create_polygon_with_holes(
        const double* outer_x, const double* outer_y, size_t outer_size,
        const double** holes_x, const double** holes_y, const size_t* hole_sizes, size_t num_holes);
    void free_single_polygon(Polygon_with_holes_2* pwh);
    void* triangulate_contours_directly(const double* x_coords, const double* y_coords, const size_t* contour_sizes, size_t num_contours);
}
#endif // POLYGON_CLASSIFIER_H
