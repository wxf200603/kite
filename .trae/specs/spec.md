# Kelivo × Operit 能力融合 - 产品需求文档

## Overview
- **Summary**: 把 Operit 1.12.2 中独有的四项 Android AI Agent 能力引入 Kelivo 1.3.0：本地 LLM 推理、ToolPkg JS 工具包、工作流引擎、角色卡与图谱长期记忆。实现后 Kelivo 同时具备「跨平台 LLM 聊天客户端」和「Android 端 AI Agent 平台」两种定位。
- **Purpose**: Kelivo 当前只有云端模型聊天 + 基础工作区，缺少设备本地推理、JS 扩展工具、可视化任务编排、角色化长期记忆等 Agent 能力；Operit 在这些方面成熟，但仅 Android 且非 Flutter。以 Platform Channel 复用 Operit 原生模块 + Dart 重写跨平台逻辑的方式融合。
- **Target Users**: 需要在 Android 设备上使用本地模型、JS 工具扩展、自动化工作流、角色化记忆的 Kelivo 用户。

## Goals
- 在 Kelivo Android 端接入本地 LLM 推理（MNN / llama.cpp GGUF），模型作为可选 provider 出现在模型选择中。
- 在 Kelivo 中运行 Operit 风格的 ToolPkg（JS 工具包），通过 QuickJS 引擎执行并向模型暴露工具。
- 提供可视化工作流编辑器与执行引擎，支持触发节点 / 执行节点 / 条件节点 / 逻辑节点，可手动触发与定时触发。
- 支持角色卡（Character Card）配置与图谱式长期记忆（节点-边），记忆可在对话中检索并注入上下文。

## Non-Goals
- 不为 iOS / 桌面 / Web 实现上述原生能力（MNN、llama、QuickJS）；Dart 层逻辑对全平台可用，原生调用在非 Android 平台返回 `unsupported`。
- 不构建 MNN / llama.cpp / QuickJS 的预编译 `.so` 产物（需要独立 NDK 构建环境，本任务只交付 Kotlin 封装 + JNI 桩 + Gradle 模块接入）。
- 不实现 Operit 的 Shizuku 自动化、Shower 投屏、Compose DSL、Ubuntu 用户空间终端等深度系统能力。
- 不迁移 Operit 的 UI（Kotlin Compose）；所有新 UI 用 Flutter 重写。
- 不保证与 Operit 现有 ToolPkg / 工作流 / 角色卡二进制完全兼容，只保证数据结构语义对齐、可手动导入。

## Background & Context
- Kelivo 是 Flutter 工程，包名 `Kelivo`，`lib/features/<feature>/` 按功能分层，状态管理用 Provider，数据库用 Drift，平台通信用 MethodChannel（见 `lib/core/services/sandbox/workspace_channel.dart` 与 `android/.../MainActivity.kt`、`WorkspacePlugin.kt`）。
- Kelivo Android 已有 CMake 原生构建（`android/app/src/main/cpp/CMakeLists.txt`，含 termux_pty）和 NDK 配置。
- Operit 的相关原生模块：`llm/mnn`（MNN 推理，含 `libsherpa-mnn-jni.so`）、`llm/llama`（llama.cpp JNI 桩）、`quickjs`（QuickJS 引擎 + Kotlin 封装）。
- Operit 的工作流模型在 `app/src/main/java/com/ai/assistance/operit/data/model/Workflow.kt`，执行器在 `core/workflow/WorkflowExecutor.kt`；图谱记忆模型在 `ui/features/memory/screens/graph/model/GraphModels.kt`。

## Functional Requirements

### FR-1 本地 LLM 推理（Android 原生）
- 新增 Gradle 模块复用 Operit `llm/mnn` 与 `llm/llama`，包名迁移到 `com.psyche.kelivo.llm`。
- 新增 MethodChannel `app.llm`，Dart 端 `LocalLlmChannel` 提供：`listModels`、`loadModel(path, type)`、`generate(prompt, params)`、`cancel()`、`unload()`。
- 推理结果以 `Stream<String>` 增量返回 token。
- 非 Android 平台调用返回 `unsupported` 异常，不崩溃。

### FR-2 ToolPkg JS 工具包（Android 原生）
- 新增 Gradle 模块复用 Operit `quickjs`，包名迁移到 `com.psyche.kelivo.quickjs`。
- 新增 MethodChannel `app.toolpkg`，Dart 端 `ToolPkgChannel` 提供：`install(zipPath)`、`list()`、`invoke(toolId, args)`、`uninstall(id)`。
- 每个 ToolPkg 为 zip，含 `manifest.json` 与 JS 入口；QuickJS 执行 JS，通过 host dispatcher 回调 Dart 侧工具。
- 已安装 ToolPkg 的工具出现在 Kelivo 工具列表中，可被模型调用。

