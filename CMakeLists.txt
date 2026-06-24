cmake_minimum_required(VERSION 3.25)

# ------------------------------------------------------------------
# MeshForge - Industrial STEP Lightweight Processor
# GUI: SDL2 + OpenGL + ImGui (bgfx optional for future 3D viewport)
# ------------------------------------------------------------------

project(MeshForge
    VERSION 0.1.0
    LANGUAGES CXX C
    DESCRIPTION "Industrial STEP model lightweight processing software"
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(APPLE)
    set(CMAKE_OSX_ARCHITECTURES "arm64")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")
endif()

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ------------------------------------------------------------------
# Find brew-installed packages
# ------------------------------------------------------------------
find_package(Threads REQUIRED)

# TBB
find_path(TBB_INCLUDE_DIR tbb/task_group.h PATHS /opt/homebrew/include)
find_library(TBB_LIBRARY tbb PATHS /opt/homebrew/lib)
if(TBB_INCLUDE_DIR AND TBB_LIBRARY)
    set(TBB_FOUND TRUE)
    add_library(TBB::tbb UNKNOWN IMPORTED)
    set_target_properties(TBB::tbb PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${TBB_INCLUDE_DIR}"
        IMPORTED_LOCATION "${TBB_LIBRARY}"
    )
endif()

# OpenCASCADE
find_path(OpenCASCADE_INCLUDE_DIR Standard_Version.hxx PATHS /opt/homebrew/include/opencascade)
set(OpenCASCADE_LIBS TKDESTEP TKDEIGES TKXSBase TKShHealing
    TKOffset TKFeat TKFillet TKBool TKMesh TKBO TKPrim TKHLR TKGeomBase TKBRep
    TKGeomAlgo TKTopAlgo TKG3d TKG2d TKMath TKernel TKService TKV3d TKOpenGl
    TKXCAF TKLCAF TKCAF TKCDF TKStd TKBin)
set(OpenCASCADE_LIBRARIES "")
foreach(lib ${OpenCASCADE_LIBS})
    find_library(OpenCASCADE_${lib}_LIBRARY NAMES ${lib} PATHS /opt/homebrew/lib)
    if(OpenCASCADE_${lib}_LIBRARY)
        list(APPEND OpenCASCADE_LIBRARIES ${OpenCASCADE_${lib}_LIBRARY})
    endif()
endforeach()
if(OpenCASCADE_INCLUDE_DIR AND OpenCASCADE_LIBRARIES)
    set(OpenCASCADE_FOUND TRUE)
    add_library(OpenCASCADE::OpenCASCADE INTERFACE IMPORTED)
    set_target_properties(OpenCASCADE::OpenCASCADE PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${OpenCASCADE_INCLUDE_DIR}"
        INTERFACE_LINK_LIBRARIES "${OpenCASCADE_LIBRARIES}"
    )
endif()

# SDL2
find_package(SDL2 CONFIG QUIET)
if(NOT SDL2_FOUND)
    find_path(SDL2_INCLUDE_DIR SDL2/SDL.h PATHS /opt/homebrew/include)
    find_library(SDL2_LIBRARY SDL2 PATHS /opt/homebrew/lib)
    if(SDL2_INCLUDE_DIR AND SDL2_LIBRARY)
        add_library(SDL2::SDL2 INTERFACE IMPORTED)
        set_target_properties(SDL2::SDL2 PROPERTIES
            INTERFACE_INCLUDE_DIRECTORIES "${SDL2_INCLUDE_DIR}"
            INTERFACE_LINK_LIBRARIES "${SDL2_LIBRARY}"
        )
        set(SDL2_FOUND TRUE)
    endif()
endif()

# glm (header-only)
find_path(GLM_INCLUDE_DIR glm/glm.hpp PATHS /opt/homebrew/include)
if(GLM_INCLUDE_DIR)
    add_library(glm::glm INTERFACE IMPORTED)
    set_target_properties(glm::glm PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${GLM_INCLUDE_DIR}")
endif()

# spdlog + fmt
find_path(SPDLOG_INCLUDE_DIR spdlog/spdlog.h PATHS /opt/homebrew/include)
find_library(SPDLOG_LIBRARY spdlog PATHS /opt/homebrew/lib)
find_library(FMT_LIBRARY fmt PATHS /opt/homebrew/lib)
if(SPDLOG_INCLUDE_DIR)
    add_library(spdlog::spdlog INTERFACE IMPORTED)
    set_target_properties(spdlog::spdlog PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${SPDLOG_INCLUDE_DIR}")
    if(SPDLOG_LIBRARY AND FMT_LIBRARY)
        set_target_properties(spdlog::spdlog PROPERTIES
            INTERFACE_LINK_LIBRARIES "${SPDLOG_LIBRARY};${FMT_LIBRARY}")
    elseif(SPDLOG_LIBRARY)
        set_target_properties(spdlog::spdlog PROPERTIES INTERFACE_LINK_LIBRARIES "${SPDLOG_LIBRARY}")
    endif()
endif()

# nlohmann-json (header-only)
find_path(NLJSON_INCLUDE_DIR nlohmann/json.hpp PATHS /opt/homebrew/include)
if(NLJSON_INCLUDE_DIR)
    add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED)
    set_target_properties(nlohmann_json::nlohmann_json PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${NLJSON_INCLUDE_DIR}")
endif()

# Eigen (header-only)
find_path(EIGEN_INCLUDE_DIR Eigen/Core PATHS /opt/homebrew/include/eigen3)
if(EIGEN_INCLUDE_DIR)
    add_library(Eigen3::Eigen INTERFACE IMPORTED)
    set_target_properties(Eigen3::Eigen PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${EIGEN_INCLUDE_DIR}")
endif()

# ------------------------------------------------------------------
# Compiler flags
# ------------------------------------------------------------------
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|AppleClang")
    add_compile_options(-Wall -Wextra -Wpedantic -Wno-unused-parameter -Wno-missing-field-initializers)
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
        add_compile_options(-O3 -ffast-math)
    endif()
endif()

# ------------------------------------------------------------------
# Third-party: imgui core (header-only style, built as STATIC)
# ------------------------------------------------------------------
set(IMGUI_SOURCES
    third_party/imgui/imgui.cpp
    third_party/imgui/imgui_draw.cpp
    third_party/imgui/imgui_tables.cpp
    third_party/imgui/imgui_widgets.cpp
    third_party/imgui/imgui_demo.cpp
)
add_library(imgui STATIC ${IMGUI_SOURCES})
target_include_directories(imgui PUBLIC third_party/imgui)

# ImGui SDL2 backend
add_library(imgui_sdl STATIC
    third_party/imgui/backends/imgui_impl_sdl2.cpp
)
target_include_directories(imgui_sdl PUBLIC third_party/imgui third_party/imgui/backends)
target_link_libraries(imgui_sdl PUBLIC imgui SDL2::SDL2)

# ImGui OpenGL3 backend
add_library(imgui_gl STATIC
    third_party/imgui/backends/imgui_impl_opengl3.cpp
)
target_include_directories(imgui_gl PUBLIC third_party/imgui third_party/imgui/backends)
target_link_libraries(imgui_gl PUBLIC imgui)

# Draco (from Homebrew)
find_path(DRACO_INCLUDE_DIR draco/compression/encode.h PATHS /opt/homebrew/include)
find_library(DRACO_LIBRARY draco PATHS /opt/homebrew/lib)
if(DRACO_INCLUDE_DIR AND DRACO_LIBRARY)
    add_library(draco INTERFACE)
    target_include_directories(draco INTERFACE ${DRACO_INCLUDE_DIR})
    target_link_libraries(draco INTERFACE ${DRACO_LIBRARY})
    message(STATUS "Draco found: ${DRACO_LIBRARY}")
else()
    message(STATUS "Draco not found, using stub")
    add_library(draco_stub INTERFACE)
    target_include_directories(draco_stub INTERFACE ${CMAKE_SOURCE_DIR}/third_party/draco_stub)
    add_library(draco ALIAS draco_stub)
endif()

# Meshoptimizer (FetchContent from GitHub)
include(FetchContent)
FetchContent_Declare(
    meshoptimizer
    GIT_REPOSITORY https://github.com/zeux/meshoptimizer.git
    GIT_TAG v0.21
    GIT_SHALLOW TRUE
)
# Use FetchContent_MakeAvailable for proper CMake integration
FetchContent_MakeAvailable(meshoptimizer)
message(STATUS "Meshoptimizer: ${meshoptimizer_SOURCE_DIR}")

# Fast Quadric Mesh Simplification (header-only, stub)
add_library(fast_quadic_simplification INTERFACE)
target_include_directories(fast_quadic_simplification INTERFACE ${CMAKE_SOURCE_DIR}/third_party/FastQuadricMeshSimplification)

# bgfx cross-platform rendering library (Metal/Vulkan/DX12)
# Disabled by default — uncomment to enable when bgfx is available
# option(MESHFORGE_USE_BGFX "Build with bgfx renderer" OFF)
# if(MESHFORGE_USE_BGFX)
#     include(FetchContent)
#     FetchContent_Declare(
#         bgfx
#         GIT_REPOSITORY https://github.com/bkaradzic/bgfx.cmake.git
#         GIT_TAG master
#         GIT_SHALLOW TRUE
#     )
#     FetchContent_MakeAvailable(bgfx)
#     add_compile_definitions(MF_HAS_BGFX=1)
#     message(STATUS "bgfx integrated via bgfx.cmake")
# endif()

# ------------------------------------------------------------------
# Modules
# ------------------------------------------------------------------
add_subdirectory(src/Core)
add_subdirectory(src/Math)
add_subdirectory(src/Geometry)
add_subdirectory(src/Mesh)
add_subdirectory(src/Scene)
add_subdirectory(src/Renderer)
add_subdirectory(src/IO)
add_subdirectory(src/UI)
add_subdirectory(src/App)

# ------------------------------------------------------------------
# Main executable
# ------------------------------------------------------------------
add_executable(MeshForgeApp src/main.cpp)
target_link_libraries(MeshForgeApp PRIVATE MeshForgeAppLib)

set_target_properties(MeshForgeApp PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

add_executable(StepProbe tools/StepProbe.cpp)
target_include_directories(StepProbe PRIVATE src)
target_link_libraries(StepProbe PRIVATE MeshForgeCore MeshForgeMath MeshForgeGeometry)
set_target_properties(StepProbe PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

enable_testing()
