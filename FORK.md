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

## 画面转文字后删除视频（MEET-5，2026-10-08）

本节替代下节“统一日常记录”中关于屏幕的旧描述（“屏幕仅回看引用，不做 OCR”“screen 不随之删除”“容量上限不是删除策略”）；其余采集合同不变。用户 2026-10-08 决定：屏幕录像按**分段**转文字（不按小时/天、不实时），成功后删视频只留文字，失败保留视频可重试，10 GB 上限保留作异常兜底；默认 OCR 用本机 Apple Vision，本地视觉模型描述画面本轮不做。

**处理时机与队列。** `LifelogController.closeUnified` 在 `UnifiedSegmentCapture.stop()` 返回（WAV 与每个 asset writer 已收尾）并写好 `segment.json` 后，把该段放进独立的串行 `screenQueue`（`.utility` 优先级）。与音频 ASR 队列**并行**，理由：OCR 永远本机、不需要 `TranscriptionLock`，不能被“选了 OpenAI 引擎”的音频门禁卡住，也不该排在长 ASR 后面或拖慢逐字稿；两队列各自串行，峰值为一段 ASR + 一段 OCR。抽帧/识别在主线程之外，录音不受阻塞。纯静音桌面段、音频或媒体失败的段同样处理（画面独立于语音；截断的 mp4 读不出时单独记失败并保留）。`UnifiedCapture.swift` 未改。

**抽帧、去重与识别（`ScreenTextExtractor.swift`）。** `AVAssetReader` 按序解码每个 `screen-<displayID>.mp4`（32BGRA），每秒最多分析一帧（`sampleInterval` 1 s，容忍 0.05 s 抖动）；指纹为 64×36 亮度网格（每格 3×3 采样均值）。与**上一关键帧**（不是上一帧）比较：单格亮度差 >16 记为变化，变化格 ≥0.4%（约 9/2304 格）且距上一关键帧 ≥3 s 才成为关键帧——光标、菜单栏时钟低于阈值，新增一行文字/换窗口高于阈值；持续变化（滚动、视频）最多每 3 s 识别一次，缓慢累积的变化最终也会触发。只对关键帧调用 `VNRecognizeTextRequest`（accurate，`zh-Hans, ja-JP, en-US`，语言校正开，`automaticallyDetectsLanguage = true`——探针证实固定语言列表会整行丢日文或把中文识成日文字形），置信度 <0.3、空白和同帧重复行去掉；阅读顺序为自上而下分行、行内自左向右，每个识别框一行（并排窗口按行交错，不在一行内拼接）。同一显示器连续关键帧的行集合重叠系数（|A∩B|/min）≥0.75 时合并为一条并给出时间范围，新增行并入；比较键忽略空白与大小写（Vision 对中英混排空格不稳定）。条目时间范围＝首个关键帧到该显示器下一条不同内容开始（最后一条到最后解码帧，再由落盘步骤延到段结束），所以只有一个关键帧的静止页面也覆盖它显示的整段时间，选段按时间重叠能取到。时间：`actualFirstFrameAt + (帧 PTS − 首帧 PTS)`，换算段内偏移；缺少首帧元数据时用段起点并在结果里标记该显示器“时间估算”。

**落盘（机器可读选 `screen-text.json`，不放进 `segment.json` 正文）。** 段目录新增 `screen-text.json`（段 ID/起止、引擎、估算时间的显示器、统计、条目：displayID、绝对起止、段内偏移、合并帧数、行）和 `screen-text.md`（按时间排列，每条标显示器，正文放在 ````text 围栏里；没有识别到文字时只写 JSON，与 `transcript.md` 规则一致）。`segment.json` 只加两个可选字段：`screenText`（`status` pending/complete/failed、`attempts`、`startedAt`/`completedAt`、`error`、`stats`、`preview` 前 3 行、`deleteRequested`）和 `screenDeletedAt`；统计含总帧数、分析帧数、关键帧数、条目数、字符数、识别失败数、Vision 耗时、总处理耗时。旧 JSON 照常解码，未设置时不写出，实验脚本读取的既有字段不变。

```text
<root>/YYYY-MM-DD/HHmmss-id8/{segment.json,transcript.md,screen-text.json,screen-text.md}
<root>/screen/YYYY-MM-DD/<uuid>/screen-<displayID>.mp4   # 文字落盘成功后删除，空目录一并删除
```

