import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../state/app_controller.dart';
import 'theme.dart';

class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({super.key});

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  final _url = TextEditingController();
  final _fingerprint = TextEditingController();
  final _code = TextEditingController();
  final _deviceName = TextEditingController(text: 'Android');

  @override
  void dispose() {
    _url.dispose();
    _fingerprint.dispose();
    _code.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    FocusScope.of(context).unfocus();
    try {
      await ref.read(appControllerProvider.notifier).pair(
            url: _url.text,
            fingerprint: _fingerprint.text,
            code: _code.text,
            deviceName: _deviceName.text.trim().isEmpty
                ? 'Android'
                : _deviceName.text.trim(),
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (result == null || !mounted) return;
    final url = result['url'];
    final cert = result['certSha256'];
    final code = result['code'];
    if (url is String) _url.text = url;
    if (cert is String) _fingerprint.text = cert;
    if (code is String) _code.text = code;
    await _pair();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'CR',
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Claude Remote',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: scheme.outlineVariant),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        '配对',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 34),
                const Text(
                  '连接你的电脑',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.9,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '扫描 daemon 终端里的二维码，或手动填写连接信息。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.55),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                _FieldLabel('服务器地址'),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: 'wss://192.168.1.23:8787/ws',
                  ),
                ),
                const SizedBox(height: 14),
                _FieldLabel('证书 SHA-256'),
                TextField(
                  controller: _fingerprint,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                  decoration: const InputDecoration(
                    hintText: '64 位十六进制指纹',
                  ),
                ),
                const SizedBox(height: 14),
                _FieldLabel('一次性配对码'),
                TextField(
                  controller: _code,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                  decoration: const InputDecoration(hintText: '例如 74WCRLLA'),
                ),
                const SizedBox(height: 14),
                _FieldLabel('设备名称'),
                TextField(
                  controller: _deviceName,
                  decoration: const InputDecoration(hintText: 'Android'),
                ),
                if (state.connectionError != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      state.connectionError!,
                      style: TextStyle(color: scheme.onErrorContainer, fontSize: 12.5),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: state.busy ? null : _scan,
                        icon: const Icon(Icons.qr_code_scanner, size: 18),
                        label: const Text('扫描二维码'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: state.busy ? null : _pair,
                        icon: state.busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.link, size: 18),
                        label: Text(state.busy ? '连接中…' : '配对并连接'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: () {
                      _url.text = 'wss://10.0.2.2:8787/ws';
                    },
                    child: const Text('使用模拟器地址（10.0.2.2）'),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.terminal, size: 18, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '在电脑上运行：\ncd daemon && npm run dev\n终端会打印 WSS 地址、证书指纹、配对码和二维码。',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.6,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.62),
        ),
      ),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              for (final barcode in capture.barcodes) {
                final raw = barcode.rawValue;
                if (raw == null) continue;
                try {
                  final decoded = jsonDecode(raw);
                  if (decoded is Map && decoded['url'] is String) {
                    _handled = true;
                    Navigator.of(context).pop(
                      decoded.map(
                        (key, value) => MapEntry(key.toString(), value),
                      ),
                    );
                    return;
                  }
                } catch (_) {
                  /* not our QR payload */
                }
              }
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '无法打开相机：$error\n请返回后手动填写连接信息。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.6),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 236,
              height: 236,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.pineLight, width: 2),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.14),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                  const Spacer(),
                  const Center(
                    child: Text(
                      '扫描电脑终端里的配对二维码',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
