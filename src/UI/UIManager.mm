#include "UI/UIManager.h"
#include "Core/Logger.h"

#include <imgui.h>
#include <imgui_internal.h>
#include <imgui_impl_sdl2.h>
#include <imgui_impl_opengl3.h>
#include <SDL2/SDL.h>

#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#include <glm/gtc/type_ptr.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <cmath>
#include <cstring>

// macOS native file dialog
#ifdef __APPLE__
#import <AppKit/AppKit.h>

static std::string macOSOpenFileDialog() {
    @autoreleasepool {
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Open STEP File";
        NSArray* types = @[@"stp", @"step", @"STP", @"STEP"];
        panel.allowedFileTypes = types;
        if ([panel runModal] == NSModalResponseOK) {
            NSURL* url = panel.URLs.firstObject;
            return std::string(url.path.UTF8String);
        }
    }
    return "";
}

static std::string macOSSaveFileDialog(bool stlMode = false) {
    @autoreleasepool {
        NSSavePanel* panel = [NSSavePanel savePanel];
        if (stlMode) {
            panel.title = @"Export STL";
            panel.allowedFileTypes = @[@"stl"];
            panel.nameFieldStringValue = @"model.stl";
        } else {
            panel.title = @"Export glTF";
            panel.allowedFileTypes = @[@"glb", @"gltf"];
            panel.nameFieldStringValue = @"model.glb";
        }
        if ([panel runModal] == NSModalResponseOK) {
            NSURL* url = panel.URL;
            return std::string(url.path.UTF8String);
        }
    }
    return "";
}
#else
static std::string macOSOpenFileDialog() { return ""; }
static std::string macOSSaveFileDialog(bool) { return ""; }
#endif

namespace mf {

// ------------------------------------------------------------------
// OpenGL shader sources
// ------------------------------------------------------------------
static const char* g_vertShader = R"(#version 150
uniform mat4 u_mvp;
uniform mat4 u_model;
uniform vec3 u_lightDir;
uniform vec3 u_camPos;
uniform float u_highlightScale;
in vec3 a_pos;
in vec3 a_normal;
in vec4 a_color;
out vec3 v_normal;
out vec3 v_worldPos;
out vec4 v_color;
void main() {
    // u_highlightScale is a world-space offset along normal (0 = no offset)
    vec3 displaced = a_pos + a_normal * u_highlightScale;
    vec4 wp = u_model * vec4(displaced, 1.0);
    v_worldPos = wp.xyz;
    v_normal = mat3(u_model) * a_normal;
    v_color = a_color;
    gl_Position = u_mvp * vec4(displaced, 1.0);
}
)";

static const char* g_fragShader = R"(#version 150
in vec3 v_normal;
in vec3 v_worldPos;
in vec4 v_color;
uniform vec3 u_lightDir;
uniform vec3 u_camPos;
uniform vec3 u_tintColor;
out vec4 outColor;
void main() {
    vec3 N = normalize(v_normal);
    vec3 L = normalize(u_lightDir);
    vec3 V = normalize(u_camPos - v_worldPos);
    vec3 H = normalize(L + V);
    float diff = max(dot(N, L), 0.0);
    float spec = pow(max(dot(N, H), 0.0), 64.0);
    vec3 base = v_color.rgb * u_tintColor;
    vec3 ambient = base * 0.15;
    vec3 diffuse = base * diff * 0.7;
    vec3 specular = vec3(0.3) * spec;
    outColor = vec4(ambient + diffuse + specular, 1.0);
}
)";

static unsigned compileShader(const char* src, GLenum type) {
    unsigned s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    int ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char buf[512]; glGetShaderInfoLog(s, 512, nullptr, buf); printf("Shader error: %s\n", buf); }
    return s;
}

// ------------------------------------------------------------------
// ViewportPanel
// ------------------------------------------------------------------
ViewportPanel::ViewportPanel() = default;
ViewportPanel::~ViewportPanel() {
    if (m_fbo) glDeleteFramebuffers(1, &m_fbo);
    if (m_fboTex) glDeleteTextures(1, &m_fboTex);
    if (m_fboDepth) glDeleteTextures(1, &m_fboDepth);
    if (m_vao) glDeleteVertexArrays(1, &m_vao);
    if (m_vbo) glDeleteBuffers(1, &m_vbo);
    if (m_ebo) glDeleteBuffers(1, &m_ebo);
    if (m_shader) glDeleteProgram(m_shader);
}

void ViewportPanel::initGL() {
    // Shader
    unsigned vs = compileShader(g_vertShader, GL_VERTEX_SHADER);
    unsigned fs = compileShader(g_fragShader, GL_FRAGMENT_SHADER);
    m_shader = glCreateProgram();
    glAttachShader(m_shader, vs);
    glAttachShader(m_shader, fs);
    glBindAttribLocation(m_shader, 0, "a_pos");
    glBindAttribLocation(m_shader, 1, "a_normal");
    glBindAttribLocation(m_shader, 2, "a_color");
    glLinkProgram(m_shader);
    int ok; glGetProgramiv(m_shader, GL_LINK_STATUS, &ok);
    if (!ok) { char buf[512]; glGetProgramInfoLog(m_shader, 512, nullptr, buf); printf("Link error: %s\n", buf); }
    glDeleteShader(vs); glDeleteShader(fs);

    // VAO
    glGenVertexArrays(1, &m_vao);
    glGenBuffers(1, &m_vbo);
    glGenBuffers(1, &m_ebo);

    // FBO
    glGenFramebuffers(1, &m_fbo);
    glGenTextures(1, &m_fboTex);
    glGenTextures(1, &m_fboDepth);

    printf("[Viewport] OpenGL init done, shader=%u\n", m_shader);
}

