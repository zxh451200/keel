import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/ping.dart' show PingRequest, PingResponse;
import 'package:keel/ui/widgets/ui_layout.dart';

/// 桥接验收页：同步字符串、同步结构体、异步结构体三类调用。
class SamplesPage extends StatefulWidget {
  const SamplesPage({
    super.key,
    this.syncGreet = samplesGreet,
    this.syncPing = samplesSyncPing,
    this.asyncPing = samplesAsyncPing,
  });

  final String Function() syncGreet;
  final PingResponse Function() syncPing;
  final Future<PingResponse> Function(PingRequest request) asyncPing;

  @override
  State<SamplesPage> createState() => _SamplesPageState();
}

class _SamplesPageState extends State<SamplesPage> {
  PingResponse? _asyncResult;
  bool _running = false;

  Future<void> _runAsyncPing() async {
    setState(() => _running = true);
    final response = await widget.asyncPing(
      PingRequest(
        sequence: 2,
        payload: 'keel-async',
        tags: const ['bridge', 'stage-0', 'tokio'],
      ),
    );
    if (!mounted) return;
    setState(() {
      _asyncResult = response;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final response = _asyncResult;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UiPageHeader(title: t.samplesTitle, subtitle: t.samplesPageHint),
          const SizedBox(height: 18),
          _SamplePanel(
            icon: FluentIcons.text_field,
            title: t.sampleSyncString,
            action: 'greet(name: "Tom")',
            result: widget.syncGreet(),
          ),
          const SizedBox(height: 12),
          _SamplePanel(
            icon: FluentIcons.code,
            title: t.sampleSyncStruct,
            action: 'ping(request: PingRequest(sequence: 1, …))',
            result: _formatPing(widget.syncPing()),
          ),
          const SizedBox(height: 12),
          _SamplePanel(
            icon: FluentIcons.lightning_bolt,
            title: t.sampleAsyncStruct,
            action: 'pingAsync(request: PingRequest(sequence: 2, …))',
            result: _running
                ? null
                : response == null
                ? t.sampleNotCalled
                : _formatPing(response),
            footer: FilledButton(
              onPressed: _running ? null : _runAsyncPing,
              child: Text(t.sampleCallAsync),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatPing(PingResponse response) {
  return 'sequence=${response.sequence} echo=${response.echo} '
      'tagCount=${response.tagCount} workMs=${response.workMs} '
      'serverTimeMs=${response.serverTimeMs}';
}

class _SamplePanel extends StatelessWidget {
  const _SamplePanel({
    required this.icon,
    required this.title,
    required this.action,
    required this.result,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String action;
  final String? result;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final t = AppLocalizations.of(context);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    final code = theme.typography.body?.copyWith(fontSize: 13, height: 1.55);
    return UiPanel(
      header: Row(
        children: [
          Icon(icon, size: 14, color: muted),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.sampleAction(action), style: code),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: (theme.typography.body?.color ?? Colors.black)
                    .withValues(alpha: 0.10),
              ),
            ),
            child: SelectableText(
              t.sampleResult(result ?? t.sampleRunning),
              style: code,
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: 10),
            Align(alignment: AlignmentDirectional.centerEnd, child: footer!),
          ],
        ],
      ),
    );
  }
}
