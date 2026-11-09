import 'package:fluent_ui/fluent_ui.dart';
import 'package:keel/ui/tokens.dart';

/// Fluent 版确认对话框；返回 true 表示用户确认。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => ContentDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: danger
              ? ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(
                    UiTokens.of(context).colors.dangerFill,
                  ),
                  foregroundColor: const WidgetStatePropertyAll(Colors.white),
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
