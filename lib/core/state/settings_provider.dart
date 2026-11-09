import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:keel/core/regional_formatters.dart';
import 'package:keel/src/rust/api/settings.dart';

/// 启动时读到的设置。`main` 里用真实值覆盖；测试里用默认值（不读不写文件）。
final initialSettingsProvider = Provider<Settings>(
  (ref) => Settings(language: null, theme: null, formatLocale: null),
);

/// 保存设置的动作。`main` 里换成调用 Rust 的实现；默认什么都不做（测试）。
final settingsSinkProvider = Provider<Future<void> Function(Settings)>(
  (ref) => (settings) async {},
);

/// 加载失败或来自更新版本的配置不允许覆盖；界面仍可临时切换语言/主题。
final settingsWritableProvider = Provider<bool>((ref) => true);
final initialSettingsErrorProvider = Provider<Object?>((ref) => null);

/// 当前设置。语言、主题和显示区域各自更新自己的字段，再一起写回文件。
final settingsProvider = StateProvider<Settings>(
  (ref) => ref.watch(initialSettingsProvider),
);

final initialRegionalSettingsProvider = Provider<RegionalSettings>(
  (ref) => RegionalSettings(timeZone: null, currency: null),
);
final regionalSettingsSinkProvider =
    Provider<Future<void> Function(RegionalSettings)>(
      (ref) => (settings) async {},
    );

class RegionalSettingsNotifier extends Notifier<RegionalSettings> {
  @override
  RegionalSettings build() => ref.read(initialRegionalSettingsProvider);

  void setTimeZone(String? value) {
    if (ref.read(preferencesImportGateProvider).blocksWrites ||
        (value != null && !supportedTimeZones.contains(value)) ||
        value == state.timeZone) {
      return;
    }
    state = RegionalSettings(timeZone: value, currency: state.currency);
    unawaited(ref.read(settingsSaveProvider.notifier).saveLatest());
  }

  void setCurrency(String? value) {
    if (ref.read(preferencesImportGateProvider).blocksWrites ||
        (value != null && !supportedCurrencies.contains(value)) ||
        value == state.currency) {
      return;
    }
    state = RegionalSettings(timeZone: state.timeZone, currency: value);
    unawaited(ref.read(settingsSaveProvider.notifier).saveLatest());
  }

  void applyImported(RegionalSettings settings) => state = settings;
}

final regionalSettingsProvider =
    NotifierProvider<RegionalSettingsNotifier, RegionalSettings>(
      RegionalSettingsNotifier.new,
    );

/// 导入期间封闭新的偏好写入；落盘后回读失败时保持封闭，防止旧 UI 覆盖新配置。
class PreferencesImportState {
  const PreferencesImportState({
    this.busy = false,
    this.reloadRequired = false,
  });
  final bool busy;
  final bool reloadRequired;
  bool get blocksWrites => busy || reloadRequired;
}

class PreferencesImportGate extends Notifier<PreferencesImportState> {
  bool _disposed = false;

  @override
  PreferencesImportState build() {
    ref.onDispose(() => _disposed = true);
    return const PreferencesImportState();
  }

  bool begin({bool reload = false}) {
    if (_disposed || state.busy || reload != state.reloadRequired) return false;
    state = PreferencesImportState(
      busy: true,
      reloadRequired: state.reloadRequired,
    );
    return true;
  }

  void saved() {
    if (!_disposed) {
      state = const PreferencesImportState(busy: true, reloadRequired: true);
    }
  }

  void reloaded() {
    if (!_disposed) state = const PreferencesImportState(busy: true);
  }

  void finish() {
    if (!_disposed) {
      state = PreferencesImportState(reloadRequired: state.reloadRequired);
    }
  }
}

final preferencesImportGateProvider =
    NotifierProvider<PreferencesImportGate, PreferencesImportState>(
      PreferencesImportGate.new,
    );

class SettingsSaveState {
  const SettingsSaveState({this.saving = false, this.error});

  final bool saving;
  final Object? error;
}

/// 只协调配置文件写入，不承担另一套 UI 状态。每次都保存完整快照，按修改顺序串行写。
class SettingsSaveNotifier extends Notifier<SettingsSaveState> {
  Future<void> _tail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  @override
  SettingsSaveState build() {
    ref.onDispose(() => _disposed = true);
    return SettingsSaveState(error: ref.read(initialSettingsErrorProvider));
  }

  Future<void> saveLatest() {
    if (!ref.read(settingsWritableProvider) ||
        ref.read(preferencesImportGateProvider).blocksWrites) {
      return Future<void>.value();
    }
    final revision = ++_revision;
    final snapshot = ref.read(settingsProvider);
    final regionalSnapshot = ref.read(regionalSettingsProvider);
    final save = ref.read(settingsSinkProvider);
    final saveRegional = ref.read(regionalSettingsSinkProvider);
    _tail = _tail.then((_) async {
      if (_disposed) return;
      Object? error;
      try {
        await save(snapshot);
        await saveRegional(regionalSnapshot);
      } catch (failure) {
        error = failure;
      }
      // 旧请求的结果不能清掉较新请求的加载态/错误，也不把内部错误打印到控制台。
      if (!_disposed && revision == _revision) {
        state = SettingsSaveState(error: error);
      }
    });
    state = const SettingsSaveState(saving: true);
    return _tail;
  }

  Future<void> retry() => state.saving ? _tail : saveLatest();

  Future<void> drain() => _tail;

  /// 仅在排空队列并完成导入回读后调用，不写文件。
  void acceptImported() => state = const SettingsSaveState();
}

final settingsSaveProvider =
    NotifierProvider<SettingsSaveNotifier, SettingsSaveState>(
      SettingsSaveNotifier.new,
    );

/// 更新并保存设置。界面立即生效，写盘失败由全局提示展示，重试保存当前完整快照。
void updateSettings(Ref ref, Settings Function(Settings current) change) {
  if (ref.read(preferencesImportGateProvider).blocksWrites) return;
  final next = change(ref.read(settingsProvider));
  ref.read(settingsProvider.notifier).state = next;
  unawaited(ref.read(settingsSaveProvider.notifier).saveLatest());
}
