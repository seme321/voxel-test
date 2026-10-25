cmake_minimum_required(VERSION 3.20)
project(voxel_raytracer LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Configure godot-cpp target
set(GODOT_GDEXTENSION_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp/gdextension")
add_subdirectory(godot-cpp)

# Native Voxel RayTracer sources
set(SOURCES
    src/register_types.cpp
    src/voxel_raytracer.cpp
)

set(HEADERS
    src/register_types.h
    src/voxel_raytracer.h
)

add_library(${PROJECT_NAME} SHARED ${SOURCES} ${HEADERS})

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/vulkan-headers/include
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    godot::cpp
)

# Output directly into voxel-test/bin directory
set(OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../bin")

set_target_properties(${PROJECT_NAME} PROPERTIES
    PREFIX ""
    OUTPUT_NAME "voxel_raytracer.windows.template_debug.x86_64"
    ARCHIVE_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${OUTPUT_DIR}"
)
