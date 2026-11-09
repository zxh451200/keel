import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 两种语言的 ARB 必须一一对应：少键、多键或占位符不一致都会在运行时退化成回退文案。
void main() {
  Map<String, dynamic> load(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  Set<String> messageKeys(Map<String, dynamic> arb) =>
      arb.keys.where((key) => !key.startsWith('@')).toSet();

  Set<String> placeholders(String message) => RegExp(
    r'\{(\w+)[,}]',
  ).allMatches(message).map((match) => match.group(1)!).toSet();

  test('en and zh ARB define the same keys', () {
    final en = load('lib/l10n/app_en.arb');
    final zh = load('lib/l10n/app_zh.arb');
    final enKeys = messageKeys(en);
    final zhKeys = messageKeys(zh);
    expect(zhKeys.difference(enKeys), isEmpty, reason: 'zh 多出的键');
    expect(enKeys.difference(zhKeys), isEmpty, reason: 'zh 缺少的键（会回退到英文）');
  });

  test('en and zh messages use the same placeholders', () {
    final en = load('lib/l10n/app_en.arb');
    final zh = load('lib/l10n/app_zh.arb');
    for (final key in messageKeys(en)) {
      final expected = placeholders(en[key] as String);
      final actual = placeholders(zh[key] as String);
      expect(actual, expected, reason: '占位符不一致：$key');
    }
  });

  test('template metadata declares exactly the placeholders used', () {
    final en = load('lib/l10n/app_en.arb');
    for (final key in messageKeys(en)) {
      final meta = en['@$key'] as Map<String, dynamic>?;
      final declared = ((meta?['placeholders'] as Map?)?.keys ?? const [])
          .cast<String>()
          .toSet();
      expect(
        declared,
        placeholders(en[key] as String),
        reason: '@$key 的 placeholders 与消息文本不一致',
      );
    }
  });
}