### FR-3 工作流引擎（Dart）
- 数据模型对齐 Operit `Workflow.kt`：`Workflow`、`TriggerNode`、`ExecuteNode`、`ConditionNode`、`LogicNode`、`WorkflowNodeConnection`、`ExecutionStatus`，用 `freezed`/`json_serializable` 或手写 `toJson/fromJson`。
- 执行器 `WorkflowExecutor`（Dart）按依赖图拓扑执行节点，支持工具调用、JS 代码执行（走 ToolPkg 通道）、条件分支、逻辑组合。
- 持久化到 Drift（新增表 `workflows`、`workflow_execution_logs`）。
- 可视化编辑器页面：画布拖拽节点、连线、配置参数；列表页管理工作流；手动触发；定时触发复用 Kelivo 现有 `scheduled_tasks` 机制。

### FR-4 角色卡与图谱长期记忆（Dart）
- 角色卡模型：name、description、personality、system_prompt、avatar、tags、creator、character_book（场景/对话示例）。
- 图谱记忆：`Graph { nodes: [Node], edges: [Edge] }`，对齐 Operit `GraphModels.kt`；节点有 label、metadata、所属 folder；边有 source/target、label、weight。
- Drift 表：`character_cards`、`memory_nodes`、`memory_edges`、`memory_folders`。
- 对话时根据当前消息检索相关记忆节点（关键词 + 边权重），注入系统提示。
- 角色卡可绑定到对话，替换默认 system prompt。

## Non-Functional Requirements
- **NFR-1 构建不破坏**：改动后 `flutter analyze`、`dart format`、`flutter test` 在现有范围内保持通过（新增代码需通过 analyze）。
- **NFR-2 平台通道契约稳定**：所有新增 MethodChannel 有明确的方法名、参数、返回值、错误码，Dart 端有类型化封装。
- **NFR-3 复用优先**：原生模块直接复用 Operit 源码（调整包名），不重写推理/JS 引擎核心逻辑。
- **NFR-4 渐进可用**：每个能力可独立编译通过；缺少原生 `.so` 时优雅降级（返回 unsupported / 错误提示），不导致 App 崩溃。
- **NFR-5 代码风格**：遵循 Kelivo `AGENTS.md`——feature 分层、Provider 状态、Drift 数据库、`lucide_icons_flutter`、自定义组件优先。

## Constraints
- **Technical**: 仅 Android 原生能力；Flutter Platform Channel；复用 Operit Kotlin 模块需迁移包名 `com.ai.assistance` → `com.psyche.kelivo`；MNN/llama/QuickJS 预编译库不在本任务交付范围。
- **Business**: 保留 Kelivo 现有所有功能不受影响；不引入破坏性变更。
- **Dependencies**: Operit 1.12.2 源码（已解压在 `/workspace/operit/Operit-1.12.2`）；Kelivo 现有 Drift、Provider、MethodChannel 基础设施。

## Assumptions
- 用户接受原生 `.so` 需另行构建（Kotlin 封装 + JNI 桩可编译，但实际推理需预编译库）。
- 工作流与记忆的 UI 以可用为目标，不追求与 Operit 完全一致的视觉。
- Drift 数据库迁移通过新增表 + 版本号递增完成，不改动现有表结构。

## Acceptance Criteria

### AC-1: 本地 LLM 平台通道存在且类型化
- **Type**: `rule`
- **Given**: Kelivo Android 工程已新增 `llm` 相关 Gradle 模块与 `app.llm` MethodChannel
- **When**: Dart 端调用 `LocalLlmChannel.listModels()`
- **Then**: 方法存在且返回 `List<LocalModelInfo>`；非 Android 平台抛出 `unsupported` 错误且不崩溃
- **Pass Condition**: `LocalLlmChannel` 类存在，`listModels/loadModel/generate/cancel/unload` 方法均有实现与类型签名；`flutter analyze` 无新增错误
- **Evidence**: 源码文件存在 + analyze 输出

