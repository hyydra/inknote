import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

const inkNoteVersion =
    String.fromEnvironment('INKNOTE_VERSION', defaultValue: '0.3.0');

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String fileName;
  const UpdateInfo(this.version, this.downloadUrl, this.fileName);
}

class UpdateService {
  static const _channel = MethodChannel('inknote/update');
  static bool _checked = false;

  static List<int> _parts(String value) => value
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('.')
      .map((part) => int.tryParse(RegExp(r'^\d+').stringMatch(part) ?? '') ?? 0)
      .toList();

  static bool _isNewer(String candidate, String current) {
    final a = _parts(candidate);
    final b = _parts(current);
    for (var i = 0; i < math.max(a.length, b.length); i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  static Future<UpdateInfo?> check() async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/hyydra/inknote/releases/latest'));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'InkNote/$inkNoteVersion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final release = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final version =
          (release['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (!_isNewer(version, inkNoteVersion)) return null;
      final suffix = Platform.isAndroid ? '.apk' : '.zip';
      final assets =
          (release['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
      final asset = assets.where((item) =>
          (item['name'] as String? ?? '').toLowerCase().endsWith(suffix));
      if (asset.isEmpty) return null;
      final selected = asset.first;
      return UpdateInfo(version, selected['browser_download_url'] as String,
          selected['name'] as String);
    } finally {
      client.close();
    }
  }

  static Future<void> prompt(BuildContext context,
      {bool automatic = false}) async {
    if (automatic && _checked) return;
    _checked = true;
    final update = await check();
    if (!context.mounted) return;
    if (update == null) {
      if (!automatic) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('InkNote is up to date.')));
      }
      return;
    }
    final install = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('InkNote update available'),
              content: Text(
                  'Version ${update.version} is available. Download and install it now?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Later')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Update')),
              ],
            ));
    if (install != true || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Downloading update…')));
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(update.downloadUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download failed (${response.statusCode})');
      }
      final file = File(
          '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}${update.fileName}');
      final sink = file.openWrite();
      await response.pipe(sink);
      if (Platform.isAndroid) {
        await _channel.invokeMethod('install', {'path': file.path});
      } else {
        final app = Platform.resolvedExecutable;
        final installDir = File(app).parent.path;
        String quoted(String value) => value.replaceAll("'", "''");
        final script = File('${file.path}.ps1');
        await script.writeAsString('''
param([int]\$InkNotePid)
Wait-Process -Id \$InkNotePid -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath '${quoted(file.path)}' -DestinationPath '${quoted(installDir)}' -Force
Start-Process -FilePath '${quoted(app)}'
Remove-Item -LiteralPath \$PSCommandPath -Force
''');
        await Process.start(
            'powershell',
            [
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              script.path,
              pid.toString()
            ],
            mode: ProcessStartMode.detached);
        exit(0);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update failed: $error')));
      }
    } finally {
      client.close();
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InkNoteApp());
}

class InkNoteApp extends StatelessWidget {
  const InkNoteApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'InkNote',
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xff594fc8),
            scaffoldBackgroundColor: const Color(0xfffaf9f6)),
        home: const LauncherCanvasPage(),
      );
}