**并发写安全。** 音频与画面两个队列都在 MainActor 上但有 await 点：ASR 期间持有的旧 `segment.json` 副本会覆盖 OCR 结果。现在 `LifelogStore.complete`/`markFailed`、`closeUnified` 和重试按钮的音频侧写入走 `saveKeepingScreen`（画面字段保留磁盘值），画面侧只用 `update(in:)` 无挂起地“重读→改→原子写”。

**删除与失败。** 顺序：写 `screen-text.json`/`.md` → 标 `complete` 并记 `deleteRequested`（按处理时的开关）→ 只删本段 screen 目录里的 `screen-*.mp4`（system.wav 在段目录，不受影响）→ 标 `screenDeletedAt`。删除失败只记错误，下次启动补删；之后再打开删除开关不会删以前保留的视频。任一视频读不出、或有关键帧识别失败，状态记 `failed`、`attempts`+1、可读错误，视频与旧结果原样保留；启动恢复自动重试 `attempts < 3` 的失败段，**Retry failed transcripts and screen text (all days)** 手动重试不受次数限制。退出不等 OCR：任务被取消，段保持 `pending`，下次启动从头重算（不保存半段结果）。新段在创建时即标 `pending`，所以崩溃留下的段也会在恢复时尝试（缺 moov 的 mp4 会失败并保留）。根切换门禁同时要求画面队列为空，且没有 pending/failed/未完成删除的画面状态。启动时恢复与旧段计数各在主线程遍历一次全部日目录（与原有音频恢复相同方式），历史很长后启动会变慢。

**旧数据不自动处理。** 没有 `screenText` 字段的旧段（本版之前录制）启动时**不**调度、不删除；Settings 在存在这类段时显示 **Convert N earlier screen recordings to text**，用户点击才转换，转换后同样按开关删除视频。

**设置。** Always-on 面板新增 **Delete screen video after text recognition**（`lifelog.screenTextDeletesVideo`，默认开，旧安装缺键视为开）。关闭时仍做 OCR，只保留视频。容量上限 `screenCapacityGB` 仍每秒检查 screen 子根逻辑字节并暂停媒体；新增：因容量暂停后，若删除视频使用量降到上限 90% 以下，自动恢复记录（需记录开关仍开）。状态行显示今日画面文字完成/等待/失败段数。

**Today、选段与汇总。** Today 时间线在媒体行之后显示“画面文字”行：状态、字符/帧数、前 3 行预览，**Show more** 读取 `screen-text.json` 最多 60 行（含时间与显示器），可打开 `screen-text.md`；摘要只读 `segment.json`，在视图 `.task` 中按段列表和 `screenTextRevision` 刷新，不在 body 里读文件。录制详情在视频删除后只给“打开画面文字”，否则两者都给。选段保存 `screenItems` 与 `screenTextFile`，`references.md` 链向 `screen-text.md`，视频仍在时才链 screen 目录。选段纪要和每日汇总把画面文字作为 `[screen <displayID>]` 行与逐字稿按时间交错（T3 仍只在 references.md），提示词说明这是本机 OCR、只表示屏幕可见内容、可能有误、重复只出现一次。长度上限（`ScreenTextEvidence`）：同一次汇总/选段内相同行（忽略空白大小写）只取最早一次；每条 ≤10 行、每行 ≤160 字符；每段 ≤3 000 字符；全部画面证据 ≤40 000 字符；被截断处放一条 `…(more screen text omitted)`。只有画面文字、没有语音的段也会进入汇总并链到 `screen-text.md`；画面待识别的段会推迟前一日的补汇总（与音频 pending 相同）。

**本地视觉模型（后续接入点，本轮未实现）。** `LifelogController` 的 `extractScreenText` 注入点（`LifelogScreenTextJob.Extract`：视频列表 + 段起点 → `ScreenTextExtraction`）即替换/叠加点：可在关键帧上额外生成描述并写入条目，默认关闭开关届时再加，不留死设置。

