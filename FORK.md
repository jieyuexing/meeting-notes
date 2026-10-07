# Meeting Notes 中文个人 fork

本分支 `jie-custom` 从上游正式 tag `v1.3.2`（`53a9ce5`）开始，按跟随型 fork 维护。`main` 保留为上游镜像。定制集中在新增 Swift 文件，上游仅保留少量接入点。

## 定制与入口

在 **Settings → Summaries → Summary backend** 选择后端。设置即时保存；一次摘要任务开始时固定后端与命令，避免长会议的分块任务中途切换后端。

- **Codex**：默认值。保留上游 ChatGPT 登录、摘要模型和 reasoning 设置，使用应用自己的 `MeetingNotes/ChatGPTAuth`。未设置 `summary.backend` 或保存了未知值时回退到 Codex。
- **Custom command**：无需应用内 ChatGPT 登录。`summary.command` 保存原样 shell 命令；程序用 `/bin/zsh -lc` 运行，继承环境并加载登录 shell 配置，不设置 `CODEX_HOME`，不改写 CLI 账号或配置。模型由命令指定，下面的上游 Codex Model/Reasoning 控件仅影响 Codex 后端。
- **Off**：`enrich` 立即返回“已关闭”错误，转写和录音定稿流程继续。无生成摘要；原有归档元数据与转写仍由上游保存，包括 `meeting.md` 中“未生成结构化摘要”的占位提示；不改写归档格式。自动补摘要和手动重试的候选查询返回空，因此不会周期性重复生成或弹通知。已有摘要不删除；重新启用后端后，原有缺摘要记录可按上游维护周期补齐。主动点击重新生成时会显示关闭提示。

**Test** 使用内置短样例“今天决定周五发布新版，小王负责更新说明。”走同一提示词、schema、后端分派与 `GeneratedInsights` 解码，不写入会议归档。关闭模式禁用测试按钮。命令以当前用户身份运行，应选择自己信任的命令。

命令工作目录是独立临时目录，不继承项目规则目录。登录 shell 必须在 `.zprofile` / `.zshenv` 等非交互登录环境中提供 PATH；只放在 `.zshrc` 中的别名或 PATH 不保证可用，必要时使用可执行文件绝对路径。stdin 是与 Codex 相同的指令文本，加 JSON schema 和只返回 JSON 的要求；stdin 不参与 shell 命令拼接。stdout 与 stderr 分开保存，取 stdout 第一个完整对象，容忍代码围栏和前后非 JSON 杂讯，处理字符串内的括号、转义引号及嵌套对象。无对象、截断对象、非法 JSON、必需字段缺失或类型错误都会报错，不跳过第一个坏对象去寻找后续对象。不要选输出 JSON 事件信封的模式。

超时沿用 `generationTimeout`：按完整输入字符数从 10 分钟增加，最长 20 分钟。超时或取消时终止直接 shell/CLI 进程，忽略 SIGTERM 时升级为 SIGKILL；命令不应后台化或自行脱离进程，任意自建命令产生的脱离子进程不在本版保证范围。输入和输出采用临时文件，避免大转写填满 pipe 后互相阻塞，完成后清理。CLI 自己的会话、缓存等仍归 CLI 管理。

## 命令示例

以下参数于 2026-10-07 使用本机 `claude --help`、`codex exec --help`、`opencode run --help` 实际核对。模型名用 `opencode models deepseek` 核对；这里不包含账号或密钥。任选一条粘贴到 Custom command 输入框：

```sh
claude -p --output-format text --tools '' --no-session-persistence --strict-mcp-config --restricted
```

Claude 接收 stdin 并输出纯文本。`--tools ''` 关闭工具，`--restricted` 不加载个人/项目设置，`--strict-mcp-config` 不加载默认 MCP；认证沿用 CLI 登录。已用真实 CLI 跑内置中文假转写，通过实际提取器和 `GeneratedInsights` 解码（见下方验证入口）。

```sh
codex exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --sandbox read-only --color never -
```

Codex 的 `-` 从 stdin 读提示词；`--ignore-user-config` 不加载用户 config，但认证仍使用 CLI 原本的 home。可按本机可用模型追加 `--model <model>`。这里不是应用内 Codex 专用后端，不会把 `CODEX_HOME` 改到应用目录。参数已核对；本轮未做这个命令的真实模型调用。

```sh
opencode run --pure --model deepseek/deepseek-v4-pro "$(cat)"
```