void ViewportPanel::uploadMesh() {
    if (!m_mesh || m_mesh->vertices.empty()) return;

    // Vertex format: pos(12) + normal(12) + color(16) = 40 bytes interleaved
    struct V3D { float px, py, pz, nx, ny, nz; float r, g, b, a; };
    std::vector<V3D> verts;
    try {
        verts.resize(m_mesh->vertices.size());
    } catch (const std::bad_alloc&) {
        printf("[Viewport] Failed to allocate vertex buffer (%zu verts)\n", m_mesh->vertices.size());
        m_gpuIndexCount = 0;
        m_meshDirty = false;
        return;
    }
    for (size_t i = 0; i < m_mesh->vertices.size(); ++i) {
        verts[i].px = m_mesh->vertices[i].position.x;
        verts[i].py = m_mesh->vertices[i].position.y;
        verts[i].pz = m_mesh->vertices[i].position.z;
        verts[i].nx = m_mesh->vertices[i].normal.x;
        verts[i].ny = m_mesh->vertices[i].normal.y;
        verts[i].nz = m_mesh->vertices[i].normal.z;
        verts[i].r = 0.7f; verts[i].g = 0.6f; verts[i].b = 0.5f; verts[i].a = 1.0f;
    }

    glBindVertexArray(m_vao);

    // Orphan old buffer before uploading new data: pass nullptr first to
    // allocate a fresh buffer, then write the real data.  This prevents the
    // GPU from referencing the old buffer while we overwrite it (Metal bridge
    // will abort on in-flight buffer modification).
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    glBufferData(GL_ARRAY_BUFFER, verts.size() * sizeof(V3D), nullptr, GL_DYNAMIC_DRAW);
    glBufferData(GL_ARRAY_BUFFER, verts.size() * sizeof(V3D), verts.data(), GL_DYNAMIC_DRAW);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        printf("[Viewport] glBufferData(VBO) failed: err=%u, size=%zu MB\n",
               err, (verts.size() * sizeof(V3D)) / (1024*1024));
        m_gpuIndexCount = 0;
        m_meshDirty = false;
        glBindVertexArray(0);
        return;
    }

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, m_ebo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, m_mesh->indices.size() * sizeof(Index), nullptr, GL_DYNAMIC_DRAW);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, m_mesh->indices.size() * sizeof(Index),
                 m_mesh->indices.data(), GL_DYNAMIC_DRAW);
    err = glGetError();
    if (err != GL_NO_ERROR) {
        printf("[Viewport] glBufferData(EBO) failed: err=%u, size=%zu MB\n",
               err, (m_mesh->indices.size() * sizeof(Index)) / (1024*1024));
        m_gpuIndexCount = 0;
        m_meshDirty = false;
        glBindVertexArray(0);
        return;
    }

    // position
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(V3D), (void*)0);
    // normal
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(V3D), (void*)12);
    // color
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, sizeof(V3D), (void*)24);

    m_gpuIndexCount = m_mesh->indexCount();
    m_meshDirty = false;
    glBindVertexArray(0);
    printf("[Viewport] Mesh uploaded: %u verts, %u tris\n",
           m_mesh->vertexCount(), m_mesh->triangleCount());
}

void ViewportPanel::orbitCamera() {
    if (!ImGui::IsWindowHovered()) return;

    ImGuiIO& io = ImGui::GetIO();
    ImVec2 vpSize = ImGui::GetContentRegionAvail();
    int vpH = (int)vpSize.y;
    if (vpH < 1) vpH = 1;

    // Scroll wheel zoom (centered on cursor behavior feel)
    float scroll = io.MouseWheel;
    if (scroll != 0) {
        float zoomSpeed = 0.12f;
        m_distance *= (1.0f - scroll * zoomSpeed);
        m_distance = std::max(0.05f, std::min(m_distance, m_farPlane * 0.95f));
    }

    bool middleDown = ImGui::IsMouseDown(ImGuiMouseButton_Middle);
    bool shiftDown = io.KeyShift;
    bool ctrlDown = io.KeyCtrl || io.KeySuper;

    if (middleDown) {
        if (!m_dragging) {
            m_dragging = true;
            m_lastMouseX = io.MousePos.x;
            m_lastMouseY = io.MousePos.y;
        }
        float dx = io.MousePos.x - m_lastMouseX;
        float dy = io.MousePos.y - m_lastMouseY;
        m_lastMouseX = io.MousePos.x;
        m_lastMouseY = io.MousePos.y;

        if (shiftDown) {
            // Shift + middle drag = pan (move target along view plane)
            Vec3 forward(
                std::sin(m_yaw) * std::cos(m_pitch),
                std::sin(m_pitch),
                std::cos(m_yaw) * std::cos(m_pitch)
            );
            Vec3 right = glm::normalize(glm::cross(forward, Vec3(0, 1, 0)));
            Vec3 up = glm::cross(right, forward);

            // Adaptive pan speed: pixel-to-world ratio based on distance and FOV
            float fovRad = glm::radians(45.0f);
            float panSpeed = m_distance * std::tan(fovRad * 0.5f) / (vpH * 0.5f);
            // Extra multiplier for comfortable speed
            panSpeed *= 1.5f;

            m_target += right * (-dx * panSpeed) + up * (dy * panSpeed);
        } else {
            // Middle drag = orbit around target
            // Adaptive orbit sensitivity: consistent angular speed regardless of distance
            float orbitSpeed = 0.0035f;
            m_yaw   += dx * orbitSpeed;
            m_pitch -= dy * orbitSpeed;
            // Clamp pitch to prevent camera flip
            m_pitch = std::max(-1.55f, std::min(1.55f, m_pitch));
        }
    } else {
        m_dragging = false;
    }

    // --- Viewport Selection (Left Click / Shift+Box) ---
    if (ImGui::IsWindowHovered()) {
        bool leftClicked = ImGui::IsMouseClicked(ImGuiMouseButton_Left);
        bool leftReleased = ImGui::IsMouseReleased(ImGuiMouseButton_Left);
        bool leftDown = ImGui::IsMouseDown(ImGuiMouseButton_Left);

        if (leftClicked && !shiftDown && !ctrlDown) {
            m_mouseLeftDown = true;
            m_boxSelectStartX = io.MousePos.x;
            m_boxSelectStartY = io.MousePos.y;
            m_isBoxSelecting = false;
        }

        if (m_mouseLeftDown && leftDown && !m_dragging) {
            float dx = io.MousePos.x - m_boxSelectStartX;
            float dy = io.MousePos.y - m_boxSelectStartY;
            if (std::abs(dx) > 4.0f || std::abs(dy) > 4.0f) {
                m_isBoxSelecting = true;
            }
            if (m_isBoxSelecting) {
                m_boxSelectEndX = io.MousePos.x;
                m_boxSelectEndY = io.MousePos.y;
            }
        }

        if (m_mouseLeftDown && leftReleased) {
            if (m_isBoxSelecting) {
                // Box select (drag > threshold)
                doBoxPick(m_boxSelectStartX, m_boxSelectStartY,
                          m_boxSelectEndX, m_boxSelectEndY);
            } else if (!shiftDown && !ctrlDown) {
                // Point pick (click without drag)
                doRayPick(io.MousePos.x, io.MousePos.y);
            }
            m_mouseLeftDown = false;
            m_isBoxSelecting = false;
        }
    }
}

void ViewportPanel::setHighlightRange(uint32_t indexOffset, uint32_t indexCount) {
    m_highlightIndexOffset = indexOffset;
    m_highlightIndexCount = indexCount;
    m_hasHighlight = (indexCount > 0);
}

void ViewportPanel::clearHighlight() {
    m_hasHighlight = false;
    m_highlightIndexCount = 0;
}

void ViewportPanel::setPickParts(const std::vector<PartPickInfo>& parts) {
    m_pickParts = parts;
}

