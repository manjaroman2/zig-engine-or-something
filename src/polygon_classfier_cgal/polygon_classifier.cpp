#include "polygon_classifier.h"
#include <CGAL/General_polygon_set_2.h>
#include <queue>

PolygonalDomains classify_contours(const ContourList &contours)
{
    try
    {
        CGAL::General_polygon_set_2<Traits_2> polygon_set;

        for (size_t i = 0; i < contours.size(); ++i)
        {
            const auto &contour = contours[i];
            Polygon_2 poly(contour.begin(), contour.end());
            if (!poly.is_simple())
            {
                std::cerr << "C++: Warning - Polygon " << i << " is not simple (has self-intersections), skipping"
                          << std::endl;
                continue;
            }
            if (poly.is_clockwise_oriented())
            {
                poly.reverse_orientation();
            }
            polygon_set.symmetric_difference(poly);
        }
        PolygonalDomains result;
        polygon_set.polygons_with_holes(std::back_inserter(result));
        return result;
    }
    catch (const std::exception &e)
    {
        std::cerr << "C++: Exception in classify_contours: " << e.what() << std::endl;
        return PolygonalDomains();
    }
    catch (...)
    {
        std::cerr << "C++: Unknown exception in classify_contours" << std::endl;
        return PolygonalDomains();
    }
}

void free_single_polygon(Polygon_with_holes_2 *pwh)
{
    if (pwh)
    {
        delete pwh;
    }
}

