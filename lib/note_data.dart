class CanvasPoint {
  final double x;
  final double y;
  final double pressure;
  final double pressureMin;
  final double pressureMax;
  final double tilt;
  final double orientation;

  const CanvasPoint(
    this.x,
    this.y, {
    this.pressure = 1,
    this.pressureMin = 0,
    this.pressureMax = 1,
    this.tilt = 0,
    this.orientation = 0,
  });

  double get normalizedPressure {
    final range = pressureMax - pressureMin;
    if (range < 0.0001) return 0.5;
    return ((pressure - pressureMin) / range).clamp(0.0, 1.0).toDouble();
  }

  factory CanvasPoint.fromJson(Map<String, dynamic> value) => CanvasPoint(
        (value['x'] as num).toDouble(),
        (value['y'] as num).toDouble(),
        pressure: (value['pressure'] as num?)?.toDouble() ?? 1,
        pressureMin: (value['pressureMin'] as num?)?.toDouble() ?? 0,
        pressureMax: (value['pressureMax'] as num?)?.toDouble() ?? 1,
        tilt: (value['tilt'] as num?)?.toDouble() ?? 0,
        orientation: (value['orientation'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'pressure': pressure,
        'pressureMin': pressureMin,
        'pressureMax': pressureMax,
        'tilt': tilt,
        'orientation': orientation,
      };
}

class Stroke {
  final List<CanvasPoint> points;
  final int color;
  final double width;
  final bool highlight;
  final bool blur;
  final double opacity;
  final bool pressureSensitive;

  Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.highlight,
    this.blur = false,
    this.opacity = 1,
    this.pressureSensitive = false,
  });

  factory Stroke.fromJson(Map<String, dynamic> value) => Stroke(
        points: (value['points'] as List? ?? const [])
            .map(
              (point) =>
                  CanvasPoint.fromJson(Map<String, dynamic>.from(point as Map)),
            )
            .toList(),
        color: value['color'] as int,
        width: (value['width'] as num).toDouble(),
        highlight: value['highlight'] as bool? ?? false,
        blur: value['blur'] as bool? ?? false,
        opacity: (value['opacity'] as num?)?.toDouble() ?? 1,
        pressureSensitive: value['pressureSensitive'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'points': points.map((point) => point.toJson()).toList(),
        'color': color,
        'width': width,
        'highlight': highlight,
        'blur': blur,
        'opacity': opacity,
        'pressureSensitive': pressureSensitive,
      };
}

bool commitActiveStroke(List<Stroke> strokes, Stroke? active) {
  if (active == null) {
    return false;
  }
  strokes.add(active);
  return true;
}

class TaskItem {
  String text;
  bool done;

  TaskItem({required this.text, this.done = false});

  factory TaskItem.fromJson(Map<String, dynamic> value) => TaskItem(
        text: value['text'] as String,
        done: value['done'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {'text': text, 'done': done};
}

class TextStyleRange {
  int start;
  int end;
  bool? bold;
  int? color;
  double? fontSize;

  TextStyleRange({
    required this.start,
    required this.end,
    this.bold,
    this.color,
    this.fontSize,
  });

  factory TextStyleRange.fromJson(Map<String, dynamic> value) => TextStyleRange(
        start: value['start'] as int,
        end: value['end'] as int,
        bold: value['bold'] as bool?,
        color: value['color'] as int?,
        fontSize: (value['fontSize'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        if (bold != null) 'bold': bold,
        if (color != null) 'color': color,
        if (fontSize != null) 'fontSize': fontSize,
      };
}

class TextBlockFormat {
  bool bold;
  int color;
  double fontSize;
  double x;
  double y;
  double width;
  double height;
  List<TextStyleRange> styles;

  TextBlockFormat({
    this.bold = false,
    this.color = 0xff000000,
    this.fontSize = 20,
    this.x = 48,
    this.y = 48,
    this.width = 320,
    this.height = 160,
    List<TextStyleRange>? styles,
  }) : styles = styles ?? [];

  factory TextBlockFormat.fromJson(Map<String, dynamic> value) =>
      TextBlockFormat(
        bold: value['bold'] as bool? ?? false,
        color: value['color'] as int? ?? 0xff000000,
        fontSize: (value['fontSize'] as num?)?.toDouble() ?? 20,
        x: (value['x'] as num?)?.toDouble() ?? 48,
        y: (value['y'] as num?)?.toDouble() ?? 48,
        width: (value['width'] as num?)?.toDouble() ?? 320,
        height: (value['height'] as num?)?.toDouble() ?? 160,
        styles: (value['styles'] as List? ?? const [])
            .map((item) => TextStyleRange.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'bold': bold,
        'color': color,
        'fontSize': fontSize,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'styles': styles.map((style) => style.toJson()).toList(),
      };
}

/// The style of a note's single text document. There is no position or size:
/// the document is a fixed column at the top of page 1 that grows downward.
class TextDocumentFormat {
  bool bold;
  int color;
  double fontSize;
  List<TextStyleRange> styles;

  TextDocumentFormat({
    this.bold = false,
    this.color = 0xff000000,
    this.fontSize = 20,
    List<TextStyleRange>? styles,
  }) : styles = styles ?? [];

  factory TextDocumentFormat.fromJson(Map<String, dynamic> value) =>
      TextDocumentFormat(
        bold: value['bold'] as bool? ?? false,
        color: value['color'] as int? ?? 0xff000000,
        fontSize: (value['fontSize'] as num?)?.toDouble() ?? 20,
        styles: (value['styles'] as List? ?? const [])
            .map((item) => TextStyleRange.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'bold': bold,
        'color': color,
        'fontSize': fontSize,
        'styles': styles.map((style) => style.toJson()).toList(),
      };

  TextDocumentFormat copy() => TextDocumentFormat(
        bold: bold,
        color: color,
        fontSize: fontSize,
        styles: styles
            .map((style) => TextStyleRange(
                  start: style.start,
                  end: style.end,
                  bold: style.bold,
                  color: style.color,
                  fontSize: style.fontSize,
                ))
            .toList(),
      );
}

class Note {
  static const int currentFormatVersion = 7;

  String id;
  String title;
  String text;
  TextDocumentFormat textFormat;
  int backgroundColor;
  String backgroundPattern;
  int pageCount;
  int rasterWidth;
  int rasterPageHeight;
  Map<int, String> rasterPages;
  Map<String, String> rasterTiles;
  DateTime updated;
  List<Stroke> strokes;
  List<TaskItem> tasks;

  Note({
    required this.id,
    required this.title,
    this.text = '',
    TextDocumentFormat? textFormat,
    this.backgroundColor = 0xfffffdf7,
    this.backgroundPattern = 'lined',
    this.pageCount = 1,
    this.rasterWidth = 0,
    this.rasterPageHeight = 0,
    Map<int, String>? rasterPages,
    Map<String, String>? rasterTiles,
    required this.updated,
    required this.strokes,
    List<TaskItem>? tasks,
  })  : textFormat = textFormat ?? TextDocumentFormat(),
        rasterPages = rasterPages ?? <int, String>{},
        rasterTiles = rasterTiles ?? <String, String>{},
        tasks = tasks ?? [];

  factory Note.fromJson(Map<String, dynamic> value) {
    final formatVersion = value['formatVersion'] as int? ?? 0;
    if (formatVersion > currentFormatVersion) {
      throw FormatException('Unsupported note format version $formatVersion');
    }
    final document = _documentFromBlocks(
      (value['textBlocks'] as List?)
              ?.map((block) => block as String)
              .toList() ??
          const <String>[],
      value['textBlockFormats'] as List?,
    );

    return Note(
      id: value['id'] as String,
      title: value['title'] as String,
      text: document?.$1 ?? value['text'] as String? ?? '',
      textFormat: document?.$2 ??
          (value['textFormat'] == null
              ? TextDocumentFormat()
              : TextDocumentFormat.fromJson(
                  Map<String, dynamic>.from(value['textFormat'] as Map),
                )),
      backgroundColor: value['backgroundColor'] as int? ?? 0xfffffdf7,
      backgroundPattern: value['backgroundPattern'] as String? ?? 'lined',
      pageCount: (value['pageCount'] as int? ?? 1).clamp(1, 10000),
      rasterWidth: value['rasterWidth'] as int? ?? 0,
      rasterPageHeight: value['rasterPageHeight'] as int? ?? 0,
      rasterPages: _parseRasterPages(value['rasterPages']),
      rasterTiles: _parseRasterTiles(value['rasterTiles']),
      updated: DateTime.parse(value['updated'] as String),
      strokes: (value['strokes'] as List? ?? const [])
          .map(
            (stroke) =>
                Stroke.fromJson(Map<String, dynamic>.from(stroke as Map)),
          )
          .toList(),
      tasks: (value['tasks'] as List? ?? const [])
          .map(
            (task) => TaskItem.fromJson(Map<String, dynamic>.from(task as Map)),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': currentFormatVersion,
        'id': id,
        'title': title,
        'text': text,
        'textFormat': textFormat.toJson(),
        'backgroundColor': backgroundColor,
        'backgroundPattern': backgroundPattern,
        'pageCount': pageCount,
        'rasterWidth': rasterWidth,
        'rasterPageHeight': rasterPageHeight,
        'rasterPages': {
          for (final entry in rasterPages.entries)
            entry.key.toString(): entry.value,
        },
        'rasterTiles': rasterTiles,
        'updated': updated.toUtc().toIso8601String(),
        'strokes': strokes.map((stroke) => stroke.toJson()).toList(),
        'tasks': tasks.map((task) => task.toJson()).toList(),
      };
}

/// Folds a legacy note's blocks into one document, or returns null when the
/// file is already document-shaped. Offsets shift by every earlier block plus
/// the two-character separator that joined them.
(String, TextDocumentFormat)? _documentFromBlocks(
  List<String> blocks,
  List? rawFormats,
) {
  if (blocks.isEmpty) return null;
  final formats = List<TextBlockFormat>.generate(blocks.length, (index) {
    if (rawFormats == null || index >= rawFormats.length) {
      return TextBlockFormat();
    }
    return TextBlockFormat.fromJson(
      Map<String, dynamic>.from(rawFormats[index] as Map),
    );
  });
  final document = TextDocumentFormat(
    bold: formats.first.bold,
    color: formats.first.color,
    fontSize: formats.first.fontSize,
  );
  var offset = 0;
  for (var index = 0; index < blocks.length; index++) {
    final block = blocks[index];
    final format = formats[index];
    if (block.isNotEmpty &&
        (format.bold != document.bold ||
            format.color != document.color ||
            format.fontSize != document.fontSize)) {
      document.styles.add(TextStyleRange(
        start: offset,
        end: offset + block.length,
        bold: format.bold,
        color: format.color,
        fontSize: format.fontSize,
      ));
    }
    for (final style in format.styles) {
      document.styles.add(TextStyleRange(
        start: offset + style.start,
        end: offset + style.end,
        bold: style.bold,
        color: style.color,
        fontSize: style.fontSize,
      ));
    }
    offset += block.length + 2;
  }
  return (blocks.join('\n\n'), document);
}

Map<String, String> _parseRasterTiles(Object? rawTiles) {
  if (rawTiles == null) return <String, String>{};
  if (rawTiles is! Map) {
    throw const FormatException('Raster tiles must be an object');
  }
  final tiles = <String, String>{};
  rawTiles.forEach((key, value) {
    final parts = key.toString().split(':');
    final validKey = parts.length == 3 &&
        parts.every((part) => int.tryParse(part) != null) &&
        parts.every((part) => int.parse(part) >= 0);
    if (!validKey || value is! String) {
      throw const FormatException('Invalid raster tile entry');
    }
    tiles[key.toString()] = value;
  });
  return tiles;
}

Map<int, String> _parseRasterPages(Object? rawPages) {
  if (rawPages == null) return <int, String>{};
  if (rawPages is! Map) {
    throw const FormatException('Raster pages must be an object');
  }
  final pages = <int, String>{};
  rawPages.forEach((key, value) {
    final page = int.tryParse(key.toString());
    if (page == null || page < 0 || value is! String) {
      throw const FormatException('Invalid raster page entry');
    }
    pages[page] = value;
  });
  return pages;
}

/// Records that a note was deleted so the deletion survives a Drive sync.
///
/// Without a tombstone every sync re-imports any note that is present in the
/// Drive folder but absent locally, so a note deleted on one device returns on
/// the next sync. A tombstone is stored as `<id>.deleted.json` beside the note
/// payloads, locally and in the shared folder.
///
/// A tombstone only suppresses payloads whose [Note.updated] is not newer than
/// [deleted]. A note edited after it was deleted therefore wins and revives,
/// which keeps the rule a plain instant comparison instead of a vote.
class NoteTombstone {
  /// Suffix of the file that carries a tombstone, in the notes folder.
  static const String fileSuffix = '.deleted.json';

  static const int currentFormatVersion = 1;
  static final RegExp _safeNoteId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  final String id;
  final DateTime deleted;

  const NoteTombstone({required this.id, required this.deleted});

  factory NoteTombstone.fromJson(Map<String, dynamic> value) {
    final id = value['id'] as String? ?? '';
    if (!_safeNoteId.hasMatch(id)) {
      throw const FormatException('Unsafe tombstone note id');
    }
    final raw = value['deleted'];
    if (raw is! String) {
      throw const FormatException('Tombstone has no deleted instant');
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw FormatException('Invalid tombstone instant: $raw');
    }
    return NoteTombstone(id: id, deleted: parsed.toUtc());
  }

  /// Name of the file that carries this tombstone in the notes folder.
  String get fileName => '$id$fileSuffix';

  /// True when [note] was not edited after the deletion this records.
  bool suppresses(Note note) => !note.updated.isAfter(deleted);

  Map<String, dynamic> toJson() => {
        'formatVersion': currentFormatVersion,
        'id': id,
        'deleted': deleted.toUtc().toIso8601String(),
      };
}
