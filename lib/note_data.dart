class InkPoint {
  final double x;
  final double y;

  const InkPoint(this.x, this.y);

  factory InkPoint.fromJson(Map<String, dynamic> value) =>
      InkPoint((value['x'] as num).toDouble(), (value['y'] as num).toDouble());

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

class Stroke {
  final List<InkPoint> points;
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
          (point) => InkPoint.fromJson(Map<String, dynamic>.from(point as Map)),
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

class Note {
  static const int currentFormatVersion = 1;

  String id;
  String title;
  String text;
  int backgroundColor;
  String backgroundPattern;
  DateTime updated;
  List<Stroke> strokes;
  List<TaskItem> tasks;

  Note({
    required this.id,
    required this.title,
    this.text = '',
    this.backgroundColor = 0xfffffdf7,
    this.backgroundPattern = 'lined',
    required this.updated,
    required this.strokes,
    List<TaskItem>? tasks,
  }) : tasks = tasks ?? [];

  factory Note.fromJson(Map<String, dynamic> value) {
    final formatVersion = value['formatVersion'] as int? ?? 0;
    if (formatVersion > currentFormatVersion) {
      throw FormatException('Unsupported note format version $formatVersion');
    }

    return Note(
      id: value['id'] as String,
      title: value['title'] as String,
      text: value['text'] as String? ?? '',
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
    'backgroundColor': backgroundColor,
    'backgroundPattern': backgroundPattern,
    'updated': updated.toIso8601String(),
    'strokes': strokes.map((stroke) => stroke.toJson()).toList(),
    'tasks': tasks.map((task) => task.toJson()).toList(),
  };
}
