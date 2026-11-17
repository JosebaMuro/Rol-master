import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.init();
  runApp(DirectorApp(services: services));
}

class DirectorApp extends StatefulWidget {
  const DirectorApp({super.key, required this.services});
  final AppServices services;

  @override
  State<DirectorApp> createState() => _DirectorAppState();
}

class _DirectorAppState extends State<DirectorApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Libera los motores de IA antes de cerrar (llama.cpp lo exige).
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await widget.services.dispose();
      return AppExitResponse.exit;
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MultiProvider(
      providers: [
        Provider.value(value: s),
        ChangeNotifierProvider.value(value: s.settings),
        ChangeNotifierProvider.value(value: s.llm),
        ChangeNotifierProvider.value(value: s.voices),
        ChangeNotifierProvider.value(value: s.voicePacks),
        ChangeNotifierProvider.value(value: s.music),
        ChangeNotifierProvider.value(value: s.maps),
        ChangeNotifierProvider.value(value: s.docs),
        ChangeNotifierProvider.value(value: s.speech),
        ChangeNotifierProvider.value(value: s.bundled),
        ChangeNotifierProvider.value(value: s.images),
      ],
      child: MaterialApp(
        title: 'Director de Rol',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeShell(),
      ),
    );
  }
}
