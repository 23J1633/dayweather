import 'package:flutter_test/flutter_test.dart';

import 'package:dayweather/main.dart';

void main() {
  testWidgets('renders the weather dashboard', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(DayWeatherApp(controller: controller));
    await tester.pump();

    expect(find.text('今天的影像天气'), findsOneWidget);
    expect(find.text('精彩瞬间'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
  });
}
