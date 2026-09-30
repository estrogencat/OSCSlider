import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updater.dart';
import 'config_store.dart';
import 'live_controller.dart';
import 'osc_input_hub.dart';

Future<void> showUpdateDialog(
  BuildContext context, {
  required UpdateInfo info,
  required String currentVersion,
  required LiveController live,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(info: info, currentVersion: currentVersion, live: live),
  );
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  final String currentVersion;
  final LiveController live;
  const _UpdateDialog({required this.info, required this.currentVersion, required this.live});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

enum _Stage { idle, downloading, installing, downloaded, failed }

class _UpdateDialogState extends State<_UpdateDialog> {
  final _kind = detectInstallKind();
  late final ReleaseAsset? _asset = assetFor(widget.info, _kind);
  _Stage _stage = _Stage.idle;
  int _received = 0;
  int _total = 0;
  String? _error;
  File? _file;
  UpdateCancelToken? _cancel;

  UpdateInfo get info => widget.info;

  Future<void> _start() async {
    final asset = _asset;
    if (asset == null) return;
    if (_kind == InstallKind.android) {
      // the browser downloads it, then Android's own installer takes over.
      await launchUrl(asset.url, mode: LaunchMode.externalApplication);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final cancel = _cancel = UpdateCancelToken();
    setState(() {
      _stage = _Stage.downloading;
      _received = 0;
      _total = asset.size;
      _error = null;
    });
    try {
      final file = await downloadUpdate(
        info,
        asset,
        _kind,
        cancel: cancel,
        onProgress: (r, t) {
          if (mounted) {
            setState(() {
              _received = r;
              _total = t;
            });
          }
        },
      );
      if (!mounted) return;
      if (updatesInPlace(_kind)) setState(() => _stage = _Stage.installing);
      var restarting = false;
      try {
        restarting = await applyUpdate(_kind, file);
      } catch (_) {
        if (updatesInPlace(_kind)) rethrow;
        // opening it failed, but the file is there - "Show in folder" still works.
      }
      if (restarting) {
        try {
          await Future.wait([ConfigStore.flush(), oscInputHub.stop()]).timeout(const Duration(seconds: 2));
        } catch (_) {}
        exit(0);
      }
      if (mounted) {
        setState(() {
          _stage = _Stage.downloaded;
          _file = file;
        });
      }
    } catch (e) {
      if (!mounted || cancel.cancelled) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e.toString();
      });
    }
  }

  void _skip() {
    widget.live.config.skippedUpdateVersion = info.version;
    widget.live.persist();
    Navigator.of(context).pop();
  }

  void _cancelDownload() {
    _cancel?.cancelled = true;
    setState(() => _stage = _Stage.idle);
  }

  String get _actionLabel => switch (_kind) {
    InstallKind.windowsInstaller || InstallKind.appImage => 'Update and restart',
    InstallKind.deb => 'Download and install',
    InstallKind.macos => 'Download',
    InstallKind.android => 'Download APK',
    _ => 'Download',
  };

  String get _afterDownloadText => switch (_kind) {
    InstallKind.deb =>
      'Your software installer should open with the new package. Install it, then restart '
          'OSCSlider.',
    InstallKind.macos =>
      'The disk image is open. Quit OSCSlider, then drag the new one into Applications and '
          'replace the old copy.',
    InstallKind.windowsPortable || InstallKind.linuxPortable =>
      'Close OSCSlider and extract it over this copy\'s folder. Your settings are stored separately, so '
          'they\'ll carry over.',
    _ => 'Saved to your Downloads folder.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _stage == _Stage.downloading || _stage == _Stage.installing;
    final published = info.publishedAt?.toLocal();
    return AlertDialog(
      title: Text('OSCSlider v${info.version}${info.prerelease ? ' (pre-release)' : ''}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You have v${widget.currentVersion}'
              '${published == null ? '' : '  ·  released ${published.year}-${_two(published.month)}-${_two(published.day)}'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 340),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: SelectionArea(child: _ReleaseNotes(info.notes)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ..._status(theme),
          ],
        ),
      ),
      actions: [
        if (_stage == _Stage.downloading)
          TextButton(onPressed: _cancelDownload, child: const Text('Cancel'))
        else if (!busy) ...[
          TextButton(onPressed: () => launchUrl(info.pageUrl), child: const Text('Release page')),
          if (_stage != _Stage.downloaded) TextButton(onPressed: _skip, child: const Text('Skip this version')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_stage == _Stage.downloaded ? 'Close' : 'Later'),
          ),
          if (_stage == _Stage.downloaded && _file != null)
            FilledButton.tonal(onPressed: () => revealFile(_file!), child: const Text('Show in folder'))
          else if (_asset != null)
            FilledButton(onPressed: _start, child: Text(_stage == _Stage.failed ? 'Try again' : _actionLabel)),
        ],
      ],
    );
  }

  List<Widget> _status(ThemeData theme) {
    switch (_stage) {
      case _Stage.idle:
        if (_asset == null) {
          return [
            Text(
              'There\'s no download for this system in the release. Grab it from the release page instead.',
              style: theme.textTheme.bodySmall,
            ),
          ];
        }
        return [
          Text('${_asset.name}${_asset.size > 0 ? '  ·  ${_mb(_asset.size)}' : ''}', style: theme.textTheme.bodySmall),
        ];
      case _Stage.downloading:
        final fraction = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
        return [
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 6),
          Text(
            'Downloading  ${_mb(_received)}${_total > 0 ? ' of ${_mb(_total)}' : ''}',
            style: theme.textTheme.bodySmall,
          ),
        ];
      case _Stage.installing:
        return [
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(
            _kind == InstallKind.windowsInstaller
                ? 'Starting the installer. OSCSlider will close and reopen once it\'s updated.'
                : 'Restarting into the new version…',
            style: theme.textTheme.bodySmall,
          ),
        ];
      case _Stage.downloaded:
        return [
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(_afterDownloadText, style: theme.textTheme.bodySmall)),
            ],
          ),
        ];
      case _Stage.failed:
        return [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _error ?? 'Update failed',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ];
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// just enough markdown for GitHub release notes: headings, bullets,
/// bold and links shown as plain text. tables and html are dropped.
class _ReleaseNotes extends StatelessWidget {
  final String markdown;
  const _ReleaseNotes(this.markdown);

