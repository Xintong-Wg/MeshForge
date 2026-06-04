#include "Geometry/BRepEngine.h"
#include "Core/Logger.h"
#include "Math/MathUtils.h"

#include <opencascade/BRepMesh_IncrementalMesh.hxx>
#include <opencascade/BRep_Tool.hxx>
#include <opencascade/TopExp_Explorer.hxx>
#include <opencascade/TopAbs_ShapeEnum.hxx>
#include <opencascade/Poly_Triangulation.hxx>
#include <opencascade/Poly_Array1OfTriangle.hxx>
#include <opencascade/TColgp_Array1OfPnt.hxx>
#include <opencascade/gp_Pnt.hxx>
#include <opencascade/gp_Vec.hxx>
#include <opencascade/BRepGProp.hxx>
#include <opencascade/GProp_GProps.hxx>
#include <opencascade/TopLoc_Location.hxx>
#include <opencascade/BRepTools.hxx>
#include <opencascade/GeomLProp_SLProps.hxx>
#include <opencascade/BRepAdaptor_Surface.hxx>
#include <opencascade/TopoDS_Face.hxx>
#include <opencascade/TopoDS.hxx>
#include <opencascade/BRepBndLib.hxx>
#include <opencascade/Bnd_Box.hxx>

namespace mf {

// Compute normal at UV param on surface
static Vec3 computeNormal(const TopoDS_Face& face, const Handle(Poly_Triangulation)& tri,
                          int nodeIndex, const gp_Pnt2d& uv) {
    try {
        BRepAdaptor_Surface surf(face, Standard_False);
        GeomLProp_SLProps props(surf.Surface().Surface(), uv.X(), uv.Y(), 1, 1e-6);
        if (props.IsNormalDefined()) {
            gp_Dir n = props.Normal();
            if (face.Orientation() == TopAbs_REVERSED) n.Reverse();
            return Vec3(static_cast<float>(n.X()), static_cast<float>(n.Y()), static_cast<float>(n.Z()));
        }
    } catch (...) {}

    // Fallback: average face normals from triangles containing this node
    Standard_Integer nbNodes = tri->NbNodes();
    if (nodeIndex >= 1 && nodeIndex <= nbNodes) {
        gp_Vec avg(0, 0, 0);
        int count = 0;
        for (Standard_Integer t = 1; t <= tri->NbTriangles(); ++t) {
            const Poly_Triangle& triangle = tri->Triangle(t);
            Standard_Integer n1, n2, n3;
            triangle.Get(n1, n2, n3);
            if (n1 == nodeIndex || n2 == nodeIndex || n3 == nodeIndex) {
                gp_Pnt p1 = tri->Node(n1);
                gp_Pnt p2 = tri->Node(n2);
                gp_Pnt p3 = tri->Node(n3);
                gp_Vec v1(p2.XYZ() - p1.XYZ());
                gp_Vec v2(p3.XYZ() - p1.XYZ());
                gp_Vec fn = v1.Crossed(v2);
                if (fn.Magnitude() > 1e-12) {
                    avg += fn.Normalized();
                    ++count;
                }
            }
        }
        if (count > 0) {
            avg /= count;
            if (avg.Magnitude() > 1e-12) {
                avg.Normalize();
                return Vec3(static_cast<float>(avg.X()), static_cast<float>(avg.Y()), static_cast<float>(avg.Z()));
            }
        }
    }
    return Vec3(0, 0, 1);
}

class BRepEngine::Impl {
public:
    BRepMesh doTessellate(const TopoDS_Shape& shape, const TopLoc_Location& loc,
                          const TessellationParams& params);
};

BRepEngine::BRepEngine() : m_impl(std::make_unique<Impl>()) {}
BRepEngine::~BRepEngine() = default;

BRepMesh BRepEngine::tessellate(const TopoDS_Shape& shape, const TessellationParams& params) {
    return m_impl->doTessellate(shape, TopLoc_Location(), params);
}

BRepMesh BRepEngine::tessellate(const TopoDS_Shape& shape, const TopLoc_Location& loc,
                                const TessellationParams& params) {
    return m_impl->doTessellate(shape, loc, params);
}

BRepMesh BRepEngine::tessellate(const TopoDS_Shape& shape, const Mat4& transform,
                                const TessellationParams& params) {
    gp_Trsf trsf;
    trsf.SetValues(
        transform[0][0], transform[1][0], transform[2][0], transform[3][0],
        transform[0][1], transform[1][1], transform[2][1], transform[3][1],
        transform[0][2], transform[1][2], transform[2][2], transform[3][2]);
    return m_impl->doTessellate(shape, TopLoc_Location(trsf), params);
}

BRepMesh BRepEngine::Impl::doTessellate(const TopoDS_Shape& shape, const TopLoc_Location& loc,
                                        const TessellationParams& params) {
    BRepMesh mesh;
    if (shape.IsNull()) return mesh;

    float linDefl = params.linearDeflection;
    if (params.relative) {
        GProp_GProps props;
        BRepGProp::VolumeProperties(shape, props);
        if (props.Mass() > 0) {
            Bnd_Box box;
            BRepBndLib::Add(shape, box);
            if (!box.IsVoid()) {
                float diag = static_cast<float>(box.SquareExtent());
                linDefl = std::max(diag * params.linearDeflection, params.minEdgeLength);
            }
        }
    }

    BRepMesh_IncrementalMesh incMesh(shape, linDefl, Standard_False,
                                     static_cast<Standard_Real>(params.angularDeflection),
                                     Standard_True);

    uint32_t vertexOffset = 0;
    TopExp_Explorer faceExp(shape, TopAbs_FACE);
    for (; faceExp.More(); faceExp.Next()) {
        TopoDS_Face face = TopoDS::Face(faceExp.Current());
        TopLoc_Location faceLoc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, faceLoc);
        if (tri.IsNull()) continue;

        Standard_Integer nbNodes = tri->NbNodes();
        Standard_Integer nbTriangles = tri->NbTriangles();

        TopLoc_Location totalLoc = loc * faceLoc;
        gp_Trsf trsf = totalLoc.Transformation();

        bool hasUV = tri->HasUVNodes();

        for (Standard_Integer n = 1; n <= nbNodes; ++n) {
            gp_Pnt p = tri->Node(n).Transformed(trsf);
            Vec3 pos(static_cast<float>(p.X()), static_cast<float>(p.Y()), static_cast<float>(p.Z()));
            mesh.aabb.expand(pos);

            Vec3 normal(0, 0, 1);
            Vec2 uv(0, 0);
            if (hasUV) {
                gp_Pnt2d uvNode = tri->UVNode(n);
                uv = Vec2(static_cast<float>(uvNode.X()), static_cast<float>(uvNode.Y()));
                normal = computeNormal(face, tri, n, uvNode);
            }

            Vertex v;
            v.position = pos;
            v.normal = normal;
            v.uv = uv;
            v.tangent = Vec4(1, 0, 0, 1);
            mesh.vertices.push_back(v);
        }

        for (Standard_Integer t = 1; t <= nbTriangles; ++t) {
            const Poly_Triangle& triangle = tri->Triangle(t);
            Standard_Integer n1, n2, n3;
            triangle.Get(n1, n2, n3);
            mesh.indices.push_back(vertexOffset + (n1 - 1));
            mesh.indices.push_back(vertexOffset + (n2 - 1));
            mesh.indices.push_back(vertexOffset + (n3 - 1));
        }

        vertexOffset += static_cast<uint32_t>(nbNodes);
        ++mesh.faceCount;
        mesh.triangleCount += static_cast<uint32_t>(nbTriangles);
    }

    MF_INFO("BRepEngine: {} vertices, {} triangles from {} faces",
            mesh.vertices.size(), mesh.indices.size() / 3, mesh.faceCount);
    return mesh;
}

} // namespace mf