### AC-2: ToolPkg 平台通道存在且类型化
- **Type**: `rule`
- **Given**: Kelivo Android 工程已新增 `quickjs` 模块与 `app.toolpkg` MethodChannel
- **When**: Dart 端调用 `ToolPkgChannel.list()`
- **Then**: 返回已安装工具包列表；`install/invoke/uninstall` 方法存在且类型签名完整
- **Pass Condition**: `ToolPkgChannel` 类存在且方法齐全；analyze 通过
- **Evidence**: 源码文件存在 + analyze 输出

### AC-3: 工作流数据模型与执行器可用
- **Type**: `rule`
- **Given**: 已定义 Workflow 系列数据模型与 `WorkflowExecutor`
- **When**: 构造一个含 Trigger→Execute→Condition 节点的工作流并执行
- **Then**: 执行器按拓扑顺序执行，返回每个节点的状态（Success/Skipped/Failed）与结果
- **Pass Condition**: `WorkflowExecutor.run(workflow)` 返回 `WorkflowExecutionResult`，单元测试覆盖成功与失败路径
- **Evidence**: 单元测试通过

### AC-4: 工作流持久化到 Drift
- **Type**: `rule`
- **Given**: 新增 Drift 表 `workflows`、`workflow_execution_logs`
- **When**: 保存一个工作流并重新加载
- **Then**: 数据完整往返（字段无丢失）
- **Pass Condition**: Drift DAO 的 `insertWorkflow`/`getWorkflow` 往返一致，单元测试通过
- **Evidence**: 单元测试通过

### AC-5: 角色卡模型与持久化
- **Type**: `rule`
- **Given**: 定义 `CharacterCard` 模型与 Drift 表
- **When**: 保存并读取角色卡
- **Then**: 字段（name、personality、system_prompt 等）完整往返
- **Pass Condition**: 单元测试验证序列化/反序列化一致
- **Evidence**: 单元测试通过

### AC-6: 图谱记忆模型与检索
- **Type**: `rule`
- **Given**: 定义 `MemoryNode`、`MemoryEdge`、`MemoryGraph` 与 Drift 表
- **When**: 存入若干节点/边后按关键词检索
- **Then**: 返回匹配的节点及其邻居，按权重排序
- **Pass Condition**: `MemoryRepository.search(query)` 返回相关节点，单元测试通过
- **Evidence**: 单元测试通过

### AC-7: 原生模块包名迁移且可编译
- **Type**: `rule`
- **Given**: Operit 的 `quickjs`、`mnn`、`llama` 模块源码已复制到 Kelivo `android/`
- **When**: 检查所有 Kotlin 文件的 package 声明与 import
- **Then**: 包名为 `com.psyche.kelivo.*`，无残留 `com.ai.assistance` 引用（除注释外）
- **Pass Condition**: `grep -r "com.ai.assistance" android/` 在新增模块中无匹配
- **Evidence**: grep 输出为空

### AC-8: 工作流编辑器页面可打开
- **Type**: `rubric`
- **Dimension**: 工作流编辑器可用性
- **Scale**: 1-5
- **Anchors**: 1 = 页面空白或崩溃；3 = 能显示节点列表与画布，可添加节点；5 = 完整拖拽、连线、配置、保存、执行
- **Pass Threshold**: >= 3
- **Evidence**: 运行 App 打开工作流编辑器页面截图或日志

### AC-9: 角色卡管理页面可打开
- **Type**: `rubric`
- **Dimension**: 角色卡页面可用性
- **Scale**: 1-5
- **Anchors**: 1 = 空白或崩溃；3 = 能列出/新建/编辑角色卡并保存；5 = 完整导入导出、绑定对话、实时预览
- **Pass Threshold**: >= 3
- **Evidence**: 运行 App 打开角色卡页面截图或日志

### AC-10: 记忆图谱页面可打开
- **Type**: `rubric`
- **Dimension**: 记忆图谱页面可用性
- **Scale**: 1-5
- **Anchors**: 1 = 空白或崩溃；3 = 能列出记忆条目、查看图谱、检索；5 = 完整节点/边编辑、可视化图谱、对话注入验证
- **Pass Threshold**: >= 3
- **Evidence**: 运行 App 打开记忆页面截图或日志

## Open Questions
- [ ] 本地 LLM 的预编译 `.so` 由谁、何时构建？（本任务交付 Kotlin 封装 + 通道，不交付二进制）
- [ ] ToolPkg 的 manifest 格式是否完全照搬 Operit，还是做简化版？（倾向照搬以兼容）
- [ ] 工作流定时触发是否直接复用 Kelivo `scheduled_tasks`，还是独立调度？（倾向复用）
