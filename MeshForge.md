你是一名资深工业图形软件架构师，请帮我设计一个工业级 STEP 模型轻量化处理软件。

# 项目目标

开发一个轻量、高性能、可扩展的工业3D应用，专门用于：

- STEP工业模型解析
- 装配层级拆分
- 自动零件拆分
- 网格化（Tessellation）
- Mesh减面（Simplification）
- 自动LOD生成
- 最终导出轻量化模型

主要用于：

- 数字孪生
- 工业场景可视化
- 大型装配预处理
- 实时渲染场景

模型精度要求不高，但要求：

- 速度快
- 内存占用低
- 可处理超大STEP
- 稳定
- 易扩展

典型STEP文件：

- 500MB左右
- 多层级装配
- 大量重复实例
- 工业机械模型

# 关键要求

软件必须：

- 支持大型STEP装配
- 支持Assembly Tree
- 支持按层级拆分
- 支持按模块导出
- 支持自动LOD
- 支持Mesh缓存
- 支持实例复用
- 支持大场景渲染
- 支持流式处理
- UI轻量
- 架构易扩展

# 不考虑

不考虑：

- AI Agent
- 云端部署
- Web前端
- Electron
- Unity
- Unreal
- Qt

# 技术路线要求

请基于以下技术路线设计：

## CAD解析

- OpenCascade

用于：

- STEP读取
- Assembly解析
- BRep
- Tessellation

## UI

- Dear ImGui

要求：

- Docking
- Scene Tree
- Property Panel
- Task System
- 工具型UI

## 渲染

- bgfx

要求：

- Metal
- Vulkan
- DX12兼容
- 高性能
- 大模型场景

## Mesh处理

- meshoptimizer
- Fast Quadric Simplification

## 数学库

- Eigen

## 并行

- Intel TBB

## 输出格式

主要：

- glTF/glb

压缩：

- Draco

不要推荐 STL 作为主格式。

# 平台要求

开发平台：

- macOS
- Apple Silicon
- M系列芯片

要求：

- 原生ARM64
- CMake
- vcpkg
- CLion开发

# 希望你输出的内容

请完整设计：

1. 整体软件架构
2. Geometry Engine设计
3. Scene Graph设计
4. STEP解析流程
5. 大文件流式处理方案
6. Mesh Pipeline设计
7. Tessellation参数建议
8. Mesh Simplification方案
9. 自动LOD方案
10. Mesh Cache方案
11. 实例识别方案
12. Renderer架构
13. ImGui UI架构
14. Viewer设计
15. GPU优化方案
16. 大场景优化方案
17. glTF导出方案
18. 多线程方案
19. 模块划分
20. 插件系统设计
21. 文件结构设计
22. CMake工程结构
23. Mac开发建议
24. 性能瓶颈分析
25. MVP开发顺序
26. 后续扩展路线

# 输出要求

请：

- 使用工业软件架构视角
- 使用C++工程视角
- 偏工程化
- 偏高性能
- 偏可维护性
- 偏大型项目设计

不要泛泛而谈。

请给出：

- 模块结构
- 数据结构
- Pipeline
- 类设计建议
- 目录结构
- 渲染架构
- 缓存架构
- 多线程架构
- 实际工程建议

重点关注：

- 500MB STEP处理
- 多层级装配
- 流式mesh化
- GPU Instancing
- Mesh Cache
- LOD
- Viewer性能
- 内存控制
- 工业场景稳定性