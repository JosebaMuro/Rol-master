import 'package:material_ui/material_ui.dart';

const kGold = Color(0xFFD4A84F);
const kBlood = Color(0xFF9E2B25);
const kInk = Color(0xFF15120F);
const kPanel = Color(0xFF221D18);
const kParchment = Color(0xFFEDE0C4);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kGold,
    brightness: Brightness.dark,
    surface: kInk,
    primary: kGold,
    secondary: kBlood,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: kInk,
    cardTheme: const CardThemeData(color: kPanel, margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
    appBarTheme: const AppBarTheme(backgroundColor: kInk, centerTitle: false),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.bold, color: kGold),
      titleLarge: TextStyle(fontFamily: 'serif', fontWeight: FontWeight.bold),
    ),
  );
}
