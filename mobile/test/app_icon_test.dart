import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS notification icon slots contain the shield and use the app catalog', () async {
    const directory = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final manifest = jsonDecode(
      File('$directory/Contents.json').readAsStringSync(),
    );
    final notificationSlots = (manifest['images'] as List)
        .where((slot) => slot['size'] == '20x20')
        .toList();
    for (final idiom in ['iphone', 'ipad']) {
      for (final scale in idiom == 'iphone' ? ['2x', '3x'] : ['1x', '2x']) {
        final slot = notificationSlots.singleWhere(
          (slot) => slot['idiom'] == idiom && slot['scale'] == scale,
        );
        final codec = await ui.instantiateImageCodec(
          File('$directory/${slot['filename']}').readAsBytesSync(),
        );
        final image = (await codec.getNextFrame()).image;
        try {
          final size = 20 * int.parse(scale.substring(0, 1));
          expect(image.width, size);
          expect(image.height, size);
          final data = (await image.toByteData())!;
          final bytes = data.buffer.asUint8List();
          expect(bytes.sublist(0, 4), [255, 255, 255, 255]);
          // Uniform sky blue in the shield's upper center, not Flutter artwork.
          final offset = (size * (size * 0.3).floor() + size ~/ 2) * 4;
          expect(bytes.sublist(offset, offset + 4), [22, 138, 196, 255]);
        } finally {
          image.dispose();
          codec.dispose();
        }
      }
    }
    final project = File('ios/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    expect(
      RegExp('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
          .allMatches(project)
          .length,
      3,
    );
  });
}
