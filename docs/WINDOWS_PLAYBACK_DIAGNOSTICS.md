# Windows 播放画面异常排查

适用：用户报告 RTX 4050 Mobile 偶发疑似撕裂。当前仅完成源码核查，尚无受影响设备日志或可复现的最终屏幕录制，不能确认根因。

## 2026-10-15 更新：呈现反馈补齐

用户确认硬解下撕裂仍然存在。依据 vendored 的 libmpv `render.h`（与上游一致，非过时资料）补上了一处明确的缺失：

- `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`（默认启用）说明 `mpv_render_context_render()` 会阻塞到目标显示时刻，`video-timing-offset` 控制提前量；这正是 render API 下的帧步调机制。
- `mpv_render_context_report_swap()` 文档要求：呈现时机由宿主/外部控制时，宿主应在呈现完成后上报，mpv 才能把帧步调锚定在真实呈现上。
- 本集成中真实呈现由 Flutter 合成器通过 `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` 完成，此前从无任何 swap 上报——mpv 只能按渲染完成时间估计呈现节奏，帧输出相对扫描线漂移，在部分 GPU/驱动组合上表现为撕裂。
- 现已在 H/W 渲染路径的 `Render()` 完成后调用 `mpv_render_context_report_swap()`（`video_output.cc`）。已通过 Windows MSVC 实际编译验证。效果仍需用户在受影响设备上确认；若撕裂依旧，下一步候选是把 `MISC_SHARED` 升级为 keyed mutex/fence 协议（需与 Flutter 引擎的纹理消费方式配合，属引擎级改动）。

## 已确认的实现

- `third_party/media_kit_video/windows/video_output.cc` 向 libmpv 设置 `video-sync=audio` 与 `video-timing-offset=0`。
- Windows 硬件纹理路径经过 ANGLE/D3D11 共享纹理。`angle_surface_manager.cc` 的 Draw/Read 使用 CPU 互斥，Draw 完成调用 `glFinish`；Read 调用 `CopyResource` 和 `Flush`。
- 这些操作不等于显示器已呈现该帧。`Flush` 是提交 GPU 工作，CPU 互斥也不能证明 Flutter 引擎 GPU 采样已经结束。
- 当前插件没有与引擎消费完成对应的共享纹理 fence/keyed-mutex 协议。Resize/Create 的同步范围也值得针对复现进一步检查。这些是时序风险候选，尚未证明会产生本次故障。
- libmpv render API 存在 `REPEAT`、`BLOCK_VSYNC` 和 `report_swap`，不能笼统认定其不支持显示同步；当前集成没有完整的真实呈现反馈链。因此本次不强制切换 `display-resample` 或开启插帧。

播放器信息页现在展示可获取的 mpv 版本、输出、请求的 video-sync/interpolation、实际 display-sync 状态、音视频偏差和掉帧计数。`hwdec-current` 缺失时显示未知；解码请求不等于实际硬解，视频输出名称也不能单独证明 Flutter 最终纹理后端。

## 在受影响设备上区分现象

使用固定本地匀速平移片段，记录片源帧率、屏幕刷新率、窗口/全屏、解码模式与超分设置。每次只改一个可恢复的应用设置。

- 横向断裂、同一屏幕内上下部分来自不同视频帧，才支持撕裂判断。
- 整帧保持完整但运动步幅不均匀，更接近帧节奏问题（judder）。
- 局部闪烁、花屏或窗口调整时异常还需区分纹理生命周期与解码问题。

以最终屏幕的可靠录制与相机画面互相对照。播放器截图只取得 mpv 视频帧，不能证明桌面合成输出是否撕裂；录屏路径也可能改变呈现行为，因此单一记录不足以下结论。

## 收集与对照

1. 记录 Windows、NVIDIA/集显驱动、显示器刷新率及独显/混合显卡设置；保存播放器信息页。不要收集账号凭据或网络密码。
2. 分别观察窗口与全屏，记录异常是否随窗口尺寸、切换屏幕或刷新率改变。
3. 关闭超分进行单项对照；硬件/软件解码对照必须核对实际 `hwdec-current`，软件纹理路径也不能预设为不存在竞态。
4. 必要时使用 Flutter frame timings 和 PresentMon/ETW 作只读观测，关联异常时刻与掉帧、呈现间隔。未支持的 mpv 属性记为未知。
5. 驱动垂直同步设置先保留原始基线；如需对照，仅改该应用的可撤销设置，不修改全局设置。

出现稳定复现并获得日志后，再决定是否调整共享纹理同步或呈现反馈。此次未修改 Windows 原生渲染和默认同步策略。
