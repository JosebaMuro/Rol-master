import 'db.dart';

/// Tipo de escena para el fondo del panel gráfico de la partida.
class SceneKind {
  const SceneKind(this.id, this.name, this.icon, this.keywords);
  final String id;
  final String name;
  final String icon;
  /// Palabras (normalizadas, sin tildes) que delatan este tipo de lugar.
  final List<String> keywords;
}

class Scenes {
  /// Clave en la biblia de campaña donde se guarda la escena actual.
  static const bibleKey = '_escena';

  static const kinds = <SceneKind>[
    SceneKind('mazmorra', 'Mazmorra', '⛓️', ['mazmorra', 'calabozo', 'celda', 'dungeon', 'subterraneo', 'sotano', 'carcel', 'prision']),
    SceneKind('cripta', 'Cripta', '⚰️', ['cripta', 'tumba', 'sepulcro', 'catacumba', 'mausoleo', 'osario', 'cementerio', 'necropolis']),
    SceneKind('cueva', 'Cueva', '🪨', ['cueva', 'caverna', 'gruta', 'mina', 'tunel', 'cubil', 'guarida']),
    SceneKind('castillo', 'Castillo', '🏰', ['castillo', 'fortaleza', 'alcazar', 'torre', 'palacio', 'ciudadela', 'muralla', 'salon del trono', 'baluarte', 'fuerte']),
    SceneKind('ciudad', 'Ciudad', '🏘️', ['ciudad', 'pueblo', 'aldea', 'villa', 'mercado', 'plaza', 'calle', 'puerto', 'barrio', 'capital']),
    SceneKind('taberna', 'Taberna', '🍺', ['taberna', 'posada', 'meson', 'cantina', 'hostal', 'tasca']),
    SceneKind('templo', 'Templo', '⛪', ['templo', 'santuario', 'iglesia', 'capilla', 'monasterio', 'abadia', 'altar', 'catedral']),
    SceneKind('bosque', 'Bosque', '🌲', ['bosque', 'selva', 'arboleda', 'jungla', 'claro']),
    SceneKind('montana', 'Montaña', '⛰️', ['montana', 'monte', 'pico', 'cumbre', 'paso', 'desfiladero', 'acantilado', 'risco', 'cordillera']),
    SceneKind('mar', 'Mar y costa', '🌊', ['mar', 'costa', 'playa', 'barco', 'nave', 'isla', 'oceano', 'muelle', 'bahia', 'lago', 'rio']),
    SceneKind('pantano', 'Pantano', '🐸', ['pantano', 'cienaga', 'marisma', 'humedal']),
    SceneKind('desierto', 'Desierto', '🏜️', ['desierto', 'dunas', 'oasis', 'yermo', 'paramo']),
    SceneKind('ruinas', 'Ruinas', '🏛️', ['ruina', 'ruinas', 'derruido', 'abandonad']),
    SceneKind('camino', 'Camino', '🛤️', ['camino', 'sendero', 'calzada', 'llanura', 'pradera', 'campo', 'viaje', 'carretera']),
  ];

  static SceneKind? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    final n = AppDatabase.normalize(id);
    for (final k in kinds) {
      if (k.id == n || AppDatabase.normalize(k.name) == n) return k;
    }
    return null;
  }

  /// Busca el tipo de escena en un texto libre (nombre de lugar, tipo de mapa…).
  /// Gana la palabra que aparece antes, así «Taberna del castillo» es taberna.
  static SceneKind? detect(String text) {
    final direct = byId(text);
    if (direct != null) return direct;
    final n = ' ${AppDatabase.normalize(text)}';
    SceneKind? best;
    var bestPos = 1 << 30;
    for (final k in kinds) {
      for (final w in k.keywords) {
        final i = n.indexOf(RegExp('[^a-z]$w'));
        if (i >= 0 && i < bestPos) {
          bestPos = i;
          best = k;
        }
      }
    }
    return best;
  }
}