// ------------------------------------------------------------------
// Ray pick: screen-space mouse pos -> world ray -> AABB intersection
// ------------------------------------------------------------------
static bool rayAABBIntersect(const Vec3& rayOrigin, const Vec3& rayDir,
                              const AABB& aabb, float& outT) {
    float tmin = 0.0f, tmax = std::numeric_limits<float>::max();
    for (int i = 0; i < 3; ++i) {
        if (std::abs(rayDir[i]) < 1e-6f) {
            if (rayOrigin[i] < aabb.min[i] || rayOrigin[i] > aabb.max[i]) return false;
        } else {
            float t1 = (aabb.min[i] - rayOrigin[i]) / rayDir[i];
            float t2 = (aabb.max[i] - rayOrigin[i]) / rayDir[i];
            if (t1 > t2) std::swap(t1, t2);
            tmin = std::max(tmin, t1);
            tmax = std::min(tmax, t2);
            if (tmin > tmax) return false;
        }
    }
    outT = tmin;
    return outT >= 0.0f;
}

void ViewportPanel::doRayPick(float mouseX, float mouseY) {
    if (m_pickParts.empty() || !m_selectionCallback) return;

    // Use stored FBO image origin from render3D, or fallback to content region
    float originX = m_vpImgOriginX;
    float originY = m_vpImgOriginY;
    int w = (int)m_vpImgW, h = (int)m_vpImgH;
    if (w < 4 || h < 4) {
        // First frame: render3D hasn't set m_vpImg* yet, use window pos + estimate
        ImVec2 winPos = ImGui::GetWindowPos();
        ImVec2 avail = ImGui::GetContentRegionAvail();
        originX = winPos.x;
        originY = winPos.y + ImGui::GetFrameHeightWithSpacing() * 1.5f + ImGui::GetTextLineHeightWithSpacing();
        w = (int)avail.x; h = (int)avail.y;
        if (w < 4 || h < 4) return;
    }

    float vpX = mouseX - originX;
    float vpY = mouseY - originY;

    // Normalized device coordinates
    float ndcX = (2.0f * vpX / w) - 1.0f;
    float ndcY = 1.0f - (2.0f * vpY / h);

    // Camera matrices
    Vec3 eye(m_target.x + m_distance * std::sin(m_yaw) * std::cos(m_pitch),
             m_target.y + m_distance * std::sin(m_pitch),
             m_target.z + m_distance * std::cos(m_yaw) * std::cos(m_pitch));
    Mat4 proj = glm::perspective(glm::radians(45.0f), (float)w / (float)h, 0.1f, m_farPlane);
    Mat4 view = glm::lookAt(eye, m_target, Vec3(0, 1, 0));
    Mat4 invVP = glm::inverse(proj * view);

    // Ray origin (eye) and direction from NDC
    Vec4 rayStartNDC(ndcX, ndcY, -1.0f, 1.0f);
    Vec4 rayEndNDC(ndcX, ndcY, 1.0f, 1.0f);
    Vec4 rayStartWorld = invVP * rayStartNDC;
    Vec4 rayEndWorld = invVP * rayEndNDC;
    rayStartWorld /= rayStartWorld.w;
    rayEndWorld /= rayEndWorld.w;

    Vec3 rayOrigin(rayStartWorld);
    Vec3 rayDir = glm::normalize(Vec3(rayEndWorld) - rayOrigin);

    // Find closest intersecting part
    float closestT = std::numeric_limits<float>::max();
    EntityId closestId = 0;
    for (const auto& part : m_pickParts) {
        if (part.worldAABB.isEmpty()) continue;
        float t;
        if (rayAABBIntersect(rayOrigin, rayDir, part.worldAABB, t)) {
            if (t < closestT) {
                closestT = t;
                closestId = part.sceneNodeId;
            }
        }
    }

    if (closestId != 0) {
        m_selectionCallback({closestId});
    }
}

// ------------------------------------------------------------------
// Box pick: project each part's world AABB to screen space,
// then check 2D rectangle overlap (touch semantics).
// ------------------------------------------------------------------
void ViewportPanel::doBoxPick(float x0, float y0, float x1, float y1) {
    if (m_pickParts.empty() || !m_selectionCallback) return;

    // FBO image origin and size
    float originX = m_vpImgOriginX;
    float originY = m_vpImgOriginY;
    int w = (int)m_vpImgW, h = (int)m_vpImgH;
    if (w < 4 || h < 4) {
        ImVec2 winPos = ImGui::GetWindowPos();
        ImVec2 avail = ImGui::GetContentRegionAvail();
        originX = winPos.x;
        originY = winPos.y + ImGui::GetFrameHeightWithSpacing() * 1.5f + ImGui::GetTextLineHeightWithSpacing();
        w = (int)avail.x; h = (int)avail.y;
        if (w < 4 || h < 4) return;
    }

    // Selection rectangle in image-local coordinates
    float sx0 = x0 - originX, sy0 = y0 - originY;
    float sx1 = x1 - originX, sy1 = y1 - originY;
    float selMinX = std::min(sx0, sx1), selMaxX = std::max(sx0, sx1);
    float selMinY = std::min(sy0, sy1), selMaxY = std::max(sy0, sy1);

    // Camera matrices for world→screen projection
    Vec3 eye(m_target.x + m_distance * std::sin(m_yaw) * std::cos(m_pitch),
             m_target.y + m_distance * std::sin(m_pitch),
             m_target.z + m_distance * std::cos(m_yaw) * std::cos(m_pitch));
    Mat4 proj = glm::perspective(glm::radians(45.0f), (float)w / (float)h, 0.1f, m_farPlane);
    Mat4 viewMat = glm::lookAt(eye, m_target, Vec3(0, 1, 0));
    Mat4 vp = proj * viewMat;

    auto projectToScreen = [&](const Vec3& worldPt) -> std::pair<float, float> {
        Vec4 clip = vp * Vec4(worldPt, 1.0f);
        if (std::abs(clip.w) < 1e-8f) return { -9999.f, -9999.f };
        float ndcX = clip.x / clip.w;
        float ndcY = clip.y / clip.w;
        float screenX = (ndcX * 0.5f + 0.5f) * w;
        float screenY = (1.0f - (ndcY * 0.5f + 0.5f)) * h;
        return { screenX, screenY };
    };

    std::vector<EntityId> selected;
    for (const auto& part : m_pickParts) {
        if (part.worldAABB.isEmpty()) continue;

        // Project all 8 corners of the world AABB to screen space
        float pminX = std::numeric_limits<float>::max();
        float pmaxX = -std::numeric_limits<float>::max();
        float pminY = std::numeric_limits<float>::max();
        float pmaxY = -std::numeric_limits<float>::max();

        for (int ci = 0; ci < 8; ++ci) {
            Vec3 corner(
                (ci & 1) ? part.worldAABB.max.x : part.worldAABB.min.x,
                (ci & 2) ? part.worldAABB.max.y : part.worldAABB.min.y,
                (ci & 4) ? part.worldAABB.max.z : part.worldAABB.min.z
            );
            auto [sx, sy] = projectToScreen(corner);
            pminX = std::min(pminX, sx);
            pmaxX = std::max(pmaxX, sx);
            pminY = std::min(pminY, sy);
            pmaxY = std::max(pmaxY, sy);
        }

        // Touch semantics: any overlap = selected
        if (pmaxX >= selMinX && pminX <= selMaxX &&
            pmaxY >= selMinY && pminY <= selMaxY) {
            if (part.sceneNodeId != 0)
                selected.push_back(part.sceneNodeId);
        }
    }

    if (!selected.empty()) {
        m_selectionCallback(selected);
    }
}

