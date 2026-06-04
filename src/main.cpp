#include "App/Application.h"
#include "Core/Logger.h"
#include <cstring>

int main(int argc, char** argv) {
    mf::Logger::init();
    MF_INFO("MeshForge starting...");

    // Self-test mode (no window)
    if (argc > 1 && std::strcmp(argv[1], "--self-test") == 0) {
        MF_INFO("Running self-test...");

        mf::AABB aabb;
        aabb.expand(mf::Vec3(0, 0, 0));
        aabb.expand(mf::Vec3(1, 1, 1));
        if (aabb.isEmpty()) { MF_ERROR("AABB self-test FAILED"); return 1; }
        MF_INFO("AABB self-test PASSED");

        mf::MeshData mesh;
        mesh.vertices.push_back(mf::Vertex{mf::Vec3(0,0,0), mf::Vec3(0,1,0), mf::Vec2(0,0), mf::Vec4(1,0,0,1)});
        mesh.vertices.push_back(mf::Vertex{mf::Vec3(1,0,0), mf::Vec3(0,1,0), mf::Vec2(1,0), mf::Vec4(1,0,0,1)});
        mesh.vertices.push_back(mf::Vertex{mf::Vec3(0,1,0), mf::Vec3(0,1,0), mf::Vec2(0,1), mf::Vec4(1,0,0,1)});
        mesh.indices = {0, 1, 2};
        mesh.computeAABB();
        if (mesh.aabb.min != mf::Vec3(0,0,0) || mesh.aabb.max != mf::Vec3(1,1,0)) {
            MF_ERROR("MeshData self-test FAILED"); return 1;
        }
        MF_INFO("MeshData self-test PASSED");

        mf::SimplifyParams sp; sp.targetRatio = 0.5f;
        auto sr = mf::Simplifier::simplify(mesh, sp);
        if (sr.mesh.triangleCount() > mesh.triangleCount()) {
            MF_ERROR("Simplifier self-test FAILED"); return 1;
        }
        MF_INFO("Simplifier self-test PASSED");

        mf::LODGenerator::Params lodParams;
        auto lods = mf::LODGenerator::generate(mesh, lodParams);
        if (lods.empty()) { MF_ERROR("LODGenerator self-test FAILED"); return 1; }
        MF_INFO("LODGenerator self-test PASSED");

        mf::Scene scene;
        auto node = std::make_shared<mf::SceneNode>("TestNode", mf::SceneNode::Type::Mesh);
        scene.root()->addChild(node);
        int count = 0;
        scene.root()->traverse([&count](mf::SceneNode* n) { (void)n; ++count; });
        if (count != 2) { MF_ERROR("SceneGraph self-test FAILED"); return 1; }
        MF_INFO("SceneGraph self-test PASSED");

        std::atomic<int> taskValue{0};
        auto task = std::make_shared<mf::Task>("TestTask", [&taskValue](mf::Task* t) {
            t->setProgress(0.5f); taskValue.store(42); t->setProgress(1.0f);
        });
        mf::TaskSystem::instance().submit(task);
        mf::TaskSystem::instance().waitAll();
        if (taskValue.load() != 42) { MF_ERROR("TaskSystem self-test FAILED"); return 1; }
        MF_INFO("TaskSystem self-test PASSED");

        MF_INFO("=== ALL SELF-TESTS PASSED ===");
        return 0;
    }

    // GUI mode
    mf::Application app;
    if (!app.init(1920, 1080, "MeshForge")) {
        MF_ERROR("Failed to initialize application");
        return 1;
    }

    while (app.isRunning()) {
        app.runFrame();
    }

    app.shutdown();
    return 0;
}
