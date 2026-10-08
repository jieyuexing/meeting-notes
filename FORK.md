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

## 最终转写的跨进程锁（2026-10-07）

录音结束定稿与恢复录音共用 `FinalTranscriptionEngine.process(microphone:system:)`。
该入口在读取/转写之前取得录音目录内 `.transcription.lock` 的内核 `flock`，持有到两个音轨的最终转写返回或抛错。
目录路径先解析符号链接、去重并排序；同一录音目录跨进程互斥，不同目录仍可并行。实时预览的
`LiveTranscriptionEngine` 与 `SerialAudioBatchQueue` 不参与此锁，摘要与归档也不在锁范围内。

竞争时异步等待（50ms 检查一次），不阻塞 Swift executor，也不把“忙”直接标成会议失败。取消等待会释放已取得的部分锁；
转写中的取消在已有异步边界和本机音频分块之间检查，云端取消不会触发本机回退。普通云端错误仍按上游逻辑回退。
成功、错误、取消均由描述符生命周期释放，进程崩溃由内核释放；锁文件永久保留，不按时间/PID 抢占，也不手工删除活跃锁文件。
这只是最终转写阶段的互斥，不保证整个会议归档流程的跨进程事务、去重或资源全局调度；旧版 app 不识别新锁，不能与新版混跑。