// Draw selection box overlay during drag
void ViewportPanel::drawSelectionBox() {
    if (!m_isBoxSelecting) return;
    ImDrawList* dl = ImGui::GetWindowDrawList();
    ImVec2 p0(m_boxSelectStartX, m_boxSelectStartY);
    ImVec2 p1(m_boxSelectEndX, m_boxSelectEndY);
    dl->AddRectFilled(p0, p1, IM_COL32(100, 200, 255, 40));
    dl->AddRect(p0, p1, IM_COL32(100, 200, 255, 200), 0.0f, 0, 1.5f);
}

void ViewportPanel::refresh() {
    m_meshDirty = true;
    MF_INFO("Viewport refresh requested");
}

void ViewportPanel::focusOnObject() {
    if (!m_mesh || m_mesh->vertices.empty()) return;
    const auto& aabb = m_mesh->aabb;
    if (aabb.isEmpty()) return;

    Vec3 center = aabb.center();
    float radius = aabb.diagonal() * 0.6f;
    if (radius < 0.01f) radius = 1.0f;

    m_target = center;
    m_distance = radius * 2.5f;
    m_yaw = 0.5f;
    m_pitch = 0.3f;
    m_farPlane = std::max(1000.0f, m_distance * 5.0f);
    MF_INFO("Camera focused: center=({:.2f},{:.2f},{:.2f}) dist={:.2f} far={:.2f}",
            center.x, center.y, center.z, m_distance, m_farPlane);
}

void ViewportPanel::render3D() {
    // Upload mesh before render check (was bug: m_gpuIndexCount started 0)
    if (m_mesh && m_meshDirty) uploadMesh();

    // Resize FBO if needed
    ImVec2 size = ImGui::GetContentRegionAvail();
    int w = (int)size.x, h = (int)size.y;
    if (w < 1) w = 1; if (h < 1) h = 1;

    if (w != m_fboW || h != m_fboH) {
        m_fboW = w; m_fboH = h;
        glBindTexture(GL_TEXTURE_2D, m_fboTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, m_fboDepth);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, w, h, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, nullptr);

        glBindFramebuffer(GL_FRAMEBUFFER, m_fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, m_fboTex, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, m_fboDepth, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    // Render to FBO
    glBindFramebuffer(GL_FRAMEBUFFER, m_fbo);
    glViewport(0, 0, w, h);
    glClearColor(0.2f, 0.2f, 0.22f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);

    if (m_mesh && m_gpuIndexCount > 0) {
        Vec3 eye(m_target.x + m_distance * std::sin(m_yaw) * std::cos(m_pitch),
                 m_target.y + m_distance * std::sin(m_pitch),
                 m_target.z + m_distance * std::cos(m_yaw) * std::cos(m_pitch));

        Mat4 proj = glm::perspective(glm::radians(45.0f), (float)w/(float)h, 0.1f, m_farPlane);
        Mat4 view = glm::lookAt(eye, m_target, Vec3(0, 1, 0));
        Mat4 mvp = proj * view * Mat4(1.0f);

        int tintLoc = glGetUniformLocation(m_shader, "u_tintColor");
        int scaleLoc = glGetUniformLocation(m_shader, "u_highlightScale");
        int mvpLoc  = glGetUniformLocation(m_shader, "u_mvp");
        int modelLoc = glGetUniformLocation(m_shader, "u_model");
        int lightLoc = glGetUniformLocation(m_shader, "u_lightDir");
        int camLoc   = glGetUniformLocation(m_shader, "u_camPos");

        glUseProgram(m_shader);
        glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, glm::value_ptr(mvp));
        glUniformMatrix4fv(modelLoc, 1, GL_FALSE, glm::value_ptr(Mat4(1.0f)));
        glUniform3f(lightLoc, 0.5f, 1.0f, 0.3f);
        glUniform3f(camLoc, eye.x, eye.y, eye.z);

        glBindVertexArray(m_vao);

        // Pass 1: normal fill rendering
        glUniform3f(tintLoc, 1.0f, 1.0f, 1.0f);
        glUniform1f(scaleLoc, 0.0f); // no offset
        glDrawElements(GL_TRIANGLES, m_gpuIndexCount, GL_UNSIGNED_INT, 0);

        // Pass 2: highlight — bright filled overlay drawn slightly in front
        if (m_hasHighlight && m_highlightIndexCount > 0) {
            // Push highlighted geometry slightly forward to avoid z-fighting
            glEnable(GL_POLYGON_OFFSET_FILL);
            glPolygonOffset(-2.0f, -4.0f);

            // Draw highlighted triangles in bright orange-yellow fill
            glUniform3f(tintLoc, 1.0f, 0.65f, 0.0f); // bright orange
            glUniform1f(scaleLoc, 0.0f);
            glDrawElements(GL_TRIANGLES, m_highlightIndexCount, GL_UNSIGNED_INT,
                           reinterpret_cast<void*>(static_cast<uintptr_t>(m_highlightIndexOffset * sizeof(Index))));

            glDisable(GL_POLYGON_OFFSET_FILL);
        }

        glBindVertexArray(0);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    // Store FBO image screen-space origin for accurate ray/box picking
    ImVec2 cursorPos = ImGui::GetCursorScreenPos();
    m_vpImgOriginX = cursorPos.x;
    m_vpImgOriginY = cursorPos.y;
    m_vpImgW = size.x;
    m_vpImgH = size.y;

    // Display FBO texture in ImGui
    ImGui::Image((ImTextureID)(intptr_t)m_fboTex, size, ImVec2(0, 1), ImVec2(1, 0));

    // Draw selection box on top
    drawSelectionBox();
}

void ViewportPanel::processInput() {
    // Called before other panels draw to ensure pick results propagate
    // to scene tree in the same frame. Not used currently — see panel order fix.
}

void ViewportPanel::draw() {
    // Toolbar
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(4, 4));
    if (ImGui::Button("Focus")) focusOnObject();
    ImGui::SameLine();
    if (ImGui::Button("Refresh")) refresh();
    ImGui::SameLine();
    if (m_mesh && m_mesh->triangleCount() > 0) {
        ImGui::Text("Tris: %u | Verts: %u", m_mesh->triangleCount(), m_mesh->vertexCount());
    } else {
        ImGui::Text("No mesh");
    }
    ImGui::PopStyleVar();
    ImGui::Separator();

    orbitCamera();
    render3D();

    // Right-click context menu on viewport image
    if (ImGui::IsItemClicked(ImGuiMouseButton_Right)) {
        ImGui::OpenPopup("ViewportCtxMenu");
    }
    if (ImGui::BeginPopup("ViewportCtxMenu")) {
        if (auto* cb = getActionCbs()) {
            if (ImGui::MenuItem("Focus on Selection")) {
                cb->onFocusOnSelection();
            }
            ImGui::Separator();
            if (ImGui::MenuItem("Delete Selected")) {
                cb->onDeleteSelected();
            }
            if (ImGui::MenuItem("Export Selected glTF")) {
                cb->onExportSelectedglTF();
            }
            if (ImGui::MenuItem("Export Selected STL")) {
                cb->onExportSelectedSTL();
            }
            ImGui::Separator();
            if (ImGui::MenuItem("Group Selected (Merge)")) {
                cb->onGroupSelected();
            }
        }
        ImGui::EndPopup();
    }
}