**资源估计（2026-10-08，M3 Max，合成 1920×1080、2 fps 单显示器，见总仓 `.local/tmp/lifelog-screen-ocr/RECORD.md`）。** 30 分钟少量变化（每分钟新增一行）：3600 帧解码、1800 帧分析、30 个关键帧，总 25.4 s（Vision 13.2 s，其余为解码与指纹），用户态 CPU 约 34 s，测试进程峰值 RSS 约 0.28 GB，合并为 3 条、1 925 字符。最坏情况（全屏文字每秒滚动）：10 分钟 200 个关键帧（每 3 s 一个上限），113 s，约 0.54 s/关键帧，单核满载，峰值 RSS 约 0.48 GB，合并为 64 条、约 10.5 万字符；按比例 30 分钟每显示器约 5.6 分钟，两块屏约 11 分钟，仍快于实时。真实 ScreenCaptureKit 录像在静止时帧更少，解码成本更低；真实桌面文字密度、两屏同时繁忙和长期磁盘/CPU 曲线须在 24 小时实验中实测。

验证：`swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors`（含 `ScreenTextExtractorTests` 真实 H.264 解码/去重/时间映射、`LifelogScreenTextTests`、`UnifiedLifecycleTests` 控制器删除/失败恢复/开关/退出/容量/并发写/旧数据），`python3 Tests/test_ui_localization.py`。真实 Vision 探针（不设变量即跳过，只喂合成视频，源文件不修改，结果写到给定根）：

```sh
MEETING_NOTES_SCREEN_OCR_VIDEO=/abs/synthetic.mp4 MEETING_NOTES_SCREEN_OCR_OUT=/abs/out-root \
  swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors --filter screenTextVisionProbe
```

本节新增文件：`ScreenTextExtractor.swift`、`LifelogScreenText.swift`、`Tests/MeetingNotesTests/ScreenTextExtractorTests.swift`、`Tests/MeetingNotesTests/LifelogScreenTextTests.swift`。改动的 fork 自有文件：`LifelogController.swift`、`LifelogStore.swift`、`LifelogSettings.swift`、`LifelogSettingsView.swift`、`DailyEvidenceTimeline.swift`、`LifelogSelection.swift`、`LifelogDigest.swift`、en/zh-Hans `Localizable.strings`、`UnifiedLifecycleTests.swift`。**未改任何上游文件**（`AppModel.swift`、`UILanguage.swift`、`Models.swift`、`UnifiedCapture.swift` 均未动；生产默认 `extractScreenText` 即 Vision 实现，因此 AppModel 不需要传参）。

## 统一日常记录、Today 与完整 UI 本地化（2026-10-08）

屏幕部分已由上节 MEET-5 替代。本节替代早期 Today 菜单切片的未集成状态，并覆盖下节 MEET-4 中仅麦克风、静音删段、同步退出的旧行为；旧段/独立会议接口仍兼容。用户已正式确认：T3 保留任务标题、状态、请求和最终答复；屏幕范围为所有亮着的显示器。本轮只完成源码与离线验证，未部署，运行中的 24 小时实验仍是原版二进制。

主入口是 **开始记录 / 停止记录**，无需会议标题或预先分类；旧会议在“单独会议（高级）”中保留。`AppModel` 向 `LifelogController` 注入 `UnifiedSegmentCapture`。默认新增设置为 unifiedMedia=true、allDisplays=true、screenCapacityGB=10、t3Enabled=true、t3IncludeText=true，原 enabled（默认 false）和音频留存偏好保留。旧安装缺少新字段时采用上述默认；第一次启用或部署后恢复已启用状态时落 enabledAt。加载设置本身不写 defaults。本轮没有运行新 app，因此未迁移实验偏好。

`DisplayCaptureGate` 在初始启动、重试、唤醒及记录中检查 console session / 亮屏列表。屏幕、系统睡眠、session 暂停各有独立门闩；屏幕唤醒不能清除 session 锁。锁定/熄屏事件同步关闭输出准入和麦克风，再异步等待启动中的 stream、WAV 与视频 writer 收尾；恢复排空旧 generation 后另开段。亮屏列表变化会轮换段。macOS 没有公开稳定的 unlocked 谓词：公开 NSWorkspace session/screen 通知加 `CGSessionCopyCurrentDictionary` 的 console 位，辅以非公开锁位和 distributed lock/unlock 通知；不能将 SCShareableContent 成功当解锁证据，也不能声称漏通知时有系统级锁屏保证。当前桌面只读探针确认 console=true、active 私有键缺失，故不再依赖不存在的 active 键。真实锁屏/多屏热插拔仍须实验后验收。