Polygon_with_holes_2 *create_polygon_with_holes(const double *outer_x, const double *outer_y, size_t outer_size,
                                                const double **holes_x, const double **holes_y,
                                                const size_t *hole_sizes, size_t num_holes)
{

    try
    {
        // std::cout << "C++: create_polygon_with_holes called" << std::endl;
        // std::cout << "C++: Outer boundary: " << outer_size << " points" << std::endl;
        // std::cout << "C++: Number of holes: " << num_holes << std::endl;

        // Build outer boundary
        std::vector<Point_2> outer_points;
        outer_points.reserve(outer_size);
        for (size_t i = 0; i < outer_size; ++i)
        {
            outer_points.push_back(Point_2(outer_x[i], outer_y[i]));
        }

        // Remove consecutive duplicates from outer
        std::vector<Point_2> cleaned_outer;
        cleaned_outer.reserve(outer_points.size());
        for (size_t i = 0; i < outer_points.size(); ++i)
        {
            if (cleaned_outer.empty() || outer_points[i] != cleaned_outer.back())
            {
                cleaned_outer.push_back(outer_points[i]);
            }
        }
        if (cleaned_outer.size() > 1 && cleaned_outer.front() == cleaned_outer.back())
        {
            cleaned_outer.pop_back();
        }

        // std::cout << "C++: After cleaning outer: " << cleaned_outer.size() << " points" << std::endl;

        Polygon_2 outer_poly(cleaned_outer.begin(), cleaned_outer.end());

        // std::cout << "C++: Outer polygon orientation: " << (outer_poly.is_clockwise_oriented() ? "CW" : "CCW")
        //           << std::endl;

        // Ensure counter-clockwise orientation
        if (outer_poly.is_clockwise_oriented())
        {
            outer_poly.reverse_orientation();
            // std::cout << "C++: Reversed outer to CCW" << std::endl;
        }

        // Build holes
        std::vector<Polygon_2> hole_polygons;
        for (size_t h = 0; h < num_holes; ++h)
        {
            // std::cout << "C++: Processing hole " << h << " with " << hole_sizes[h] << " points" << std::endl;

            std::vector<Point_2> hole_points;
            hole_points.reserve(hole_sizes[h]);
            for (size_t i = 0; i < hole_sizes[h]; ++i)
            {
                hole_points.push_back(Point_2(holes_x[h][i], holes_y[h][i]));
            }

            // Remove consecutive duplicates from hole
            std::vector<Point_2> cleaned_hole;
            cleaned_hole.reserve(hole_points.size());
            for (size_t i = 0; i < hole_points.size(); ++i)
            {
                if (cleaned_hole.empty() || hole_points[i] != cleaned_hole.back())
                {
                    cleaned_hole.push_back(hole_points[i]);
                }
            }
            if (cleaned_hole.size() > 1 && cleaned_hole.front() == cleaned_hole.back())
            {
                cleaned_hole.pop_back();
            }

            // std::cout << "C++: After cleaning hole: " << cleaned_hole.size() << " points" << std::endl;

            Polygon_2 hole_poly(cleaned_hole.begin(), cleaned_hole.end());

            // std::cout << "C++: Hole polygon orientation: " << (hole_poly.is_clockwise_oriented() ? "CW" : "CCW")
            //           << std::endl;

            // Holes should be clockwise (opposite of outer)
            if (!hole_poly.is_clockwise_oriented())
            {
                hole_poly.reverse_orientation();
                // std::cout << "C++: Reversed hole to CW" << std::endl;
            }

            hole_polygons.push_back(hole_poly);
        }

        // Create polygon with holes
        auto *pwh = new Polygon_with_holes_2(outer_poly, hole_polygons.begin(), hole_polygons.end());

        // std::cout << "C++: Created polygon with " << pwh->number_of_holes() << " holes" << std::endl;

        return pwh;
    }
    catch (const std::exception &e)
    {
        std::cerr << "C++: Exception in create_polygon_with_holes: " << e.what() << std::endl;
        return nullptr;
    }
}
void mark_domains(CDT &cdt, const Polygon_with_holes_2 *pwh)
{
    // Initialize all as inside
    int total_faces = 0;
    for (auto fit = cdt.all_faces_begin(); fit != cdt.all_faces_end(); ++fit)
    {
        fit->info().in_domain = true;
        total_faces++;
    }
    std::cout << "C++: Total faces in triangulation: " << total_faces << std::endl;

    std::queue<CDT::Face_handle> to_visit;

    // Seed 1: Start from infinite face (exterior)
    CDT::Face_handle inf = cdt.infinite_face();
    inf->info().in_domain = false;
    to_visit.push(inf);
    std::cout << "C++: Starting flood fill from infinite face" << std::endl;

    // Seed 2: Start from inside each hole
    int hole_idx = 0;
    for (auto hit = pwh->holes_begin(); hit != pwh->holes_end(); ++hit, ++hole_idx)
    {
        double sum_x = 0, sum_y = 0;
        int count = 0;

        std::cout << "C++: Hole " << hole_idx << " vertices: ";
        for (auto vit = hit->vertices_begin(); vit != hit->vertices_end(); ++vit)
        {
            double x = CGAL::to_double(vit->x());
            double y = CGAL::to_double(vit->y());
            std::cout << "(" << x << "," << y << ") ";
            sum_x += x;
            sum_y += y;
            count++;
        }
        std::cout << std::endl;

        if (count > 0)
        {
            Point_2 hole_center(sum_x / count, sum_y / count);
            std::cout << "C++: Hole " << hole_idx << " center: (" << CGAL::to_double(hole_center.x()) << ", "
                      << CGAL::to_double(hole_center.y()) << ")" << std::endl;

            CDT::Locate_type lt;
            int li;
            CDT::Face_handle fh = cdt.locate(hole_center, lt, li);

            std::cout << "C++: Locate result: ";
            if (fh == CDT::Face_handle())
            {
                std::cout << "NULL handle" << std::endl;
            }
            else if (cdt.is_infinite(fh))
            {
                std::cout << "INFINITE face" << std::endl;
            }
            else
            {
                std::cout << "Finite face, current in_domain = " << fh->info().in_domain << std::endl;
                if (fh->info().in_domain)
                {
                    fh->info().in_domain = false;
                    to_visit.push(fh);
                    std::cout << "C++: Added hole seed to queue" << std::endl;
                }
                else
                {
                    std::cout << "C++: Face already marked as outside" << std::endl;
                }
            }
        }
    }

    // BFS flood fill
    int faces_marked = 0;
    while (!to_visit.empty())
    {
        CDT::Face_handle current = to_visit.front();
        to_visit.pop();

        for (int i = 0; i < 3; ++i)
        {
            CDT::Face_handle neighbor = current->neighbor(i);

            if (!neighbor->info().in_domain)
            {
                continue;
            }

            if (cdt.is_constrained(CDT::Edge(current, i)))
            {
                continue;
            }

            neighbor->info().in_domain = false;
            to_visit.push(neighbor);
            faces_marked++;
        }
    }

    std::cout << "C++: Marked " << faces_marked << " faces as outside during flood fill" << std::endl;

    // Count final result
    int inside_count = 0;
    int outside_count = 0;
    for (auto fit = cdt.finite_faces_begin(); fit != cdt.finite_faces_end(); ++fit)
    {
        if (fit->info().in_domain)
        {
            inside_count++;
        }
        else
        {
            outside_count++;
        }
    }
    std::cout << "C++: Final: " << inside_count << " faces inside, " << outside_count << " faces outside" << std::endl;
}

