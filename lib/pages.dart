import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:video_player/video_player.dart';

import 'brand_icon.dart';
import 'main.dart' show AppController, brandBlue, brandCoral, ink;
import 'models.dart';
import 'services/qwen_service.dart';

// Visual-only helpers shared across the redesigned pages.
EdgeInsets _pageInsets(
  BuildContext context, {
  double top = 20,
  double bottom = 32,
  bool safeTop = true,
  bool safeBottom = true,
}) {
  final media = MediaQuery.of(context);
  return EdgeInsets.fromLTRB(
    20,
    top + (safeTop ? media.padding.top : 0),
    20,
    bottom + (safeBottom ? media.padding.bottom : 0),
  );
}

Card _surfaceCard(
  BuildContext context, {
  required Widget child,
  EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  Color? fillColor,
  BorderRadiusGeometry? borderRadius,
  Clip clipBehavior = Clip.none,
  bool outlined = true,
}) {
  final colors = Theme.of(context).colorScheme;
  final isDark = colors.brightness == material.Brightness.dark;
  return Card(
    padding: padding,
    filled: true,
    fillColor: fillColor ?? colors.card,
    borderRadius: borderRadius ?? BorderRadius.circular(18),
    borderColor: outlined ? colors.border.withValues(alpha: 0.6) : null,
    borderWidth: outlined ? 1 : null,
    boxShadow: outlined
        ? [
            BoxShadow(
              color: ink.withValues(alpha: isDark ? 0.18 : 0.05),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ]
        : null,
    clipBehavior: clipBehavior,
    child: child,
  );
}

material.IconData _weatherGlyph(WeatherKind kind) {
  switch (kind) {
    case WeatherKind.sunny:
      return material.Icons.wb_sunny_rounded;
    case WeatherKind.cloudy:
      return material.Icons.cloud_rounded;
    case WeatherKind.rain:
      return material.Icons.water_drop_rounded;
    case WeatherKind.storm:
      return material.Icons.thunderstorm_rounded;
    case WeatherKind.rainbow:
      return material.Icons.auto_awesome_rounded;
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    this.color,
    this.size = 44,
    this.iconSize = 20,
    this.radius = 14,
  });

  final material.IconData icon;
  final Color? color;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? brandBlue;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tint.withValues(alpha: 0.18)),
      ),
      child: Center(
        child: material.Icon(icon, size: iconSize, color: tint),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [brandBlue, Color(0xFF7A93FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: brandBlue.withValues(alpha: 0.28),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: const Center(child: BrandIcon(size: 22)),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) {
    return material.Icon(
      material.Icons.chevron_right_rounded,
      size: 20,
      color: Theme.of(
        context,
      ).colorScheme.mutedForeground.withValues(alpha: 0.8),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final material.IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = colors.mutedForeground;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        material.Icon(icon, size: 13, color: tint),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: tint,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final node = controller.selectedNode;
    return SingleChildScrollView(
      padding: _pageInsets(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            eyebrow: '23J / DAYWEATHER',
            title: controller.text('今天的影像天气', 'Today in weather'),
            subtitle: controller.text(
              '把声音、画面和时间线放在同一张天气图里。',
              'A weather map for sound, scenes, and time.',
            ),
            trailing: const _BrandMark(),
          ),
          const SizedBox(height: 20),
          if (node != null)
            ForecastCard(controller: controller, node: node)
          else
            EmptyState(
              icon: material.Icons.wb_cloudy_rounded,
              title: controller.text(
                '等待真实天气心情',
                'Waiting for real mood weather',
              ),
              subtitle: controller.text(
                '连接 GO Ultra 并导入含音频的视频后，这里才会显示模型结果。',
                'Connect GO Ultra and import a video with audio to show model results.',
              ),
            ),
          const SizedBox(height: 26),
          SectionTitle(
            title: controller.text('影像氛围曲线', 'Atmosphere curve'),
            trailing: SecondaryBadge(
              child: Text(controller.text('可回溯', 'Traceable')),
            ),
          ),
          const SizedBox(height: 10),
          _surfaceCard(
            context,
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
            child: controller.timeline.isEmpty
                ? EmptyState(
                    bare: true,
                    icon: material.Icons.insights_rounded,
                    title: controller.text(
                      '暂无真实分析结果',
                      'No real analysis result yet',
                    ),
                    subtitle: controller.text(
                      '导入含音频的视频并完成分析后，氛围曲线会出现在这里。',
                      'Import a video with audio and run analysis to plot the curve here.',
                    ),
                  )
                : Column(
                    children: [
                      MoodCurve(
                        nodes: controller.timeline,
                        selectedIndex: controller.selectedNodeIndex,
                        onSelected: (index) {
                          controller.selectNode(index);
                          if (index >= 0 &&
                              index < controller.timeline.length) {
                            showNodeSheet(
                              context,
                              controller,
                              controller.timeline[index],
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (
                            var index = 0;
                            index < controller.timeline.length;
                            index++
                          )
                            GestureDetector(
                              onTap: () {
                                controller.selectNode(index);
                                showNodeSheet(
                                  context,
                                  controller,
                                  controller.timeline[index],
                                );
                              },
                              child: _NodePill(
                                node: controller.timeline[index],
                                selected: index == controller.selectedNodeIndex,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 26),
          SectionTitle(
            title: controller.text('精彩瞬间', 'Highlights'),
            trailing: controller.highlights.isEmpty
                ? null
                : TextButtonLike(
                    label: controller.text('查看全部', 'See all'),
                    onPressed: () => showHighlightsSheet(context, controller),
                  ),
          ),
          const SizedBox(height: 10),
          if (controller.highlights.isEmpty)
            EmptyState(
              icon: material.Icons.movie_filter_rounded,
              title: controller.text('暂无精彩瞬间', 'No highlights yet'),
              subtitle: controller.text(
                '模型分析完成后，剧烈情绪变化才会出现在这里。',
                'Highlights appear after the models find real mood changes.',
              ),
            )
          else
            for (final clip in controller.highlights.take(3)) ...[
              HighlightCard(clip: clip, controller: controller),
              const SizedBox(height: 12),
            ],
          if (controller.videoEvents.isNotEmpty) ...[
            const SizedBox(height: 18),
            SectionTitle(
              title: controller.text('视频事件', 'Video events'),
              trailing: SecondaryBadge(
                child: Text('${controller.videoEvents.length}'),
              ),
            ),
            const SizedBox(height: 10),
            for (final event in controller.videoEvents.take(8)) ...[
              VideoEventCard(event: event, controller: controller),
              const SizedBox(height: 10),
            ],
          ],
          if (controller.analysisHistory.isNotEmpty) ...[
            const SizedBox(height: 18),
            SectionTitle(
              title: controller.text('历史分析', 'Analysis history'),
              trailing: SecondaryBadge(
                child: Text('${controller.analysisHistory.length}'),
              ),
            ),
            const SizedBox(height: 10),
            for (final entry in controller.analysisHistory.take(5)) ...[
              HistoryCard(entry: entry, controller: controller),
              const SizedBox(height: 10),
            ],
          ],
          const SizedBox(height: 18),
          PrivacyNotice(
            text: controller.text(
              '天气图表达的是影像氛围趋势，不是心理或医疗诊断。',
              'Weather labels describe video atmosphere, not psychology or medical conditions.',
            ),
          ),
          const SizedBox(height: 16),
          SourceControlCard(controller: controller),
        ],
      ),
    );
  }
}

/// Lists video files found on the device so analysis can start without relying on
/// the system file picker, which some vendor ROMs do not expose to Flutter.
void showLocalVideoSheet(BuildContext context, AppController controller) {
  material.showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.78,
            ),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.border,
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  controller.text('选择设备上的视频', 'Pick a video on this device'),
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  controller.text(
                    '扫描 Movies / DCIM / Download 等目录',
                    'Scanning Movies, DCIM and Download folders',
                  ),
                  style: TextStyle(color: colors.mutedForeground, fontSize: 12),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlineButton(
                    onPressed: () async {
                      final path = await FilePicker.platform.pickFiles(
                        type: FileType.video,
                        allowMultiple: false,
                      );
                      final picked = path?.files.single.path;
                      if (picked == null) return;
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                      await controller.importVideoPath(picked);
                    },
                    leading: const material.Icon(
                      material.Icons.folder_open_rounded,
                      size: 16,
                    ),
                    child: Text(
                      controller.text('打开系统文件选择器', 'Open the system picker'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: FutureBuilder<List<String>>(
                    future: controller.discoverImportableVideos(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 30),
                          child: Center(
                            child: material.CircularProgressIndicator(),
                          ),
                        );
                      }
                      final files = snapshot.data!;
                      if (files.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            controller.text('没有找到视频文件', 'No video files found'),
                            style: TextStyle(color: colors.mutedForeground),
                          ),
                        );
                      }
                      return ListView.separated(
                        shrinkWrap: true,
                        itemCount: files.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final filePath = files[index];
                          final name = filePath.split('/').last;
                          return material.InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () async {
                              Navigator.of(sheetContext).pop();
                              await controller.importVideoPath(filePath);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: colors.card,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: colors.border.withValues(alpha: 0.65),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const _IconBadge(
                                    icon: material.Icons.movie_rounded,
                                    color: brandBlue,
                                    size: 38,
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  material.Icon(
                                    material.Icons.chevron_right_rounded,
                                    color: colors.mutedForeground,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Lets the user pick which clip on the camera card to download and analyze,
/// instead of silently analyzing whichever video happens to be newest.
void showCameraVideoSheet(BuildContext context, AppController controller) {
  controller.loadCameraVideos();
  material.showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final videos = controller.cameraVideos;
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.78,
            ),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.border,
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const _IconBadge(
                      icon: material.Icons.video_library_rounded,
                      color: brandBlue,
                      size: 40,
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            controller.text('选择素材', 'Pick a clip'),
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            controller.text(
                              '相机存储卡上的视频',
                              'Videos stored on the camera card',
                            ),
                            style: TextStyle(
                              color: colors.mutedForeground,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GhostButton(
                      density: ButtonDensity.dense,
                      onPressed: controller.loadingCameraVideos
                          ? null
                          : controller.loadCameraVideos,
                      child: Text(controller.text('刷新', 'Refresh')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (controller.loadingCameraVideos)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 34),
                    child: Center(child: material.CircularProgressIndicator()),
                  )
                else if (controller.cameraVideoError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 26),
                    child: Text(
                      controller.cameraVideoError!,
                      style: const TextStyle(color: brandCoral, fontSize: 13),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: videos.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final video = videos[index];
                        final isCurrent = controller.sourceName == video.name;
                        return material.InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: controller.isAnalyzing
                              ? null
                              : () {
                                  Navigator.of(sheetContext).pop();
                                  controller.analyzeCameraVideo(video);
                                },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? brandBlue.withValues(alpha: 0.08)
                                  : colors.card,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isCurrent
                                    ? brandBlue.withValues(alpha: 0.35)
                                    : colors.border.withValues(alpha: 0.65),
                              ),
                            ),
                            child: Row(
                              children: [
                                _IconBadge(
                                  icon: material.Icons.movie_rounded,
                                  color: brandBlue,
                                  size: 42,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        video.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        [
                                          formatDuration(video.durationMs),
                                          if (video.creationTimeMs != null)
                                            formatTimestamp(
                                              video.creationTimeMs!,
                                            ),
                                          if (video.sizeBytes != null)
                                            '${(video.sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB',
                                        ].join(' · '),
                                        style: TextStyle(
                                          color: colors.mutedForeground,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                material.Icon(
                                  material.Icons.chevron_right_rounded,
                                  color: colors.mutedForeground,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  controller.text(
                    '选择后会从 GO Ultra 下载该视频，并按 3 分钟窗口完成分析。',
                    'The clip is downloaded from GO Ultra and analyzed in 3-minute windows.',
                  ),
                  style: TextStyle(
                    color: colors.mutedForeground,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class SourceControlCard extends StatelessWidget {
  const SourceControlCard({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasSource = controller.sourcePath != null;
    const activeGreen = Color(0xFF36A269);
    return _surfaceCard(
      context,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconBadge(
                icon: material.Icons.auto_awesome_rounded,
                color: brandBlue,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.text('真实素材分析', 'Real media analysis'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hasSource
                          ? controller.sourceName
                          : controller.text(
                              '尚未导入 GO Ultra 视频',
                              'No GO Ultra video imported',
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.mutedForeground,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SecondaryBadge(
                child: Text(controller.text('不造数据', 'NO MOCK DATA')),
              ),
            ],
          ),
          if (controller.mediaInfo != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.muted.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  material.Icon(
                    material.Icons.videocam_rounded,
                    size: 15,
                    color: colors.mutedForeground,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      controller.sourceRecordedAtMs == null
                          ? controller.text(
                              '时长 ${formatDuration(controller.mediaInfo!.durationMs)} · 未读取到拍摄时间',
                              'Duration ${formatDuration(controller.mediaInfo!.durationMs)} · recording time unavailable',
                            )
                          : controller.text(
                              '时长 ${formatDuration(controller.mediaInfo!.durationMs)} · 拍摄 ${formatTimestamp(controller.sourceRecordedAtMs!)}',
                              'Duration ${formatDuration(controller.mediaInfo!.durationMs)} · recorded ${formatTimestamp(controller.sourceRecordedAtMs!)}',
                            ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.mutedForeground,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            _sourceStatusMessage(controller),
            style: TextStyle(
              color: controller.analysisStage == AnalysisStage.failed
                  ? brandCoral
                  : colors.foreground,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: controller.connectionIsActive
                  ? activeGreen.withValues(alpha: 0.12)
                  : colors.muted.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: controller.connectionIsActive
                    ? activeGreen.withValues(alpha: 0.24)
                    : colors.border.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: controller.connectionStage.isBusy
                      ? const SizedBox(
                          key: ValueKey('sync-spinner'),
                          width: 15,
                          height: 15,
                          child: material.CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : Container(
                          key: const ValueKey('connection-dot'),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: controller.connectionIsActive
                                ? activeGreen
                                : colors.mutedForeground.withValues(
                                    alpha: 0.45,
                                  ),
                            shape: BoxShape.circle,
                          ),
                        ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    controller.connectionStatus,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (controller.connectionIsActive)
                  PrimaryBadge(
                    child: Text(controller.text('自动同步', 'AUTO SYNC')),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              material.Icon(
                material.Icons.sync_rounded,
                size: 13,
                color: colors.mutedForeground,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  controller.syncStatus,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.mutedForeground, fontSize: 11),
                ),
              ),
            ],
          ),
          if (controller.lastError != null &&
              controller.connectionStage == DeviceConnectionStage.failed) ...[
            const SizedBox(height: 8),
            Text(
              controller.lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: brandCoral,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
          if (controller.isAnalyzing) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: material.LinearProgressIndicator(
                value: controller.analysisProgress,
                minHeight: 5,
                color: brandBlue,
                backgroundColor: colors.muted,
              ),
            ),
          ],
          if (controller.lastError != null &&
              controller.analysisStage == AnalysisStage.failed) ...[
            const SizedBox(height: 8),
            Text(
              controller.lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: brandCoral,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlineButton(
                  onPressed: controller.isAnalyzing
                      ? null
                      : () => showLocalVideoSheet(context, controller),
                  leading: const material.Icon(
                    material.Icons.upload_file_rounded,
                    size: 16,
                  ),
                  child: Text(controller.text('导入视频', 'Import video')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  onPressed: hasSource && !controller.isAnalyzing
                      ? controller.startAnalysis
                      : null,
                  leading: const material.Icon(
                    material.Icons.bolt_rounded,
                    size: 16,
                  ),
                  child: Text(controller.text('开始分析', 'Analyze')),
                ),
              ),
            ],
          ),
          if (controller.connectionIsActive) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                onPressed: controller.isAnalyzing
                    ? null
                    : controller.toggleRecording,
                leading: material.Icon(
                  controller.recordingActive
                      ? material.Icons.stop_rounded
                      : material.Icons.fiber_manual_record_rounded,
                  size: 16,
                  color: controller.recordingActive ? brandCoral : null,
                ),
                child: Text(
                  controller.recordingActive
                      ? controller.text('停止录像', 'Stop recording')
                      : controller.text('开始录像', 'Start recording'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: controller.recordingActive
                        ? brandCoral
                        : colors.mutedForeground.withValues(alpha: 0.4),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    controller.recordingStatus,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlineButton(
                onPressed: controller.isAnalyzing
                    ? null
                    : () => showCameraVideoSheet(context, controller),
                leading: const material.Icon(
                  material.Icons.video_library_rounded,
                  size: 16,
                ),
                child: Text(
                  controller.text(
                    '从 GO Ultra 选择素材',
                    'Pick a clip from GO Ultra',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlineButton(
                    onPressed: controller.syncingLatestMedia
                        ? null
                        : () => controller.syncLatestMedia(),
                    leading: controller.syncingLatestMedia
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: material.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const material.Icon(
                            material.Icons.download_rounded,
                            size: 16,
                          ),
                    child: Text(controller.text('立即同步', 'Sync now')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SecondaryBadge(
                    child: Text(
                      controller.autoSyncEnabled
                          ? controller.text('每 3 分钟检查', 'Checks every 3 min')
                          : controller.text('自动同步关闭', 'Auto sync off'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class MoodCurvePainter extends CustomPainter {
  MoodCurvePainter({
    required this.nodes,
    required this.selectedIndex,
    required this.colors,
  });

  final List<WeatherNode> nodes;
  final int selectedIndex;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;
    final chartRect = Rect.fromLTWH(
      12,
      12,
      math.max(0.0, size.width - 24),
      math.max(0.0, size.height - 46),
    );
    final gridPaint = Paint()
      ..color = colors.border.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    for (var index = 0; index < 4; index++) {
      final y = chartRect.top + chartRect.height * index / 3;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
    }
    final values = nodes
        .map((node) => node.intensity.toDouble() / 100)
        .toList();
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x =
          chartRect.left +
          chartRect.width * (index / math.max(1, values.length - 1));
      final y = chartRect.bottom - chartRect.height * values[index];
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        final previousX =
            chartRect.left +
            chartRect.width * ((index - 1) / math.max(1, values.length - 1));
        final previousY =
            chartRect.bottom - chartRect.height * values[index - 1];
        final controlX = (previousX + x) / 2;
        path.cubicTo(controlX, previousY, controlX, y, x, y);
      }
    }
    final fillPath = Path.from(path)
      ..lineTo(chartRect.right, chartRect.bottom)
      ..lineTo(chartRect.left, chartRect.bottom)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          colors: [
            brandBlue.withValues(alpha: 0.26),
            brandBlue.withValues(alpha: 0.0),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(chartRect),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = brandBlue.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = brandBlue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round,
    );
    for (var index = 0; index < values.length; index++) {
      final x =
          chartRect.left +
          chartRect.width * (index / math.max(1, values.length - 1));
      final y = chartRect.bottom - chartRect.height * values[index];
      final selected = index == selectedIndex;
      final color = Color(nodes[index].kind.colorValue);
      if (selected) {
        canvas.drawCircle(
          Offset(x, y),
          12,
          Paint()..color = brandBlue.withValues(alpha: 0.16),
        );
      }
      canvas.drawCircle(
        Offset(x, y),
        selected ? 6.5 : 4.5,
        Paint()..color = colors.card,
      );
      canvas.drawCircle(
        Offset(x, y),
        selected ? 5 : 3.4,
        Paint()..color = color,
      );
      final showLabel =
          values.length <= 6 ||
          index == 0 ||
          index == values.length - 1 ||
          selected ||
          index.isEven;
      if (!showLabel) continue;
      final timePainter = TextPainter(
        text: TextSpan(
          text: nodes[index].startLabel.substring(0, 5),
          style: TextStyle(
            color: selected ? brandBlue : colors.mutedForeground,
            fontSize: 9,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      timePainter.paint(
        canvas,
        Offset(x - timePainter.width / 2, chartRect.bottom + 14),
      );
    }
  }

  @override
  bool shouldRepaint(covariant MoodCurvePainter oldDelegate) =>
      oldDelegate.nodes != nodes ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.colors != colors;
}

class _PipelineRow extends StatelessWidget {
  const _PipelineRow({
    required this.label,
    required this.value,
    required this.active,
  });

  final String label;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = active ? const Color(0xFF36A269) : colors.mutedForeground;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: tint,
              shape: BoxShape.circle,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: tint.withValues(alpha: 0.4),
                        blurRadius: 6,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: TextStyle(
                color: colors.mutedForeground,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              active ? 'CONFIGURED' : 'WAITING',
              style: TextStyle(
                color: tint,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void showNodeSheet(
  BuildContext context,
  AppController controller,
  WeatherNode node,
) {
  material.showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => NodeDetailSheet(controller: controller, node: node),
  );
}

void showClipSheet(
  BuildContext context,
  AppController controller,
  HighlightClip clip,
) {
  material.showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => ClipDetailSheet(controller: controller, clip: clip),
  );
}

void showHighlightsSheet(BuildContext context, AppController controller) {
  material.showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return SafeArea(
        child: Container(
          height: MediaQuery.sizeOf(context).height * 0.78,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.border,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const _IconBadge(
                    icon: material.Icons.movie_filter_rounded,
                    color: brandBlue,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      controller.text('全部精彩瞬间', 'All highlights'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  SecondaryBadge(
                    child: Text('${controller.highlights.length}'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: controller.highlights.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) => HighlightCard(
                    clip: controller.highlights[index],
                    controller: controller,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class NodeDetailSheet extends StatelessWidget {
  const NodeDetailSheet({
    required this.controller,
    required this.node,
    super.key,
  });

  final AppController controller;
  final WeatherNode node;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.border,
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                WeatherIcon(kind: node.kind, size: 52),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.kind.chineseName,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          material.Icon(
                            material.Icons.schedule_rounded,
                            size: 13,
                            color: colors.mutedForeground,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            node.timeRange,
                            style: TextStyle(
                              color: colors.mutedForeground,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                PrimaryBadge(
                  child: Text('${(node.confidence * 100).round()}%'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _surfaceCard(
              context,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.text('影像氛围', 'Atmosphere'),
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    node.mood,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    controller.text('依据', 'Evidence'),
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final item in node.evidence)
                        SecondaryBadge(child: Text(item)),
                    ],
                  ),
                  if (node.visualSummary != null &&
                      node.visualSummary!.trim().isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      controller.text('画面事件概述', 'Visual event summary'),
                      style: TextStyle(
                        color: colors.mutedForeground,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      node.visualSummary!,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              controller.text('带时间戳转写', 'Timestamped transcript'),
              style: TextStyle(
                color: colors.mutedForeground,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: colors.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 3,
                    height: 34,
                    decoration: BoxDecoration(
                      color: brandBlue.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      '“${node.transcript}”',
                      style: const TextStyle(fontSize: 13.5, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      showClipSheet(
                        context,
                        controller,
                        HighlightClip(
                          id: 'node-${node.startMs}',
                          startMs: node.startMs,
                          endMs: node.endMs,
                          kind: node.kind,
                          title: node.mood,
                          reason: node.evidence.join(' + '),
                          score: node.confidence,
                          transcript: node.transcript,
                          nodeStartMs: node.startMs,
                          sourcePath: controller.sourcePath,
                          absoluteStartMs: node.absoluteStartMs,
                          absoluteEndMs: node.absoluteEndMs,
                        ),
                      );
                    },
                    leading: const material.Icon(
                      material.Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    child: Text(controller.text('回看原片', 'Review source')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlineButton(
                    onPressed: () => controller.syncToMicPro(node),
                    leading: const material.Icon(
                      material.Icons.watch_rounded,
                      size: 16,
                    ),
                    child: Text(controller.text('同步 Mic Pro', 'Sync Mic Pro')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ClipDetailSheet extends StatelessWidget {
  const ClipDetailSheet({
    required this.controller,
    required this.clip,
    super.key,
  });

  final AppController controller;
  final HighlightClip clip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.border,
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                WeatherIcon(kind: clip.kind, size: 44),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    clip.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SecondaryBadge(child: Text(clip.clockRange)),
              ],
            ),
            const SizedBox(height: 16),
            ClipPlayer(clip: clip, controller: controller),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                material.Icon(
                  material.Icons.auto_awesome_rounded,
                  size: 15,
                  color: brandBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    clip.reason,
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: colors.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 3,
                    height: 34,
                    decoration: BoxDecoration(
                      color: brandBlue.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      '“${clip.transcript}”',
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    onPressed: () {
                      WeatherNode? node;
                      for (final candidate in controller.timeline) {
                        if (candidate.startMs == clip.nodeStartMs) {
                          node = candidate;
                          break;
                        }
                      }
                      final selectedNode = node;
                      if (selectedNode != null) {
                        controller.syncToMicPro(selectedNode);
                      }
                    },
                    leading: const material.Icon(
                      material.Icons.watch_rounded,
                      size: 16,
                    ),
                    child: Text(controller.text('投放到墨水屏', 'Send to e-ink')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlineButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(controller.text('完成', 'Done')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ClipPlayer extends StatefulWidget {
  const ClipPlayer({required this.clip, required this.controller, super.key});

  final HighlightClip clip;
  final AppController controller;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer> {
  VideoPlayerController? _player;
  bool _ready = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    // Prefer the trimmed clip: it starts at zero and holds only this highlight, so
    // playback and sharing never fall back to the untrimmed recording.
    final clipPath = widget.clip.clipPath;
    final sourcePath = widget.clip.sourcePath;
    final trimmed = clipPath != null && File(clipPath).existsSync();
    final path = trimmed ? clipPath : sourcePath;
    if (path != null && File(path).existsSync()) {
      _player = VideoPlayerController.file(File(path))
        ..initialize().then((_) async {
          if (!trimmed) {
            await _player?.seekTo(Duration(milliseconds: widget.clip.startMs));
          }
          if (mounted) setState(() => _ready = true);
        });
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready && _player != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: ColoredBox(
          color: const Color(0xFF0F172A),
          child: GestureDetector(
            onTap: () async {
              if (_player!.value.isPlaying) {
                await _player!.pause();
              } else {
                await _player!.play();
              }
              if (mounted) setState(() => _playing = _player!.value.isPlaying);
            },
            child: Stack(
              alignment: Alignment.center,
              children: [
                AspectRatio(
                  aspectRatio: _player!.value.aspectRatio,
                  child: VideoPlayer(_player!),
                ),
                if (!_playing)
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const material.Icon(
                      material.Icons.play_arrow_rounded,
                      size: 34,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    final hasSource =
        widget.clip.sourcePath != null &&
        File(widget.clip.sourcePath!).existsSync();
    return Container(
      height: 168,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: material.Icon(
                  hasSource
                      ? material.Icons.hourglass_top_rounded
                      : material.Icons.videocam_off_rounded,
                  size: 24,
                  color: const Color(0xCCFFFFFF),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.controller.text(
                hasSource ? '正在加载原片' : '原片文件不可用',
                hasSource ? 'Loading source video' : 'Source video unavailable',
              ),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              widget.clip.timeRange,
              style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class HighlightCard extends StatelessWidget {
  const HighlightCard({
    required this.clip,
    required this.controller,
    super.key,
  });

  final HighlightClip clip;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => showClipSheet(context, controller, clip),
      child: _surfaceCard(
        context,
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              height: 76,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: HighlightPainter(kind: clip.kind)),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.32),
                          ),
                        ),
                        child: const Center(
                          child: material.Icon(
                            material.Icons.play_arrow_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          clip.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _Chevron(),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _MetaChip(
                    icon: material.Icons.schedule_rounded,
                    label: clip.clockRange,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    clip.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoEventCard extends StatelessWidget {
  const VideoEventCard({
    required this.event,
    required this.controller,
    super.key,
  });

  final VideoEvent event;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    HighlightClip? exportedClip;
    for (final candidate in controller.highlights) {
      final sameSource =
          candidate.sourcePath == null ||
          event.sourceRef == null ||
          candidate.sourcePath == event.sourceRef;
      final overlaps =
          candidate.startMs < event.endMs && candidate.endMs > event.startMs;
      if (sameSource && overlaps && candidate.clipPath != null) {
        exportedClip = candidate;
        break;
      }
    }
    final clip =
        exportedClip ??
        HighlightClip(
          id: 'event-${event.startMs}-${event.endMs}',
          startMs: math.max(0, event.startMs - 5000),
          endMs: event.endMs,
          kind: WeatherKind.cloudy,
          title: event.title,
          reason: event.description,
          score: event.confidence,
          transcript: event.description,
          nodeStartMs: event.startMs,
          sourcePath: event.sourceRef ?? controller.sourcePath,
          absoluteStartMs: event.absoluteStartMs == null
              ? null
              : math.max(
                  controller.sourceRecordedAtMs ?? event.absoluteStartMs!,
                  event.absoluteStartMs! - 5000,
                ),
          absoluteEndMs: event.absoluteEndMs,
        );
    return GestureDetector(
      onTap: () => showClipSheet(context, controller, clip),
      child: _surfaceCard(
        context,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            const _IconBadge(
              icon: material.Icons.movie_rounded,
              color: brandBlue,
              size: 38,
              iconSize: 18,
              radius: 12,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          event.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      SecondaryBadge(child: Text(event.clockRange)),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    event.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryCard extends StatelessWidget {
  const HistoryCard({required this.entry, required this.controller, super.key});

  final AnalysisHistory entry;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = DateTime.fromMillisecondsSinceEpoch(entry.analyzedAtMs);
    final stamp =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final recordedTimes = entry.timeline
        .map((node) => node.absoluteStartMs)
        .whereType<int>()
        .toList();
    final recordedAt = recordedTimes.isEmpty ? null : recordedTimes.first;
    final historyStamp = recordedAt == null
        ? controller.text('分析于 $stamp', 'Analyzed $stamp')
        : controller.text(
            '拍摄于 ${formatTimestamp(recordedAt)}',
            'Recorded ${formatTimestamp(recordedAt)}',
          );
    return GestureDetector(
      onTap: () => controller.restoreHistory(entry),
      child: _surfaceCard(
        context,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            const _IconBadge(
              icon: material.Icons.history_rounded,
              color: Color(0xFF8C6DDE),
              size: 38,
              iconSize: 18,
              radius: 12,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$historyStamp · ${entry.timeline.length} ${controller.text('段情绪', 'mood points')} · ${entry.videoEvents.length} ${controller.text('个事件', 'events')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            TextButtonLike(
              label: controller.text('恢复', 'Restore'),
              onPressed: () => controller.restoreHistory(entry),
            ),
          ],
        ),
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    this.trailing,
    super.key,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: brandBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    eyebrow,
                    style: const TextStyle(
                      color: brandBlue,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                subtitle,
                style: TextStyle(
                  color: colors.mutedForeground,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 14), trailing!],
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 3,
        height: 16,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [brandBlue, Color(0xFF8AA0FF)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(99),
        ),
      ),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ),
      if (trailing != null) trailing!,
    ],
  );
}

class TextButtonLike extends StatelessWidget {
  const TextButtonLike({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GhostButton(
    density: ButtonDensity.dense,
    onPressed: onPressed,
    trailing: const material.Icon(
      material.Icons.arrow_forward_rounded,
      size: 15,
    ),
    child: Text(label),
  );
}

class ProfileAction extends StatelessWidget {
  const ProfileAction({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.icon = material.Icons.chevron_right_rounded,
    this.trailing,
    super.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final material.IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: _surfaceCard(
        context,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            _IconBadge(icon: icon, size: 40, iconSize: 18, radius: 13),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: colors.mutedForeground,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (trailing != null) trailing! else const _Chevron(),
          ],
        ),
      ),
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.icon,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget trailing;
  final material.IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (icon != null) ...[
          _IconBadge(icon: icon!, size: 38, iconSize: 17, radius: 12),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: colors.mutedForeground,
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    );
  }
}

class PrivacyNotice extends StatelessWidget {
  const PrivacyNotice({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: brandBlue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: brandBlue.withValues(alpha: 0.14)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: brandBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: material.Icon(
                material.Icons.shield_outlined,
                size: 16,
                color: brandBlue,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.mutedForeground,
                fontSize: 11.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.title,
    required this.subtitle,
    this.icon = material.Icons.inbox_rounded,
    this.color,
    this.bare = false,
    super.key,
  });

  final String title;
  final String subtitle;
  final material.IconData icon;
  final Color? color;
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = color ?? brandBlue;
    final content = Padding(
      padding: bare
          ? const EdgeInsets.symmetric(vertical: 10, horizontal: 8)
          : const EdgeInsets.symmetric(vertical: 26, horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: tint.withValues(alpha: 0.16)),
            ),
            child: Center(child: material.Icon(icon, size: 26, color: tint)),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.mutedForeground,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
    if (bare) return content;
    return _surfaceCard(
      context,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: content,
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: const Color(0xFFB8F27A),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFB8F27A).withValues(alpha: 0.6),
              blurRadius: 6,
            ),
          ],
        ),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFFD5E0D0),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
    ],
  );
}

class _NodePill extends StatelessWidget {
  const _NodePill({required this.node, required this.selected});

  final WeatherNode node;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = Color(node.kind.colorValue);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.14)
            : colors.muted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: selected
              ? color.withValues(alpha: 0.45)
              : colors.border.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            node.startLabel,
            style: TextStyle(
              color: selected ? color : colors.mutedForeground,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class WeatherIcon extends StatelessWidget {
  const WeatherIcon({required this.kind, required this.size, super.key});

  final WeatherKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tint = Color(kind.colorValue);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        shape: BoxShape.circle,
        border: Border.all(color: tint.withValues(alpha: 0.22)),
      ),
      child: Center(
        child: material.Icon(
          _weatherGlyph(kind),
          size: size * 0.5,
          color: tint,
        ),
      ),
    );
  }
}

class MoodCurve extends StatelessWidget {
  const MoodCurve({
    required this.nodes,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final List<WeatherNode> nodes;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (details) {
        if (nodes.isEmpty) return;
        final width = context.size?.width ?? 1;
        final index = ((details.localPosition.dx / width) * nodes.length)
            .floor()
            .clamp(0, nodes.length - 1);
        onSelected(index);
      },
      child: SizedBox(
        height: 196,
        width: double.infinity,
        child: CustomPaint(
          painter: MoodCurvePainter(
            nodes: nodes,
            selectedIndex: selectedIndex,
            colors: Theme.of(context).colorScheme,
          ),
        ),
      ),
    );
  }
}

class SkyPainter extends CustomPainter {
  SkyPainter({required this.kind});

  final WeatherKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final gradientColors = switch (kind) {
      WeatherKind.sunny => const [Color(0xFF50789F), Color(0xFFE2B66C)],
      WeatherKind.cloudy => const [Color(0xFF526A86), Color(0xFF9EAFC3)],
      WeatherKind.rain => const [Color(0xFF24486E), Color(0xFF5A88B5)],
      WeatherKind.storm => const [Color(0xFF24233F), Color(0xFF725DAB)],
      WeatherKind.rainbow => const [Color(0xFF4D6B92), Color(0xFFE78396)],
    };
    final gradient = LinearGradient(
      colors: gradientColors,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.07);
    for (var index = 0; index < 8; index++) {
      canvas.drawCircle(
        Offset(
          size.width * (0.08 + index * 0.17),
          size.height * (0.1 + (index % 3) * 0.23),
        ),
        1.5 + index % 2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SkyPainter oldDelegate) =>
      oldDelegate.kind != kind;
}

class HighlightPainter extends CustomPainter {
  HighlightPainter({required this.kind});

  final WeatherKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final color = Color(kind.colorValue);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0.92), const Color(0xFF1F2937)],
        ).createShader(rect),
    );
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var index = 0; index < 5; index++) {
      canvas.drawLine(
        Offset(0, size.height * (0.25 + index * 0.14)),
        Offset(size.width, size.height * (0.15 + index * 0.16)),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HighlightPainter oldDelegate) =>
      oldDelegate.kind != kind;
}

class ForecastCard extends StatelessWidget {
  const ForecastCard({required this.controller, required this.node, super.key});

  final AppController controller;
  final WeatherNode node;

  @override
  Widget build(BuildContext context) {
    return Card(
      padding: EdgeInsets.zero,
      filled: true,
      fillColor: const Color(0xFF22304A),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 376,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: SkyPainter(kind: node.kind)),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.28),
                      Colors.black.withValues(alpha: 0.02),
                      Colors.black.withValues(alpha: 0.36),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              top: 58,
              child: WeatheredGlyph(kind: node.kind, size: 84),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Text(
                          controller.text('影像天气 · 今日', 'IMAGE WEATHER · TODAY'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      const Spacer(),
                      material.Icon(
                        material.Icons.schedule_rounded,
                        size: 13,
                        color: const Color(0xCCFFFFFF),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        node.clockRange,
                        style: const TextStyle(
                          color: Color(0xCCFFFFFF),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    node.mood,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      height: 1.25,
                      shadows: [
                        Shadow(color: Color(0x66000000), blurRadius: 8),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${node.intensity}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 66,
                          fontWeight: FontWeight.w300,
                          height: 0.95,
                          letterSpacing: -2,
                          shadows: [
                            Shadow(color: Color(0x66000000), blurRadius: 10),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9, left: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              controller.text('情绪强度', 'MOOD'),
                              style: const TextStyle(
                                color: Color(0xE6FFFFFF),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              node.kind.chineseName,
                              style: const TextStyle(
                                color: Color(0xB3FFFFFF),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${node.confidence.toStringAsFixed(2)} ${controller.text('置信度', 'confidence')}',
                          style: const TextStyle(
                            color: Color(0xFFD3DCEA),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        _StatusDot(label: controller.text('已分析', 'ANALYZED')),
                        const SizedBox(width: 10),
                        ButtonStyleOverride(
                          textStyle: (context, states, value) => value.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                          iconTheme: (context, states, value) =>
                              value.copyWith(color: Colors.white),
                          decoration: (context, states, value) =>
                              value.copyWithIfBoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.42),
                                ),
                              ),
                          child: OutlineButton(
                            onPressed: () =>
                                showNodeSheet(context, controller, node),
                            density: ButtonDensity.dense,
                            leading: const material.Icon(
                              material.Icons.search_rounded,
                              size: 14,
                            ),
                            child: Text(controller.text('查看证据', 'Evidence')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WeatheredGlyph extends StatelessWidget {
  const WeatheredGlyph({required this.kind, required this.size, super.key});

  final WeatherKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    return material.Icon(
      _weatherGlyph(kind),
      size: size,
      color: Colors.white.withValues(alpha: 0.9),
      shadows: const [Shadow(color: Color(0x66000000), blurRadius: 16)],
    );
  }
}

class ConnectionStatusCard extends StatelessWidget {
  const ConnectionStatusCard({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = controller.connectionIsActive;
    final failed = controller.connectionStage == DeviceConnectionStage.failed;
    final busy = controller.connectionStage.isBusy;
    const activeGreen = Color(0xFF36A269);
    final deviceName =
        controller.connectedDeviceName ??
        controller.connectedDevice?.name ??
        'GO Ultra';
    final accent = failed
        ? brandCoral
        : active
        ? activeGreen
        : colors.mutedForeground;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: failed
            ? brandCoral.withValues(alpha: 0.07)
            : active
            ? activeGreen.withValues(alpha: 0.09)
            : colors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: failed
              ? brandCoral.withValues(alpha: 0.3)
              : active
              ? activeGreen.withValues(alpha: 0.28)
              : colors.border.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: busy
                ? const SizedBox(
                    key: ValueKey('connection-progress'),
                    width: 38,
                    height: 38,
                    child: material.CircularProgressIndicator(strokeWidth: 3),
                  )
                : Container(
                    key: ValueKey('$active-$failed'),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.22)),
                    ),
                    child: Center(
                      child: material.Icon(
                        failed
                            ? material.Icons.error_outline_rounded
                            : active
                            ? material.Icons.wifi_rounded
                            : material.Icons.wifi_find_rounded,
                        size: 20,
                        color: accent,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active || controller.connectionStage.isBusy
                      ? deviceName
                      : controller.text('GO Ultra 连接状态', 'GO Ultra status'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  controller.connectionStatus,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.mutedForeground,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
                if (failed && controller.lastError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    controller.lastError!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: brandCoral, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (active)
            PrimaryBadge(
              child: Text(
                controller.previewReady
                    ? controller.text('实时', 'LIVE')
                    : controller.text('已连接', 'ONLINE'),
              ),
            )
          else if (busy)
            SecondaryBadge(child: Text(controller.text('处理中', 'WORKING'))),
        ],
      ),
    );
  }
}

class DevicesPage extends StatelessWidget {
  const DevicesPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The controller narrows the scan to the project camera by default; the GO-only
    // switch stays as a second, broader filter.
    final visibleDevices = _distinctDevices(
      controller.visibleScanDevices.where(
        (device) =>
            !controller.showOnlyGo || device.model.toLowerCase().contains('go'),
      ),
    );
    final connected = controller.connectedDevice;
    return SingleChildScrollView(
      padding: _pageInsets(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            eyebrow: 'HARDWARE / INPUT',
            title: controller.text('设备连接', 'Devices'),
            subtitle: controller.text(
              '先在 App 内扫描 GO Ultra Wi‑Fi，再由 SDK 建立视频与音频链路。',
              'Scan GO Ultra Wi‑Fi in the app, then let the SDK establish video and audio.',
            ),
            trailing: const _IconBadge(
              icon: material.Icons.wifi_rounded,
              color: brandBlue,
              size: 46,
              iconSize: 22,
              radius: 15,
            ),
          ),
          const SizedBox(height: 20),
          _surfaceCard(
            context,
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Row(
                  children: [
                    const _IconBadge(
                      icon: material.Icons.filter_alt_rounded,
                      color: brandBlue,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            controller.text('扫描结果过滤', 'Scan result filter'),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            controller.text(
                              '相机只使用 Wi‑Fi；App 扫描和连接都不调用相机蓝牙',
                              'The camera uses Wi‑Fi only; in-app scan and connection never use camera Bluetooth',
                            ),
                            style: TextStyle(
                              color: colors.mutedForeground,
                              fontSize: 11.5,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: controller.showPreferredOnly,
                      onChanged: controller.setShowPreferredOnly,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    onPressed: controller.connectionStage.isBusy
                        ? null
                        : () => controller.connectCameraAutomatically(),
                    leading:
                        controller.connectionStage ==
                            DeviceConnectionStage.connectingWifi
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: material.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const material.Icon(
                            material.Icons.wifi_rounded,
                            size: 18,
                          ),
                    child: Text(
                      controller.connectionStage ==
                              DeviceConnectionStage.connectingWifi
                          ? controller.text('连接中…', 'Connecting…')
                          : controller.text(
                              '扫描 GO Ultra Wi‑Fi',
                              'Scan GO Ultra Wi‑Fi',
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlineButton(
                    onPressed:
                        controller.scanning || controller.connectionStage.isBusy
                        ? null
                        : () => controller.connectCurrentWifiCamera(),
                    leading: controller.scanning
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: material.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const material.Icon(
                            material.Icons.wifi_rounded,
                            size: 18,
                          ),
                    child: Text(
                      controller.text(
                        '连接当前已选 Wi‑Fi（备用）',
                        'Use already selected Wi‑Fi (fallback)',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: GhostButton(
                    onPressed:
                        controller.scanning || controller.connectionStage.isBusy
                        ? null
                        : () => controller.scanDevices(),
                    leading: controller.scanning
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: material.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const material.Icon(
                            material.Icons.radar_rounded,
                            size: 18,
                          ),
                    child: Text(
                      controller.scanning
                          ? controller.text('检查中…', 'Checking…')
                          : controller.text(
                              '重新扫描相机 Wi‑Fi（不使用蓝牙）',
                              'Rescan camera Wi‑Fi (no Bluetooth)',
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ConnectionStatusCard(controller: controller),
          const SizedBox(height: 20),
          if (visibleDevices.isNotEmpty) ...[
            SectionTitle(
              title: controller.text('已发现设备', 'Discovered devices'),
              trailing: SecondaryBadge(child: Text('${visibleDevices.length}')),
            ),
            const SizedBox(height: 10),
          ],
          if (visibleDevices.isEmpty)
            EmptyState(
              icon: material.Icons.devices_other_rounded,
              title: controller.text('还没有设备', 'No devices yet'),
              subtitle: controller.text(
                '打开 GO Ultra 的 Wi‑Fi 后，在 App 内点击扫描。',
                'Turn on GO Ultra Wi‑Fi, then scan inside the app.',
              ),
            ),
          for (final device in visibleDevices) ...[
            DeviceCard(device: device, controller: controller),
            const SizedBox(height: 12),
          ],
          if (connected != null) ...[
            const SizedBox(height: 8),
            SectionTitle(title: controller.text('实时影像流', 'Live video stream')),
            const SizedBox(height: 10),
            PreviewPanel(device: connected, controller: controller),
            const SizedBox(height: 12),
            _surfaceCard(
              context,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      material.Icon(
                        material.Icons.sync_alt_rounded,
                        size: 16,
                        color: brandBlue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          controller.text(
                            '音频轨道与视频 PTS 同步保留，ASR 结果可回到原片。',
                            'The audio track keeps video PTS so ASR results can jump back to the source.',
                          ),
                          style: const TextStyle(fontSize: 12, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlineButton(
                          density: ButtonDensity.dense,
                          onPressed: controller.syncingLatestMedia
                              ? null
                              : () => controller.syncLatestMedia(),
                          leading: controller.syncingLatestMedia
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: material.CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const material.Icon(
                                  material.Icons.download_rounded,
                                  size: 15,
                                ),
                          child: Text(controller.text('同步最新素材', 'Sync latest')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      PrimaryBadge(
                        child: Text(controller.text('已对齐', 'SYNCED')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _surfaceCard(
              context,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: controller.realtimeAsrConnecting
                        ? const SizedBox(
                            key: ValueKey('realtime-asr-loading'),
                            width: 18,
                            height: 18,
                            child: material.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : Container(
                            key: const ValueKey('realtime-audio-dot'),
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: const Color(0xFF36A269),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF36A269,
                                  ).withValues(alpha: 0.5),
                                  blurRadius: 7,
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.text(
                            '实时音频 / Qwen ASR',
                            'Live audio / Qwen ASR',
                          ),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          controller.realtimeTranscript.isEmpty
                              ? controller.realtimeStatus
                              : '${controller.realtimeStatus} · ${controller.realtimeTranscript}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.mutedForeground,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                        if (controller.realtimeMood.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            '${controller.text('当前天气', 'Current weather')}: ${controller.realtimeWeather?.chineseName ?? controller.realtimeWeather?.englishName ?? ''} · ${controller.realtimeMood}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SecondaryBadge(
                    child: Text(
                      '${controller.realtimeAudioFrames} ${controller.text('帧', 'frames')}',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

List<DeviceRecord> _distinctDevices(Iterable<DeviceRecord> devices) {
  // BLE controllers rotate randomized addresses, so one camera can arrive several
  // times with different ids. Name+model is the stable identity for GO devices, so
  // prefer it and fall back to the id/address for anything unnamed.
  final seen = <String>{};
  final result = <DeviceRecord>[];
  for (final device in devices) {
    final name = device.name.trim();
    final key = name.isEmpty
        ? (device.id.isNotEmpty
              ? device.id
              : device.address ?? 'unknown-${result.length}')
        : '${device.model}|$name';
    if (seen.add(key)) result.add(device);
  }
  return result;
}

String _sourceStatusMessage(AppController controller) {
  final message = controller.analysisMessage;
  final isScanSummary =
      message.contains('GO 系列') || message.contains('GO-series');
  if (!isScanSummary) return message;
  final count = _distinctDevices(controller.devices).length;
  if (count <= 0) return message;
  return controller.text(
    '发现 $count 台真实 GO 系列设备',
    '$count real GO-series device(s) found',
  );
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({required this.device, required this.controller, super.key});

  final DeviceRecord device;
  final AppController controller;

  Future<void> _showWifiPasswordDialog(BuildContext context) async {
    final passwordController = material.TextEditingController();
    final password = await material.showDialog<String>(
      context: context,
      builder: (dialogContext) => material.AlertDialog(
        title: Text(
          controller.text('连接 GO Ultra Wi‑Fi', 'Connect GO Ultra Wi‑Fi'),
        ),
        content: material.TextField(
          controller: passwordController,
          autofocus: true,
          obscureText: true,
          textInputAction: material.TextInputAction.done,
          decoration: material.InputDecoration(
            labelText: controller.text('Wi‑Fi 密码', 'Wi‑Fi password'),
            helperText: controller.text(
              '相机下拉菜单 → 设置 → Wi‑Fi 设置可查看密码',
              'Camera swipe-down menu → Settings → Wi‑Fi Settings',
            ),
          ),
          onSubmitted: (value) =>
              material.Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          material.TextButton(
            onPressed: () => material.Navigator.of(dialogContext).pop(),
            child: Text(controller.text('取消', 'Cancel')),
          ),
          material.FilledButton(
            onPressed: () => material.Navigator.of(
              dialogContext,
            ).pop(passwordController.text),
            child: Text(controller.text('连接', 'Connect')),
          ),
        ],
      ),
    );
    passwordController.dispose();
    if (password == null) return;
    await controller.connectScannedWifiDevice(device, password);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connecting =
        controller.connectingDeviceId == device.id &&
        controller.connectionStage.isBusy;
    final anotherDeviceBusy = controller.connectionStage.isBusy && !connecting;
    final connected = device.isConnected;
    final accent = connected ? const Color(0xFF36A269) : brandBlue;
    return _surfaceCard(
      context,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IconBadge(
                icon: material.Icons.videocam_rounded,
                color: accent,
                size: 48,
                iconSize: 22,
                radius: 15,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${device.model} · ${device.connection}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.mutedForeground,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: connecting
                    ? SecondaryBadge(
                        key: const ValueKey('connecting'),
                        child: Text(controller.text('连接中', 'CONNECTING')),
                      )
                    : PrimaryBadge(
                        key: ValueKey(device.isConnected),
                        child: Text(
                          connected
                              ? controller.text('已连接', 'ONLINE')
                              : controller.text('未连接', 'OFFLINE'),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: colors.muted.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _MetaChip(
                  icon: material.Icons.battery_5_bar_rounded,
                  label: '${device.battery ?? '--'}%',
                ),
                const Spacer(),
                _MetaChip(
                  icon: material.Icons.sd_storage_rounded,
                  label: device.storage ?? controller.text('等待读取', 'Waiting'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: connecting
                    ? const SizedBox(
                        height: 34,
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: material.CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      )
                    : connected
                    ? OutlineButton(
                        density: ButtonDensity.dense,
                        onPressed: anotherDeviceBusy
                            ? null
                            : () => controller.toggleDevice(device),
                        leading: const material.Icon(
                          material.Icons.link_off_rounded,
                          size: 15,
                        ),
                        child: Text(controller.text('断开连接', 'Disconnect')),
                      )
                    : PrimaryButton(
                        density: ButtonDensity.dense,
                        onPressed: anotherDeviceBusy
                            ? null
                            : () => _showWifiPasswordDialog(context),
                        leading: const material.Icon(
                          material.Icons.wifi_rounded,
                          size: 15,
                        ),
                        child: Text(
                          controller.text(
                            '在 App 内连接此 Wi‑Fi',
                            'Connect this Wi‑Fi in app',
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              GhostButton(
                density: ButtonDensity.dense,
                onPressed: anotherDeviceBusy || connecting
                    ? null
                    : () => controller.removeDevice(device),
                leading: const material.Icon(
                  material.Icons.delete_outline_rounded,
                  size: 15,
                ),
                child: Text(controller.text('移除', 'Remove')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({
    required this.device,
    required this.controller,
    super.key,
  });

  final DeviceRecord device;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final ready = controller.previewReady;
    final live = controller.connectionIsActive;
    return Card(
      padding: EdgeInsets.zero,
      filled: true,
      fillColor: const Color(0xFF101827),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 208,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (Platform.isAndroid)
              const AndroidView(viewType: 'dayweather/go-preview')
            else
              ColoredBox(
                color: const Color(0xFF152033),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      material.Icon(
                        material.Icons.android_rounded,
                        size: 28,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        controller.text(
                          'Android 实时预览不可用',
                          'Android live preview is unavailable',
                        ),
                        style: const TextStyle(color: Color(0xB3FFFFFF)),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.5),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.62),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.4, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 14,
              top: 14,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: ready
                    ? PrimaryBadge(
                        key: const ValueKey('preview-ready'),
                        child: Text(controller.text('实时预览', 'LIVE PREVIEW')),
                      )
                    : SecondaryBadge(
                        key: const ValueKey('preview-loading'),
                        child: Text(
                          live
                              ? controller.text('视频流启动中', 'STARTING STREAM')
                              : controller.text('等待视频流', 'WAITING FOR STREAM'),
                        ),
                      ),
              ),
            ),
            Positioned(
              right: 14,
              top: 14,
              child: SecondaryBadge(child: Text('GO ULTRA')),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 14,
              child: Text(
                controller.text(
                  ready && controller.realtimeAsrActive
                      ? '视频流已接入 · 实时音频与 PTS 已对齐'
                      : ready
                      ? '视频流已接入，等待实时 ASR'
                      : live
                      ? '设备已连接，等待首帧…'
                      : '等待 GO Ultra 视频流',
                  ready && controller.realtimeAsrActive
                      ? 'Video stream connected · live audio aligned by PTS'
                      : ready
                      ? 'Video stream connected · waiting for realtime ASR'
                      : live
                      ? 'Device connected · waiting for first frame…'
                      : 'Waiting for the GO Ultra stream',
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Color(0x8A000000), blurRadius: 5)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: _pageInsets(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            eyebrow: 'PERSONAL / CONTROL',
            title: controller.text('我的空间', 'Your space'),
            subtitle: controller.text(
              '管理偏好、设备联动与隐私边界。',
              'Preferences, device sync, and privacy controls.',
            ),
          ),
          const SizedBox(height: 22),
          Card(
            padding: const EdgeInsets.all(18),
            filled: true,
            borderRadius: BorderRadius.circular(22),
            borderColor: brandBlue.withValues(alpha: 0.16),
            borderWidth: 1,
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned(
                  right: -28,
                  top: -34,
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [
                          brandBlue.withValues(alpha: 0.16),
                          brandBlue.withValues(alpha: 0.0),
                        ],
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Avatar(
                      initials: '23J',
                      size: 64,
                      backgroundColor: const Color(0xFFFFD7C9),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '23J',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                              color: colors.foreground,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            controller.text(
                              '影像氛围记录者',
                              'Visual atmosphere maker',
                            ),
                            style: TextStyle(
                              color: colors.mutedForeground,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SecondaryBadge(
                      child: Text(controller.text('黑客松原型', 'HACKATHON')),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          ProfileAction(
            icon: material.Icons.tune_rounded,
            title: controller.text('设置', 'Settings'),
            subtitle: controller.text(
              '明暗主题、语言与模型入口',
              'Theme, language, and model access',
            ),
            onTap: controller.openSettings,
          ),
          const SizedBox(height: 12),
          ProfileAction(
            icon: material.Icons.public_rounded,
            title: controller.text('开发者主页', 'Developer homepage'),
            subtitle: 'www.23j1633.xyz',
            onTap: controller.openDeveloper,
          ),
          const SizedBox(height: 26),
          SectionTitle(title: controller.text('隐私与边界', 'Privacy & boundaries')),
          const SizedBox(height: 10),
          PrivacyNotice(
            text: controller.text(
              '原始素材默认留在本机；只有启用 Qwen 分析并配置 API Key 时，才会发送必要的音频/视频片段。Mic Pro 只显示天气图标，不参与录音。',
              'Original media stays on-device by default. Only required clips leave the device when Qwen analysis is enabled. Mic Pro displays icons only and does not record.',
            ),
          ),
          const SizedBox(height: 20),
          SectionTitle(title: controller.text('模型管线', 'Model pipeline')),
          const SizedBox(height: 10),
          _surfaceCard(
            context,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PipelineRow(
                  label: 'ASR',
                  value: QwenService.asrModel,
                  active: controller.qwen.isConfigured,
                ),
                _PipelineRow(
                  label: 'Live ASR',
                  value: QwenService.realtimeAsrModel,
                  active: controller.qwen.isConfigured,
                ),
                _PipelineRow(
                  label: 'Mood',
                  value: 'qwen3.8-max',
                  active: controller.qwen.isConfigured,
                ),
                _PipelineRow(
                  label: 'Video',
                  value: 'qwen3.8-omni-flash',
                  active: controller.qwen.isConfigured,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      headers: [
        AppBar(
          leading: [
            GhostButton(
              density: ButtonDensity.dense,
              onPressed: controller.closeSettings,
              leading: const material.Icon(
                material.Icons.arrow_back_rounded,
                size: 16,
              ),
              child: Text(controller.text('返回', 'Back')),
            ),
          ],
          title: Text(
            controller.text('设置', 'Settings'),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        const Divider(),
      ],
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 32 + bottomPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel(
              icon: material.Icons.palette_outlined,
              text: 'Appearance',
            ),
            const SizedBox(height: 10),
            _surfaceCard(
              context,
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  SettingRow(
                    icon: material.Icons.dark_mode_outlined,
                    title: controller.text('深色主题', 'Dark theme'),
                    subtitle: controller.text(
                      '适合夜间整理素材',
                      'Comfortable for night-time editing',
                    ),
                    trailing: Switch(
                      value: controller.darkMode,
                      onChanged: controller.setDarkMode,
                    ),
                  ),
                  const Divider(height: 26),
                  SettingRow(
                    icon: material.Icons.translate_rounded,
                    title: controller.text('语言', 'Language'),
                    subtitle: controller.text(
                      '界面文案即时切换',
                      'Switch UI copy instantly',
                    ),
                    trailing: GhostButton(
                      density: ButtonDensity.dense,
                      onPressed: () => controller.setLanguage(
                        controller.language == AppLanguage.chinese
                            ? AppLanguage.english
                            : AppLanguage.chinese,
                      ),
                      child: Text(
                        controller.language == AppLanguage.chinese
                            ? '中文'
                            : 'EN',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            const _SectionLabel(
              icon: material.Icons.memory_rounded,
              text: 'AI service',
            ),
            const SizedBox(height: 10),
            _surfaceCard(
              context,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingRow(
                    icon: material.Icons.hub_rounded,
                    title: controller.text('百炼连接测试', 'Bailian connection test'),
                    subtitle: controller.text(
                      '使用当前 Qwen 配置发送真实请求',
                      'Send a real request with the current Qwen configuration',
                    ),
                    trailing: controller.qwen.isConfigured
                        ? PrimaryBadge(
                            child: Text(controller.text('已配置', 'READY')),
                          )
                        : SecondaryBadge(
                            child: Text(controller.text('未配置', 'MISSING')),
                          ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      onPressed: controller.aiTesting
                          ? null
                          : controller.testAiConnection,
                      leading: controller.aiTesting
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: material.CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const material.Icon(
                              material.Icons.bolt_rounded,
                              size: 17,
                            ),
                      child: Text(
                        controller.aiTesting
                            ? controller.text('请求中…', 'Testing…')
                            : controller.text('测试 AI 连接', 'Test AI connection'),
                      ),
                    ),
                  ),
                  if (controller.aiTestMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.muted.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        controller.aiTestMessage!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              controller.aiTestMessage!.contains(
                                controller.text('连接失败', 'Connection failed'),
                              )
                              ? brandCoral
                              : colors.mutedForeground,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 26),
            const _SectionLabel(
              icon: material.Icons.watch_rounded,
              text: 'Device output',
            ),
            const SizedBox(height: 10),
            _surfaceCard(
              context,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingRow(
                    icon: material.Icons.watch_rounded,
                    title: controller.text(
                      'Mic Pro 墨水屏',
                      'Mic Pro e-ink display',
                    ),
                    subtitle: controller.text(
                      '独立蓝牙通道，可随时更换壁纸',
                      'Independent Bluetooth channel for wallpaper updates',
                    ),
                    trailing: controller.micProConnectedAddress != null
                        ? const PrimaryBadge(child: Text('已连接'))
                        : SecondaryBadge(
                            child: Text(controller.text('未连接', 'OFFLINE')),
                          ),
                  ),
                  const Divider(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      onPressed: controller.micProScanning
                          ? null
                          : controller.scanMicProDevices,
                      leading: controller.micProScanning
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: material.CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const material.Icon(
                              material.Icons.bluetooth_searching_rounded,
                              size: 16,
                            ),
                      child: Text(
                        controller.micProScanning
                            ? controller.text('扫描中…', 'Scanning…')
                            : controller.text('扫描 Mic Pro', 'Scan Mic Pro'),
                      ),
                    ),
                  ),
                  if (controller.micProConnectedAddress != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlineButton(
                        onPressed: controller.probeMicProProtocol,
                        leading: const material.Icon(
                          material.Icons.science_rounded,
                          size: 16,
                        ),
                        child: Text(
                          controller.text(
                            '协议探测（读取真实响应）',
                            'Probe protocol (read replies)',
                          ),
                        ),
                      ),
                    ),
                    if (controller.lastMicProProbe != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        controller.lastMicProProbe!,
                        style: const TextStyle(fontSize: 11, height: 1.5),
                      ),
                    ],
                  ],
                  if (controller.micProStatus.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      controller.micProStatus,
                      style: TextStyle(
                        color: colors.mutedForeground,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                  for (final device in controller.micProDevices) ...[
                    const SizedBox(height: 10),
                    material.InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => controller.connectMicProDevice(
                        device['address']?.toString() ?? '',
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colors.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.border.withValues(alpha: 0.65),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    device['name']?.toString() ?? 'Mic Pro',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${device['address']}  RSSI ${device['rssi']}',
                                    style: TextStyle(
                                      color: colors.mutedForeground,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            material.Icon(
                              material.Icons.chevron_right_rounded,
                              color: colors.mutedForeground,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (controller.syncMessage != null) ...[
                    const Divider(height: 26),
                    Text(
                      controller.syncMessage!,
                      style: TextStyle(
                        color: colors.mutedForeground,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 26),
            const _SectionLabel(
              icon: material.Icons.info_outline_rounded,
              text: 'About',
            ),
            const SizedBox(height: 10),
            ProfileAction(
              icon: material.Icons.public_rounded,
              title: controller.text('开发者主页', 'Developer homepage'),
              subtitle: 'www.23j1633.xyz',
              onTap: controller.openDeveloper,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text});

  final material.IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        material.Icon(
          icon,
          size: 14,
          color: Theme.of(context).colorScheme.mutedForeground,
        ),
        const SizedBox(width: 7),
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.mutedForeground,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.3,
          ),
        ),
      ],
    );
  }
}