class InkPoint {
  final double x, y;
  const InkPoint(this.x, this.y);
  factory InkPoint.fromJson(Map<String, dynamic> m) =>
      InkPoint((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

class Stroke {
  final List<InkPoint> points;
  final int color;
  final double width;
  final bool highlight;
  final double opacity;
  Stroke(
      {required this.points,
      required this.color,
      required this.width,
      required this.highlight,
      this.opacity = 1});
  factory Stroke.fromJson(Map<String, dynamic> m) => Stroke(
      points: (m['points'] as List)
          .map((e) => InkPoint.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      color: m['color'] as int,
      width: (m['width'] as num).toDouble(),
      highlight: m['highlight'] as bool? ?? false,
      opacity: (m['opacity'] as num?)?.toDouble() ?? 1);
  Map<String, dynamic> toJson() => {
        'points': points.map((e) => e.toJson()).toList(),
        'color': color,
        'width': width,
        'highlight': highlight,
        'opacity': opacity
      };
}

class TaskItem {
  String text;
  bool done;
  TaskItem({required this.text, this.done = false});
  factory TaskItem.fromJson(Map<String, dynamic> value) => TaskItem(
      text: value['text'] as String, done: value['done'] as bool? ?? false);
  Map<String, dynamic> toJson() => {'text': text, 'done': done};
}

class Note {
  String id, title, text;
  int backgroundColor;
  String backgroundPattern;
  DateTime updated;
  List<Stroke> strokes;
  List<TaskItem> tasks;
  Note(
      {required this.id,
      required this.title,
      this.text = '',
      this.backgroundColor = 0xfffffdf7,
      this.backgroundPattern = 'lined',
      required this.updated,
      required this.strokes,
      List<TaskItem>? tasks})
      : tasks = tasks ?? [];
  factory Note.fromJson(Map<String, dynamic> m) => Note(
      id: m['id'] as String,
      title: m['title'] as String,
      text: m['text'] as String? ?? '',
      backgroundColor: m['backgroundColor'] as int? ?? 0xfffffdf7,
      backgroundPattern: m['backgroundPattern'] as String? ?? 'lined',
      updated: DateTime.parse(m['updated'] as String),
      strokes: (m['strokes'] as List)
          .map((e) => Stroke.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      tasks: (m['tasks'] as List? ?? const [])
          .map((e) => TaskItem.fromJson(Map<String, dynamic>.from(e)))
          .toList());
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'text': text,
        'backgroundColor': backgroundColor,
        'backgroundPattern': backgroundPattern,
        'updated': updated.toIso8601String(),
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'tasks': tasks.map((task) => task.toJson()).toList()
      };
}

class NoteStore {
  Future<Directory> get folder async {
    final dir =
        Directory('${(await getApplicationDocumentsDirectory()).path}/inknote');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<Note>> load() async {
    final dir = await folder;
    final notes = <Note>[];
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        try {
          notes.add(Note.fromJson(jsonDecode(await entry.readAsString())));
        } catch (_) {/* Skip damaged note without deleting it. */}
      }
    }
    notes.sort((a, b) => b.updated.compareTo(a.updated));
    return notes;
  }

  Future<void> save(Note n) async {
    final dir = await folder;
    final file = File('${dir.path}/${n.id}.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(n.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }

  Future<void> delete(Note n) async {
    final dir = await folder;
    final f = File('${dir.path}/${n.id}.json');
    if (await f.exists()) await f.delete();
  }
}

class LauncherCanvasPage extends StatefulWidget {
  const LauncherCanvasPage({super.key});

  @override
  State<LauncherCanvasPage> createState() => _LauncherCanvasPageState();
}

class _LauncherCanvasPageState extends State<LauncherCanvasPage> {
  static const launcherNoteId = 'launcher-canvas';
  final store = NoteStore();
  Note? note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await store.load();
    final existing = notes.where((item) => item.id == launcherNoteId);
    final loaded = existing.isEmpty
        ? Note(
            id: launcherNoteId,
            title: 'Launcher note',
            text: '',
            updated: DateTime.now(),
            strokes: [],
          )
        : existing.first;
    if (mounted) {
      setState(() => note = loaded);
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => UpdateService.prompt(context, automatic: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = note;
    if (loaded == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return EditorPage(note: loaded, launcherMode: true);
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final store = NoteStore();
  List<Note> notes = [];
  bool loading = true;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final loaded = await store.load();
    if (mounted)
      setState(() {
        notes = loaded;
        loading = false;
      });
  }

  Future<void> openNote([Note? note]) async {
    final n = note ??
        Note(
            id: const Uuid().v4(),
            title: 'Untitled note',
            text: '',
            updated: DateTime.now(),
            strokes: []);
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => EditorPage(note: n)));
    await refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('All notes')),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => openNote(),
            icon: const Icon(Icons.add),
            label: const Text('New note')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : notes.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.draw_outlined, size: 64, color: Colors.grey),
                    SizedBox(height: 12),
                    Text('Start your first handwritten note')
                  ]))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: notes.length,
                    itemBuilder: (context, i) {
                      final n = notes[i];
                      return Card(
                          child: ListTile(
                              leading: const Icon(Icons.note_alt_outlined),
                              title: Text(n.title),
                              subtitle: Text(
                                  '${n.strokes.length} strokes • ${n.updated.toLocal()}'),
                              onTap: () => openNote(n),
                              trailing: PopupMenuButton<String>(
                                  onSelected: (v) async {
                                    if (v == 'delete') {
                                      await store.delete(n);
                                      refresh();
                                    }
                                  },
                                  itemBuilder: (_) => [
                                        const PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Delete'))
                                      ])));
                    }),
      );
}

