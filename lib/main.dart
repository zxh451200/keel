import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/api/bridge.dart';
import 'package:keel/app.dart';
import 'package:keel/src/rust/api/settings.dart' show RegionalSettings;
import 'package:keel/core/state/database_provider.dart';
import 'package:keel/core/state/settings_provider.dart';
import 'package:keel/core/workspace/workspace_navigation_preferences_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final init = await initBridge();
  runApp(
    ProviderScope(
      overrides: [
        initialSettingsProvider.overrideWithValue(init.settings),
        initialRegionalSettingsProvider.overrideWithValue(
          init.regionalSettings ??
              RegionalSettings(timeZone: null, currency: null),
        ),
        settingsWritableProvider.overrideWithValue(init.canSave),
        initialSettingsErrorProvider.overrideWithValue(init.settingsError),
        initialDatabaseErrorProvider.overrideWithValue(init.databaseError),
        initialWorkspaceNavigationPreferencesProvider.overrideWithValue(
          init.navigationPreferences,
        ),
        workspaceNavigationWritableProvider.overrideWithValue(init.canSave),
        workspaceNavigationLoadErrorProvider.overrideWithValue(
          init.navigationError,
        ),
        if (init.canSave)
          workspaceNavigationSinkProvider.overrideWithValue(
            saveWorkspaceNavigationToRust,
          ),
        if (init.canSave)
          settingsSinkProvider.overrideWithValue(saveSettingsToRust),
        if (init.canSave)
          regionalSettingsSinkProvider.overrideWithValue(
            saveRegionalSettingsToRust,
          ),
      ],
      child: const KeelApp(),
    ),
  );
}
