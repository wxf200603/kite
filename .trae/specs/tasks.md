# Kelivo × Operit 能力融合 - 实施计划

## Task 1: 迁移 Operit quickjs 模块到 Kelivo（ToolPkg JS 引擎）
- **Status**: `pending`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 复制 `/workspace/operit/Operit-1.12.2/quickjs` 到 `/workspace/kelivo/kelivo-1.3.0/android/quickjs`
  - 包名 `com.ai.assistance.operit.core.tools.javascript` → `com.psyche.kelivo.quickjs`
  - 调整 `build.gradle.kts`、`AndroidManifest.xml`、`CMakeLists.txt` 适配 Kelivo 工程
  - 注册到 `settings.gradle.kts`：`include(":quickjs")`
- **Acceptance Criteria Addressed**: AC-2, AC-7
- **Test Requirements**:
  - `rule` TR-1.1: `grep -r "com.ai.assistance" android/quickjs/` 无匹配（注释除外）
  - `rule` TR-1.2: `./gradlew :quickjs:compileDebugKotlin` 编译通过

## Task 2: 迁移 Operit mnn + llama 模块到 Kelivo（本地 LLM）
- **Status**: `pending`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 复制 `llm/mnn`、`llm/llama` 到 `android/mnn`、`android/llama`
  - 包名迁移到 `com.psyche.kelivo.llm.mnn` / `com.psyche.kelivo.llm.llama`
  - 调整 `build.gradle.kts`、`CMakeLists.txt`，注册到 `settings.gradle.kts`
  - 保留 `libsherpa-mnn-jni.so` 到对应 `jniLibs`
- **Acceptance Criteria Addressed**: AC-1, AC-7
- **Test Requirements**:
  - `rule` TR-2.1: `grep -r "com.ai.assistance" android/mnn android/llama` 无匹配
  - `rule` TR-2.2: `./gradlew :mnn:compileDebugKotlin :llama:compileDebugKotlin` 编译通过

## Task 3: Android 注册 app.llm 与 app.toolpkg MethodChannel
- **Status**: `pending`
- **Priority**: high
- **Depends On**: Task 1, Task 2
- **Description**:
  - 新建 `android/app/src/main/kotlin/com/psyche/kelivo/llm/LocalLlmPlugin.kt`，封装 MNN/Llama 调用，实现 `app.llm` 通道：`listModels/loadModel/generate/cancel/unload`
  - 新建 `android/app/src/main/kotlin/com/psyche/kelivo/toolpkg/ToolPkgPlugin.kt`，封装 QuickJS，实现 `app.toolpkg` 通道：`install/list/invoke/uninstall`
  - 在 `MainActivity.configureFlutterEngine` 中注册两个 Plugin
- **Acceptance Criteria Addressed**: AC-1, AC-2
- **Test Requirements**:
  - `rule` TR-3.1: `LocalLlmPlugin` 与 `ToolPkgPlugin` 类存在，`onMethodCall` 处理所有约定方法
  - `rule` TR-3.2: `./gradlew :app:compileDebugKotlin` 编译通过

## Task 4: Dart LocalLlmChannel 平台通道客户端
- **Status**: `pending`
- **Priority**: high
- **Depends On**: Task 3
- **Description**:
  - 新建 `lib/core/services/local_llm/local_llm_channel.dart`
  - 定义 `LocalModelInfo`、`LocalLlmChannel`，方法：`listModels/loadModel/generate/cancel/unload`
  - `generate` 返回 `Stream<String>`（token 流）
  - 非 Android 抛 `unsupported`
- **Acceptance Criteria Addressed**: AC-1
- **Test Requirements**:
  - `rule` TR-4.1: `LocalLlmChannel` 类存在且方法签名完整
  - `rule` TR-4.2: `flutter analyze` 无新增错误

