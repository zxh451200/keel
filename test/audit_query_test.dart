import 'package:flutter_test/flutter_test.dart';
import 'package:keel/features/audit/state/audit_providers.dart';
import 'package:keel/src/rust/api/audit.dart';

void main() {
  test('default filter sorts by time descending', () {
    final query = buildAuditQuery(const AuditFilter());
    expect(query.sort.length, 1);
    expect(query.sort.single.field, 'at');
    expect(query.sort.single.descending, isTrue);
  });

  test('buildAuditQuery forwards multi-column sort in order', () {
    final query = buildAuditQuery(
      const AuditFilter(
        sort: [
          AuditSort(field: 'actor', descending: false),
          AuditSort(field: 'action', descending: true),
          AuditSort(field: 'at', descending: true),
        ],
      ),
    );
    expect(query.sort.map((key) => '${key.field}:${key.descending}').toList(), [
      'actor:false',
      'action:true',
      'at:true',
    ]);
  });
}
