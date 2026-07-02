import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bootstrap = await AppBootstrap.initialize();
  runApp(App(bootstrap: bootstrap));
}
