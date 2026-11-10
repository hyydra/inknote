import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';

void main() {
  test('the embedded release version is present', () {
    expect(appVersion, isNotEmpty);
  });
}
