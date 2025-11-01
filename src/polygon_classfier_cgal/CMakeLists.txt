cmake_minimum_required(VERSION 3.12)
project(PolygonClassifier CXX)

set(CMAKE_CXX_COMPILER "g++") 
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_BUILD_TYPE "Release")

find_package(CGAL REQUIRED COMPONENTS Core)

add_library(polygon_classifier STATIC
    polygon_classifier.cpp
    polygon_classifier.h
)

target_link_libraries(polygon_classifier CGAL::CGAL)

target_include_directories(polygon_classifier PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

target_compile_options(polygon_classifier PRIVATE -Wall -Wextra)
# add_executable(polygon_set main.cpp)

# target_link_libraries(polygon_set polygon_classifier CGAL::CGAL)

# target_compile_options(polygon_set PRIVATE -Wall -Wextra)
