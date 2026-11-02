@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:app_blueprint/src/services/photo_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saves, reads back and clears card photos', () async {
    final bytes = Uint8List.fromList(List.generate(5000, (i) => i % 256));

    await writeCachedPhoto('photo-1', bytes);
    expect(await readCachedPhoto('photo-1'), bytes);
    expect(await readCachedPhoto('missing'), isNull);

    await clearCachedPhotos();
    expect(await readCachedPhoto('photo-1'), isNull);
  });
}