enum DrawTool { pencil, pen, highlighter, eraser }

enum PaperPattern { plain, lined, grid, dots }

class EditorPage extends StatefulWidget {
  final Note note;
  final bool launcherMode;
  const EditorPage({super.key, required this.note, this.launcherMode = false});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const widgetChannel = MethodChannel('inknote/widget');
  static const syncChannel = MethodChannel('inknote/sync');
  late final TextEditingController titleController;
  late final TextEditingController textController;
  late final TextEditingController taskController;
  DrawTool tool = DrawTool.pen;
  Color ink = Colors.blue.shade800;
  double width = 3;
  Stroke? active;
  bool changed = false;
  bool showText = true;
  bool showTasks = false;
  Timer? textSaveTimer;
  final List<Stroke> undone = [];
  final store = NoteStore();
  @override
  void initState() {
    super.initState();
    titleController = TextEditingController(text: widget.note.title);
    titleController.addListener(() => changed = true);
    textController = TextEditingController(text: widget.note.text);
    taskController = TextEditingController();
    textController.addListener(() {
      changed = true;
      if (widget.launcherMode) {
        textSaveTimer?.cancel();
        textSaveTimer = Timer(
            const Duration(milliseconds: 700), () => save(showMessage: false));
      }
    });
  }

  @override
  void dispose() {
    titleController.dispose();
    textSaveTimer?.cancel();
    textController.dispose();
    taskController.dispose();
    super.dispose();
  }

  void begin(Offset p) {
    if (tool == DrawTool.eraser) {
      erase(p);
      return;
    }
    setState(() {
      active = Stroke(
          points: [InkPoint(p.dx, p.dy)],
          color: ink.toARGB32(),
          width: tool == DrawTool.highlighter
              ? 22
              : tool == DrawTool.pencil
                  ? 2
                  : width,
          highlight: tool == DrawTool.highlighter,
          opacity: tool == DrawTool.pencil ? 0.58 : 1);
    });
  }

  void move(Offset p) {
    if (tool == DrawTool.eraser) {
      erase(p);
      return;
    }
    if (active == null) return;
    setState(() => active!.points.add(InkPoint(p.dx, p.dy)));
  }

  void end() {
    if (active != null) {
      setState(() {
        widget.note.strokes.add(active!);
        active = null;
        undone.clear();
        changed = true;
      });
    }
    if (widget.launcherMode && changed) unawaited(save(showMessage: false));
  }

  void erase(Offset p) {
    for (int i = widget.note.strokes.length - 1; i >= 0; i--) {
      final s = widget.note.strokes[i];
      if (s.points.any((q) =>
          (Offset(q.x, q.y) - p).distance < math.max(14, s.width / 2 + 8))) {
        setState(() {
          widget.note.strokes.removeAt(i);
          changed = true;
          undone.clear();
        });
        break;
      }
    }
  }

