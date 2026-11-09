import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/features/users/state/user_draft.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/pages/users_page.dart';

const _admin = UserInfo(
  name: 'local',
  role: 'admin',
  permissions: ['users.manage'],
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  ValueNotifier<bool>? visible,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<bool>(
          valueListenable: visible ?? ValueNotifier(true),
          builder: (context, enabled, child) =>
              TickerMode(enabled: enabled, child: const UsersPage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stale save refuses refreshing, failed and denied identity', (
    tester,
  ) async {
    var identity = Completer<UserInfo>()..complete(_admin);
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) => identity.future),
        userServiceProvider.overrideWithValue(
          UserService(
            current: () async => _admin,
            list: () async => [_admin],
            create: (_, _) async {
              calls++;
            },
            switchTo: (_) async => _admin,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await _pump(tester, container);
    await tester.enterText(find.byType(TextBox), 'Draft');
    final save = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    identity = Completer<UserInfo>();
    container.invalidate(currentUserProvider);
    container.read(currentUserProvider);
    save();
    expect(calls, 0);
    identity.completeError(StateError('identity unavailable'));
    await tester.pumpAndSettle();
    save();
    expect(calls, 0);
    identity = Completer<UserInfo>()
      ..complete(
        const UserInfo(name: 'viewer', role: 'viewer', permissions: []),
      );
    container.invalidate(currentUserProvider);
    await tester.pumpAndSettle();
    save();
    expect(calls, 0);
    expect(
      container.read(userDraftProvider(userWorkspaceEditorId)).name,
      'Draft',
    );
  });

  testWidgets('hidden and modal callbacks cannot save; failure retains draft', (
    tester,
  ) async {
    var calls = 0;
    final pending = Completer<void>();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => _admin),
        userServiceProvider.overrideWithValue(
          UserService(
            current: () async => _admin,
            list: () async => [_admin],
            create: (_, _) {
              calls++;
              return pending.future;
            },
            switchTo: (_) async => _admin,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await _pump(tester, container, visible: visible);
    await tester.enterText(find.byType(TextBox), 'Draft');
    final save = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    visible.value = false;
    await tester.pump();
    save();
    expect(calls, 0);
    visible.value = true;
    await tester.pump();
    final context = tester.element(find.byType(UsersPage));
    final dialog = showDialog<void>(
      context: context,
      builder: (_) => const ContentDialog(title: Text('Modal')),
    );
    await tester.pumpAndSettle();
    save();
    expect(calls, 0);
    Navigator.of(context).pop();
    await dialog;
    await tester.pumpAndSettle();
    save();
    save();
    expect(calls, 1);
    pending.completeError(StateError('create failed'));
    await tester.pumpAndSettle();
    final draft = container.read(userDraftProvider(userWorkspaceEditorId));
    expect(draft.name, 'Draft');
    expect(draft.busy, isFalse);
    expect(draft.error, isNotNull);
  });

  testWidgets('Enter exposes live error summary and scrolls to name', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith((ref) async => _admin)],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(600, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester, container);
    final name = tester.widget<TextBox>(find.byType(TextBox));
    name.focusNode!.requestFocus();
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(name.focusNode!.hasFocus, isTrue);
    expect(find.byType(TextBox).hitTestable(), findsOneWidget);
    expect(
      tester
          .widgetList<Semantics>(find.byType(Semantics))
          .any((widget) => widget.properties.liveRegion == true),
      isTrue,
    );
  });

  testWidgets('discard approval is invalidated even when content is restored', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith((ref) async => _admin)],
    );
    addTearDown(container.dispose);
    await _pump(tester, container);
    await tester.enterText(find.byType(TextBox), 'Draft');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final provider = userDraftProvider(userWorkspaceEditorId);
    final notifier = container.read(provider.notifier);
    notifier.state = notifier.state.copyWith(name: 'Changed');
    notifier.state = notifier.state.copyWith(name: 'Draft');
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(container.read(provider).name, 'Draft');
    expect(container.read(provider).confirming, isFalse);
  });
}
