````text
你是一名资深工业图形软件架构师、CAD轻量化专家、实时渲染工程师。

我当前已经有一个基于：

- OpenCascade
- C++
- Dear ImGui
- bgfx
- mesh simplification

的 STEP 模型处理工具。

但当前实现仍然属于：

```text
STEP -> Tessellation -> Simplification
````

这种传统 mesh decimation 路线。

目前存在严重问题：

- Mesh 三角面数量依然过大
    
- 内部不可见 mesh 没有剔除
    
- 平面被大量碎三角化
    
- 圆柱/锥体被过度离散化
    
- 减面后工业结构破坏严重
    
- 法向连续性差
    
- 出现大量碎面
    
- CAD 外观特征丢失
    
- 工业视觉保真度不够
    

我希望把当前项目升级为：

```text
Industrial CAD Lightweighting Engine
```

方向类似：

- PiXYZ Lite
    
- CAD Exchanger
    
- Visual Fidelity Pipeline
    

目标：

在视觉上尽量保持工业模型外观，同时极大减少 mesh 数量。

核心目标：

- 保留工业视觉特征
    
- 保留轮廓
    
- 保留大平面
    
- 保留圆柱/锥体等参数化特征
    
- 删除内部不可见 geometry
    
- 极限减少 triangle count
    
- 适合数字孪生/实时渲染
    
- 支持超大STEP装配
    
- 处理500MB级STEP
    
- 支持多层级Assembly
    
- 支持实例复用
    
- 支持LOD
    

# 我希望的最终效果

例如：

原始STEP：

```text
2000万 triangles
```

最终输出：

```text
20万 triangles
```

但要求：

- 外观高度一致
    
- 工业结构保真
    
- 没有大量碎面
    
- 平面保持完整
    
- 圆柱保持圆柱外观
    
- 锥体保持锥体外观
    
- 内部mesh删除
    
- 法向连续
    
- 适合实时渲染
    
- 适合数字孪生
    

# 当前错误路线

当前实现属于：

```text
STEP
 ↓
完全Tessellation
 ↓
QEM减面
```

我认为这是错误路线。

# 希望调整成的新路线

我希望升级为：

```text
CAD-aware Lightweighting Pipeline
```

即：

```text
STEP
 ↓
BRep Analysis
 ↓
Surface Classification
 ↓
Exterior Shell Extraction
 ↓
Primitive Recognition
 ↓
Proxy Geometry Replacement
 ↓
Adaptive Tessellation
 ↓
Feature-preserving Simplification
 ↓
LOD
 ↓