## Task 5: Dart ToolPkgChannel 平台通道客户端
- **Status**: `pending`
- **Priority**: high
- **Depends On**: Task 3
- **Description**:
  - 新建 `lib/core/services/toolpkg/toolpkg_channel.dart`
  - 定义 `ToolPkgInfo`、`ToolPkgChannel`，方法：`install/list/invoke/uninstall`
  - 定义 manifest 解析
- **Acceptance Criteria Addressed**: AC-2
- **Test Requirements**:
  - `rule` TR-5.1: `ToolPkgChannel` 类存在且方法签名完整
  - `rule` TR-5.2: `flutter analyze` 无新增错误

## Task 6: 工作流数据模型（Dart）
- **Status**: `pending`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 新建 `lib/features/workflow/models/workflow.dart`
  - 对齐 Operit `Workflow.kt`：`Workflow`、`WorkflowNode`(sealed)、`TriggerNode`、`ExecuteNode`、`ConditionNode`、`LogicNode`、`WorkflowNodeConnection`、`NodePosition`、`ParameterValue`、`ExecutionStatus`、`ConditionOperator`、`LogicOperator`
  - 实现 `toJson`/`fromJson`
- **Acceptance Criteria Addressed**: AC-3
- **Test Requirements**:
  - `rule` TR-6.1: 所有模型类存在，`toJson`/`fromJson` 往返一致（单元测试）

## Task 7: 工作流执行器（Dart）
- **Status**: `pending`
- **Priority**: high
- **Depends On**: Task 6, Task 5
- **Description**:
  - 新建 `lib/features/workflow/services/workflow_executor.dart`
  - 对齐 Operit `WorkflowExecutor.kt`：构建依赖图、拓扑排序、逐节点执行
  - ExecuteNode 支持调用工具（接入 Kelivo 工具服务）与 JS 代码（走 ToolPkgChannel）
  - ConditionNode / LogicNode 分支
  - 返回 `WorkflowExecutionResult`，含每节点状态
- **Acceptance Criteria Addressed**: AC-3
- **Test Requirements**:
  - `rule` TR-7.1: 成功路径测试：Trigger→Execute→Condition 全部 Success
  - `rule` TR-7.2: 失败路径测试：Execute 失败时整体 Failed，其余节点 Skipped

## Task 8: Drift 工作流表与 DAO
- **Status**: `pending`
- **Priority**: high
- **Depends On**: Task 6
- **Description**:
  - 在 `lib/core/database/` 新增 Drift 表 `workflows`（id, name, description, json_data, enabled, created_at, updated_at, execution stats）、`workflow_execution_logs`（id, workflow_id, status, started_at, finished_at, log）
  - 版本号递增，生成迁移
  - DAO：`insertWorkflow/getWorkflow/updateWorkflow/deleteWorkflow/listWorkflows/insertExecutionLog/listExecutionLogs`
- **Acceptance Criteria Addressed**: AC-4
- **Test Requirements**:
  - `rule` TR-8.1: `insertWorkflow` + `getWorkflow` 往返一致（单元测试）

## Task 9: 工作流编辑器 UI 页面
- **Status**: `pending`
- **Priority**: medium
- **Depends On**: Task 6, Task 7, Task 8
- **Description**:
  - 新建 `lib/features/workflow/pages/workflow_list_page.dart`、`workflow_editor_page.dart`
  - 列表页：新建/删除/手动触发工作流
  - 编辑器：画布、节点列表、拖拽添加、连线、参数配置、保存
  - 复用 Kelivo 自定义组件（`SectionCard` 等）、`lucide_icons_flutter`
- **Acceptance Criteria Addressed**: AC-8
- **Test Requirements**:
  - `rubric` TR-9.1: 编辑器可用性；scale 1-5；threshold >= 3；evidence: 页面可打开、可添加节点、可保存