// ------------------------------------------------------------------
// UIManager
// ------------------------------------------------------------------
UIManager::UIManager() = default;
UIManager::~UIManager() = default;

bool UIManager::init(SDL_Window* window, SDL_GLContext glContext) {
    (void)glContext;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    io.IniFilename = nullptr;

    ImGui::StyleColorsDark();
    ImGui::GetStyle().WindowRounding = 0.0f;
    ImGui::GetStyle().FrameRounding = 4.0f;

    ImGui_ImplSDL2_InitForOpenGL(window, glContext);
    ImGui_ImplOpenGL3_Init("#version 150");

    // Panels
    // IMPORTANT: Viewport must draw BEFORE SceneTree so that mouse-pick
    // selection updates happen before the tree renders its highlight.
    auto viewport = std::make_unique<ViewportPanel>();
    m_viewport = viewport.get();
    viewport->initGL();
    m_panels.push_back(std::move(viewport));

    auto sceneTree = std::make_unique<SceneTreePanel>();
    m_sceneTree = sceneTree.get();
    m_panels.push_back(std::move(sceneTree));

    auto property = std::make_unique<PropertyPanel>();
    m_property = property.get();
    m_panels.push_back(std::move(property));

    auto task = std::make_unique<TaskPanel>();
    m_panels.push_back(std::move(task));

    auto simplify = std::make_unique<SimplifySettingsPanel>();
    m_simplifySettings = simplify.get();
    m_panels.push_back(std::move(simplify));

    auto proxySimplify = std::make_unique<ProxySimplifyPanel>();
    m_proxySimplify = proxySimplify.get();
    m_panels.push_back(std::move(proxySimplify));

    auto stats = std::make_unique<StatsPanel>();
    m_stats = stats.get();
    m_panels.push_back(std::move(stats));

    // Wire action callbacks to all panels
    ActionCallbacks* cbPtr = &m_actionCallbacks;
    for (auto& p : m_panels) p->setActionCallbacks(cbPtr);

    MF_INFO("UIManager initialized (SDL2 + OpenGL + 3D Viewport)");
    return true;
}

void UIManager::shutdown() {
    m_panels.clear();
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();
}

void UIManager::setupDockingLayout(ImGuiID dockspaceId) {

    ImGui::DockBuilderRemoveNode(dockspaceId);
    ImGui::DockBuilderAddNode(dockspaceId, ImGuiDockNodeFlags_DockSpace);
    ImGui::DockBuilderSetNodeSize(dockspaceId, ImGui::GetMainViewport()->WorkSize);

    // Layout target:
    // +--------------------------------------------+
    // | Scene Tree  |   Viewport    | Simplify     |
    // |             |   (~67%)      | Settings     |
    // |   Tasks     |               | Proxy        |
    // +--------------------------------------------+
    // |                Stats (6%)                  |
    // +--------------------------------------------+

    // IMPORTANT: DockBuilderSplitNode(node, dir, ratio, out_dir, out_other)
    //   - out_dir  = the NEW child node at the split direction
    //   - out_other = the REMAINING node (opposite direction)
    //   - Return value = out_dir if non-null, else out_other
    // We ALWAYS pass both output pointers explicitly to avoid confusion.

    ImGuiID dockStats = 0, dockTop = 0;
    ImGui::DockBuilderSplitNode(dockspaceId, ImGuiDir_Down, 0.06f, &dockStats, &dockTop);
    // dockStats = bottom 6%, dockTop = top 94%

    ImGuiID dockLeft = 0, dockCenter = 0;
    ImGui::DockBuilderSplitNode(dockTop, ImGuiDir_Left, 0.16f, &dockLeft, &dockCenter);
    // dockLeft = left 16%, dockCenter = right 84%

    ImGuiID dockRight = 0, dockViewport = 0;
    ImGui::DockBuilderSplitNode(dockCenter, ImGuiDir_Right, 0.20f, &dockRight, &dockViewport);
    // dockRight = right 20% of dockCenter, dockViewport = remaining 80%

    ImGuiID dockSceneTree = 0, dockTasks = 0;
    ImGui::DockBuilderSplitNode(dockLeft, ImGuiDir_Down, 0.50f, &dockSceneTree, &dockTasks);
    // dockSceneTree = top 50% of dockLeft, dockTasks = bottom 50%

    ImGuiID dockSimplify = 0, dockProxySimplify = 0;
    ImGui::DockBuilderSplitNode(dockRight, ImGuiDir_Down, 0.50f, &dockSimplify, &dockProxySimplify);
    // dockSimplify = top 50% of dockRight, dockProxySimplify = bottom 50%

    // Dock panels
    ImGui::DockBuilderDockWindow("Stats",             dockStats);
    ImGui::DockBuilderDockWindow("Scene Tree",        dockSceneTree);
    ImGui::DockBuilderDockWindow("Tasks",             dockTasks);
    ImGui::DockBuilderDockWindow("Viewport",          dockViewport);
    ImGui::DockBuilderDockWindow("Simplify Settings", dockSimplify);
    ImGui::DockBuilderDockWindow("Proxy Simplify",    dockProxySimplify);

    // Hide Properties by default
    for (auto& panel : m_panels) {
        if (std::strcmp(panel->name(), "Properties") == 0) {
            panel->setVisible(false);
            break;
        }
    }

    ImGui::DockBuilderFinish(dockspaceId);
}