glTF/glb
```

# 请基于这个方向

完整重新设计我的技术路线。

# 请重点设计以下内容

---

# 1. 整体工业轻量化架构

请设计：

- Lightweighting Engine
    
- Visual Fidelity Pipeline
    
- Scene Graph
    
- Mesh Pipeline
    
- Cache System
    
- Streaming Pipeline
    
- Large Assembly Pipeline
    

---

# 2. CAD-aware Pipeline

请重点设计：

```text
CAD-aware Geometry Processing
```

而不是普通 mesh simplification。

请说明：

- 为什么传统QEM路线不适合工业CAD
    
- 为什么必须BRep-aware
    
- 为什么必须Feature-aware
    

---

# 3. Exterior Shell Extraction

这是重点。

我希望：

```text
删除内部不可见 geometry
```

请设计：

- 外壳提取算法
    
- Internal Face Removal
    
- Hidden Geometry Removal
    
- Outer Hull Pipeline
    

请优先推荐：

- 可直接集成的开源算法
    
- OCC方案
    
- CGAL方案
    
- Open3D方案
    

请重点考虑：

- 工业装配
    
- 多实体
    
- 封闭结构
    
- 管道系统
    
- 内部腔体
    

---

# 4. Primitive Recognition（核心）

这是最关键模块。

我希望：

对于：

- Plane
    
- Cylinder
    
- Cone
    
- Sphere
    
- Pipe
    
- Box
    
- Torus
    

不要完全Mesh化。

而是：

```text
参数化代理几何
```

请设计：

- Primitive Detection Pipeline
    
- OCC Surface Recognition
    
- Proxy Geometry Generation
    
- Runtime Procedural Geometry
    

请说明：

- 如何识别Primitive
    
- 如何替换mesh
    
- 如何生成低面数代理
    
- 如何保留视觉外观
    

请优先基于：

```text
OpenCascade
```

现有能力。

---

# 5. Adaptive Tessellation

我不希望：

```text
所有surface统一三角化
```

请设计：

- 曲率驱动细分
    
- 平面保留
    
- 圆柱分段策略
    
- 锥面策略
    
- 自适应细分
    
- 大平面Quad保留
    

希望达到：

```text
能参数化就不要mesh化
```

---

# 6. Feature-preserving Simplification

请设计：

- Feature Edge Detection
    
- Hard Edge Preservation
    
- CAD Contour Preservation
    
- Planar Region Preservation
    
- Normal Preservation
    

请重点说明：

为什么：

```text
普通QEM会破坏工业结构
```

并推荐：

- 开源算法
    
- 开源库
    
- libigl
    
- OpenMesh
    
- meshoptimizer
    
- Fast Quadric
    

如何组合。

---

# 7. Visual Fidelity Strategy

这是核心。

我希望：

```text
视觉高度保真
```

而不是数学误差最小。

请设计：

- 工业视觉保真策略
    
- 外轮廓保护
    
- 大平面保护
    
- 曲面轮廓保护
    
- 法向连续性保护
    
- 工业结构保真
    

---

# 8. Defeaturing Pipeline

请设计：

自动删除：

- 小孔
    
- 倒角
    
- 小圆角
    
- 螺纹
    
- 小特征
    

要求：

- 自动化
    
- 基于阈值
    
- 面向数字孪生
    

请推荐：

- OCC现成能力
    
- 开源方案
    
- 工业算法路线
    

---

# 9. Instancing System

工业模型有大量重复件：

- 螺丝
    
- 法兰
    
- 轴承
    
- 电机
    

请设计：

- Geometry Hash
    
- Mesh Reuse
    
- GPU Instancing
    
- Shared Mesh Cache
    

---

# 10. LOD系统

请设计：

- Auto LOD
    
- Distance LOD
    
- Hierarchical LOD
    
- Cluster LOD
    

要求：

- 工业大装配
    
- 数字孪生
    
- Viewer实时切换
    

---

# 11. 大场景实时渲染架构

请设计：

- Scene Graph
    
- Culling
    
- Instance Rendering
    
- GPU Buffer管理
    
- Streaming
    
- Render Queue
    

技术栈：

- bgfx
    
- Metal
    
- Vulkan
    

---

# 12. glTF/glb导出策略

请设计：

- glTF结构
    
- Primitive表达
    
- Instancing表达
    
- Draco压缩
    
- Metadata
    
- Assembly hierarchy
    

不要推荐 STL 作为主格式。

---

# 13. 推荐开源项目组合

请推荐：

- 最适合直接集成的开源库
    
- 每个库负责什么
    
- 哪些值得深度修改
    
- 哪些只适合辅助
    

请重点推荐：

- OpenCascade
    
- libigl
    
- OpenMesh
    
- meshoptimizer
    
- CGAL
    
- Open3D
    
- Fast Quadric
    

---

# 14. 请给出推荐最终技术架构

我当前技术栈：

- C++
    
- OpenCascade
    
- Dear ImGui
    
- bgfx
    
- meshoptimizer
    
- macOS
    
- Apple Silicon
    

请重新整理：

- 最终推荐模块结构
    
- 最终Pipeline
    
- 最终Geometry Engine结构
    
- 最终Viewer结构
    

---

# 15. 请给出真正适合工业CAD轻量化的开发顺序

不要泛泛而谈。

请明确：

第一阶段应该做什么  
第二阶段应该做什么  
第三阶段应该做什么

并说明：

哪些模块是真正的核心壁垒。

# 输出要求

请：

- 从工业CAD轻量化角度回答
    
- 从Visual Fidelity角度回答
    
- 从数字孪生角度回答
    
- 从工业实时渲染角度回答
    
- 偏工程化
    
- 偏高性能
    
- 偏大规模工业场景
    

不要只讲普通mesh simplification。

请重点围绕：

```text
CAD-aware Lightweighting
Visual Fidelity
Industrial Proxy Geometry
```

展开。