#!/bin/bash
# Build script for Release mode
set -e

cd "$(dirname "$0")/.."

echo "=== Configuring CMake (Release) ==="
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

echo -e "\n=== Building project ==="
cmake --build build -j 8

echo -e "\n✅ Build completed! Run with: ./build/bin/MeshForgeApp"
