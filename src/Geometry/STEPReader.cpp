#include "Geometry/STEPReader.h"
#include "Core/Logger.h"
#include "Math/MathUtils.h"

#include <opencascade/STEPCAFControl_Reader.hxx>
#include <opencascade/STEPControl_Reader.hxx>
#include <opencascade/XCAFDoc_ShapeTool.hxx>
#include <opencascade/XCAFDoc_DocumentTool.hxx>
#include <opencascade/TDocStd_Document.hxx>
#include <opencascade/TopoDS_Shape.hxx>
#include <opencascade/TopoDS_Compound.hxx>
#include <opencascade/BRep_Builder.hxx>
#include <opencascade/TDF_Label.hxx>
#include <opencascade/TDF_LabelSequence.hxx>
#include <opencascade/TopExp_Explorer.hxx>
#include <opencascade/TopAbs_ShapeEnum.hxx>
#include <opencascade/BRepTools.hxx>
#include <opencascade/gp_Trsf.hxx>
#include <opencascade/gp_Ax3.hxx>
#include <opencascade/Quantity_Color.hxx>
#include <opencascade/XCAFDoc_ColorTool.hxx>
#include <opencascade/XCAFDoc_ColorType.hxx>
#include <opencascade/TDataStd_Name.hxx>
#include <opencascade/TCollection_ExtendedString.hxx>
#include <opencascade/Message_ProgressRange.hxx>
#include <opencascade/Message_ProgressIndicator.hxx>
#include <opencascade/IFSelect_ReturnStatus.hxx>
#include <opencascade/StepData_StepModel.hxx>
#include <opencascade/Interface_EntityIterator.hxx>
#include <opencascade/Interface_InterfaceModel.hxx>
#include <opencascade/Standard_Integer.hxx>
#include <opencascade/Standard_Failure.hxx>
#include <opencascade/TopLoc_Location.hxx>

#include <fstream>
#include <sstream>
#include <stack>

namespace mf {

// ------------------------------------------------------------------
// Helper: convert gp_Trsf to Mat4
// ------------------------------------------------------------------
static Mat4 toMat4(const gp_Trsf& trsf) {
    Mat4 m(1.0f);
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 4; ++j) {
            m[i][j] = static_cast<float>(trsf.Value(i + 1, j + 1));
        }
    }
    return m;
}

// ------------------------------------------------------------------
// Helper: read name from TDF_Label
// ------------------------------------------------------------------
static std::string readName(const TDF_Label& label) {
    Handle(TDataStd_Name) nameAttr;
    if (label.FindAttribute(TDataStd_Name::GetID(), nameAttr)) {
        TCollection_ExtendedString extStr = nameAttr->Get();
        // Simple ASCII extraction
        std::string result;
        for (int i = 1; i <= extStr.Length(); ++i) {
            result += static_cast<char>(extStr.Value(i));
        }
        return result;
    }
    return "Unnamed";
}

// ------------------------------------------------------------------
// Pimpl
// ------------------------------------------------------------------
class STEPReader::Impl {
public:
    std::shared_ptr<STEPResult> result;

    std::shared_ptr<STEPResult> read(const std::string& filepath);
    void traverseAssembly(const Handle(XCAFDoc_ShapeTool)& shapeTool,
                          const TDF_Label& label,
                          AssemblyNodePtr parent,
                          const Mat4& parentTransform);
};

STEPReader::STEPReader() : m_impl(std::make_unique<Impl>()) {}
STEPReader::~STEPReader() = default;

std::shared_ptr<STEPResult> STEPReader::read(const std::string& filepath) {
    return m_impl->read(filepath);
}

bool STEPReader::probe(const std::string& filepath, size_t& outEntityCount) {
    std::ifstream file(filepath);
    if (!file.is_open()) return false;

    outEntityCount = 0;
    std::string line;
    while (std::getline(file, line)) {
        if (line.find("=") != std::string::npos && line.find("#") != std::string::npos) {
            ++outEntityCount;
        }
    }
    return true;
}