// Simple C API implementations
extern "C"
{
    void *triangulate_contours_directly(const double *x_coords, const double *y_coords, const size_t *contour_sizes,
                                        size_t num_contours)
    {

        try
        {
            std::cout << "C++: Direct triangulation of " << num_contours << " contours" << std::endl;

            CDT *cdt = new CDT();

            size_t offset = 0;
            for (size_t c = 0; c < num_contours; ++c)
            {
                std::vector<Point_2> points;
                for (size_t i = 0; i < contour_sizes[c]; ++i)
                {
                    points.push_back(Point_2(x_coords[offset + i], y_coords[offset + i]));
                }
                offset += contour_sizes[c];

                // Remove duplicates
                std::vector<Point_2> cleaned;
                for (size_t i = 0; i < points.size(); ++i)
                {
                    if (cleaned.empty() || points[i] != cleaned.back())
                    {
                        cleaned.push_back(points[i]);
                    }
                }
                if (cleaned.size() > 1 && cleaned.front() == cleaned.back())
                {
                    cleaned.pop_back();
                }

                if (cleaned.size() < 3)
                    continue;

                // Insert vertices and constraints
                std::vector<CDT::Vertex_handle> vertices;
                for (const auto &pt : cleaned)
                {
                    vertices.push_back(cdt->insert(pt));
                }

                for (size_t i = 0; i < vertices.size(); ++i)
                {
                    size_t j = (i + 1) % vertices.size();
                    cdt->insert_constraint(vertices[i], vertices[j]);
                }

                std::cout << "C++: Added contour " << c << " with " << cleaned.size() << " points" << std::endl;
            }

            // Simple marking: just use winding number or mark exterior only
            for (auto fit = cdt->all_faces_begin(); fit != cdt->all_faces_end(); ++fit)
            {
                fit->info().in_domain = true;
            }

            // Mark exterior as outside
            std::queue<CDT::Face_handle> queue;
            CDT::Face_handle inf = cdt->infinite_face();
            inf->info().in_domain = false;
            queue.push(inf);

            while (!queue.empty())
            {
                CDT::Face_handle fh = queue.front();
                queue.pop();

                for (int i = 0; i < 3; ++i)
                {
                    CDT::Face_handle n = fh->neighbor(i);
                    if (n->info().in_domain && !cdt->is_constrained(CDT::Edge(fh, i)))
                    {
                        n->info().in_domain = false;
                        queue.push(n);
                    }
                }
            }

            // Count
            size_t count = 0;
            for (auto fit = cdt->finite_faces_begin(); fit != cdt->finite_faces_end(); ++fit)
            {
                if (fit->info().in_domain)
                    count++;
            }

            std::cout << "C++: Result: " << count << " triangles" << std::endl;
            return static_cast<void *>(cdt);
        }
        catch (...)
        {
            return nullptr;
        }
    }
    void *triangulate_polygon_with_holes(const Polygon_with_holes_2 *pwh)
    {
        try
        {
            // std::cout << "C++: Starting triangulation" << std::endl;
            // std::cout << "C++: Input polygon has " << pwh->number_of_holes() << " holes" << std::endl;

            CDT *cdt = new CDT();

            // Insert outer boundary as constraint
            const auto &outer = pwh->outer_boundary();
            // std::cout << "C++: Inserting outer boundary with " << outer.size() << " vertices" << std::endl;

            std::vector<CDT::Vertex_handle> outer_vertices;
            for (auto vit = outer.vertices_begin(); vit != outer.vertices_end(); ++vit)
            {
                outer_vertices.push_back(cdt->insert(*vit));
            }

            // Add constraints for outer boundary
            int outer_constraints = 0;
            for (size_t i = 0; i < outer_vertices.size(); ++i)
            {
                size_t j = (i + 1) % outer_vertices.size();
                cdt->insert_constraint(outer_vertices[i], outer_vertices[j]);
                outer_constraints++;
            }
            // std::cout << "C++: Added " << outer_constraints << " constraints for outer boundary" << std::endl;

            // Insert holes as constraints
            // std::cout << "C++: Inserting " << pwh->number_of_holes() << " holes" << std::endl;
            int hole_num = 0;
            for (auto hit = pwh->holes_begin(); hit != pwh->holes_end(); ++hit)
            {
                // std::cout << "C++:   Hole " << hole_num << " has " << hit->size() << " vertices" << std::endl;

                std::vector<CDT::Vertex_handle> hole_vertices;
                for (auto vit = hit->vertices_begin(); vit != hit->vertices_end(); ++vit)
                {
                    hole_vertices.push_back(cdt->insert(*vit));
                }

                int hole_constraints = 0;
                for (size_t i = 0; i < hole_vertices.size(); ++i)
                {
                    size_t j = (i + 1) % hole_vertices.size();
                    cdt->insert_constraint(hole_vertices[i], hole_vertices[j]);
                    hole_constraints++;
                }
                // std::cout << "C++:   Added " << hole_constraints << " constraints for hole " << hole_num <<
                // std::endl;
                hole_num++;
            }

            // std::cout << "C++: Total number of vertices in CDT: " << cdt->number_of_vertices() << std::endl;
            // std::cout << "C++: Total number of faces in CDT: " << cdt->number_of_faces() << std::endl;

            // Check how many constrained edges we have
            int constrained_edges = 0;
            for (auto eit = cdt->constrained_edges_begin(); eit != cdt->constrained_edges_end(); ++eit)
            {
                constrained_edges++;
            }
            // std::cout << "C++: Total constrained edges: " << constrained_edges << std::endl;

            // Mark which triangles are inside the domain
            // std::cout << "C++: Marking domains" << std::endl;
            mark_domains(*cdt, pwh); // Pass the polygon so we can access holes

            // Count triangles inside domain
            size_t count = 0;
            for (CDT::Finite_faces_iterator fit = cdt->finite_faces_begin(); fit != cdt->finite_faces_end(); ++fit)
            {
                if (fit->info().in_domain)
                {
                    count++;
                }
            }

            // std::cout << "C++: Triangulation complete. " << count << " triangles inside domain" << std::endl;
            // std::cout << "C++: (out of " << cdt->number_of_faces() - 1 << " finite faces total)" << std::endl;

            return static_cast<void *>(cdt);
        }
        catch (const std::exception &e)
        {
            std::cerr << "C++: Exception in triangulate_polygon_with_holes: " << e.what() << std::endl;
            return nullptr;
        }
        catch (...)
        {
            std::cerr << "C++: Unknown exception in triangulate_polygon_with_holes" << std::endl;
            return nullptr;
        }
    }

    size_t get_triangulation_num_triangles(void *cdt_ptr)
    {
        if (!cdt_ptr)
            return 0;

        CDT *cdt = static_cast<CDT *>(cdt_ptr);
        size_t count = 0;

        for (CDT::Finite_faces_iterator fit = cdt->finite_faces_begin(); fit != cdt->finite_faces_end(); ++fit)
        {
            if (fit->info().in_domain)
            {
                count++;
            }
        }

        return count;
    }

    void get_triangle_vertices(void *cdt_ptr, size_t triangle_idx, double *x0, double *y0, double *x1, double *y1,
                               double *x2, double *y2)
    {
        if (!cdt_ptr)
            return;

        CDT *cdt = static_cast<CDT *>(cdt_ptr);
        size_t current_idx = 0;

        for (CDT::Finite_faces_iterator fit = cdt->finite_faces_begin(); fit != cdt->finite_faces_end(); ++fit)
        {
            if (fit->info().in_domain)
            {
                if (current_idx == triangle_idx)
                {
                    *x0 = CGAL::to_double(fit->vertex(0)->point().x());
                    *y0 = CGAL::to_double(fit->vertex(0)->point().y());
                    *x1 = CGAL::to_double(fit->vertex(1)->point().x());
                    *y1 = CGAL::to_double(fit->vertex(1)->point().y());
                    *x2 = CGAL::to_double(fit->vertex(2)->point().x());
                    *y2 = CGAL::to_double(fit->vertex(2)->point().y());
                    return;
                }
                current_idx++;
            }
        }
    }

    void free_triangulation(void *cdt_ptr)
    {
        if (cdt_ptr)
        {
            CDT *cdt = static_cast<CDT *>(cdt_ptr);
            delete cdt;
        }
    }

    Polygon_with_holes_2 **classify_contours_from_doubles(const double *x_coords, const double *y_coords,
                                                          const size_t *contour_sizes, size_t num_contours,
                                                          size_t *out_size)
    {
        try
        {
            ContourList contours;
            size_t point_offset = 0;

            for (size_t i = 0; i < num_contours; ++i)
            {
                std::vector<Point_2> contour;
                for (size_t j = 0; j < contour_sizes[i]; ++j)
                {
                    double x = x_coords[point_offset];
                    double y = y_coords[point_offset];
                    if (!std::isfinite(x) || !std::isfinite(y))
                    {
                        std::cerr << "C++: Invalid coordinates at point " << j << " in contour " << i << ": (" << x
                                  << ", " << y << ")" << std::endl;
                        *out_size = 0;
                        return nullptr;
                    }

                    contour.push_back(Point_2(x, y));
                    point_offset++;
                }
                if (contour.size() < 3)
                {
                    std::cerr << "C++: Contour " << i << " has less than 3 points" << std::endl;
                    continue; // Skip invalid contours
                }

                contours.push_back(contour);
            }
            PolygonalDomains result = classify_contours(contours);
            *out_size = result.size();

            auto domains = new Polygon_with_holes_2 *[result.size()];
            for (size_t i = 0; i < result.size(); ++i)
            {
                domains[i] = new Polygon_with_holes_2(result[i]);
            }
            return domains;
        }
        catch (const std::exception &e)
        {
            std::cerr << "C++: Exception caught: " << e.what() << std::endl;
            *out_size = 0;
            return nullptr;
        }
        catch (...)
        {
            std::cerr << "C++: Unknown exception caught" << std::endl;
            *out_size = 0;
            return nullptr;
        }
    }

    Point_2 create_point(double x, double y)
    {
        return Point_2(x, y);
    }

    Polygon_with_holes_2 **classify_contours_simple(const Point_2 *points, const size_t *contour_sizes,
                                                    size_t num_contours, size_t *out_size)
    {
        ContourList contours;
        size_t point_offset = 0;

        for (size_t i = 0; i < num_contours; ++i)
        {
            std::vector<Point_2> contour;
            for (size_t j = 0; j < contour_sizes[i]; ++j)
            {
                contour.push_back(points[point_offset++]);
            }
            contours.push_back(contour);
        }

        PolygonalDomains result = classify_contours(contours);
        *out_size = result.size();

        // Allocate array of pointers
        auto domains = new Polygon_with_holes_2 *[result.size()];
        for (size_t i = 0; i < result.size(); ++i)
        {
            domains[i] = new Polygon_with_holes_2(result[i]);
        }

        return domains;
    }

    size_t get_outer_boundary_size_simple(const Polygon_with_holes_2 *pwh)
    {
        return pwh->outer_boundary().size();
    }

    void get_outer_boundary_point_simple(const Polygon_with_holes_2 *pwh, size_t idx, double *x, double *y)
    {
        auto it = pwh->outer_boundary().vertices_begin();
        std::advance(it, idx);
        *x = CGAL::to_double(it->x());
        *y = CGAL::to_double(it->y());
    }

    size_t get_num_holes_simple(const Polygon_with_holes_2 *pwh)
    {
        return pwh->number_of_holes();
    }

    size_t get_hole_size_simple(const Polygon_with_holes_2 *pwh, size_t hole_idx)
    {
        auto hole_it = pwh->holes_begin();
        std::advance(hole_it, hole_idx);
        return hole_it->size();
    }

    void get_hole_point_simple(const Polygon_with_holes_2 *pwh, size_t hole_idx, size_t point_idx, double *x, double *y)
    {
        auto hole_it = pwh->holes_begin();
        std::advance(hole_it, hole_idx);
        auto point_it = hole_it->vertices_begin();
        std::advance(point_it, point_idx);
        *x = CGAL::to_double(point_it->x());
        *y = CGAL::to_double(point_it->y());
    }

    void free_domains_simple(Polygon_with_holes_2 **domains, size_t size)
    {
        for (size_t i = 0; i < size; ++i)
        {
            delete domains[i];
        }
        delete[] domains;
    }
}
