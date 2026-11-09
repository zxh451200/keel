import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keel/core/state/current_activities_provider.dart';
import 'package:keel/l10n/app_localizations.dart';

String currentActivityLabel(AppLocalizations t, CurrentActivity activity) =>
    switch (activity) {
      CurrentActivity.backup => t.statusActivityBackup,
      CurrentActivity.diagnostics => t.statusActivityDiagnostics,
      CurrentActivity.settingsSave => t.settingsSaving,
      CurrentActivity.auditExport => t.auditExportWorking,
      CurrentActivity.auditPrint => t.printPreviewTitle,
      CurrentActivity.settingsImport => t.navSettingsImport,
      CurrentActivity.databaseRetry => t.databaseRetrying,
    };

/// The shell supplies only registered destinations and its guarded navigation.
/// Without a shell (e.g. embedded TasksPage), rows remain readable but disabled.
class CurrentActivitiesNavigation extends InheritedWidget {
  const CurrentActivitiesNavigation({
    super.key,
    required this.registeredPages,
    required this.onLocate,
    required super.child,
  });

  final Set<String> registeredPages;
  final ValueChanged<CurrentActivity>? onLocate;

  static CurrentActivitiesNavigation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CurrentActivitiesNavigation>();

  @override
  bool updateShouldNotify(CurrentActivitiesNavigation oldWidget) => true;
}

/// Live categories only. No fabricated percentages, cancellation or history.
class CurrentActivities extends ConsumerWidget {
  const CurrentActivities({super.key, this.registeredPages, this.onLocate});

  final Set<String>? registeredPages;
  final ValueChanged<CurrentActivity>? onLocate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final activities = ref.watch(currentActivitiesProvider);
    final navigation = CurrentActivitiesNavigation.maybeOf(context);
    final pages =
        registeredPages ?? navigation?.registeredPages ?? const <String>{};
    final locate = onLocate ?? navigation?.onLocate;
    final active =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(t.statusActiveOperations(activities.length)),
        ),
        Text(t.currentActivitiesScope),
        if (activities.isEmpty) Text(t.taskViewEmpty),
        for (final activity in activities)
          Padding(
            key: ValueKey(activity),
            padding: const EdgeInsets.only(top: 8),
            child: Button(
              onPressed:
                  active &&
                      locate != null &&
                      currentActivityDestination(
                            activity,
                            current: activities,
                            registeredPages: pages,
                          ) !=
                          null
                  ? () {
                      if (!context.mounted ||
                          !TickerMode.valuesOf(context).enabled ||
                          ModalRoute.of(context)?.isCurrent == false) {
                        return;
                      }
                      if (currentActivityDestination(
                            activity,
                            current: ref.read(currentActivitiesProvider),
                            registeredPages: pages,
                          ) ==
                          null) {
                        return;
                      }
                      locate(activity);
                    }
                  : null,
              child: Text(currentActivityLabel(t, activity)),
            ),
          ),
      ],
    );
  }
}
