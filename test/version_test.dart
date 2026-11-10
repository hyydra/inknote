import 'package:flutter_test/flutter_test.dart';
import 'package:inknote/main.dart';

void main() {
  test('the embedded release version is present', () {
    expect(inkNoteVersion, isNotEmpty);
  });
}
