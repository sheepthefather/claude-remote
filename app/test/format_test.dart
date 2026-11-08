import 'package:claude_remote/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shortenPath keeps the last segments', () {
    expect(shortenPath('/home/me/code/project'), '…/code/project');
    expect(shortenPath('/tmp'), '/tmp');
  });

  test('prettyJson formats maps', () {
    expect(prettyJson({'a': 1}), '{\n  "a": 1\n}');
  });

  test('truncate caps long text', () {
    expect(truncate('abcdef', 3), 'abc\n…');
  });
}