std::shared_ptr<STEPResult> STEPReader::Impl::read(const std::string& filepath) {
    result = std::make_shared<STEPResult>();

    // Use STEPCAFControl_Reader to preserve assembly hierarchy
    STEPCAFControl_Reader reader;
    IFSelect_ReturnStatus status = reader.ReadFile(filepath.c_str());
    if (status != IFSelect_RetDone) {
        MF_ERROR("Failed to read STEP file: {}", filepath);
        return nullptr;
    }

    result->entityCount = reader.NbRootsForTransfer();
    MF_INFO("STEP entities: {}", result->entityCount);

    // Transfer to XCAF document (preserves assembly tree).
    // Some STEP files have bad geometry that causes OCC's ShapeFix to hang or
    // throw (e.g. Geom_RectangularTrimmedSurface parameter out of range).
    // We use a two-path strategy:
    //   1. Try STEPCAFControl_Reader (with shape healing, preserves assembly)
    //   2. Fall back to STEPControl_Reader (no shape healing, flat structure)
    Handle(TDocStd_Document) doc = new TDocStd_Document("MeshForge");
    bool transferOk = false;
    bool usedFallback = false;

    try {
        transferOk = reader.Transfer(doc);
    } catch (const Standard_Failure& e) {
        MF_WARN("STEPCAF Transfer exception: {} — falling back to STEPControl_Reader",
                e.GetMessageString() ? e.GetMessageString() : "unknown");
    } catch (...) {
        MF_WARN("STEPCAF Transfer unknown exception — falling back to STEPControl_Reader");
    }

    if (!transferOk) {
        // Salvage: check if shapes were partially transferred
        MF_WARN("STEPCAF Transfer failed, attempting salvage...");
        try {
            Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
            if (!shapeTool.IsNull()) {
                TDF_LabelSequence salvageLabels;
                shapeTool->GetFreeShapes(salvageLabels);
                if (salvageLabels.Length() > 0) {
                    MF_INFO("Salvage: found {} shapes, using them", salvageLabels.Length());
                    transferOk = true;
                }
            }
        } catch (...) {
            MF_WARN("Salvage attempt threw exception");
        }
    }

    if (!transferOk) {
        MF_WARN("Salvage also failed, using STEPControl_Reader (flat structure)...");

        // Fallback: STEPControl_Reader reads geometry without XCAF assembly
        // and importantly, WITHOUT shape processing/ShapeFix.
        STEPControl_Reader basicReader;
        IFSelect_ReturnStatus basicStatus = basicReader.ReadFile(filepath.c_str());
        if (basicStatus != IFSelect_RetDone) {
            MF_ERROR("Fallback reader also failed to read STEP file");
            return nullptr;
        }

        // Fallback: STEPControl_Reader transfers shapes without XCAF overhead.
        // Transfer roots one by one, skip any that throw during shape healing.
        Standard_Integer nbRoots = basicReader.NbRootsForTransfer();
        if (nbRoots <= 0) {
            MF_ERROR("Fallback reader found no roots");
            return nullptr;
        }

        TopoDS_Compound compound;
        BRep_Builder builder;
        builder.MakeCompound(compound);
        int transferred = 0;

        for (Standard_Integer i = 1; i <= nbRoots; ++i) {
            try {
                basicReader.TransferRoot(i);
                TopoDS_Shape shape = basicReader.Shape(i);
                if (!shape.IsNull()) {
                    builder.Add(compound, shape);
                    ++transferred;
                }
            } catch (const Standard_Failure& e) {
                MF_WARN("Fallback: skipping root {} — {}", i,
                        e.GetMessageString() ? e.GetMessageString() : "exception");
            } catch (...) {
                MF_WARN("Fallback: skipping root {} due to unknown exception", i);
            }
        }

        if (transferred == 0) {
            MF_ERROR("Fallback reader transferred 0 shapes");
            return nullptr;
        }

        // Build a flat shape structure manually (no assembly tree)
        std::string flatKey = "shape_fallback";
        result->shapesByKey[flatKey] = compound;
        result->root = std::make_shared<AssemblyNode>();
        result->root->id = "root";
        result->root->name = "Root";
        result->root->type = AssemblyNode::Type::Root;

        auto part = std::make_shared<AssemblyNode>();
        part->id = "part_fallback";
        part->name = filepath.substr(filepath.find_last_of("/\\") + 1);
        part->type = AssemblyNode::Type::Part;
        part->shapeKey = flatKey;
        part->localTransform = Mat4(1.0f);
        result->root->children.push_back(part);
        part->parent = result->root;
        result->partsById[part->id] = part;

        result->entityCount = transferred;
        usedFallback = true;

        MF_INFO("Fallback: loaded {} roots as flat assembly", transferred);
    }

    if (!usedFallback) {
        Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());

        TDF_LabelSequence rootLabels;
        shapeTool->GetFreeShapes(rootLabels);

        result->root = std::make_shared<AssemblyNode>();
        result->root->id = "root";
        result->root->name = "Root";
        result->root->type = AssemblyNode::Type::Root;

        for (Standard_Integer i = 1; i <= rootLabels.Length(); ++i) {
            traverseAssembly(shapeTool, rootLabels.Value(i), result->root, Mat4(1.0f));
        }

        // Post-process: detect instances by shape key
        std::unordered_map<std::string, std::string> shapeToPrototype;
        for (auto& [id, node] : result->partsById) {
            if (node->type == AssemblyNode::Type::Part && !node->isInstance) {
                if (shapeToPrototype.find(node->shapeKey) == shapeToPrototype.end()) {
                    shapeToPrototype[node->shapeKey] = node->id;
                } else {
                    node->isInstance = true;
                    node->prototypeId = shapeToPrototype[node->shapeKey];
                    result->instances[node->prototypeId].push_back(node);
                }
            }
        }

        MF_INFO("Assembly: {} root shapes, {} total parts, {} instances",
                rootLabels.Length(), result->partsById.size(), result->instances.size());
    }

    return result;
}