void UIManager::beginFrame() {
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL2_NewFrame();
    ImGui::NewFrame();

    ImGuiViewport* viewport = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(viewport->WorkPos);
    ImGui::SetNextWindowSize(viewport->WorkSize);
    ImGui::SetNextWindowViewport(viewport->ID);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));

    ImGuiWindowFlags windowFlags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoCollapse
        | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove
        | ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNavFocus
        | ImGuiWindowFlags_MenuBar;

    ImGui::Begin("MainDockWindow", nullptr, windowFlags);
    ImGui::PopStyleVar(3);

    // Compute dockspace ID INSIDE Begin() so the ID stack is consistent
    ImGuiID dockspaceId = ImGui::GetID("MainDockSpace");

    // Set up layout on first frame (must be inside Begin for correct ID)
    if (m_firstFrame) {
        setupDockingLayout(dockspaceId);
        m_firstFrame = false;
    }

    ImGui::DockSpace(dockspaceId, ImVec2(0.0f, 0.0f), ImGuiDockNodeFlags_PassthruCentralNode);
    ImGui::End();
}

MenuAction UIManager::showMainMenu() {
    MenuAction action = MenuAction::None;
    if (ImGui::BeginMainMenuBar()) {
        if (ImGui::BeginMenu("File")) {
            if (ImGui::MenuItem("Open STEP...", "Cmd+O")) action = MenuAction::OpenSTEP;
            ImGui::Separator();
            if (ImGui::MenuItem("Export glTF...", "Cmd+E")) action = MenuAction::ExportglTF;
            if (ImGui::MenuItem("Export STL...")) action = MenuAction::ExportSTL;
            ImGui::Separator();
            if (ImGui::MenuItem("Export Selected glTF...")) action = MenuAction::ExportSelectedglTF;
            if (ImGui::MenuItem("Export Selected STL...")) action = MenuAction::ExportSelectedSTL;
            if (ImGui::MenuItem("Batch Export Selected Assembly...")) action = MenuAction::BatchExportSelected;
            ImGui::Separator();
            if (ImGui::MenuItem("Undo Simplify", "Cmd+Z")) action = MenuAction::UndoSelected;
            if (ImGui::MenuItem("Reset to Original")) action = MenuAction::ResetSelected;
            ImGui::Separator();
            if (ImGui::MenuItem("Delete Selected", "Del")) action = MenuAction::DeleteSelected;
            ImGui::Separator();
            if (ImGui::MenuItem("Exit", "Cmd+Q")) action = MenuAction::Exit;
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("View")) {
            for (auto& panel : m_panels) {
                bool v = panel->visible();
                ImGui::MenuItem(panel->name(), nullptr, &v);
                panel->setVisible(v);
            }
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("Process")) {
            if (ImGui::MenuItem("Tessellate All")) action = MenuAction::TessellateAll;
            if (ImGui::MenuItem("Generate LODs")) action = MenuAction::GenerateLOD;
            if (ImGui::MenuItem("Simplify All")) action = MenuAction::SimplifyAll;
            ImGui::EndMenu();
        }
        ImGui::EndMainMenuBar();
    }
    return action;
}