每个亮着的显示器一个 ScreenCaptureKit stream，只有一个 stream 提供系统混音；单独 AVAudioEngine 采一次麦克风。保留既有系统应用排除和排除本进程音频策略。视频上限边长 1920、2 fps，writer 背压丢帧计数；音频固定 16 kHz 单声道，两轨通过同一 CaptureClock 将源 host timestamp 映射至段起点，在首 buffer 前补齐启动延迟；屏幕首帧时间也由该时钟映射，而非将回调队列延迟当成采集时间。调度、设备/框架时间戳及启动延迟仍须实采测量，不承诺样本级无缝。视频独立于音频静音处理：

```text
<root>/YYYY-MM-DD/HHmmss-id8/{segment.json,microphone.wav,system.wav,transcript.md}
<root>/screen/YYYY-MM-DD/<uuid>/screen-<displayID>.mp4
<root>/t3/activity.json
<root>/selections/<uuid>/{selection.json,transcript.md,references.md,meeting.md,summary.json}
```

`segment.json` 的 screenRelativeFolder/media 保存回看文件、实际首帧/结束、丢帧、gap 与失败信息；源文件收尾后才进入转写。系统音轨的语音同样防止误删静音段；纯静音桌面保留 screen 与 empty 元数据，不触发 ASR。成功后音频按既有留存设置删除，两轨一致，screen 不随之删除。每秒检查 screen 子根逻辑文件字节，达到配置容量暂停两种媒体；不是删除策略，检查周期/缓冲可能少量超额，失败/未转写音频和 T3 占用不计入该 screen 上限。Settings 显示用量和上限。失败保留源文件和可读错误；正常退出由 app delegate 等待媒体及 T3 清理，不等最终 ASR，待处理段下次恢复。切根继续要求关闭并排空在途/失败段。

两条 WAV 都在现有 `FinalTranscriptionEngine` / `TranscriptionLock` 内严格读取和本机引擎处理；旧无系统轨段兼容，OpenAI 在锁内拒绝，未重写 ASR、锁和回退算法。正式会议先等待统一采集收尾才接管设备，停止后恢复日常记录。录制期间 T3 独立运行，显示器暂停不停止任务证据。

T3 consumer 每 60 秒调用用户可配置的绝对 t3ctl 路径（默认 `~/.local/bin/t3ctl`），通过本机公开 session/RPC 只读 observe，没有每分钟 LLM 任务。5 分钟 overlap + source ID/updatedAt/hash upsert，跨页采用最早 observedAt 推进水位；不完整、投影截断、循环游标或未知 schema 不前移水位。仅保留请求和最终答复正文，流式回复只保留状态；正文单条上限 12000 字符，显式 textTruncated，完整文本可打开原 T3 链接。投影每线程 message/run 上限 200/100，冻结候选线程 ≤100，consumer 最多 4 页、总 message/run 各 ≤10000；到达界限明确显示错误，不静默淘汰。缓存持久化并恢复，元数据模式清除缓存正文。未知 schema/损坏缓存不覆盖；服务不可用/超时独立可见并重试，不丢媒体记录。线程状态不推断人的焦点，也不是全量工具活动时间线。

GUI transport 使用显式 PATH、双管道有界读取、70 秒超时；取消发一次 TERM 并给 helper 清理时间，25 秒后仍未退出只强停自身子进程。Exporter observe 的 RPC/签发/撤销各有限时，TERM 走 finally 撤销短期 session，输出不含令牌。签发服务无回应而无法取得 session ID、服务无法撤销或强退时不能保证即时撤销，15 分钟 session TTL 是剩余边界。非 observe 的旧 t3ctl 行为保持兼容。

Today 从缓存合并最近 12 条媒体段、最多 20 条消息和 12 条额外重叠 run，按时间排列并标来源；更多入口打开日期目录 / T3 缓存，旧会议独立可读。屏幕仅回看引用，不做 OCR/视觉模型识别。选段窗口支持标题、起止（≤48 小时）、完整逐字稿、pending/failed 状态，跨边界保留整句，保存新 selection 不改源段。生成纪要复用 `LifelogDigest` 分块/归并，只用已配置的日常 command；Off、Codex 或未配 command 时按钮禁用并说明，不临时转云。command 是否连接本地由用户原配置决定，程序不另设后端。T3/屏幕引用单列在 references.md，仅表示时间重叠。

