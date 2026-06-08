#!/bin/bash
# Build script for Debug mode
set -e

cd "$(dirname "$0")/.."

echo "=== Configuring CMake (Debug) ==="
cmake -S . -B build_debug \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

echo -e "\n=== Building project ==="
cmake --build build_debug -j 8

echo -e "\n✅ Build completed! Run with: ./build_debug/bin/MeshForgeApp"
