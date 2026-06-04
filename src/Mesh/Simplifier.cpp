#include "Mesh/Simplifier.h"
#include "Mesh/FeatureSimplifier.h"
#include "Core/Logger.h"
#include <meshoptimizer.h>
#include <cmath>
#include <cstring>
#include <vector>
#include <unordered_map>
#include <cstdint>

// Fast Quadric Mesh Simplification header-only
#include "Simplify.h"

namespace mf {

// ------------------------------------------------------------------
// Adaptive error threshold for visual fidelity
// The more aggressive the target ratio, the more error we tolerate.
// But we keep a floor to avoid visually catastrophic collapse.
// ------------------------------------------------------------------
static float computeAdaptiveError(float targetRatio, float baseError, float aggressive) {
    // ratioFactor: at ratio=1.0 -> 1.0, at ratio=0.1 -> ~3.4 (default aggressive=0)
    float ratioFactor = 1.0f + (1.0f - std::max(targetRatio, 0.01f)) * (2.0f + aggressive * 4.0f);
    float err = baseError * ratioFactor;
    // Clamp: never below half baseError (avoid over-constraint),
    // never above 0.5 (50% of bbox diagonal — extreme simplification)
    return std::clamp(err, baseError * 0.5f, 0.5f);
}

// ------------------------------------------------------------------
// Run a single meshopt_simplify pass
// Returns the resulting triangle count and the actual error
// ------------------------------------------------------------------
static size_t runMeshOptSimplify(
    std::vector<unsigned int>& indices,
    const MeshData& input,
    size_t targetIndexCount,
    float targetError,
    bool preserveBoundary,
    float* outError)
{
    unsigned int options = 0;
    if (preserveBoundary) options |= meshopt_SimplifyLockBorder;

    size_t resultCount = meshopt_simplify(
        indices.data(),
        input.indices.data(),
        static_cast<size_t>(input.indexCount()),
        reinterpret_cast<const float*>(input.vertices.data()),
        static_cast<size_t>(input.vertexCount()),
        sizeof(Vertex),
        targetIndexCount,
        targetError,
        options,
        outError
    );
    return resultCount;
}

// ------------------------------------------------------------------
// Run meshopt_simplifySloppy as a fallback
// Guarantees reaching the target count (quality may be lower)
// ------------------------------------------------------------------
static size_t runMeshOptSimplifySloppy(
    std::vector<unsigned int>& indices,
    const MeshData& input,
    size_t targetIndexCount,
    float* outError)
{
    return meshopt_simplifySloppy(
        indices.data(),
        input.indices.data(),
        static_cast<size_t>(input.indexCount()),
        reinterpret_cast<const float*>(input.vertices.data()),
        static_cast<size_t>(input.vertexCount()),
        sizeof(Vertex),
        targetIndexCount,
        1e10f, // very loose error — sloppy will do its best
        outError
    );
}

// ------------------------------------------------------------------
// Build output mesh from simplified indices + vertex fetch remap
// ------------------------------------------------------------------
static MeshData buildOutputMesh(const MeshData& input, std::vector<unsigned int>& indices, size_t indexCount)
{
    indices.resize(indexCount);

    MeshData out;
    out.indices.resize(indices.size());
    for (size_t i = 0; i < indices.size(); ++i) {
        out.indices[i] = static_cast<Index>(indices[i]);
    }

    // Vertex fetch optimization: remap to only used vertices
    std::vector<unsigned int> remap(input.vertexCount());
    size_t unique = meshopt_optimizeVertexFetchRemap(
        remap.data(), out.indices.data(), out.indices.size(), input.vertexCount()
    );

    out.vertices.resize(unique);
    for (size_t i = 0; i < out.indices.size(); ++i) {
        out.indices[i] = static_cast<Index>(remap[out.indices[i]]);
    }
    for (size_t i = 0; i < unique; ++i) {
        out.vertices[i] = input.vertices[remap[i]];
    }

    // Optimize vertex cache and overdraw
    meshopt_optimizeVertexCache(out.indices.data(), out.indices.data(), out.indices.size(), unique);
    meshopt_optimizeOverdraw(out.indices.data(), out.indices.data(), out.indices.size(),
                             reinterpret_cast<const float*>(out.vertices.data()), unique, sizeof(Vertex), 1.05f);

    out.computeAABB();
    return out;
}

// ------------------------------------------------------------------
// Main meshoptimizer simplification
// Strategy for CAD meshes:
//   1. Try meshopt_simplify once (attribute discontinuities limit this for CAD)
//   2. If result > 1.5x target: weld vertex normals & positions at face seams,
//      then run meshopt_simplifySloppy directly from original
// This bypasses the CAD face-boundary locking inherent in attribute-aware simplify.
// ------------------------------------------------------------------
SimplifyResult Simplifier::simplifyMeshOptimizer(const MeshData& input, const SimplifyParams& params) {
    SimplifyResult result;
    if (input.triangleCount() == 0) {
        result.mesh = input;
        result.achievedRatio = 1.0f;
        return result;
    }

    uint32_t sourceTris = input.triangleCount();
    uint32_t targetTris = std::max(4u,
        static_cast<uint32_t>(static_cast<float>(sourceTris) * params.targetRatio));
    targetTris = std::min(targetTris, sourceTris - 1);

    float adaptiveError = computeAdaptiveError(params.targetRatio, params.targetError, params.aggressive);

    // --- Pass 1: normal simplify ---
    std::vector<unsigned int> indices(input.indices.begin(), input.indices.end());
    float actualError = 0.0f;
    size_t resultCount = runMeshOptSimplify(
        indices, input,
        static_cast<size_t>(targetTris * 3),
        adaptiveError,
        params.preserveBoundary,
        &actualError
    );
    uint32_t normalTris = static_cast<uint32_t>(resultCount / 3);
    result.mesh = buildOutputMesh(input, indices, resultCount);
    result.usedError = actualError;
    result.passes = 1;

    MF_INFO("Simplify pass 1: {} -> {} tris (target {}, error {:.4f})",
            sourceTris, normalTris, targetTris, adaptiveError);

    // --- Retry with looser error ---
    float retryError = adaptiveError;
    uint32_t bestTris = normalTris;
    while (bestTris > targetTris * 1.15f && retryError < 0.5f) {
        retryError = std::min(retryError * 2.0f, 0.5f);
        std::vector<unsigned int> retryIndices(input.indices.begin(), input.indices.end());
        float retryActualError = 0.0f;
        size_t retryCount = runMeshOptSimplify(
            retryIndices, input,
            static_cast<size_t>(targetTris * 3),
            retryError,
            false, &retryActualError
        );
        uint32_t retryTris = static_cast<uint32_t>(retryCount / 3);
        MF_INFO("  Simplify retry: {} -> {} tris (target {}, error {:.4f})",
                sourceTris, retryTris, targetTris, retryError);
        if (retryTris < bestTris) {
            result.mesh = buildOutputMesh(input, retryIndices, retryCount);
            result.usedError = retryActualError;
            bestTris = retryTris;
            ++result.passes;
        } else {
            break; // retries stopped helping
        }
    }

    // --- Cad bypass: weld seam vertices, then sloppy from original ---
    // CAD meshes have face-boundary attribute discontinuities that block
    // attribute-aware simplify.  Weld close vertices (same position, average
    // normals) then run sloppy which doesn't preserve seams.
    if (params.useSloppyFallback && bestTris > targetTris * 1.4f) {
        MF_INFO("  Normal simplify stalled at {:.1f}% (target {:.1f}%) — "
                "welding CAD seams + sloppy simplify...",
                static_cast<float>(bestTris) / static_cast<float>(sourceTris) * 100.0f,
                params.targetRatio * 100.0f);

        // Build a welded copy: merge vertices at the same position
        MeshData welded;
        welded.vertices.reserve(input.vertices.size());
        welded.indices.reserve(input.indices.size());

        // Spatial hash for position dedup
        std::unordered_map<uint64_t, uint32_t> posMap;
        constexpr float kHashScale = 1e3f;

        for (const auto& v : input.vertices) {
            // Quantize position to hash key
            int64_t hx = static_cast<int64_t>(v.position.x * kHashScale);
            int64_t hy = static_cast<int64_t>(v.position.y * kHashScale);
            int64_t hz = static_cast<int64_t>(v.position.z * kHashScale);
            uint64_t key = (static_cast<uint64_t>(hx) << 42)
                         ^ (static_cast<uint64_t>(hy) << 21)
                         ^ static_cast<uint64_t>(hz);

            auto it = posMap.find(key);
            if (it != posMap.end()) {
                // Same approximate position — average the normal
                welded.vertices[it->second].normal += v.normal;
            } else {
                posMap[key] = static_cast<uint32_t>(welded.vertices.size());
                welded.vertices.push_back(v);
            }
        }
        for (auto& v : welded.vertices) {
            v.normal = glm::normalize(v.normal);
        }

        // Remap indices through the welded vertex map
        for (auto idx : input.indices) {
            const auto& v = input.vertices[idx];
            int64_t hx = static_cast<int64_t>(v.position.x * kHashScale);
            int64_t hy = static_cast<int64_t>(v.position.y * kHashScale);
            int64_t hz = static_cast<int64_t>(v.position.z * kHashScale);
            uint64_t key = (static_cast<uint64_t>(hx) << 42)
                         ^ (static_cast<uint64_t>(hy) << 21)
                         ^ static_cast<uint64_t>(hz);
            welded.indices.push_back(posMap[key]);
        }

        MF_INFO("  Welded: {} verts -> {} verts ({} face seams merged)",
                input.vertexCount(), welded.vertexCount(),
                input.vertexCount() - welded.vertexCount());

        // Run sloppy on the welded mesh — no attribute seams to block it
        std::vector<unsigned int> sloppyIndices(welded.indices.begin(), welded.indices.end());
        float sloppyError = 0.0f;
        size_t sloppyCount = runMeshOptSimplifySloppy(
            sloppyIndices, welded,
            static_cast<size_t>(targetTris * 3),
            &sloppyError
        );
        uint32_t sloppyTris = static_cast<uint32_t>(sloppyCount / 3);
        MF_INFO("  Sloppy: {} -> {} tris (target {}, after welding)",
                sourceTris, sloppyTris, targetTris);

        if (sloppyCount > 0 && sloppyTris < bestTris) {
            MeshData sloppyMesh = buildOutputMesh(welded, sloppyIndices, sloppyCount);
            sloppyMesh.computeNormals(); // re-derive normals from simplified geometry
            sloppyMesh.computeTangents();
            result.mesh = std::move(sloppyMesh);
            result.usedSloppy = true;
            result.usedError = sloppyError;
            bestTris = sloppyTris;
            ++result.passes;
        }
    } else if (!params.useSloppyFallback && bestTris > targetTris * 1.4f) {
        MF_INFO("  Sloppy fallback disabled — achieved {:.1f}% vs target {:.1f}%",
                static_cast<float>(bestTris) / static_cast<float>(sourceTris) * 100.0f,
                params.targetRatio * 100.0f);
    }

    result.achievedRatio = static_cast<float>(bestTris) / static_cast<float>(sourceTris);

    MF_INFO("Simplify result: {} -> {} tris (target {:.3f}, achieved {:.3f}, error {:.4f}, sloppy={})",
            sourceTris, result.mesh.triangleCount(),
            params.targetRatio, result.achievedRatio,
            result.usedError, result.usedSloppy);

    result.mesh.computeAABB();
    return result;
}

// ------------------------------------------------------------------
// DEPRECATED: Fast Quadric stub — delegates to meshoptimizer
// The stub only did uniform triangle sampling which produces holes.
// ------------------------------------------------------------------
MeshData Simplifier::simplifyQuadric(const MeshData& input, const SimplifyParams& params) {
    auto result = simplifyMeshOptimizer(input, params);
    return std::move(result.mesh);
}

// ------------------------------------------------------------------
// Auto-pick — always uses meshoptimizer for consistent quality
// ------------------------------------------------------------------
SimplifyResult Simplifier::simplify(const MeshData& input, const SimplifyParams& params) {
    return simplifyMeshOptimizer(input, params);
}

// ------------------------------------------------------------------
// File size estimation
// ------------------------------------------------------------------
float estimateFileSizeMB(const MeshData& mesh) {
    if (mesh.triangleCount() == 0) return 0.0f;

    // Vertex: 48 bytes (pos 12 + normal 12 + uv 8 + tangent 16)
    // Index: 4 bytes (uint32)
    constexpr float kBytesPerVertex = 48.0f;
    constexpr float kBytesPerIndex = 4.0f;
    constexpr float kDracoRatio = 0.12f;     // Draco compresses to ~12% of raw
    constexpr float kGLTFOverhead = 1.20f;    // JSON/buffer structure overhead

    double rawBytes = mesh.vertexCount() * kBytesPerVertex + mesh.indexCount() * kBytesPerIndex;
    double dracoBytes = rawBytes * kDracoRatio * kGLTFOverhead;
    return static_cast<float>(dracoBytes / (1024.0 * 1024.0));
}

// ------------------------------------------------------------------
// Improved file-size-to-ratio conversion
// Accounts for non-linear vertex reduction during simplification.
// As triangles reduce, vertex sharing improves, so verts don't drop linearly.
// ------------------------------------------------------------------
float ratioForTargetFileSize(const MeshData& mesh, float targetMB) {
    if (mesh.triangleCount() == 0 || targetMB <= 0.0f) return 0.01f;

    float currentMB = estimateFileSizeMB(mesh);
    if (currentMB <= targetMB) return 1.0f;

    // Binary search for ratio in [0.005, 1.0]
    // Use a more accurate model: indices drop linearly with ratio,
    // but vertices drop slower (improved sharing) using a sqrt-like model
    float lo = 0.005f, hi = 1.0f;
    float bestRatio = lo;

    for (int iter = 0; iter < 30; ++iter) {
        float mid = (lo + hi) * 0.5f;

        // Vertices don't shrink as fast as triangles due to better sharing
        // Use a blended model: vc_ratio = sqrt(mid) * 0.3 + mid * 0.7
        float vcRatio = std::sqrt(mid) * 0.3f + mid * 0.7f;
        float icRatio = mid;

        float vc = static_cast<float>(mesh.vertexCount()) * vcRatio;
        float ic = static_cast<float>(mesh.indexCount()) * icRatio;
        double rawBytes = vc * 48.0 + ic * 4.0;
        double dracoBytes = rawBytes * 0.12 * 1.20;
        float estMB = static_cast<float>(dracoBytes / (1024.0 * 1024.0));

        if (std::abs(estMB - targetMB) / targetMB < 0.02f) {
            bestRatio = mid;
            break;
        }
        if (estMB > targetMB) {
            hi = mid;
        } else {
            lo = mid;
            bestRatio = mid;
        }
    }
    return bestRatio;
}

// ------------------------------------------------------------------
// LOD generation
// ------------------------------------------------------------------
std::vector<LODLevel> LODGenerator::generate(const MeshData& baseMesh, const Params& params) {
    std::vector<LODLevel> lods;

    LODLevel l0;
    l0.level = 0;
    l0.screenSize = params.baseScreenSize;
    l0.mesh = baseMesh;
    lods.push_back(std::move(l0));

    MeshData current = baseMesh;
    float screenSize = params.baseScreenSize;

    for (uint32_t i = 1; i < params.levels; ++i) {
        SimplifyParams sp;
        sp.targetRatio = params.reductionFactor;
        sp.targetError = 1e-2f * static_cast<float>(i);
        sp.maxPasses = 2;
        sp.useSloppyFallback = true;
        auto sr = Simplifier::simplify(current, sp);
        current = std::move(sr.mesh);

        screenSize *= params.reductionFactor;

        LODLevel lod;
        lod.level = i;
        lod.screenSize = screenSize;
        lod.mesh = current;
        lods.push_back(std::move(lod));

        if (current.triangleCount() <= 10) break;
    }

    return lods;
}

std::vector<LODLevel> LODGenerator::generateWithTags(
    const MeshData& baseMesh,
    const std::vector<SurfaceTag>& tags,
    const Params& params) {

    std::vector<LODLevel> lods;
    if (baseMesh.triangleCount() == 0) return lods;

    LODLevel l0;
    l0.level = 0;
    l0.screenSize = params.baseScreenSize;
    l0.mesh = baseMesh;
    lods.push_back(std::move(l0));

    MeshData current = baseMesh;
    float screenSize = params.baseScreenSize;

    FeatureSimplifier fs;
    FeatureAwareSimplifyParams fsp;
    fsp.targetRatio = params.reductionFactor;
    fsp.usePerTriangleTags = !tags.empty();
    fsp.maxError = 1e-2f;

    for (uint32_t i = 1; i < params.levels; ++i) {
        if (tags.empty()) {
            current = fs.simplify(current, fsp);
        } else {
            current = fs.simplify(current, tags, fsp);
        }
        fsp.maxError = std::min(fsp.maxError * 1.5f, 0.2f); // progressively looser
        screenSize *= params.reductionFactor;

        LODLevel lod;
        lod.level = i;
        lod.screenSize = screenSize;
        lod.mesh = current;
        lods.push_back(std::move(lod));

        if (current.triangleCount() <= 10) break;
    }

    return lods;
}

SimplifyResult LODGenerator::mergeAndSimplify(
    const std::vector<const MeshData*>& meshes,
    const std::vector<Mat4>& transforms,
    float targetRatio) {

    if (meshes.empty()) {
        return SimplifyResult{MeshData{}, 1.0f, 0.0f, false, 0};
    }

    // Merge all meshes into one
    MeshData merged;
    uint32_t vertOff = 0;
    for (size_t i = 0; i < meshes.size() && i < transforms.size(); ++i) {
        const Mat4& t = transforms[i];
        for (auto& v : meshes[i]->vertices) {
            Vertex wv = v;
            wv.position = Vec3(t * Vec4(v.position, 1.0f));
            wv.normal = glm::normalize(Vec3(t * Vec4(v.normal, 0.0f)));
            merged.vertices.push_back(wv);
        }
        for (auto idx : meshes[i]->indices) {
            merged.indices.push_back(vertOff + idx);
        }
        vertOff += meshes[i]->vertexCount();
    }

    // Simplify merged mesh
    SimplifyParams sp;
    sp.targetRatio = targetRatio;
    sp.targetError = 5e-2f; // more permissive for merged meshes
    sp.preserveBoundary = false;
    sp.maxPasses = 2;
    sp.useSloppyFallback = true;

    auto result = Simplifier::simplify(merged, sp);
    result.mesh.computeAABB();
    return result;
}

int LODGenerator::pickDistanceLOD(float distance, const Params& params) {
    for (int i = 0; i < static_cast<int>(params.levels); ++i) {
        if (i < 4 && distance < params.lodDistances[i]) return i;
    }
    return static_cast<int>(params.levels) - 1;
}

// ------------------------------------------------------------------
// Geometry hashing
// ------------------------------------------------------------------
GeometryHash computeGeometryHash(const MeshData& mesh) {
    GeometryHash h;
    h.bbox = mesh.aabb;

    // Simple hash: combine vertex count, triangle count, and aabb
    h.vertexHash = static_cast<uint64_t>(mesh.vertexCount()) << 32;
    h.vertexHash |= static_cast<uint64_t>(mesh.triangleCount());

    // XOR with AABB extent (position-independent)
    Vec3 ext = mesh.aabb.extent();
    h.indexHash = (static_cast<uint64_t>(*reinterpret_cast<const uint32_t*>(&ext.x)) << 32)
                | static_cast<uint64_t>(*reinterpret_cast<const uint32_t*>(&ext.y));
    h.indexHash ^= static_cast<uint64_t>(*reinterpret_cast<const uint32_t*>(&ext.z));

    return h;
}

// ------------------------------------------------------------------
// Stream loader
// ------------------------------------------------------------------
void StreamLoader::enqueue(const StreamLoadRequest& req) {
    // Insert sorted by priority (lowest = highest priority first)
    auto it = m_requests.begin();
    while (it != m_requests.end() && it->priority <= req.priority) ++it;
    m_requests.insert(it, req);
}

void StreamLoader::processPending() {
    int processed = 0;
    while (!m_requests.empty() && processed < m_maxConcurrent) {
        auto req = m_requests.front();

        if (m_memoryUsed >= m_memoryBudget) break;

        m_requests.erase(m_requests.begin());

        // Request will be processed by the task system
        // (actual loading is handled by Application)
        ++m_loaded;
        ++processed;
    }
}

} // namespace mf