UI 使用 `UILanguage`（系统默认、简中、English），手选即时更新 SwiftUI locale、显式 Bundle 查找和通知动作；与文稿/转写语言分离。全部 owned 菜单、Settings pane、Today/选段、提示、help/accessibility、状态/alert、日期与容量显示都经 en/zh-Hans 表或所选 locale；保留英文 fallback。品牌、用户正文/标题、模型 ID、命令/路径/协议/存档 raw 值、系统/第三方原始错误不翻译；默认模型提示词和生成文稿不是 UI 语言内容。Apple 权限弹窗/第三方 Sparkle 自有界面由其宿主语言机制控制；本 app 的隐私用途有英中 InfoPlist.strings。`scripts/build-app.sh` 复制 lproj；验证使用独立 Foundation 进程对打包 .app 实际查找，不启动 app。

最终离线验证与源码 SHA256 清单见根 `.local/tmp/lifelog-unified-capture/INTEGRATE-RECORD.md`，覆盖严格 Swift 整包、锁 fixture、T3 Python、已知坏样本和冻结 APFS release 打包。真实权限、菜单视觉/热切语言、多屏锁屏/睡眠、采集时间对齐、设备/磁盘长时故障、24h 资源曲线与真实摘要质量尚未实采验收。原实验 2026-10-08T04:01:18Z 至 2026-10-09T04:01:18Z 不因本轮构建而验收；部署留给实验结束后主线程决定。

## MEET-4 常开模式（2026-10-08，原始麦克风基线）

以下保留原实验与兼容接口合同；统一模式以本节上方的新合同为准。

**Settings → Always-on → Record continuously**，默认关闭。麦克风沿用 Microphone 面板的设备 UID/优先级；建议实验固定 USB 输入并确认它仍连接。此模式只采麦克风，不采系统音频，系统应用排除列表仍仅影响正式会议。
默认根 `~/jieyuexing-universe/.state/opsail/lifelog`，与会议归档、Spool 的相同/父子路径（含可解析符号链接）互斥，文件系统根也拒绝。反向修改会议归档时同样校验。修改常开根前必须先关闭录音并排空：当前段、正在启动、在途转写、内存队列以及磁盘中的 recording/pending/failed 任一存在都拒绝切根并显示提示；旧根元数据读错也拒绝。关闭开关并处理 failed 后才能换根，不搬移或删除历史，不建立历史根注册表。同根设置修改（含可解析符号链接别名）不触发切根或把当前段加入转写队列；拒绝后界面恢复实际根。

