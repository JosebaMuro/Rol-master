import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Saca el texto de un documento para que la IA lo aprenda.
///
/// Formatos: PDF, Word (.docx), OpenDocument (.odt), EPUB, HTML, RTF y texto
/// plano (.txt, .md, .csv, .json…). Todo en Dart, igual en Windows y Android.
class DocExtractor {
  static const extensions = [
    'pdf', 'docx', 'odt', 'epub', 'html', 'htm', 'xhtml', 'rtf', //
    'txt', 'md', 'markdown', 'csv', 'json', 'yaml', 'yml', 'xml', 'log', 'srt',
  ];

  static bool supports(String path) => extensions.contains(kindOf(path));

  static String kindOf(String path) => p.extension(path).toLowerCase().replaceFirst('.', '');

  /// Pensado para ejecutarse con `Isolate.run` (no toca la interfaz).
  static String extractFile(String path) => extract(File(path).readAsBytesSync(), kindOf(path));

  static String extract(Uint8List bytes, String kind) {
    final text = switch (kind) {
      'pdf' => _pdf(bytes),
      'docx' => _zipXml(bytes, (n) => n == 'word/document.xml' || RegExp(r'^word/(footnotes|endnotes)\.xml$').hasMatch(n)),
      'odt' => _zipXml(bytes, (n) => n == 'content.xml'),
      'epub' => _epub(bytes),
      'html' || 'htm' || 'xhtml' => htmlToText(_decode(bytes)),
      'rtf' => _rtf(_decode(bytes)),
      'xml' => xmlToText(_decode(bytes)),
      _ => _decode(bytes),
    };
    return tidy(text);
  }

  static String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes); // ficheros antiguos de Windows
    }
  }

  static String _pdf(Uint8List bytes) {
    final doc = PdfDocument(inputBytes: bytes);
    try {
      final ex = PdfTextExtractor(doc);
      final b = StringBuffer();
      for (var i = 0; i < doc.pages.count; i++) {
        try {
          b
            ..writeln(ex.extractText(startPageIndex: i, endPageIndex: i))
            ..writeln();
        } catch (_) {
          // Una página rota no impide leer el resto.
        }
      }
      return b.toString();
    } finally {
      doc.dispose();
    }
  }

  static String _zipXml(Uint8List bytes, bool Function(String name) wanted) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final b = StringBuffer();
    for (final f in zip.files) {
      if (f.isFile && wanted(f.name)) b.writeln(xmlToText(utf8.decode(f.content, allowMalformed: true)));
    }
    return b.toString();
  }

  static String _epub(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final byName = {for (final f in zip.files) if (f.isFile) f.name: f};
    // Orden de lectura del libro (spine del .opf); si falla, orden alfabético.
    var order = <String>[];
    final container = byName['META-INF/container.xml'];
    if (container != null) {
      final opfPath = RegExp(r'full-path="([^"]+)"').firstMatch(utf8.decode(container.content, allowMalformed: true))?.group(1);
      final opf = opfPath == null ? null : byName[opfPath];
      if (opf != null) {
        final xml = utf8.decode(opf.content, allowMalformed: true);
        final base = p.posix.dirname(opfPath!);
        final items = {
          for (final m in RegExp(r'<item\b[^>]*>').allMatches(xml))
            if (RegExp(r'id="([^"]+)"').firstMatch(m[0]!) case final id?)
              id.group(1)!: RegExp(r'href="([^"]+)"').firstMatch(m[0]!)?.group(1) ?? '',
        };
        for (final m in RegExp(r'<itemref\b[^>]*idref="([^"]+)"').allMatches(xml)) {
          final href = items[m.group(1)];
          if (href != null && href.isNotEmpty) {
            order.add(p.posix.normalize(base == '.' ? Uri.decodeComponent(href) : '$base/${Uri.decodeComponent(href)}'));
          }
        }
      }
    }
    if (order.isEmpty) {
      order = byName.keys.where((n) => RegExp(r'\.x?html?$').hasMatch(n)).toList()..sort();
    }
    final b = StringBuffer();
    for (final n in order) {
      final f = byName[n];
      if (f != null) b.writeln(htmlToText(utf8.decode(f.content, allowMalformed: true)));
    }
    return b.toString();
  }

  static String _rtf(String s) {
    var t = s.replaceAllMapped(RegExp(r"\\'([0-9a-fA-F]{2})"), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
    t = t.replaceAll(RegExp(r'\\par[d]?\b'), '\n').replaceAll(RegExp(r'\\line\b'), '\n');
    t = t.replaceAll(RegExp(r'\{\\\*[^{}]*\}'), '');
    t = t.replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '').replaceAll(RegExp(r'[{}]'), '');
    return t;
  }

  /// Texto de un XML de ofimática: cada párrafo en su línea.
  static String xmlToText(String xml) {
    final t = xml
        .replaceAll(RegExp(r'</(w:p|text:p|text:h|p|h\d|li|tr)>'), '\n')
        .replaceAll(RegExp(r'<(w:tab|text:tab)\s*/>'), '\t')
        .replaceAll(RegExp(r'<(w:br|text:line-break)\s*/>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    return _entities(t);
  }

  static String htmlToText(String html) {
    final t = html
        .replaceAll(RegExp(r'<(script|style|head)\b[\s\S]*?</\1>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|h\d|li|tr|section|article|blockquote)>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    return _entities(t);
  }

  static String _entities(String s) => s
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// Quita espacios sobrantes y une las palabras cortadas con guion al final de línea.
  static String tidy(String s) => s
      .replaceAll('\r', '')
      .replaceAll('\u00ad', '')
      .replaceAllMapped(RegExp(r'([a-záéíóúñü])-\n([a-záéíóúñü])'), (m) => '${m[1]}${m[2]}')
      .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
