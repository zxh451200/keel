import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/errors/error_text.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/diagnostics/state/diagnostics_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/diagnostics.dart';
import 'package:keel/src/rust/api/users.dart';

/// 对本次运行保留的脱敏日志文件做字面检索，不是内存事件筛选。
class DiagnosticHistoryDialog extends ConsumerStatefulWidget {
  const DiagnosticHistoryDialog({super.key});

  @override
  ConsumerState<DiagnosticHistoryDialog> createState() => _HistoryState();
}

class _HistoryState extends ConsumerState<DiagnosticHistoryDialog> {
  final _text = TextEditingController();
  bool _busy = false;
  bool _invalid = false;
  DiagnosticHistoryPage? _page;
  Object? _error;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _text.dispose();
    super.dispose();
  }

  bool get _interactive =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false;

  UserInfo? _readyUser() {
    final user = ref.read(currentUserProvider);
    return user.isLoading || user.hasError ? null : user.asData?.value;
  }

  Future<void> _search() async {
    if (!_interactive || _busy) return;
    final owner = _readyUser();
    if (!hasPermission(owner, 'diagnostics.export')) return;
    final text = normalizeDiagnosticId(_text.text);
    setState(() => _invalid = !validDiagnosticId(text));
    if (_invalid) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _page = null;
      _error = null;
    });
    try {
      final page = await ref.read(diagnosticHistorySourceProvider)(
        DiagnosticHistoryQuery(text: text),
      );
      if (!mounted) return;
      final current = _readyUser();
      if (!_interactive ||
          generation != _generation ||
          owner?.name != current?.name ||
          owner?.role != current?.role ||
          !hasPermission(current, 'diagnostics.export')) {
        return;
      }
      setState(() => _page = page);
    } catch (error) {
      if (_interactive &&
          generation == _generation &&
          owner?.name == _readyUser()?.name &&
          owner?.role == _readyUser()?.role &&
          hasPermission(_readyUser(), 'diagnostics.export')) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.62);
    ref.listen(currentUserProvider, (previous, next) {
      final a = previous?.asData?.value;
      final b = next.asData?.value;
      if (a?.name != b?.name ||
          a?.role != b?.role ||
          next.isLoading ||
          next.hasError ||
          next.asData == null) {
        setState(() {
          _generation++;
          _page = null;
          _error = null;
          _busy = false;
        });
      }
    });
    final identity = ref.watch(currentUserProvider);
    final allowed =
        !identity.isLoading &&
        !identity.hasError &&
        hasPermission(identity.asData?.value, 'diagnostics.export');
    final page = allowed ? _page : null;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
      title: Text(t.diagHistoryTitle),
      content: SizedBox(
        width: 760,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.diagHistoryScope, style: TextStyle(color: muted)),
            const SizedBox(height: 8),
            TextBox(
              controller: _text,
              enabled: allowed && !_busy,
              placeholder: t.diagHistoryText,
              onSubmitted: (_) => _search(),
            ),
            if (_invalid)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  t.diagSearchIdInvalid,
                  style: theme.typography.caption?.copyWith(
                    color: const Color(0xFFC42B1C),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Button(
              onPressed: allowed && !_busy ? _search : null,
              child: Text(t.actionSearch),
            ),
            if (_busy) const ProgressBar(),
            if (_error != null && allowed)
              Text(
                t.loadFailed(errorText(t, _error!)),
                style: TextStyle(color: const Color(0xFFC42B1C)),
              ),
            if (page != null && page.truncated) Text(t.diagHistoryTruncated),
            if (page != null && page.lines.isEmpty) Text(t.diagHistoryEmpty),
            if (page != null)
              Expanded(
                child: ListView.builder(
                  itemCount: page.lines.length,
                  itemBuilder: (_, index) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: SelectableText(
                      page.lines[index],
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionClose),
        ),
      ],
    );
  }
}