- 默认连续静音 180 秒或单段 1800 秒切段，可在该面板调整。分段用新增 `LifelogRecorder` 的 AVAudioEngine 麦克风 tap，在锁内交换 WAV 文件句柄；不改上游 `MicrophoneRecorder`/`SystemAudioRecorder`。正常切段不主动重启引擎，但音频回调、磁盘同步、系统调度/设备驱动可能造成丢帧，**未证明无缝，也没有可保证的间隙上限**。静音判断是既有能量阈值，不是说话人识别；低音量或远场漏检仍须实验核实。高采样率的小缓冲先累积到 100ms 再交能量监测，关闭文件前再检查 WAV 信号，避免回调尾部被当作空段。
- `LifelogController` 独立拥有录音和串行待转写队列；正式会议开始前收尾并释放麦克风，会议录音停止（含启动失败）后恢复。会议暂停期间仍让出，等待会议结束。交接有启动/授权/调度耗时，无硬上界。睡眠收尾，唤醒另开；录音持有现有 `RecordingWakeLock`。第一次 WAV 写入/checkpoint 失败在锁外异步通知控制器（携带段 URL），立即收尾保留已写前缀并标 failed，显示写错与重试状态，30 秒后尝试新段；首错只通知一次，过期段通知不停止新段。异步调度没有实时上界，不承诺故障至收尾期间的音频可恢复。设备变更在 2 秒后重试，启动失败每 30 秒重试；不能保证断开期间有音频，也不补造该时段。
- 正常退出由 `NSApplication.willTerminateNotification` 同步关闭尾段并落 `pending`，不等 ASR；下次启动恢复。强退/崩溃后 `recording` 段先验证本模式固定 PCM WAV 头与偶数字节，再按文件字节修复 header 的长度并重试；坏头、读错、修头失败均保留 WAV 标 failed，修头权限恢复后可手动重试。未持久化到磁盘的音频无法保证。关闭开关收尾后仍处理已排队段；启用设置保留则应用下次启动自动录音。
- 最终转写沿用 `FinalTranscriptionEngine.process` 的跨进程目录锁、SenseVoice/Nemotron 与取消处理。常开调用增加 `onDeviceOnly: true`：即使等待锁时引擎切为 OpenAI，也在锁内拒绝上传；音频留待恢复本地引擎。常开麦克风在该锁内同样使用 throwing 信号检查，读错不能经旧 Bool 检查变成空识别；常开中的 Cocoa 文件读取/POSIX 错误直接抛出，不用 ASR 回退掩盖一次性读错；其他 SenseVoice 模型故障的回退仍走严格检查，且此模式不读不存在的系统轨。会议调用默认参数及旧 WavFile Bool API 行为不变。常开建议 SenseVoice，但不替用户改设置；缺失模型仍可能按既有逻辑下载模型或回退 Nemotron。
- **不调用 MeetingStore**，不产生会议标题、实时预览、逐段摘要、对照翻译、Codex 线程、Tana、rsync、HTTP/Shell hook；只做本地语言判定。常开启用期间不弹新的会议检测通知；正式会议自己的检测/自动停止继续工作。每日摘要的 Codex/command 是用户单独配置的外发边界，会议摘要设置不会自动继承到常开。
- 只有成功读取且验证头部/长度、确认无信号的全静音段才删除目录并增加同日 `day.json` 计数；有信号且 ASR 成功返回空转写才保留 `empty` 元数据，不写空逐字稿，删除音频。成功转写按既有 Storage 音频留存设置（默认删音频）；读取/校验/修头、捕获写入/checkpoint/stop 错误及转写失败保留音频并标 `failed`，不会把通用 fileReadCorruptFile 吞为成功空识别。元数据自身不可写时只能显示错误并保留原文件，不能保证 failed 状态成功落盘。Always-on 的 **Retry failed transcripts (all days)** 手动重试。失败不自动无限重试；pending/recording 在下次启动恢复，队列无并行转写/无自动丢弃上限，积压会增加磁盘占用。采样分别记录 pending、recording、failed。

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
MEET-4 含 R1–R4 修复累计改动的上游 Swift 文件仅 **4 个**：`AppModel.swift`（初始化、会议交接、归档隔离/检测通知门禁）、`SettingsView.swift`（Always-on 入口）、`TranscriptionEngine.swift`（本地处理约束与严格读取）、`WavFile.swift`（新增常开 throwing 校验/安全修头，旧会议 API 兼容）；既有转写锁 fixture 增加 local-only 与严格读错传播断言。同步上游时重点核对录音 start/stop 的 await 边界、willTerminate 通知、FinalTranscriptionEngine 锁内的引擎分派与 strictMicrophone 路径、WavFile 固定 PCM 头合同及常开首错/根切换门禁；不把新摘要/归档/翻译路径接到常开段。MEET-3 语言/翻译与锁保留。

实验专用脚本和完整操作合同在总仓 `.local/tmp/lifelog-24h/RUNBOOK.md`（临时、可重建；尚未启动 24h 实验）。严格测试、红绿回归、克隆构建与本地合成模型验证记录见同目录 `RECORD.md`。这些证明代码/fixture/构建边界，**不代表 USB 实录、24h 持续运行、零间隙、中文准确率或真实每日汇总质量验收**。

R1–R4 修复回执见总仓 `.local/tmp/lifelog-24h/FIXES.md`；原 `review/` 证据只读保留。脚本无 PID 时应用 CPU/RSS/累计 CPU 留空并记 process_absent；报告也兼容排除旧 CSV 无 PID 的零值，单列有 PID、缺席、探查失败样本及点跨度/采样间隔，磁盘独立统计。上述跨度不是可证明的持续停机或连续运行时长。
