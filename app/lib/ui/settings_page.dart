import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/permission_modes.dart';
import '../core/security.dart';
import '../state/app_controller.dart';
import 'format.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(appControllerProvider.notifier).requestDevices();
    });
  }

  String _connectionLabel(ConnectionStatus status) => switch (status) {
        ConnectionStatus.connected => '已连接',
        ConnectionStatus.connecting => '连接中…',
        ConnectionStatus.syncing => '同步中…',
        ConnectionStatus.error => '连接失败',
        ConnectionStatus.disconnected => '未连接',
      };

  String _fingerprint(String? value) {
    if (value == null || value.isEmpty) return '未保存';
    final normalized = normalizeFingerprint(value);
    if (normalized.length <= 24) return normalized;
    return '${normalized.substring(0, 16)}…${normalized.substring(normalized.length - 8)}';
  }

  Future<bool> _confirm({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _disconnect() async {
    final ok = await _confirm(
      title: '断开并清除配对？',
      message: '会删除本机保存的设备 token 和本地缓存，下次需要重新扫码配对。',
    );
    if (!ok) return;
    await ref.read(appControllerProvider.notifier).disconnect();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _revokeDevice(DeviceInfo device) async {
    final ok = await _confirm(
      title: '撤销 ${device.name}？',
      message: device.current
          ? '会立即断开本机并清除本地配对，需要重新配对。'
          : '该设备会立即断开，需要重新配对才能继续使用。',
    );
    if (!ok) return;
    ref.read(appControllerProvider.notifier).revokeDevice(device.id);
    if (device.current && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _rotateDevice(DeviceInfo device) async {
    final ok = await _confirm(
      title: '轮换 ${device.name} 的 token？',
      message: device.current
          ? '本机会用新 token 自动重连。'
          : '该设备会立即断开，需要用新 token 重新配对。',
    );
    if (!ok) return;
    ref.read(appControllerProvider.notifier).rotateDeviceToken(device.id);
  }

  Future<void> _selectMode(String mode) async {
    final session = ref.read(appControllerProvider).currentSession;
    if (session == null || session.permissionMode == mode) return;
    if (mode == 'bypassPermissions') {
      final ok = await _confirm(
        title: '启用 Bypass 模式？',
        message: 'Claude 之后会不经手机确认执行任意命令——包括删除文件、访问网络、运行脚本。'
            '手机上的权限卡将不再出现。只在明确知道后果时启用。',
      );
      if (!ok) return;
    }
    ref.read(appControllerProvider.notifier).setPermissionMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final pairing = state.pairing;
    final session = state.currentSession;
    final allowedRoots = state.server?.allowedRoots ?? const <String>[];
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _GroupLabel('连接'),
          _Group(
            children: [
              _Row(
                title: state.server?.serverName ??
                    pairing?.serverName ??
                    '未连接',
                subtitle: pairing?.wsUrl ?? '尚未配对',
                trailing: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: state.connection == ConnectionStatus.connected
                        ? scheme.primary.withValues(alpha: 0.12)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    _connectionLabel(state.connection),
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: state.connection == ConnectionStatus.connected
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
              _Row(
                title: '证书指纹',
                subtitle: _fingerprint(pairing?.fingerprint),
                mono: true,
              ),
              _Row(
                title: '设备 ID',
                subtitle: pairing?.deviceId ?? '未保存',
                mono: true,
              ),
              _Row(
                title: '重新连接',
                subtitle: 'daemon 重启或网络恢复后可以手动重试',
                trailing: TextButton(
                  onPressed: controller.reconnect,
                  child: const Text('连接'),
                ),
              ),
            ],
          ),
          _GroupLabel('已配对设备'),
          _Group(
            children: [
              _Row(
                title: '多设备并发',
                subtitle: state.devices.isEmpty
                    ? '点刷新从 daemon 获取设备列表'
                    : '${state.devices.length} 台设备可同时查看会话；权限由最先响应者决定',
                trailing: TextButton(
                  onPressed: controller.requestDevices,
                  child: const Text('刷新'),
                ),
              ),
              if (state.devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(13),
                  child: Text(
                    '尚未加载设备。',
                    style: TextStyle(fontSize: 12),
                  ),
                )
              else
                for (final device in state.devices)
                  _DeviceRow(
                    device: device,
                    onRotate: () => _rotateDevice(device),
                    onRevoke: () => _revokeDevice(device),
                  ),
            ],
          ),
          _GroupLabel('权限'),
          _Group(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 13, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '权限模式',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      session == null
                          ? '打开一个会话后可以切换'
                          : '只对当前会话生效：${session.title}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              for (final info in permissionModeInfos)
                _ModeRow(
                  info: info,
                  selected: session?.permissionMode == info.value,
                  enabled: session != null,
                  onTap: () => _selectMode(info.value),
                ),
            ],
          ),
          _GroupLabel('运行限制'),
          _Group(
            children: [
              _Row(
                title: '单轮预算上限',
                subtitle: state.server == null
                    ? '连接后显示'
                    : '\$${state.server!.maxBudgetUsd.toStringAsFixed(2)} / 轮',
              ),
              _Row(
                title: '单轮最大轮数',
                subtitle: state.server == null
                    ? '连接后显示'
                    : '${state.server!.maxTurns} 轮',
              ),
            ],
          ),
          _GroupLabel('工作目录'),
          _Group(
            children: [
              if (allowedRoots.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(13),
                  child: Text(
                    'daemon 没有返回工作目录白名单。',
                    style: TextStyle(fontSize: 12),
                  ),
                )
              else
                for (final root in allowedRoots)
                  _Row(
                    title: shortenPath(root, keep: 3),
                    subtitle: root,
                    mono: true,
                  ),
            ],
          ),
          _GroupLabel('外观'),
          _Group(
            children: [
              Padding(
                padding: const EdgeInsets.all(13),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('浅色'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('深色'),
                      ),
                    ],
                    selected: {state.themeMode},
                    onSelectionChanged: (value) =>
                        controller.setThemeMode(value.first),
                  ),
                ),
              ),
            ],
          ),
          _GroupLabel('安全'),
          _Group(
            children: [
              _Row(
                title: '断开并清除配对',
                subtitle: '删除设备 token 与本地缓存',
                danger: true,
                trailing: TextButton(
                  onPressed: _disconnect,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: const Text('断开'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Claude Remote 0.1.0 · 协议 v1',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: scheme.onSurface.withValues(alpha: 0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.onRotate,
    required this.onRevoke,
  });

  final DeviceInfo device;
  final VoidCallback onRotate;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lastSeen =
        device.lastSeenAt == null ? '从未连接' : relativeTime(device.lastSeenAt!);
    return Padding(
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (device.current) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          '本机',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${device.id} · $lastSeen',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9.5,
                    height: 1.4,
                    color: scheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onRotate,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('轮换'),
          ),
          TextButton(
            onPressed: onRevoke,
            style: TextButton.styleFrom(
              foregroundColor: scheme.error,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.info,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final PermissionModeInfo info;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = info.dangerous ? scheme.error : scheme.primary;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected
                    ? accent
                    : scheme.onSurface.withValues(alpha: 0.35),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: info.dangerous ? scheme.error : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      info.description,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              if (info.dangerous)
                Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: scheme.error,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          letterSpacing: 1,
          fontWeight: FontWeight.w600,
          color: Theme.of(context)
              .colorScheme
              .onSurface
              .withValues(alpha: 0.42),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        items.add(Divider(height: 1, color: scheme.outlineVariant));
      }
      items.add(children[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.subtitle,
    this.trailing,
    this.mono = false,
    this.danger = false,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;
  final bool mono;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: danger ? scheme.error : null,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: mono ? 'monospace' : null,
                    fontSize: mono ? 10 : 10.5,
                    height: 1.45,
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );
  }
}