## Task 10: 角色卡模型与 Drift 表
- **Status**: `pending`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 新建 `lib/features/character/models/character_card.dart`：`CharacterCard`(id, name, description, personality, systemPrompt, avatar, tags, creator, characterBook)
  - Drift 表 `character_cards`，DAO CRUD
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `rule` TR-10.1: 保存 + 读取往返一致（单元测试）

## Task 11: 角色卡管理 UI 页面
- **Status**: `pending`
- **Priority**: medium
- **Depends On**: Task 10
- **Description**:
  - 新建 `lib/features/character/pages/character_list_page.dart`、`character_editor_page.dart`
  - 列表页：新建/删除角色卡
  - 编辑器：表单编辑所有字段、保存
- **Acceptance Criteria Addressed**: AC-9
- **Test Requirements**:
  - `rubric` TR-11.1: 角色卡页面可用性；scale 1-5；threshold >= 3；evidence: 页面可打开、可新建保存

## Task 12: 图谱记忆模型、Drift 表与检索
- **Status**: `pending`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 新建 `lib/features/memory_graph/models/memory_graph.dart`：`MemoryNode`(id, label, folderId, metadata)、`MemoryEdge`(id, sourceId, targetId, label, weight, metadata)、`MemoryGraph`
  - Drift 表 `memory_nodes`、`memory_edges`、`memory_folders`
  - `MemoryRepository.search(query)`：关键词匹配节点 label/metadata，按边权重扩展邻居，排序返回
- **Acceptance Criteria Addressed**: AC-6
- **Test Requirements**:
  - `rule` TR-12.1: 存入节点/边后 `search` 返回相关节点（单元测试）

## Task 13: 记忆图谱 UI 页面
- **Status**: `pending`
- **Priority**: medium
- **Depends On**: Task 12
- **Description**:
  - 新建 `lib/features/memory_graph/pages/memory_graph_page.dart`
  - 文件夹导航、记忆条目列表、简单图谱可视化（节点-边）、关键词检索框
- **Acceptance Criteria Addressed**: AC-10
- **Test Requirements**:
  - `rubric` TR-13.1: 记忆页面可用性；scale 1-5；threshold >= 3；evidence: 页面可打开、可检索、可查看条目

## Task 14: 集成 - ToolPkg 工具接入 Kelivo 工具目录
- **Status**: `pending`
- **Priority**: medium
- **Depends On**: Task 5
- **Description**:
  - 在 `lib/core/services/tools/` 中新增 `ToolPkgToolProvider`，把已安装 ToolPkg 的工具暴露给 Kelivo 工具系统
  - 工具调用转发到 `ToolPkgChannel.invoke`
- **Acceptance Criteria Addressed**: AC-2
- **Test Requirements**:
  - `rule` TR-14.1: `ToolPkgToolProvider` 实现 Kelivo 工具接口，可被工具目录枚举

## Task 15: 集成 - 本地 LLM 作为模型 Provider
- **Status**: `pending`
- **Priority**: medium
- **Depends On**: Task 4
- **Description**:
  - 在 `lib/features/provider/` 中新增本地模型 provider，模型列表来自 `LocalLlmChannel.listModels`
  - 聊天消息发送走 `LocalLlmChannel.generate` 流
- **Acceptance Criteria Addressed**: AC-1
- **Test Requirements**:
  - `rule` TR-15.1: 本地模型 provider 存在并实现 Kelivo provider 接口

## Task 16: 集成 - 记忆检索注入对话上下文
- **Status**: `pending`
- **Priority**: medium
- **Depends On**: Task 12, Task 10
- **Description**:
  - 在聊天流程中，发送消息前调用 `MemoryRepository.search`，把相关记忆节点注入 system prompt
  - 若对话绑定角色卡，使用角色卡的 systemPrompt
- **Acceptance Criteria Addressed**: AC-5, AC-6
- **Test Requirements**:
  - `rule` TR-16.1: 存在记忆注入逻辑，可通过单元测试验证 prompt 拼接
