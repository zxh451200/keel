// 开发期截图工具（不进 test/，不参与常规 flutter test 汇总）。
// 用法：flutter test tool/ui_capture/capture_test.dart
// 产物：build/ui-shot/*.png
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keel/core/state/app_status_provider.dart';
import 'package:keel/core/state/user_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';
import 'package:keel/features/auth/state/auth_providers.dart';
import 'package:keel/l10n/app_localizations.dart';
import 'package:keel/src/rust/api/app.dart';
import 'package:keel/src/rust/api/auth.dart';
import 'package:keel/src/rust/api/users.dart';
import 'package:keel/ui/shell.dart';
import 'package:keel/ui/theme.dart';
import 'package:keel/ui/tokens.dart';
import 'package:keel/ui/ui_page.dart';
import 'package:keel/ui/widgets/ui_layout.dart';

const _user = UserInfo(name: 'Zhang San', role: 'admin', permissions: []);
const _outDir = 'build/ui-shot';

Future<void> _loadFonts() async {
  // 测试环境默认没有真实字形，会把文字画成方块。这里把系统字体塞进主题声明的
  // 字体族，截图才看得懂排版。
  final candidates = [
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\segoeui.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader('Microsoft YaHei UI')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {
      // 换下一个候选；字体不是断言对象，失败就退回默认字形。
    }
  }
}

UiPage _fixture(String kind, String title, IconData icon) => UiPage(
  kind: kind,
  title: (_) => title,
  icon: icon,
  builder: (_, _) => _StubPage(title: title),
);

class _StubPage extends StatelessWidget {
  const _StubPage({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = UiTokens.of(context);
    return SingleChildScrollView(
      padding: UiTokens.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UiPageHeader(title: title, subtitle: 'Fixture page body'),
          const SizedBox(height: UiTokens.gapLg),
          UiPanel(
            header: Text('Panel header', style: tokens.sectionTitle),
            child: Text('Panel body content', style: tokens.body),
          ),
          const SizedBox(height: UiTokens.gapLg),
          UiBusyStrip(message: 'Working…'),
        ],
      ),
    );
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_outDir/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote ${file.path} (${bytes.lengthInBytes} bytes)');
}

final _boundaryKey = GlobalKey();

Future<void> _pumpShell(WidgetTester tester, {required Brightness mode}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStatusProvider.overrideWith(
          (ref) async => const AppStatus(version: '0.0.1', databaseReady: true),
        ),
        authStatusProvider.overrideWith(
          (ref) async => const AuthStatusDto(
            loginRequired: false,
            hasPassword: false,
            locked: false,
          ),
        ),
        currentUserProvider.overrideWith((ref) async => _user),
        usersProvider.overrideWith((ref) async => const [_user]),
        startupRestoreProvider.overrideWith(
          (ref) async => const StartupRestoreStatus(outcome: 'none'),
        ),
        initialWorkspaceNavigationPreferencesProvider.overrideWithValue(
          WorkspaceNavigationPreferences(
            favoriteKinds: const ['customers'],
            recentKinds: const ['audit', 'tasks'],
          ),
        ),
        workspaceNavigationSinkProvider.overrideWithValue((value) async {}),
      ],
      child: FluentApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: keelFluentTheme(Brightness.light),
        darkTheme: keelFluentTheme(Brightness.dark),
        themeMode: mode == Brightness.light ? ThemeMode.light : ThemeMode.dark,
        home: RepaintBoundary(
          key: _boundaryKey,
          child: KeelShell(
            pages: [
              // 与 lib/app.dart 的模块数量和 kind 保持一致，截图才代表真机首页。
              _fixture('audit', 'Audit log', FluentIcons.list),
              _fixture('diagnostics', 'Diagnostics', FluentIcons.health),
              _fixture('backup', 'Backup', FluentIcons.cloud),
              _fixture('customers', 'Customers', FluentIcons.people),
              _fixture('new-user', 'Create user', FluentIcons.contact),
              _fixture('security', 'Security', FluentIcons.lock),
              _fixture(
                'settings-import',
                'Import settings',
                FluentIcons.settings,
              ),
              _fixture('tasks', 'Tasks', FluentIcons.task_manager),
              _fixture('samples', 'Samples', FluentIcons.code),
              _fixture('form_samples', 'Form samples', FluentIcons.edit),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // 测试环境默认关闭阴影，截图要看到真实抬升效果必须打开。
    debugDisableShadows = false;
    await _loadFonts();
  });

  tearDownAll(() {
    debugDisableShadows = true;
  });

  testWidgets('capture shell light', (tester) async {
    await _pumpShell(tester, mode: Brightness.light);
    await _capture(tester, 'shell-light');
  });

  testWidgets('capture shell dark', (tester) async {
    await _pumpShell(tester, mode: Brightness.dark);
    await _capture(tester, 'shell-dark');
  });

  testWidgets('capture component board', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      FluentTheme(
        data: keelFluentTheme(Brightness.light),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: ColoredBox(
              color: const Color(0xFFF4F6F9),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Builder(
                  builder: (context) {
                    final tokens = UiTokens.of(context);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Component board', style: tokens.dashboardTitle),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            const UiStatusPill(
                              label: 'Database ready',
                              tone: UiTone.success,
                            ),
                            const UiStatusPill(
                              label: 'Version 0.0.1',
                              icon: FluentIcons.info,
                            ),
                            const UiStatusPill(
                              label: 'Blocked',
                              tone: UiTone.danger,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: const [
                            Expanded(
                              child: UiStatCard(
                                label: 'Customers',
                                value: '1,284',
                                hint: 'Page 1 of 13',
                                tone: UiTone.accent,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: UiStatCard(
                                label: 'Audit today',
                                value: '96',
                                hint: 'Last write 17:02',
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: UiStatCard(
                                label: 'Last backup',
                                value: '3.4 MB',
                                hint: '2 hours ago',
                                tone: UiTone.success,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        UiBusyStrip(message: 'Preparing the diagnostic pack…'),
                        const SizedBox(height: 16),
                        Expanded(
                          child: UiPanel(
                            header: Text('Panel', style: tokens.sectionTitle),
                            footer: Text(
                              'Footer',
                              style: tokens.caption?.copyWith(
                                color: tokens.secondaryText,
                              ),
                            ),
                            child: const UiEmpty(
                              icon: FluentIcons.search,
                              message: 'No customers match these filters.',
                              action: SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 不确定进度条是无限动画，pumpAndSettle 永远等不到静止，只能固定 pump。
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, 'components-light');
  });
}
