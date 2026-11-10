class CanvasPoint {
  final double x;
  final double y;

  const CanvasPoint(this.x, this.y);

  factory CanvasPoint.fromJson(Map<String, dynamic> value) => CanvasPoint(
        (value['x'] as num).toDouble(),
        (value['y'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

class Stroke {
  final List<CanvasPoint> points;
  final int color;
  final double width;
  final bool highlight;
  final double opacity;

  Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.highlight,
    this.opacity = 1,
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
        opacity: (value['opacity'] as num?)?.toDouble() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'points': points.map((point) => point.toJson()).toList(),
        'color': color,
        'width': width,
        'highlight': highlight,
        'opacity': opacity,
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

class TextBlockFormat {
  bool bold;
  int color;
  double x;
  double y;
  double width;
  double height;

  TextBlockFormat({
    this.bold = false,
    this.color = 0xff000000,
    this.x = 48,
    this.y = 48,
    this.width = 320,
    this.height = 160,
  });

  factory TextBlockFormat.fromJson(Map<String, dynamic> value) =>
      TextBlockFormat(
        bold: value['bold'] as bool? ?? false,
        color: value['color'] as int? ?? 0xff000000,
        x: (value['x'] as num?)?.toDouble() ?? 48,
        y: (value['y'] as num?)?.toDouble() ?? 48,
        width: (value['width'] as num?)?.toDouble() ?? 320,
        height: (value['height'] as num?)?.toDouble() ?? 160,
      );

  Map<String, dynamic> toJson() => {
        'bold': bold,
        'color': color,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

class Note {
  static const int currentFormatVersion = 4;

  String id;
  String title;
  List<String> textBlocks;
  List<TextBlockFormat> textBlockFormats;
  int backgroundColor;
  String backgroundPattern;
  DateTime updated;
  List<Stroke> strokes;
  List<TaskItem> tasks;

  Note({
    required this.id,
    required this.title,
    String text = '',
    List<String>? textBlocks,
    List<TextBlockFormat>? textBlockFormats,
    this.backgroundColor = 0xfffffdf7,
    this.backgroundPattern = 'lined',
    required this.updated,
    required this.strokes,
    List<TaskItem>? tasks,
  })  : textBlocks = textBlocks ?? (text.isEmpty ? <String>[] : <String>[text]),
        textBlockFormats = textBlockFormats ??
            List.generate(
              textBlocks?.length ?? (text.isEmpty ? 0 : 1),
              (index) => TextBlockFormat(y: 48 + index * 184),
            ),
        tasks = tasks ?? [];

  String get text => textBlocks.join('\n\n');

  set text(String value) {
    textBlocks = value.isEmpty ? <String>[] : <String>[value];
    textBlockFormats = value.isEmpty
        ? <TextBlockFormat>[]
        : <TextBlockFormat>[TextBlockFormat()];
  }

  factory Note.fromJson(Map<String, dynamic> value) {
    final formatVersion = value['formatVersion'] as int? ?? 0;
    if (formatVersion > currentFormatVersion) {
      throw FormatException('Unsupported note format version $formatVersion');
    }

    return Note(
      id: value['id'] as String,
      title: value['title'] as String,
      text: value['text'] as String? ?? '',
      textBlocks: (value['textBlocks'] as List?)
          ?.map((block) => block as String)
          .toList(),
      textBlockFormats:
          (value['textBlockFormats'] as List?)?.asMap().entries.map((entry) {
        final raw = Map<String, dynamic>.from(entry.value as Map);
        final format = TextBlockFormat.fromJson(raw);
        if (!raw.containsKey('y')) format.y = 48 + entry.key * 184;
        return format;
      }).toList(),
      backgroundColor: value['backgroundColor'] as int? ?? 0xfffffdf7,
      backgroundPattern: value['backgroundPattern'] as String? ?? 'lined',
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
        'textBlocks': textBlocks,
        'textBlockFormats': textBlockFormats
            .take(textBlocks.length)
            .map((format) => format.toJson())
            .toList(),
        'backgroundColor': backgroundColor,
        'backgroundPattern': backgroundPattern,
        'updated': updated.toIso8601String(),
        'strokes': strokes.map((stroke) => stroke.toJson()).toList(),
        'tasks': tasks.map((task) => task.toJson()).toList(),
      };
}
