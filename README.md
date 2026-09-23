# DayWeather

DayWeather 是一个面向 Insta360 GO Ultra 的 Flutter Android 原型：将影像、带时间戳的音频转写和情绪分析组织成一天的“天气曲线”，并提供精彩瞬间回放和 Mic Pro 状态卡分享。

完整的应用介绍、使用流程、安装说明、AI 配置、权限说明和常见问题见 [使用与介绍文档](使用与介绍文档.md)。已构建的开发者签名 APK 位于 `D:\Project\BoldMaker\outputs\dayweather-apks`。

## 已实现

- 使用 `shadcn_flutter` 搭建天气、设备、我的三页主界面，以及明暗主题和中英文切换。
- 应用启动图标、天气/事件/设备等少数重点视觉位置和 Mic Pro 状态卡主图使用 `assets/icon.png`；导航栏、操作按钮和通用设置项保持文字与状态动画，避免重复堆叠图标。源文件来自项目外的 `D:\Project\BoldMaker\icon\icon.png`，不会把 API Key 写入资源。
- Android 原生桥接 Insta360 Android SDK 2.1.5：扫描时只保留 GO 系列、连接设备、预览视频流、读取媒体、按原始 PTS 抽取音频片段；连接流程会把 BLE、相机 Wi‑Fi、SDK Wi‑Fi、首帧和失败原因实时推送到 Flutter。
- 设备页只展示真实扫描到的 GO 系列设备；没有真实设备时只显示空状态，不生成演示设备或伪造时间线。
- Qwen 接入分层放在 `lib/services/qwen_service.dart`：ASR 使用支持 Base64 同步调用的 `qwen3-asr-flash`，情绪分析使用 `qwen3.8-max`，视频理解使用 `qwen3.8-omni-flash`。手动导入或离线分析会按 **3 分钟窗口**从原片首尾完整覆盖（`ceil(时长 / 3min)` 均分，末端自动收窄），抽取带原片偏移的真实 JPEG 关键帧和音频块；不会只分析视频开头。每个窗口的 `startMs/endMs` 会一直保留到转写、视频事件和精彩瞬间结果。
- 精彩瞬间会在分析结束后**真实剪裁**成独立 MP4（原生 `MediaExtractor + MediaMuxer`，视频轨与音频轨同时裁剪，每段 60 秒），播放器优先加载剪裁产物；不是"把整段原片放上去"，也不只是存时间指针。
- Mic Pro 状态卡按 240×208 像素生成，天气图形用**矢量绘制**（六色墨水屏无法显示彩色 emoji，矢量图形在 6 色量化后仍可辨识）；同时提供 On-device 的 4bpp 索引图（24960 B）与 240×240 六色 PNG 转换，以及基于 TRC 协议的 BLE 直连推送实现。
- 连接成功后自动检查并同步 GO Ultra 最新视频，保留“立即同步”和手机手动导入/分析入口。实时链路会持续送入 Qwen ASR，并从 SDK 已渲染的 GO Ultra 预览流每 20 秒采样一帧；只在连续 3 分钟窗口结束后联合分析音频转写和实时画面。跨窗口末尾的 15 秒转写/画面会暂存到下一窗口，连接结束时再冲刷最后一个未完成窗口；预览帧暂时不可用时才回退到最近同步媒体。只有明显情绪变化或视频事件才写入天气曲线/事件记录。
- 真实拍摄时间与播放器偏移分开保存：播放器使用媒体相对偏移定位，界面和历史记录优先使用 GO Ultra SDK 创建时间、媒体元数据或 GO Ultra 文件名中的拍摄时间；读取不到合法拍摄时间时显示相对偏移，不用当前时间伪造。
- 分析结果以 JSON 形式持久化到应用本地 `SharedPreferences`，保留最近 20 次真实分析；首页“历史分析”可以恢复天气曲线、带时间戳转写对应的精彩瞬间和视频事件。GO Ultra 实时 ASR 的每个情绪节点也会持续更新并写入实时会话记录。

## 运行

```powershell
flutter pub get
flutter run -d <device-id>
```