隔离验证入口（在本 fork 根运行，三个临时环境变量须指向总仓本轮任务目录）：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/test_transcription_lock.py
```

该测试用 `xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors` 编译原样提取的
`FinalTranscriptionEngine`、真实锁实现和假 ASR，真实子进程覆盖互斥、不同会议并行、取消、错误、崩溃释放、符号链接别名。
测试不构建/运行 app、不解析依赖、不加载模型、不读真实音频。2026-10-07 已先在未加锁入口复现失败，再验证 10 项通过。
应用整体构建、稳定启动、真实 ASR 与录音恢复验收须另按 `AGENTS.md` 的 stable-build 流程处理；本轮未执行。

## 最终转写文本权威与 CJK 接缝（2026-10-07）

流式 Nemotron partial 会回改或截短此前的假设，故只用于实时预览。归档阶段调用
FluidAudio 0.15.7 的 `finishWithTokenTimings()`，最终文本只取其 `text`；不会把 partial
片段带入最终 `Result.segments`。token timings 只在能无损复原最终文本、时间有限且单调时生成按
安全英文/CJK 接缝分开的约 10 秒连续切片，并裁剪到音频 duration；缺失、无效或文本不一致时退回为
`0...duration` 的完整最终文本单段。这样不丢字、不把错误 partial 拼回去，也不按英语词边界拆开中文
或新插空格。既有
`VocabularyTextCorrector` 仍同时作用于最终文本和该完整段。

Nemotron 的 token timings 使用与上游 `NemotronMultilingualTokenizer.decode(ids:)` 相同的
SentencePiece 表示：每个 piece 内的 `▁` 为 ASCII 空格，跨 piece 的连续 ASCII 空格折叠为一个。
然后仍要求结果与最终文本严格相等；这不是忽略空白的比较。独立尾部 `▁` 只在最后一个片段上移除，
中间片段的显式英文前导空格保留给 formatter。这样真实、有效的时标不会因 tokenizer 自己的双空格
表示而退回整轨，同时不能以时标重写任何模型字符。

`TranscriptFormatter` 对相邻 CJK 字符紧接，不应用原先针对拉丁文字残片的短词启发，以避免将
“和背景音乐”显示成“和背 景音乐”。这仅修复展示接缝，不能替代或掩盖 ASR 对字符的识别错误。

逻辑验证（不启动 app、不加载模型或音频）：

```sh
swift test --disable-automatic-resolution --filter final
swift test --disable-automatic-resolution --filter transcriptFormatter
```

覆盖最终文本权威、中文/英文标点、Unicode、空文本、缺失/不匹配/无效 timings 回退及 duration 裁剪；
真实录音的 token timing 精度仍须用保留在本机的非敏感 WAV 单独验收。

`LocalTranscriptionProbeTests.swift` 是显式授权时的本地验收入口，默认没有环境变量即返回，
不会读音频、发现缓存或下载模型。授权运行时只传绝对的 WAV、完整本地模型 variant 目录和根任务报告路径；
它记录 raw final、token timings、旧 partial 的 appendDelta 模拟和生产 archive 边界结果。测试中不得
固化真实录音内容。

## SenseVoice 最终转写（2026-10-08）

**Settings → Transcriptions → Transcription engine** 新增 **SenseVoice (on-device)**，只用于录音结束后的最终转写；实时预览仍是 Nemotron，Live 引擎列表不出现该项。默认值不变（`transcription.engine` 缺省为 `onDevice`）；`loadLive` 遇到存成 `senseVoice` 的值回退为 `onDevice`，`saveLive` 也不会写入它。

- 入口：`FinalTranscriptionEngine.process` 在原有目录锁内按设置选择 `SenseVoiceTranscriber`（`SenseVoiceTranscriber.swift`）。麦克风和系统声两路分别处理，`TranscriptTurn.source` 与转写锁、取消检查语义不变。SenseVoice 非取消错误（例如首次下载时离线）回退 Nemotron，取消不回退；OpenAI 引擎的回退目标仍是 Nemotron。
- 模型：FluidAudio 0.15.7 的 `SenseVoiceModels.downloadAndLoad(.fp16)` 与 `VadManager()`（Silero VAD），都先用 `~/Library/Application Support/FluidAudio/Models/` 本机缓存，缺失时首次从 HuggingFace 下载（SenseVoice 约 453 MB，`silero-vad` 很小）；音频不离开本机。模型加载后留在进程内，与 Nemotron 一样不主动卸载。
- 切段：按 10 分钟块读 WAV（与 Nemotron 一样跳 44 字节头），每块跑 VAD（`maxSpeechDuration` 30 s，其余为 FluidAudio 默认）。触到块尾、且起点在块后半段的语音段推迟到下一块，从该段起点前 0.4 s（不早于上一段结尾）重读，保留前导上下文；重读块里它起点靠前，不会被再次推迟，因此每段最多推迟一次、每轮至少前进半块。起点在前半段却触到块尾的段（VAD 单段 ≤30 s，正常不会出现）直接按块边界输出。单段超过 90 s（低于约 108 s 的 1800 帧窗口，超出 FluidAudio 只记日志并截断）按等长强制切开。整轨 VAD 都没检测到语音时，按 ≤90 s 固定窗口整轨识别，避免安静但有效的音轨被丢掉。
- 时间戳：SenseVoice 不出时间戳，每个 VAD 段（或强制切片）生成一个 turn，起止为段边界，精度是**切段级**，比 Nemotron 的词元级粗。送入模型的音频在段两侧各多带最多 0.4 s 上下文，且不超过与相邻段间隙的一半（强制切片之间为 0），所以不会重复识别同一语音；turn 时间仍取 VAD 段边界。
- 文本：`language = 0`（自动识别）、`textNorm = 14`（withitn）。理由：对比实测 withitn 与 woitn 的差异只有阿拉伯数字格式（数字归一后同为 0/52），而 withitn 带标点，逐字稿合并断句、摘要和翻译输入都更好读。`SenseVoiceText.clean` 防御性去掉 `<|…|>` 语言/情绪/事件/ITN 标签与 `▁`，合并空白，删除中日文字之间及其与数字之间的空格（日文 ITN 会输出“午後 3 時”），保留韩文与拉丁文词间空格。`VocabularyTextCorrector` 逐段应用（跨两个 VAD 段的替换不生效，段间是静音）；`FillerWordFilter` 仍在 `FinalTranscriptionEngine` 对合并后的 turns 应用。`FinalTranscriptSegments` 的 tokenizer 规则只用于 Nemotron，不用于 SenseVoice。
- 已知局限：VAD 使用 FluidAudio 默认阈值，极轻声或远场语音可能被判为静音（整轨全无语音时才有固定窗口兜底）；每块整段读入内存（10 分钟约 38 MB Float）。首字识别对窗口边界敏感：保留样本在 0.0/0.2/0.5 s 补边时首字“这是”会错成“这试/测试”，0.3/0.4/0.6/0.8 s 正确，全文件直接识别也正确；0.4 s 只在这一段 16 秒样本上验证过，不代表最优值，真实会议 A/B 前不改默认引擎。

## 转写语言与中外对照逐字稿（2026-10-08）

最终稿落盘后（停止录音定稿、恢复录音、修复转写三条路径，以及手动重新生成摘要时补做），`AppModel` 另起后台任务：

1. **语言判定**（全部引擎，本地）：`TranscriptLanguageDetector` 按字符类别计数——假名占中日文字符 ≥15% 判日文，谚文占多判韩文，其余中日文字符判中文，拉丁等字母文本交给 `NLLanguageRecognizer` 在纪要语言列表内识别。结果是 ISO 639-1 代码，写入 `meeting.json` 的 `transcriptLanguage`。FluidAudio 的 `SenseVoiceManager` 在私有 decode 里剥掉语言标签，所以 SenseVoice 也用同一文本判定。只含汉字的日文短句会判成中文（测试固化了这一点）。
2. **对照翻译**：仅当判定语言与 `meetingNotesLanguage` 不同（`Same as transcript` 视为不翻译）、**Settings → Summaries → Translate foreign-language transcripts**（`transcript.translation.enabled`，默认开）打开、摘要后端不是 Off 时，才把逐字稿经摘要后端发出。分派与 `OpenAIEnricher.requestInsights` 调同样的函数和设置：Codex 走应用内 ChatGPT 登录与摘要模型/推理设置（未登录则不发，记为翻译失败），Custom command 走 `CommandSummaryBackend.generate`；Off 时不发生任何外发。外发范围与摘要相同，不新增目的地。翻译 schema 与提示词独立（`TranscriptTranslator`），提示词沿用“数据而非指令”的围栏。
3. **对齐**：翻译单位是 `TranscriptFormatter.mergedLines` 的行（与 `transcript.md` 的时间戳行一致）。按 ≤40 行、≤3000 字分块（单行过长自成一块，不拆行），每行带全局编号；返回必须恰好覆盖本块全部编号、无重复、无空译文，否则该块重试（共 3 次）。仍不符的块标为未翻译（文件中显示 “_(Translation failed for this line.)_”，frontmatter `complete: false`），其它块照常保存；后端本身连续 3 次报错则整次翻译放弃；所有块都对不齐也放弃。手动重新生成摘要会对缺失或不完整的翻译重试。
4. **产物**：`meeting.json` 的 `transcriptTranslation` 保存原文行、译文、源/目标语言、`transcriptionVersion`、生成方；`MeetingStore.persist`/`persistTranscriptArtifact` 据此渲染 `transcript.<目标语言代码>.md`（例如简体中文为 `transcript.zh.md`，代码取 `MeetingNotesLanguage.languageCode`），每行“时间戳＋原文”后接引用块译文。翻译失败、未触发或被关闭都不影响 `transcript.md` / `meeting.md` 定稿；`meeting.md` 继续按 `meetingNotesLanguage` 生成（简体中文指令为 “Write every generated text field in Chinese (Simplified), regardless of the transcript language.”，已有测试确认它进入实际摘要提示词）。

各路径行为：

| 路径 | 对照文件 |
| --- | --- |
| 本地归档镜像 / 远端 rsync（`--delete-excluded`） | 普通 `.md`，不在排除列表，随会议同步；源目录删除后镜像也删除 |
| 重命名 | 随目录移动，按新标题重新渲染 |
| 重新生成摘要、补摘要、设置 Codex 线程等 `persist` | 保留并重新渲染 |
| 重新转写（`replaceCompletedTranscript`） | 版本号变化，清空语言与翻译并删除文件，之后重新判定/翻译 |
| 「自动删除详细记录」（`purgeExpiredTranscripts`） | 与 `transcript.md`、音频一起删除，`transcriptTranslation` 清空；已删除逐字稿的会议不会再写入翻译 |
| 删除会议 | 先取消该会议进行中的翻译任务，再随整个目录删除 |

翻译保存时按会议 ID 重新读取，并核对 `transcriptionVersion` 未变、逐字稿未删除，否则丢弃结果。每次保存走既有 `persist`，会像摘要更新一样再次触发同步与会后 hook；hook 可能先于对照文件到达。`meeting.json` 体积随译文增加，它不同步到远端。

## 改动过的上游文件

- `Sources/MeetingNotes/OpenAIEnricher.swift`：入口按后端检查、请求分派、样例测试入口、后端来源标记；沿用上游提示词、schema、分块和解码结构。
- `Sources/MeetingNotes/SettingsView.swift`：Summaries 面板插入一个 `SummaryBackendSettingsView()` 引用；Transcriptions 面板拆分最终/实时引擎列表（实时去掉 SenseVoice），SenseVoice 说明文字。
- `Sources/MeetingNotes/AppModel.swift`：补摘要的登录检查仅限 Codex，并在批次中检查关闭状态；定稿、恢复、修复、重新生成摘要后调度语言判定与翻译任务，删除会议前取消该任务。
- `Sources/MeetingNotes/MeetingStore.swift`：关闭时两处补摘要候选查询返回空；`persist`/`persistTranscriptArtifact` 渲染或删除对照文件，`setTranscriptLanguage` 保存入口，重新转写清空、留存清理删除。
- `Resources/Info.plist`：关闭自动更新默认值，换 fork 空源。
- `Sources/MeetingNotes/TranscriptionEngine.swift`：最终转写入口取得录音目录锁，补充取消检查；按设置选择 SenseVoice 并在非取消错误时回退 Nemotron；实时队列不变。
- `Sources/MeetingNotes/OpenAITranscriber.swift`：`TranscriptionEngineOption.senseVoice`、`supportsLivePreview`，实时设置读写排除 SenseVoice。
- `Sources/MeetingNotes/Models.swift`：`MeetingDocument` 增加可选的 `transcriptLanguage`、`transcriptTranslation`（旧 `meeting.json` 照常解码，未设置时不写出）。

`OpenAIEnricher.swift` 本轮未改：翻译分派在 `TranscriptTranslation.swift` 中调用相同的后端函数，以把本轮触及的上游文件控制在 6 个。

新增文件：`SummaryBackendSettings.swift`、`CommandSummaryBackend.swift`、`SummaryBackendSettingsView.swift`（另含翻译开关）、`ForkUpdatePolicy.swift`、`TranscriptionLock.swift`、`SenseVoiceTranscriber.swift`、`TranscriptLanguage.swift`、`TranscriptTranslation.swift`、`Tests/MeetingNotesTests/*Tests.swift`（含 `SenseVoiceTests`、`SenseVoiceProbeTests`、`TranscriptTranslationTests`）、`Tests/test_transcription_lock.py`、`Tests/TranscriptionLockFixtures.swift`、`fork-appcast.xml`、本说明。

## 同步上游与验证

同步新正式 tag 时优先检查以上六个接入文件；确认上游没有绕开 `OpenAIEnricher` 的新摘要路径，新的补摘要任务是否也处理 off。检查 `GeneratedInsights` / schema / `generationTimeout` 的变动，确认命令与 Codex 仍共用同一合同。检查 Sparkle 是否仍使用 `UpdateChannelDelegate`、是否新增替代更新入口；保留委托拒绝、空源及稳定版/Beta 的隔离。检查停止录音和恢复路径是否仍共用 `FinalTranscriptionEngine.process`，保留文件锁与取消传播；`TranscriptionEngineOption` 若被上游改动，保留 `senseVoice` 只出现在最终引擎列表。上游若改 `requestInsights` 的分派、模型/推理设置或超时，`TranscriptTranslationBackend` 要同步改；上游若新增写 `transcript.md` 或删除逐字稿的路径，要同时处理 `transcript.<code>.md`，若改 rsync 排除规则，确认 `*.md` 仍同步。升级 FluidAudio 时复核 `SenseVoiceManager`、`VadManager.segmentSpeech`、`VadSegmentationConfig`（debug 断言要求 `speechPadding ≤ minSpeechDuration`）和 SenseVoice 窗口上限。不得用上游 `Info.plist` 覆盖自建版更新策略。原有分块 checkpoint 未新增后端维度；更换后端后继续旧失败任务可能复用既有部分摘要。

常规验证入口：`swift build`、`swift test`、`scripts/build-app.sh`。构建脚本只打包与签名，本轮不运行 `scripts/stable-build.sh`，不启动 app、不申请系统权限、不录音。开发调试只测 Swift 逻辑，不把测试通过或代码签名通过当作录音和 UI 验收。

本总仓执行时将 `TMPDIR`、`TMP`、`TEMP` 设为根 `.local/tmp/meeting-notes/tmp`；演练真实 CLI（按需，会调用已登录 CLI）：

```sh
MEETING_NOTES_TEST_COMMAND="claude -p --output-format text --tools '' --no-session-persistence --strict-mcp-config --restricted" \
  swift test --filter liveSummaryCommandProbe
```

SenseVoice 与翻译的显式探针（不设变量即直接返回）：

```sh
MEETING_NOTES_SENSEVOICE_WAVS=/abs/a.wav:/abs/b.wav MEETING_NOTES_SENSEVOICE_OUT=/abs/report.json \
  swift test --disable-automatic-resolution --filter localSenseVoiceFinalProbe
MEETING_NOTES_TEST_COMMAND="<摘要命令>" MEETING_NOTES_TRANSLATION_INPUT=/abs/report.json \
  MEETING_NOTES_TRANSLATION_OUT=/abs/out-dir \
  swift test --disable-automatic-resolution --filter liveTranscriptTranslationProbe
```

第一个走生产 `SenseVoiceTranscriber`（缓存缺失时会像应用一样首次下载模型），输出各 turn 与段时间；第二个把报告里的逐字稿文本经真实命令后端翻译并写出 `transcript.zh.md`，只应喂合成或已授权文本。2026-10-08 结果见总仓 `.local/tmp/meeting-notes-sensevoice/RECORD.md`。

普通 `swift test` 跳过真实 CLI 样例，覆盖 JSON 提取、设置默认值与读写、stdin 大输入、非零退出、超时、取消、生产解码及更新门禁。真实调用日志和执行结论在总仓 `.local/tmp/meeting-notes/RECORD.md`；长期维护合同以本文件为准。

## MEET-4 常开模式（2026-10-08）

**Settings → Always-on → Record continuously**，默认关闭。麦克风沿用 Microphone 面板的设备 UID/优先级；建议实验固定 USB 输入并确认它仍连接。此模式只采麦克风，不采系统音频，系统应用排除列表仍仅影响正式会议。
默认根 `~/jieyuexing-universe/.state/opsail/lifelog`，与会议归档、Spool 的相同/父子路径（含可解析符号链接）互斥，文件系统根也拒绝。反向修改会议归档时同样校验。修改常开根先在旧根收好尾段与静音统计；旧根的已排队任务继续在原目录完成，不搬移历史。

- 默认连续静音 180 秒或单段 1800 秒切段，可在该面板调整。分段用新增 `LifelogRecorder` 的 AVAudioEngine 麦克风 tap，在锁内交换 WAV 文件句柄；不改上游 `MicrophoneRecorder`/`SystemAudioRecorder`。正常切段不主动重启引擎，但音频回调、磁盘同步、系统调度/设备驱动可能造成丢帧，**未证明无缝，也没有可保证的间隙上限**。静音判断是既有能量阈值，不是说话人识别；低音量或远场漏检仍须实验核实。高采样率的小缓冲先累积到 100ms 再交能量监测，关闭文件前再检查 WAV 信号，避免回调尾部被当作空段。
- `LifelogController` 独立拥有录音和串行待转写队列；正式会议开始前收尾并释放麦克风，会议录音停止（含启动失败）后恢复。会议暂停期间仍让出，等待会议结束。交接有启动/授权/调度耗时，无硬上界。睡眠收尾，唤醒另开；录音持有现有 `RecordingWakeLock`。设备变更在 2 秒后重试，启动失败每 30 秒重试；不能保证断开期间有音频，也不补造该时段。
- 正常退出由 `NSApplication.willTerminateNotification` 同步关闭尾段并落 `pending`，不等 ASR；下次启动恢复。强退/崩溃后 `recording` 段按文件字节修复 WAV header 并重试，未持久化到磁盘的音频无法保证。关闭开关收尾后仍处理已排队段；启用设置保留则应用下次启动自动录音。
- 最终转写沿用 `FinalTranscriptionEngine.process` 的跨进程目录锁、SenseVoice/Nemotron 与取消处理。常开调用增加 `onDeviceOnly: true`：即使等待锁时引擎切为 OpenAI，也在锁内拒绝上传；音频留待恢复本地引擎。会议调用默认参数不变。常开建议 SenseVoice，但不替用户改设置；缺失模型仍可能按既有逻辑下载模型或回退 Nemotron。
- **不调用 MeetingStore**，不产生会议标题、实时预览、逐段摘要、对照翻译、Codex 线程、Tana、rsync、HTTP/Shell hook；只做本地语言判定。常开启用期间不弹新的会议检测通知；正式会议自己的检测/自动停止继续工作。每日摘要的 Codex/command 是用户单独配置的外发边界，会议摘要设置不会自动继承到常开。
- 全静音段删除目录并增加同日 `day.json` 计数；有信号但无转写保留 `empty` 元数据，不写空逐字稿，删除音频。成功转写按既有 Storage 音频留存设置（默认删音频）；捕获写入错误/转写失败保留音频并标 `failed`。Always-on 的 **Retry failed transcripts (all days)** 手动重试。失败不自动无限重试；pending/recording 在下次启动恢复，队列无并行转写/无自动丢弃上限，积压会增加磁盘占用。采样分别记录 pending、recording、failed。

目录合同（ISO8601 时间写在元数据内，日目录用本地日历）：

```text
<lifelog>/YYYY-MM-DD/HHmmss-<id8>/segment.json
                                      transcript.md
                                      microphone.wav   # 处理前或失败/选择留存
<lifelog>/YYYY-MM-DD/day.json                            # 丢弃的静音计数
<lifelog>/digest/YYYY-MM-DD[.<label>].md
<lifelog>/digest/YYYY-MM-DD[.<label>].json                # 用时/规模/来源/失败
```

`segment.json` 包含 startedAt/endedAt、status、closeReason、audioSeconds、speechSeconds、characterCount、language、transcriptionStartedAt/transcribedAt、transcript。speechSeconds 是 ASR turn 范围合计的**估计**，不是精确人声活动时长；Nemotron 全段回退可包含静音。结束至 transcribedAt 的差包含排队延迟。逐字稿 Markdown 用当地钟表时间；日期按**段开始时间**归属。午夜后的第一个 1 秒循环请求切段，延迟 tick/跨界缓冲仍归起始日；不是在午夜逐采样切开。改变系统时区会影响日期归属，实验期间固定时区。

### 每日汇总与命令行复跑

默认 **Custom command + 空命令**，等价不汇总；Off 也不请求/不写摘要。可单独选择 Codex（应用内 ChatGPT 登录）或 Custom command（stdin 提示词和 JSON schema、stdout JSON）。分派复用 `TranscriptTranslationBackend`，与 `requestInsights` 同一套后端函数/模型设置；不会执行对照翻译逻辑。选本地命令时内容只送回环 LM Studio；选择 Codex/DeepSeek 对比会把当天文字外发，只有手动运行对比入口才发生。

默认当地 23:55，对当天**已完成**段按顺序分块汇总再合并；每个原文块默认 ≤12000 字符，超长单行也拆开，续块重复段标签。提示词/schema 开销不计入此原文限额。归并至少每两份中间摘要合并，保证收敛；中间模型输出很长时合并输入可超过原文块限额，后端上下文不足会记失败而不截断原文。每个请求解码失败/调用错误重试一次。最终文件含概览、时间段、待办与约定、带时间/段文件链接的回看片段、完整段索引。

23:55 后的新段及当时未完成的段，**次日待前一日无 pending/recording 后补汇总**；已覆盖相同段数不重跑。自动只检查今天/昨天；超过一天的停机/积压、失败段后来才重试、或自动尝试累计 3 次耗尽时，用 CLI 显式重跑对应日期。失败间隔至少 10 分钟；失败元数据更新，已成功的 Markdown 不删，因此失败时要看同名 `.json`，不能把旧 Markdown 当新结果。手动按钮可越过自动次数上限；失败不影响逐字稿。关闭录音开关不等于关闭每日摘要，需将 Digest backend 设 Off/清空命令。

独立于运行中 app 的 opt-in 入口（无变量时普通测试跳过，不调用真实模型）：

```sh
MEETING_NOTES_LIFELOG_ROOT=/absolute/lifelog \
MEETING_NOTES_LIFELOG_DIGEST_DATE=2026-10-08 \
MEETING_NOTES_LIFELOG_LABEL=local \
MEETING_NOTES_TEST_COMMAND=/absolute/summary-command \
swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors --filter lifelogDigestProbe
```

输出为 `digest/2026-10-08.local.md` 及同名 JSON，不覆盖默认摘要。先停止实验并等队列排空，再让三个后端读取同一天的稳定文字；不要并行重跑相同 label。标签用字母/数字/连字符；总仓包装器验证日期/标签。`Run.inputCharacters` 为所有实际请求提示词字符数（含归并/重试、不含命令包装 schema），不是原文字符数/token；LM Studio 包装器另记含 schema 的字符数及可取得的 token 用量。

本次新增文件：`LifelogSettings.swift`、`LifelogRecorder.swift`、`LifelogStore.swift`、`LifelogController.swift`、`LifelogDigest.swift`、`LifelogSettingsView.swift`、`Tests/MeetingNotesTests/LifelogTests.swift`。
本次改动的上游文件仅 **3 个**：`AppModel.swift`（初始化、会议交接、归档隔离/检测通知门禁）、`SettingsView.swift`（Always-on 入口）、`TranscriptionEngine.swift`（本地处理约束）；既有转写锁 fixture 增加 local-only 断言。同步上游时重点核对录音 start/stop 的 await 边界、willTerminate 通知、FinalTranscriptionEngine 锁内的引擎分派；不把新摘要/归档/翻译路径接到常开段。MEET-3 语言/翻译与锁保留。

实验专用脚本和完整操作合同在总仓 `.local/tmp/lifelog-24h/RUNBOOK.md`（临时、可重建；尚未启动 24h 实验）。严格测试、红绿回归、克隆构建与本地合成模型验证记录见同目录 `RECORD.md`。这些证明代码/fixture/构建边界，**不代表 USB 实录、24h 持续运行、零间隙、中文准确率或真实每日汇总质量验收**。
