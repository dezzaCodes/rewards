import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw straight away; Firebase finishes starting in the background.
  runApp(App(bootstrap: AppBootstrap.initialize()));
}
