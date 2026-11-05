import 'dart:async';

import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/thread_ripper.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

String threadRipperModeDesc() {
  final settings = ThreadRipper.settings;
  if (settings.mode == RipperCdnMode.custom) {
    return settings.customHosts.isEmpty
        ? '自定义（未选择服务器，按大陆 CDN 下载）'
        : '自定义（${settings.customHosts.length} 个服务器）';
  }
  return settings.mode.desc;
}

String threadRipperThreadsDesc() {
  final settings = ThreadRipper.settings;
  return settings.autoConcurrency ? '自动（8 到 64）' : '${settings.concurrency}';
}

Future<void> showThreadRipperModeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<RipperCdnMode>(
    context: context,
    builder: (context) => SelectDialog<RipperCdnMode>(
      title: 'CDN 模式',
      value: ThreadRipper.settings.mode,
      values: RipperCdnMode.values.map((e) => (e, e.desc)).toList(),
      subtitleBuilder: (context, index) => Text(
        switch (RipperCdnMode.values[index]) {
          RipperCdnMode.mainland => '推荐，多个大陆节点一起下载',
          RipperCdnMode.overseas => '本地连大陆网络太差时使用',
          RipperCdnMode.custom => '只用你选的服务器',
        },
      ),
    ),
  );
  if (res == null) return;
  await GStorage.setting.put(SettingBoxKey.threadRipperMode, res.name);
  if (res == RipperCdnMode.custom && context.mounted) {
    await showThreadRipperCustomHostsDialog(context);
  }
  ThreadRipper.reload();
  setState();
}

Future<void> showThreadRipperCustomHostsDialog(BuildContext context) async {
  final known = ThreadRipper.knownHosts;
  final selected = Pref.threadRipperCustomHosts.toSet();
  final extra = selected.where((e) => !known.contains(e)).toList();
  final controller = TextEditingController(text: extra.join('\n'));
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('自定义 CDN'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final host in known)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(host),
                  title: Text(host, style: const TextStyle(fontSize: 13)),
                  onChanged: (value) => setDialogState(() {
                    if (value == true) {
                      selected.add(host);
                    } else {
                      selected.remove(host);
                    }
                  }),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '手动添加（每行一个）',
                  hintText: 'xxx.bilivideo.com\nxxx.akamaized.net',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('取消')),
          TextButton(
            onPressed: () {
              final typed = controller.text
                  .split(RegExp(r'[\s,，]+'))
                  .where((e) => e.trim().isNotEmpty)
                  .toList();
              final valid = typed
                  .map(normalizeCdnHost)
                  .where((e) => e.isNotEmpty)
                  .toList();
              if (valid.length < typed.length) {
                SmartDialog.showToast(
                  '只能添加 B 站视频服务器（bilivideo.com、akamaized.net 等）',
                );
                return;
              }
              Get.back(result: [...selected.where(known.contains), ...valid]);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  if (res == null) return;
  await GStorage.setting.put(
    SettingBoxKey.threadRipperCustomHosts,
    res.toSet().take(32).toList(),
  );
  ThreadRipper.reload();
}

Future<void> showThreadRipperThreadsDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final settings = ThreadRipper.settings;
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '线程数',
      value: settings.autoConcurrency ? 0 : settings.concurrency,
      values: [
        (0, '自动（推荐）'),
        for (final value in ripperConcurrencyChoices) (value, '$value'),
      ],
    ),
  );
  if (res == null) return;
  if (res == 0) {
    await GStorage.setting.put(SettingBoxKey.threadRipperAutoConcurrency, true);
  } else {
    await GStorage.setting.putAll({
      SettingBoxKey.threadRipperAutoConcurrency: false,
      SettingBoxKey.threadRipperConcurrency: res,
    });
  }
  ThreadRipper.reload();
  setState();
}

Future<void> showThreadRipperStatusDialog(
  BuildContext context,
  VoidCallback setState,
) => showDialog<void>(
  context: context,
  builder: (context) => const _StatusDialog(),
);

class _StatusDialog extends StatefulWidget {
  const _StatusDialog();

  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('线程撕裂者状态'),
      content: SingleChildScrollView(
        child: SelectableText(
          ThreadRipper.status(),
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('关闭')),
      ],
    );
  }
}
