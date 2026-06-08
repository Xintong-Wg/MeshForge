#!/bin/bash
# Watch for file changes and rebuild automatically
set -e

cd "$(dirname "$0")/.."

# Check if fswatch is installed
if ! command -v fswatch &> /dev/null; then
    echo "Error: fswatch not found. Install with: brew install fswatch"
    exit 1
fi

echo "=== Watching for changes... ==="
echo "Press Ctrl+C to stop"

# Function to build
build() {
    echo -e "\n🔨 Building..."
    if cmake --build build_debug -j 8; then
        echo "✅ Build succeeded"
    else
        echo "❌ Build failed"
    fi
}

# Initial build
build

# Watch src directory and rebuild on changes
fswatch -o src/ CMakeLists.txt | while read -r num; do
    build
done