  Future<void> save({bool showMessage = true}) async {
    widget.note.title = titleController.text.trim().isEmpty
        ? 'Untitled note'
        : titleController.text.trim();
    widget.note.text = textController.text;
    widget.note.updated = DateTime.now();
    await store.save(widget.note);
    changed = false;
    if (showMessage && mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved on this device')));
  }

  Future<Uint8List> renderPreview() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(700, 420);
    InkPainter(widget.note.strokes, null,
        background: Color(widget.note.backgroundColor),
        pattern: PaperPattern.values.firstWhere(
            (item) => item.name == widget.note.backgroundPattern,
            orElse: () => PaperPattern.lined)).paint(canvas, size);
    final picture = recorder.endRecording();
    final image =
        await picture.toImage(size.width.toInt(), size.height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return bytes!.buffer.asUint8List();
  }

  Future<void> pinWidget() async {
    await save();
    if (!Platform.isAndroid) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Home screen widgets are Android-only')));
      return;
    }
    try {
      final png = await renderPreview();
      await widgetChannel.invokeMethod(
          'setNote', {'title': widget.note.title, 'png': base64Encode(png)});
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Widget updated. Add InkNote widget from the Android home screen.')));
    } on PlatformException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Widget error: ${e.message}')));
    }
  }

  Future<void> choosePaper() async {
    var selectedColor = Color(widget.note.backgroundColor);
    var selectedPattern = PaperPattern.values.firstWhere(
        (item) => item.name == widget.note.backgroundPattern,
        orElse: () => PaperPattern.lined);
    final selection = await showModalBottomSheet<(Color, PaperPattern)>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setSheetState) => SafeArea(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Paper',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      Wrap(spacing: 12, children: [
                        for (final color in const [
                          Color(0xfffffdf7),
                          Color(0xfffff4cc),
                          Color(0xffeef7ff),
                          Color(0xffedf8ef),
                          Color(0xffffeeee),
                          Color(0xff202124),
                        ])
                          InkWell(
                              onTap: () =>
                                  setSheetState(() => selectedColor = color),
                              child: CircleAvatar(
                                  radius: 22,
                                  backgroundColor: color,
                                  child: selectedColor == color
                                      ? Icon(Icons.check,
                                          color: color.computeLuminance() > 0.5
                                              ? Colors.black
                                              : Colors.white)
                                      : null))
                      ]),
                      const SizedBox(height: 16),
                      Wrap(spacing: 8, children: [
                        for (final pattern in PaperPattern.values)
                          ChoiceChip(
                              label: Text(pattern.name),
                              selected: selectedPattern == pattern,
                              onSelected: (_) => setSheetState(
                                  () => selectedPattern = pattern))
                      ]),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                          onPressed: () => Navigator.pop(
                              context, (selectedColor, selectedPattern)),
                          icon: const Icon(Icons.check),
                          label: const Text('Apply'))
                    ])))));
    if (selection == null) return;
    setState(() {
      widget.note.backgroundColor = selection.$1.toARGB32();
      widget.note.backgroundPattern = selection.$2.name;
      changed = true;
    });
    if (widget.launcherMode) unawaited(save(showMessage: false));
  }

  void addTask() {
    final text = taskController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      widget.note.tasks.add(TaskItem(text: text));
      taskController.clear();
      changed = true;
    });
    if (widget.launcherMode) unawaited(save(showMessage: false));
  }

  void updateTask(int index, {bool? done, bool delete = false}) {
    setState(() {
      if (delete) {
        widget.note.tasks.removeAt(index);
      } else if (done != null) {
        widget.note.tasks[index].done = done;
      }
      changed = true;
    });
    if (widget.launcherMode) unawaited(save(showMessage: false));
  }

  Future<void> syncDrive() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Google Drive folder sync is Android-only for now')));
      }
      return;
    }
    await save(showMessage: false);
    try {
      var hasFolder =
          await syncChannel.invokeMethod<bool>('hasFolder') ?? false;
      if (!hasFolder) {
        hasFolder =
            await syncChannel.invokeMethod<bool>('chooseFolder') ?? false;
      }
      if (!hasFolder) return;

      final remoteRaw =
          await syncChannel.invokeMapMethod<String, String>('readFolder') ??
              <String, String>{};
      final merged = {for (final item in await store.load()) item.id: item};
      for (final content in remoteRaw.values) {
        try {
          final remote = Note.fromJson(
              Map<String, dynamic>.from(jsonDecode(content) as Map));
          final local = merged[remote.id];
          if (local == null || remote.updated.isAfter(local.updated)) {
            merged[remote.id] = remote;
            await store.save(remote);
          }
        } catch (_) {
          // Ignore unrelated or damaged JSON files in the selected folder.
        }
      }
      final syncedCurrent = merged[widget.note.id];
      if (syncedCurrent != null && !identical(syncedCurrent, widget.note)) {
        setState(() {
          widget.note.title = syncedCurrent.title;
          widget.note.text = syncedCurrent.text;
          widget.note.updated = syncedCurrent.updated;
          widget.note.strokes = syncedCurrent.strokes;
          widget.note.tasks = syncedCurrent.tasks;
          titleController.text = syncedCurrent.title;
          textController.text = syncedCurrent.text;
          changed = false;
        });
      }
      final files = <String, String>{
        for (final item in merged.values)
          '${item.id}.json': jsonEncode(item.toJson()),
      };
      await syncChannel.invokeMethod<void>('writeFolder', {'files': files});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Synced ${files.length} notes with Google Drive')));
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Drive sync error: ${error.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (changed) await save(showMessage: false);
        if (!context.mounted) return;
        if (widget.launcherMode) {
          await SystemNavigator.pop();
        } else {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
          appBar: AppBar(
              leading: widget.launcherMode
                  ? IconButton(
                      tooltip: 'All notes',
                      onPressed: () async {
                        if (changed) await save(showMessage: false);
                        if (context.mounted)
                          await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const LibraryPage()));
                      },
                      icon: const Icon(Icons.library_books_outlined))
                  : null,
              title: TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                      border: InputBorder.none, hintText: 'Note title'),
                  style: Theme.of(context).textTheme.titleLarge),
              actions: [
                IconButton(
                    tooltip: 'Undo',
                    onPressed: widget.note.strokes.isEmpty
                        ? null
                        : () => setState(() {
                              undone.add(widget.note.strokes.removeLast());
                              changed = true;
                            }),
                    icon: const Icon(Icons.undo)),
                IconButton(
                    tooltip: 'Redo',
                    onPressed: undone.isEmpty
                        ? null
                        : () => setState(() {
                              widget.note.strokes.add(undone.removeLast());
                              changed = true;
                            }),
                    icon: const Icon(Icons.redo)),
                IconButton(
                    tooltip: 'Save',
                    onPressed: save,
                    icon: const Icon(Icons.save_outlined)),
                PopupMenuButton<String>(
                    tooltip: 'Note tools',
                    onSelected: (value) {
                      switch (value) {
                        case 'text':
                          setState(() => showText = !showText);
                          return;
                        case 'tasks':
                          setState(() => showTasks = !showTasks);
                          return;
                        case 'paper':
                          choosePaper();
                          return;
                        case 'widget':
                          pinWidget();
                          return;
                        case 'sync':
                          syncDrive();
                          return;
                        case 'update':
                          save(showMessage: false)
                              .then((_) => UpdateService.prompt(context));
                          return;
                      }
                    },
                    itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'text',
                              child: ListTile(
                                  leading: const Icon(Icons.text_fields),
                                  title: Text(showText
                                      ? 'Hide typed text'
                                      : 'Show typed text'))),
                          PopupMenuItem(
                              value: 'tasks',
                              child: ListTile(
                                  leading: const Icon(Icons.checklist_outlined),
                                  title: Text(showTasks
                                      ? 'Hide checklist'
                                      : 'Show checklist'))),
                          const PopupMenuItem(
                              value: 'paper',
                              child: ListTile(
                                  leading: Icon(Icons.texture),
                                  title: Text('Paper style'))),
                          const PopupMenuItem(
                              value: 'widget',
                              child: ListTile(
                                  leading: Icon(Icons.widgets_outlined),
                                  title: Text('Update home widget'))),
                          const PopupMenuItem(
                              value: 'sync',
                              child: ListTile(
                                  leading: Icon(Icons.cloud_sync_outlined),
                                  title: Text('Sync Drive folder'))),
                          const PopupMenuItem(
                              value: 'update',
                              child: ListTile(
                                  leading: Icon(Icons.system_update_outlined),
                                  title: Text('Check for updates')))
                        ])
              ]),
          body: Column(children: [
            SizedBox(
                height: 58,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final entry in [
                        (DrawTool.pencil, Icons.create_outlined, 'Pencil'),
                        (DrawTool.pen, Icons.edit, 'Pen'),
                        (
                          DrawTool.highlighter,
                          Icons.border_color,
                          'Highlighter'
                        ),
                        (DrawTool.eraser, Icons.auto_fix_normal, 'Eraser')
                      ])
                        Padding(
                            padding: const EdgeInsets.all(4),
                            child: ChoiceChip(
                                label: Text(entry.$3),
                                avatar: Icon(entry.$2, size: 18),
                                selected: tool == entry.$1,
                                onSelected: (_) =>
                                    setState(() => tool = entry.$1))),
                      for (final c in [
                        Colors.black,
                        Colors.blue,
                        Colors.red,
                        Colors.green,
                        Colors.orange,
                        Colors.purple
                      ])
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: InkWell(
                                onTap: () => setState(() => ink = c),
                                child: CircleAvatar(
                                    radius: 15,
                                    backgroundColor: c,
                                    child: ink == c
                                        ? const Icon(Icons.check,
                                            size: 17, color: Colors.white)
                                        : null)))
                    ])),
            if (showText)
              Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: TextField(
                      controller: textController,
                      minLines: 2,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                          hintText: 'Type text here…',
                          border: OutlineInputBorder()))),
            if (showTasks)
              ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                        child: Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: taskController,
                                  onSubmitted: (_) => addTask(),
                                  decoration: const InputDecoration(
                                      hintText: 'Add a task',
                                      isDense: true,
                                      border: OutlineInputBorder()))),
                          IconButton(
                              tooltip: 'Add task',
                              onPressed: addTask,
                              icon: const Icon(Icons.add_task))
                        ])),
                    Flexible(
                        child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: widget.note.tasks.length,
                            itemBuilder: (context, index) {
                              final task = widget.note.tasks[index];
                              return CheckboxListTile(
                                  dense: true,
                                  value: task.done,
                                  onChanged: (value) =>
                                      updateTask(index, done: value),
                                  title: Text(task.text,
                                      style: task.done
                                          ? const TextStyle(
                                              decoration:
                                                  TextDecoration.lineThrough)
                                          : null),
                                  secondary: IconButton(
                                      tooltip: 'Delete task',
                                      onPressed: () =>
                                          updateTask(index, delete: true),
                                      icon: const Icon(Icons.close)));
                            }))
                  ])),
            Expanded(
                child: LayoutBuilder(
                    builder: (context, constraints) => ClipRect(
                        child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (d) => begin(d.localPosition),
                            onPanUpdate: (d) => move(d.localPosition),
                            onPanEnd: (_) => end(),
                            child: CustomPaint(
                                size: Size.infinite,
                                painter: InkPainter(widget.note.strokes, active,
                                    background:
                                        Color(widget.note.backgroundColor),
                                    pattern: PaperPattern.values.firstWhere(
                                        (item) =>
                                            item.name ==
                                            widget.note.backgroundPattern,
                                        orElse: () => PaperPattern.lined)))))))
          ])));
}

class InkPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? active;
  final Color background;
  final PaperPattern pattern;
  InkPainter(this.strokes, this.active,
      {this.background = const Color(0xfffffdf7),
      this.pattern = PaperPattern.lined});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(background, BlendMode.src);
    final line = Paint()
      ..color = background.computeLuminance() > 0.5
          ? Colors.black.withValues(alpha: 0.12)
          : Colors.white.withValues(alpha: 0.14)
      ..strokeWidth = 0.8;
    if (pattern == PaperPattern.lined || pattern == PaperPattern.grid) {
      for (double y = 29; y < size.height; y += 29) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    }
    if (pattern == PaperPattern.grid) {
      for (double x = 29; x < size.width; x += 29) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
    }
    if (pattern == PaperPattern.dots) {
      for (double y = 18; y < size.height; y += 24) {
        for (double x = 18; x < size.width; x += 24) {
          canvas.drawCircle(Offset(x, y), 1.2, line);
        }
      }
    }
    for (final s in [...strokes, if (active != null) active!]) {
      if (s.points.isEmpty) continue;
      final p = Paint()
        ..color =
            Color(s.color).withValues(alpha: s.highlight ? 0.32 : s.opacity)
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawPoints(ui.PointMode.points,
            [Offset(s.points.first.x, s.points.first.y)], p);
        continue;
      }
      final path = Path()..moveTo(s.points.first.x, s.points.first.y);
      for (final pt in s.points.skip(1)) path.lineTo(pt.x, pt.y);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant InkPainter old) => true;
}