  static String _inline(String s) => s
      .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAll(RegExp(r'<[^>]+>'), '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = markdown.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '').trim();
    if (text.isEmpty) return Text('No release notes.', style: theme.textTheme.bodySmall);
    final out = <Widget>[];
    var inCode = false;
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trimLeft().startsWith('```')) {
        inCode = !inCode;
        continue;
      }
      if (inCode || line.trimLeft().startsWith('|') || RegExp(r'^\s*>\s*\[!').hasMatch(line)) continue;
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
      if (heading != null) {
        out.add(
          Padding(
            padding: EdgeInsets.only(top: out.isEmpty ? 0 : 10, bottom: 4),
            child: Text(
              _inline(heading.group(2)!),
              style: (heading.group(1)!.length <= 2 ? theme.textTheme.titleMedium : theme.textTheme.titleSmall)
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        );
      } else if (bullet != null) {
        final indent = (bullet.group(1)!.length ~/ 2) * 14.0;
        out.add(
          Padding(
            padding: EdgeInsets.only(left: indent, bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(_inline(bullet.group(2)!), style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
        );
      } else if (line.trim().isEmpty) {
        if (out.isNotEmpty && out.last is! SizedBox) out.add(const SizedBox(height: 6));
      } else {
        out.add(Text(_inline(line.replaceFirst(RegExp(r'^\s*>\s?'), '')), style: theme.textTheme.bodyMedium));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: out);
  }
}
