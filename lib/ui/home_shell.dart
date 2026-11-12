import 'package:material_ui/material_ui.dart';

import 'campaigns_screen.dart';
import 'logs_screen.dart';
import 'maps_screen.dart';
import 'music_screen.dart';
import 'settings_screen.dart';
import 'widgets/engine_banner.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    (Icons.auto_stories, 'Campañas'),
    (Icons.map, 'Mapas'),
    (Icons.library_music, 'Música'),
    (Icons.history_edu, 'Registro'),
    (Icons.settings, 'Ajustes'),
  ];

  Widget _page() => switch (_index) {
        0 => const CampaignsScreen(),
        1 => const MapsScreen(),
        2 => const MusicScreen(),
        3 => const LogsScreen(),
        _ => const SettingsScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final body = Column(children: [const EngineBanner(), Expanded(child: _page())]);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Icon(Icons.casino, size: 36),
            ),
            destinations: [
              for (final (icon, label) in _destinations)
                NavigationRailDestination(icon: Icon(icon), label: Text(label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final (icon, label) in _destinations) NavigationDestination(icon: Icon(icon), label: label),
        ],
      ),
    );
  }
}