void STEPReader::Impl::traverseAssembly(const Handle(XCAFDoc_ShapeTool)& shapeTool,
                                        const TDF_Label& label,
                                        AssemblyNodePtr parent,
                                        const Mat4& parentTransform) {
    if (label.IsNull()) return;

    auto node = std::make_shared<AssemblyNode>();
    node->name = readName(label);

    static uint64_t genId = 1;
    node->id = node->name + "_" + std::to_string(genId++);

    // Get local transform (OCCT 7.9 returns TopLoc_Location by value)
    // For a component label in an assembly, this returns the placement of
    // the component relative to its parent assembly.
    TopLoc_Location loc = XCAFDoc_ShapeTool::GetLocation(label);
    gp_Trsf trsf = loc.Transformation();
    node->localTransform = toMat4(trsf);

    Mat4 world = parentTransform * node->localTransform;

    // Determine the "effective" label for type checking:
    // For a reference label (e.g., an assembly component that points to
    // a sub-assembly or a shape definition), we must check the referred
    // label's type, not the reference label's type.
    TDF_Label refLabel;
    TDF_Label effectiveLabel = label;
    if (shapeTool->GetReferredShape(label, refLabel)) {
        effectiveLabel = refLabel;
    }

    if (shapeTool->IsAssembly(effectiveLabel)) {
        node->type = AssemblyNode::Type::Assembly;
        parent->children.push_back(node);
        node->parent = parent;

        TDF_LabelSequence components;
        shapeTool->GetComponents(effectiveLabel, components);
        for (Standard_Integer i = 1; i <= components.Length(); ++i) {
            traverseAssembly(shapeTool, components.Value(i), node, world);
        }
    } else if (shapeTool->IsSimpleShape(effectiveLabel) || shapeTool->IsShape(effectiveLabel)) {
        node->type = AssemblyNode::Type::Part;

        // Get the shape from the effective label (the referred label, not the
        // component reference). The referred shape does NOT have the component's
        // placement applied, so we use the accumulated 'world' transform in
        // Application::loadSTEP() to place vertices correctly.
        TopoDS_Shape shp;
        std::stringstream ss;
        shapeTool->GetShape(effectiveLabel, shp);
        // Ensure shape is in local coordinates — reset any baked-in location
        // so that the assembly transform applied in loadSTEP() is the only one.
        if (!shp.IsNull()) {
            shp.Location(TopLoc_Location());
        }
        ss << effectiveLabel.Tag() << "_" << shp.ShapeType();
        node->shapeKey = ss.str();
        result->shapesByKey[node->shapeKey] = shp;
        parent->children.push_back(node);
        node->parent = parent;
        result->partsById[node->id] = node;
    }
}

} // namespace mf
