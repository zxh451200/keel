import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/ui/widgets/ui_dialogs.dart';

const userWorkspaceEditorId = 'new-user-workspace';

/// 新用户工作区草稿；关闭标签前用于判断是否有未保存内容。
class UserDraft {
  const UserDraft({
    this.name = '',
    this.role = 'operator',
    this.busy = false,
    this.confirming = false,
    this.error,
    this.revision = 0,
  });

  final String name;
  final String role;
  final bool busy;
  final bool confirming;
  final Object? error;
  final int revision;
  bool get dirty => name.isNotEmpty || role != 'operator';

  UserDraft copyWith({
    String? name,
    String? role,
    bool? busy,
    bool? confirming,
    Object? error,
  }) => UserDraft(
    name: name ?? this.name,
    role: role ?? this.role,
    busy: busy ?? this.busy,
    confirming: confirming ?? this.confirming,
    error: error,
    revision: revision + (name != null || role != null ? 1 : 0),
  );
}

final userDraftProvider = StateProvider.autoDispose.family<UserDraft, String>(
  (ref, id) => const UserDraft(),
);

/// 与 Rust str::trim / char::is_control 对齐；字符数按 Unicode 标量计。
String normalizeUserName(String value) {
  bool space(int rune) =>
      rune >= 0x09 && rune <= 0x0d ||
      rune == 0x20 ||
      rune == 0x85 ||
      rune == 0xa0 ||
      rune == 0x1680 ||
      rune >= 0x2000 && rune <= 0x200a ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202f ||
      rune == 0x205f ||
      rune == 0x3000;
  final runes = value.runes.toList();
  var start = 0;
  var end = runes.length;
  while (start < end && space(runes[start])) {
    start++;
  }
  while (end > start && space(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes.sublist(start, end));
}

String? validateUserName(AppLocalizations t, String? value) {
  final name = normalizeUserName(value ?? '');
  if (name.isEmpty) return t.userNameRequired;
  if (name.runes.length > 32) return t.userNameTooLong;
  if (name.runes.any((rune) => rune <= 0x1f || rune >= 0x7f && rune <= 0x9f)) {
    return t.userNameControl;
  }
  return null;
}

Future<bool> canDiscardUserDraft(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
    return false;
  }
  final provider = userDraftProvider(id);
  final draft = ref.read(provider);
  if (draft.busy || draft.confirming) return false;
  if (!draft.dirty) return true;
  final t = AppLocalizations.of(context);
  ref.read(provider.notifier).state = draft.copyWith(
    confirming: true,
    error: draft.error,
  );
  try {
    final discard = await showConfirmDialog(
      context,
      title: t.unsavedTitle,
      message: t.unsavedMessage,
      confirmLabel: t.actionDiscard,
      cancelLabel: t.actionKeepEditing,
      danger: true,
    );
    if (!context.mounted || !discard) return false;
    final current = ref.read(provider);
    return ModalRoute.of(context)?.isCurrent != false &&
        current.revision == draft.revision &&
        !current.busy &&
        current.name == draft.name &&
        current.role == draft.role;
  } finally {
    if (context.mounted) {
      final current = ref.read(provider);
      ref.read(provider.notifier).state = current.copyWith(
        confirming: false,
        error: current.error,
      );
    }
  }
}