void UIManager::endFrame() {
    for (auto& panel : m_panels) {
        if (!panel->visible()) continue;
        bool pv = panel->visible();
        ImGui::Begin(panel->name(), &pv, panel->windowFlags());
        panel->setVisible(pv);
        panel->draw();
        ImGui::End();
    }

    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

std::string UIManager::openFileDialog() {
    return macOSOpenFileDialog();
}

std::string UIManager::saveFileDialog(bool stlMode) {
    return macOSSaveFileDialog(stlMode);
}

void UIManager::setScene(std::shared_ptr<Scene> scene) {
    if (m_sceneTree) m_sceneTree->setScene(scene);
}

void UIManager::setMeshForViewport(const MeshData* mesh) {
    if (m_viewport) {
        m_viewport->setMesh(mesh);
        m_viewport->focusOnObject();
    }
}

void UIManager::setStats(uint32_t triangles, uint32_t drawCalls, float fps) {
    if (m_stats) m_stats->setStats(triangles, drawCalls, fps);
}

void UIManager::setPipelineStats(int analyzed, int classified, int tessellated,
                                  int shellBefore, int shellAfter, bool cadAware) {
    m_pipeAnalyzed = analyzed;
    m_pipeClassified = classified;
    m_pipeTessellated = tessellated;
    m_pipeShellBefore = shellBefore;
    m_pipeShellAfter = shellAfter;
    m_pipeCADAware = cadAware;
    if (m_stats) m_stats->setPipeline(analyzed, classified, tessellated,
                                       shellBefore, shellAfter, cadAware);
}

std::shared_ptr<SceneNode> UIManager::selectedNode() const {
    return m_sceneTree ? m_sceneTree->selectedNode() : nullptr;
}

std::vector<std::shared_ptr<SceneNode>> UIManager::selectedNodes() const {
    return m_sceneTree ? m_sceneTree->selectedNodes() : std::vector<std::shared_ptr<SceneNode>>{};
}

void UIManager::setHighlightForViewport(uint32_t offset, uint32_t count) {
    if (m_viewport) m_viewport->setHighlightRange(offset, count);
}

void UIManager::clearViewportHighlight() {
    if (m_viewport) m_viewport->clearHighlight();
}

void UIManager::refreshViewport() {
    if (m_viewport) m_viewport->refresh();
}

void UIManager::setViewportPickParts(const std::vector<ViewportPanel::PartPickInfo>& parts) {
    if (m_viewport) m_viewport->setPickParts(parts);
}

void UIManager::setViewportSelectionCallback(ViewportPanel::SelectionCallback cb) {
    if (m_viewport) m_viewport->setSelectionCallback(cb);
}

void UIManager::selectNodesById(const std::vector<EntityId>& ids) {
    std::unordered_set<EntityId> idSet(ids.begin(), ids.end());
    if (m_sceneTree) m_sceneTree->setSelection(idSet);
}

// ------------------------------------------------------------------
// SceneTreePanel
// ------------------------------------------------------------------
void SceneTreePanel::draw() {
    if (!m_scene) { ImGui::Text("No scene loaded"); return; }
    int nodeCount = 0;
    m_scene->root()->traverse([&nodeCount](SceneNode*) { ++nodeCount; });
    ImGui::Text("Nodes: %d | Selected: %zu", nodeCount - 1, m_selection.size());
    ImGui::Separator();
    drawNode(m_scene->root().get());
    // Force-expand only lasts one frame
    m_forceExpand.clear();
}

void SceneTreePanel::drawNode(SceneNode* node) {
    if (!node) return;

    // Auto-expand ancestors of selected nodes
    if (m_forceExpand.count(node->id())) {
        ImGui::SetNextItemOpen(true);
    }

    ImGuiTreeNodeFlags flags = ImGuiTreeNodeFlags_OpenOnArrow | ImGuiTreeNodeFlags_SpanAvailWidth;
    if (node->children().empty()) flags |= ImGuiTreeNodeFlags_Leaf;
    if (m_selection.count(node->id())) flags |= ImGuiTreeNodeFlags_Selected;
    if (node->parent() == nullptr) flags |= ImGuiTreeNodeFlags_DefaultOpen;

    const char* icon = "";
    switch (node->type()) {
    case SceneNode::Type::Group: icon = "[G] "; break;
    case SceneNode::Type::Mesh: icon = "[M] "; break;
    case SceneNode::Type::Instance: icon = "[I] "; break;
    default: break;
    }
    std::string label = std::string(icon) + node->name();
    bool open = ImGui::TreeNodeEx((void*)(uintptr_t)node->id(), flags, "%s", label.c_str());

    if (ImGui::IsItemClicked()) {
        bool ctrl = ImGui::GetIO().KeyCtrl || ImGui::GetIO().KeySuper;
        bool shift = ImGui::GetIO().KeyShift;

        if (shift && m_lastClickedNode != 0 && m_scene) {
            // Shift+click: select range from last-clicked to this node
            std::vector<SceneNode*> flatList;
            collectVisibleNodes(m_scene->root().get(), flatList);
            selectRange(m_scene->root().get(), node, flatList);
        } else if (ctrl) {
            // Toggle selection
            if (m_selection.count(node->id())) {
                m_selection.erase(node->id());
            } else {
                m_selection.insert(node->id());
            }
            m_lastClickedNode = node->id();
        } else {
            // Single select clears previous
            m_selection.clear();
            m_selection.insert(node->id());
            m_lastClickedNode = node->id();
        }
        // Rebuild selected nodes vector
        m_selectedNodes.clear();
        m_scene->root()->traverse([this](SceneNode* n) {
            if (m_selection.count(n->id()))
                m_selectedNodes.push_back(n->shared_from_this());
        });
    }

    // Right-click context menu on tree node
    if (ImGui::IsItemClicked(ImGuiMouseButton_Right)) {
        // If right-clicked node is not in selection, select it alone
        if (!m_selection.count(node->id())) {
            m_selection.clear();
            m_selection.insert(node->id());
            m_selectedNodes.clear();
            m_scene->root()->traverse([this](SceneNode* n) {
                if (m_selection.count(n->id()))
                    m_selectedNodes.push_back(n->shared_from_this());
            });
        }
        ImGui::OpenPopup("SceneTreeCtxMenu");
    }

    if (ImGui::BeginPopup("SceneTreeCtxMenu")) {
        size_t selCount = m_selectedNodes.size();
        if (selCount > 0) {
            ImGui::Text("%zu selected", selCount);
            ImGui::Separator();
            if (ImGui::MenuItem("Delete")) {
                if (auto* cb = getActionCbs()) cb->onDeleteSelected();
            }
            if (ImGui::MenuItem("Export glTF")) {
                if (auto* cb = getActionCbs()) cb->onExportSelectedglTF();
            }
            if (ImGui::MenuItem("Export STL")) {
                if (auto* cb = getActionCbs()) cb->onExportSelectedSTL();
            }
            if (selCount >= 2 && ImGui::MenuItem("Group (Merge)")) {
                if (auto* cb = getActionCbs()) cb->onGroupSelected();
            }
        }
        ImGui::EndPopup();
    }

    if (open) {
        for (auto& child : node->children()) drawNode(child.get());
        ImGui::TreePop();
    }
}

std::vector<std::shared_ptr<SceneNode>> SceneTreePanel::selectedNodes() const {
    return m_selectedNodes;
}

std::shared_ptr<SceneNode> SceneTreePanel::selectedNode() const {
    return m_selectedNodes.empty() ? nullptr : m_selectedNodes.front();
}

void SceneTreePanel::setSelection(const std::unordered_set<EntityId>& ids) {
    m_selection = ids;
    m_selectedNodes.clear();
    m_forceExpand.clear();
    if (m_scene) {
        m_scene->root()->traverse([this](SceneNode* n) {
            if (m_selection.count(n->id()))
                m_selectedNodes.push_back(n->shared_from_this());
        });
        // Auto-expand all ancestors of selected nodes
        for (auto& sn : m_selectedNodes) {
            collectAncestors(sn.get(), m_forceExpand);
        }
    }
}

void SceneTreePanel::collectAncestors(SceneNode* node, std::unordered_set<EntityId>& ancestors) {
    auto p = node->parent();
    while (p) {
        ancestors.insert(p->id());
        p = p->parent();
    }
}

void SceneTreePanel::collectVisibleNodes(SceneNode* root, std::vector<SceneNode*>& flatList) {
    if (!root) return;
    // Skip root node itself in the flat list
    root->traverse([&flatList](SceneNode* n) {
        if (n->type() != SceneNode::Type::Group || n->children().empty()) {
            flatList.push_back(n);
        } else {
            flatList.push_back(n); // also include groups so they're selectable
        }
    });
}

void SceneTreePanel::selectRange(SceneNode* from, SceneNode* to,
                                  std::vector<SceneNode*>& flatList) {
    // Find indices of last-clicked and current in flat list
    int idxFrom = -1, idxTo = -1;
    for (size_t i = 0; i < flatList.size(); ++i) {
        if (flatList[i]->id() == m_lastClickedNode) idxFrom = static_cast<int>(i);
        if (flatList[i]->id() == to->id()) idxTo = static_cast<int>(i);
    }
    if (idxFrom < 0 || idxTo < 0) return;

    // Select range (don't clear — Shift adds to existing selection)
    int lo = std::min(idxFrom, idxTo);
    int hi = std::max(idxFrom, idxTo);
    for (int i = lo; i <= hi; ++i) {
        m_selection.insert(flatList[i]->id());
    }
    m_lastClickedNode = to->id();
}

// ------------------------------------------------------------------
// PropertyPanel
// ------------------------------------------------------------------
void PropertyPanel::draw() {
    if (!m_node) { ImGui::Text("No node selected"); return; }
    ImGui::Text("Name: %s", m_node->name().c_str());
    ImGui::Text("ID: %llu", static_cast<unsigned long long>(m_node->id()));
    ImGui::Separator();
    auto pos = m_node->localTransform().translation;
    if (ImGui::DragFloat3("Position", &pos.x, 0.01f)) {
        Transform t = m_node->localTransform();
        t.translation = pos;
        m_node->setLocalTransform(t);
    }
}

// ------------------------------------------------------------------
// TaskPanel
// ------------------------------------------------------------------
void TaskPanel::draw() {
    auto tasks = TaskSystem::instance().tasks();
    if (tasks.empty()) { ImGui::Text("No active tasks"); return; }
    for (auto& task : tasks) {
        ImGui::Text("%s", task->name().c_str());
        ImGui::ProgressBar(task->progress(), ImVec2(-1, 0), task->message().c_str());
    }
}

// ------------------------------------------------------------------
// SimplifySettingsPanel
// ------------------------------------------------------------------
void SimplifySettingsPanel::draw() {
    ImGui::Text("Simplification Parameters");

    // Mode selector — bidirectional sync to ensure m_params.mode and
    // m_modeCombo are always consistent.
    const char* modes[] = { "By Ratio", "By Target File Size (MB)" };
    int comboMode = (m_params.mode == SimplifyMode::Ratio) ? 0 : 1;
    if (ImGui::Combo("Mode", &comboMode, modes, 2)) {
        m_params.mode = (comboMode == 0) ? SimplifyMode::Ratio : SimplifyMode::TargetFileSizeMB;
    }
    // Defensive: if m_params.mode was changed elsewhere, keep combo in sync
    m_modeCombo = (m_params.mode == SimplifyMode::Ratio) ? 0 : 1;

    ImGui::Separator();

    if (m_params.mode == SimplifyMode::Ratio) {
        ImGui::SliderFloat("Target Ratio", &m_params.targetRatio, 0.01f, 1.0f, "%.2f");
        if (!m_targetNodes.empty()) {
            uint32_t totalTris = 0;
            for (auto& n : m_targetNodes) {
                if (n->mesh() && !n->mesh()->lods.empty())
                    totalTris += n->mesh()->lods[0].mesh.triangleCount();
            }
            uint32_t estTris = static_cast<uint32_t>(totalTris * m_params.targetRatio);
            ImGui::TextDisabled("Est. triangles: %u -> %u", totalTris, estTris);
        }
    } else {
        ImGui::InputFloat("Target Size (MB)", &m_params.targetFileSizeMB, 0.1f, 1.0f, "%.1f");
        m_params.targetFileSizeMB = std::max(0.01f, m_params.targetFileSizeMB);

        if (!m_targetNodes.empty()) {
            uint32_t totalTris = 0;
            for (auto& n : m_targetNodes) {
                if (n->mesh() && !n->mesh()->lods.empty())
                    totalTris += n->mesh()->lods[0].mesh.triangleCount();
            }
            ImGui::TextDisabled("Target: %.1f MB | Source: %u tris",
                                m_params.targetFileSizeMB, totalTris);
        }
    }

    // Error threshold: wider range for CAD models (0.1 = 10% of bbox diagonal)
    ImGui::SliderFloat("Error Threshold", &m_params.targetError, 0.005f, 0.5f, "%.3f");
    ImGui::SameLine();
    ImGui::TextDisabled("(?");
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip("Max allowed error as %% of bounding-box diagonal.\n"
                          "Higher = more simplification, lower = better quality.\n"
                          "For CAD: 0.01-0.03 (high quality), 0.05-0.10 (balanced), 0.15+ (aggressive)");
    }

    ImGui::Checkbox("Preserve Boundary", &m_params.preserveBoundary);
    ImGui::SameLine();
    ImGui::Checkbox("Sloppy Fallback", &m_params.useSloppyFallback);
    if (ImGui::IsItemHovered()) {
        ImGui::SetTooltip("Allow sloppy simplification when normal simplify\n"
                          "cannot reach the target ratio. Guarantees target\n"
                          "but may produce lower quality.");
    }

    ImGui::Separator();
    ImGui::Text("Target Nodes: %zu", m_targetNodes.size());
    if (!m_targetNodes.empty()) {
        ImGui::BeginChild("TargetNodes", ImVec2(0, ImGui::GetTextLineHeightWithSpacing() * 6), true);
        for (auto& n : m_targetNodes) {
            ImGui::Text("- %s", n->name().c_str());
        }
        ImGui::EndChild();
        ImGui::Separator();

        if (ImGui::Button("Apply Simplify", ImVec2(-1, 0))) {
            m_applyRequested = true;
        }
    } else {
        ImGui::TextDisabled("Select nodes in Scene Tree to simplify");
    }
}