真实分析必须配置百炼 API Key。按照 `OpenAI兼容接口连接文档.md`，本项目默认使用已验证的共享北京端点 `https://dashscope.aliyuncs.com/compatible-mode/v1`；推荐把本机密钥放在被忽略的 `.dart-define.local.json` 中，然后运行：

```powershell
flutter run -d <device-id> --dart-define-from-file=.dart-define.local.json
```

也可以直接使用 `--dart-define=DASHSCOPE_API_KEY=你的Key`。当前业务空间配置在 `lib/services/qwen_service.dart`，包含配置 ID `7379080`、北京兼容接口和 DashScope 接口地址。不要把真实 Key 写进可提交 Dart 文件、提交到 Git 或上传到 GitHub；`.gitignore` 已覆盖 `.env`、`.dart-define.local.json`、本地 secrets 文件和 Android 签名配置。

## 调试设备约定

- 调试时优先使用当前在线的 Android 真机，并先用 `adb devices -l` 确认状态。
- 真机不可用或掉线时，再回退到 Pixel 9 Pro 模拟器 `emulator-5554`。

## 已确认的测试设备

- 用户的 GO Ultra 设备名为 **`GO Ultra 5GQGMW`**，这是唯一属于本项目调试的真机相机；扫描列表中的其他 GO 设备（如 `GO 3S *`、`GO Ultra 5AMYUS`、`GO Ultra 5X848R` 等）都不是用户的设备，不要连接、不要同步它们的媒体。

## Android / GO Ultra

Insta360 SDK 的私有 Maven 仓库配置位于 `android/build.gradle.kts`，应用最低 Android API 为 29。首次连接真实 GO Ultra 时，需要授予网络和媒体权限；平板先在 Android 系统 Wi‑Fi 设置中加入 GO Ultra 相机热点，应用随后将当前 Wi‑Fi 的 `Network.handle` 交给官方 SDK 的 `ConnectType.WIFI`，并绑定预览流。AI 请求通过独立的已验证移动数据网络发送，避免相机 Wi‑Fi 无互联网造成冲突。

设备页的“连接当前相机 Wi‑Fi”是主连接入口；BLE 扫描仅用于确认设备身份，不会自动触发 BLE 握手或要求 Action Pod 授权。真机或模拟器均只使用真实数据，不使用演示数据。

## Mic Pro 说明

官方公开使用路径是将自定义壁纸导入 Mic Pro；本项目因此生成 240×208 状态卡并打开系统分享面板，用户可选择 Insta360 App 完成导入。若后续获得官方直接写入接口，只需要替换 `MicProService` 的分享实现，UI 和图片生成逻辑可以复用。

## 产物与验证

- Debug APK：`build/app/outputs/flutter-apk/app-debug.apk`
- `flutter analyze`：通过
- `flutter test`：通过
- `:app:assembleDebug`：通过
- 当前验证约定：只把真实 HTTP 成功结果写入天气曲线、事件总结和精彩回放；接口失败时应用显示错误，不伪造分析结果。共享端点的模型连通性应以本地 `OpenAI兼容接口连接文档.md` 中的 API Key 为准。
- 本次模拟器实测使用 `视频素材` 中第一条 10 分 23 秒实拍视频的完整时长压缩验证副本：程序拆成 11 个窗口并从 `00:00:00` 覆盖到结尾，视频理解、ASR 和 `qwen3.8-max` 均返回真实结果；天气曲线显示全片窗口，视频事件和精彩回放可回到原片偏移。拍摄时间从 `2026-09-22 15:15:22` 元数据/文件名得到并显示在素材卡和历史记录中。
- 模拟器设置页的“测试 AI 连接”实测显示 `连接成功：OK`。验证过程中没有写入或提交 API Key；`build/` 下的 APK、验证切片和截图均为本地忽略产物。

## 相关资料

- [Insta360 GO Ultra Android SDK 2.1.5](../Reference/Android-SDK-2.1.5)
- [Mic Pro 自定义壁纸说明](https://onlinemanual.insta360.com/micpro/zh-cn/camera/using-app/e-ink-display)
- [阿里云百炼 OpenAI 兼容 Chat API](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions)