OpenCode 帮助将 prompt 声明为位置参数，所以此示例显式把 stdin 读为单个带引号参数，避免依赖未在帮助中声明的 stdin 行为。`--pure` 不加载外部插件；不使用 `--format json`（其输出是事件流而非目标摘要对象）。本机模型列表同时包含 `deepseek/deepseek-flash`，可替换。参数及模型 ID 已核对；本轮未做 DeepSeek 真实调用。很长的转写可能遇到系统 argv 长度限制，需要改用支持 stdin 的 CLI/包装器；此示例适合短输入。

其他 CLI（如 Grok）遵守相同 stdin/stdout 契约即可；本轮未核对 Grok 参数，不提供未经核对的选项示例。

## 禁止上游更新覆盖

三层防护：

1. `Info.plist` 默认关闭 `SUEnableAutomaticChecks`，并关闭 `SUAllowsAutomaticUpdates`。
2. `SUFeedURL` 指向本 fork `jie-custom/fork-appcast.xml`，文件不包含任何更新条目。文件名不是 `appcast.xml`，所以上游 Beta 通道改写逻辑不会把它换成 `appcast-beta.xml`。未推送之前远程文件可能不存在；这不会回退到上游。
3. `ForkUpdatePolicy.swift` 扩展既有 `UpdateChannelDelegate`，通过 Sparkle 的 `updater(_:mayPerform:)` 始终抛错，拒绝自动、手动和信息检查。即使旧版在 UserDefaults 中保留了上游 feed 或自动检查偏好，也不能开始更新检查。手动 “Check for Updates…” 会说明自建版禁用更新。该策略不改用户偏好，不依赖替换签名密钥。

委托接口依据 [Sparkle 官方 SPUUpdaterDelegate 文档](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)，并核对本地解析的 Sparkle 2.10.0 源码。`SUPublicEDKey`、bundle ID、签名脚本均未改；仅将 plist 设为 false 不足以覆盖旧偏好，因此委托门禁必须保留。真正的窗口操作与安装由协调者后续验收。

## 改动过的上游文件

- `Sources/MeetingNotes/OpenAIEnricher.swift`：入口按后端检查、请求分派、样例测试入口、后端来源标记；沿用上游提示词、schema、分块和解码结构。
- `Sources/MeetingNotes/SettingsView.swift`：Summaries 面板插入一个 `SummaryBackendSettingsView()` 引用。
- `Sources/MeetingNotes/AppModel.swift`：补摘要的登录检查仅限 Codex，并在批次中检查关闭状态。
- `Sources/MeetingNotes/MeetingStore.swift`：关闭时两处补摘要候选查询返回空。
- `Resources/Info.plist`：关闭自动更新默认值，换 fork 空源。

新增文件：`SummaryBackendSettings.swift`、`CommandSummaryBackend.swift`、`SummaryBackendSettingsView.swift`、`ForkUpdatePolicy.swift`、两份 `Tests/MeetingNotesTests/*Tests.swift`、`fork-appcast.xml`、本说明。

## 同步上游与验证

同步新正式 tag 时优先检查以上五个接入文件；确认上游没有绕开 `OpenAIEnricher` 的新摘要路径，新的补摘要任务是否也处理 off。检查 `GeneratedInsights` / schema / `generationTimeout` 的变动，确认命令与 Codex 仍共用同一合同。检查 Sparkle 是否仍使用 `UpdateChannelDelegate`、是否新增替代更新入口；保留委托拒绝、空源及稳定版/Beta 的隔离。不得用上游 `Info.plist` 覆盖自建版更新策略。原有分块 checkpoint 未新增后端维度；更换后端后继续旧失败任务可能复用既有部分摘要。

常规验证入口：`swift build`、`swift test`、`scripts/build-app.sh`。构建脚本只打包与签名，本轮不运行 `scripts/stable-build.sh`，不启动 app、不申请系统权限、不录音。开发调试只测 Swift 逻辑，不把测试通过或代码签名通过当作录音和 UI 验收。

本总仓执行时将 `TMPDIR`、`TMP`、`TEMP` 设为根 `.local/tmp/meeting-notes/tmp`；演练真实 CLI（按需，会调用已登录 CLI）：

```sh
MEETING_NOTES_TEST_COMMAND="claude -p --output-format text --tools '' --no-session-persistence --strict-mcp-config --restricted" \
  swift test --filter liveSummaryCommandProbe
```

普通 `swift test` 跳过真实 CLI 样例，覆盖 JSON 提取、设置默认值与读写、stdin 大输入、非零退出、超时、取消、生产解码及更新门禁。真实调用日志和执行结论在总仓 `.local/tmp/meeting-notes/RECORD.md`；长期维护合同以本文件为准。