void SimplifySettingsPanel::setTargetNodes(const std::vector<std::shared_ptr<SceneNode>>& nodes) {
    m_targetNodes = nodes;
}

// ------------------------------------------------------------------
// ProxySimplifyPanel
// ------------------------------------------------------------------
void ProxySimplifyPanel::setTargetNodes(const std::vector<std::shared_ptr<SceneNode>>& nodes) {
    m_targetNodes = nodes;
}

void ProxySimplifyPanel::draw() {
    ImGui::Text("Bounding Proxy Replacement");
    ImGui::Separator();

    const char* geomTypes[] = {"Box", "Sphere", "Cylinder"};
    ImGui::Combo("Geometry", &m_geomType, geomTypes, 3);

    ImGui::SliderFloat("Margin", &m_margin, -0.2f, 2.0f, "%.2f");
    ImGui::SameLine();
    ImGui::TextDisabled("(?)");
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Negative = shrink, 0 = exact AABB, Positive = expand");

    ImGui::Separator();
    ImGui::Text("Target: %zu node(s)", m_targetNodes.size());
    if (!m_targetNodes.empty()) {
        for (auto& n : m_targetNodes)
            ImGui::Text("- %s", n->name().c_str());
        ImGui::Separator();
        if (ImGui::Button("Apply Bounding Proxy", ImVec2(-1, 0)))
            m_applyRequested = true;
    } else {
        ImGui::TextDisabled("Select nodes in Scene Tree to replace");
    }
}

// ------------------------------------------------------------------
// StatsPanel
// ------------------------------------------------------------------
void StatsPanel::draw() {
    ImGui::Text("FPS: %.1f", m_fps);
    ImGui::Text("Triangles: %u", m_triangles);
    ImGui::Text("Draw Calls: %u", m_drawCalls);

    if (m_pipeCADAware) {
        ImGui::Separator();
        ImGui::TextColored(ImVec4(0.4f, 0.9f, 0.4f, 1.0f), "CAD-Aware Pipeline");
        ImGui::Text("  Shapes: %d analyzed / %d classified / %d tessellated",
                    m_pipeAnalyzed, m_pipeClassified, m_pipeTessellated);
        if (m_pipeShellBefore > 0) {
            float reduction = 100.0f * (1.0f - static_cast<float>(m_pipeShellAfter) /
                                        static_cast<float>(m_pipeShellBefore));
            ImGui::Text("  Shell: %d -> %d tris (%.1f%% removed)",
                        m_pipeShellBefore, m_pipeShellAfter, reduction);
        }
    }
}

} // namespace mf
