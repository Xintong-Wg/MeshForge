#pragma once

#include "Core/Types.h"
#include <string>
#include <vector>
#include <memory>
#include <unordered_map>

// OpenCASCADE
#include <opencascade/TopoDS_Shape.hxx>

namespace mf {

struct AssemblyNode;
using AssemblyNodePtr = std::shared_ptr<AssemblyNode>;

// ------------------------------------------------------------------
// Assembly tree node from STEP
// ------------------------------------------------------------------
struct AssemblyNode {
    enum class Type { Root, Assembly, Part };

    std::string id;          // STEP entity tag or generated UUID
    std::string name;
    std::string stepId;      // Original STEP #id
    Type type = Type::Part;
    Mat4 localTransform = Mat4(1.0f);

    std::vector<AssemblyNodePtr> children;
    AssemblyNodePtr parent;

    // For parts: link to shape definition for meshing
    std::string shapeKey;
    bool isInstance = false; // true if this is a placement of a shared shape
    std::string prototypeId; // for instances: points to the original shape/part
};

// ------------------------------------------------------------------
// STEP parsing result
// ------------------------------------------------------------------
struct STEPResult {
    AssemblyNodePtr root;
    std::unordered_map<std::string, AssemblyNodePtr> partsById;
    std::unordered_map<std::string, std::vector<AssemblyNodePtr>> instances; // prototypeId -> placements
    std::unordered_map<std::string, TopoDS_Shape> shapesByKey;              // shapeKey -> TopoDS_Shape
    size_t entityCount = 0;
    double fileScale = 1.0;
};

// ------------------------------------------------------------------
// STEP reader using OpenCASCADE
// ------------------------------------------------------------------
class STEPReader {
public:
    STEPReader();
    ~STEPReader();

    // Parse a STEP file into assembly tree
    std::shared_ptr<STEPResult> read(const std::string& filepath);

    // Streaming parse: read header, count entities, prepare for chunk processing
    bool probe(const std::string& filepath, size_t& outEntityCount);

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace mf
