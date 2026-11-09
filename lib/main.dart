import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'autosave_controller.dart';
import 'note_data.dart';
import 'note_store.dart';

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
      scaffoldBackgroundColor: const Color(0xfffaf9f6),
    ),
        home: const LauncherCanvasPage(),
      );
}

Future<Directory> _noteDirectory() async =>
        Directory('${(await getApplicationDocumentsDirectory()).path}/inknote');

class LauncherCanvasPage extends StatefulWidget {
  const LauncherCanvasPage({super.key});

  @override
  State<LauncherCanvasPage> createState() => _LauncherCanvasPageState();
}

class _LauncherCanvasPageState extends State<LauncherCanvasPage> {
  static const launcherNoteId = 'launcher-canvas';
  final store = NoteStore(directoryProvider: _noteDirectory);
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
    if (mounted) setState(() => note = loaded);
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
  final store = NoteStore(directoryProvider: _noteDirectory);
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
    final n =
        note ??
        Note(
            id: const Uuid().v4(),
            title: 'Untitled note',
            text: '',
            updated: DateTime.now(),
          strokes: [],
        );
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditorPage(note: n)),
    );
    await refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('All notes')),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => openNote(),
            icon: const Icon(Icons.add),
      label: const Text('New note'),
    ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : notes.isEmpty
                ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                    Icon(Icons.draw_outlined, size: 64, color: Colors.grey),
                    SizedBox(height: 12),
                Text('Start your first handwritten note'),
              ],
            ),
          )
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
                    '${n.strokes.length} strokes • ${n.updated.toLocal()}',
                  ),
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
                        child: Text('Delete'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
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

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  static const widgetChannel = MethodChannel('inknote/widget');
  static const syncChannel = MethodChannel('inknote/sync');
  late final TextEditingController titleController;
  late final TextEditingController textController;
  late final TextEditingController taskController;
  DrawTool tool = DrawTool.pen;
  Color ink = Colors.blue.shade800;
  double width = 3;
  Stroke? active;
  bool showText = true;
  bool showTasks = false;
  bool applyingExternalChange = false;
  late final AutosaveController autosave;
  final List<Stroke> undone = [];
  final store = NoteStore(directoryProvider: _noteDirectory);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    autosave = AutosaveController(
      onSave: _persist,
      onStatusChanged: (_) {
        if (mounted) setState(() {});
      },
    );
    titleController = TextEditingController(text: widget.note.title);
    titleController.addListener(_markChanged);
    textController = TextEditingController(text: widget.note.text);
    taskController = TextEditingController();
    textController.addListener(_markChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    autosave.dispose();
    titleController.dispose();
    textController.dispose();
    taskController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _finalizeActiveStroke();
      unawaited(autosave.saveNow());
    }
  }

  void _markChanged() {
    if (!applyingExternalChange) autosave.markChanged();
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
        opacity: tool == DrawTool.pencil ? 0.58 : 1,
      );
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

  void end() => _finalizeActiveStroke();

  void _finalizeActiveStroke() {
    if (!commitActiveStroke(widget.note.strokes, active)) return;
    setState(() {
      active = null;
      undone.clear();
    });
    _markChanged();
  }

  void erase(Offset p) {
    for (int i = widget.note.strokes.length - 1; i >= 0; i--) {
      final s = widget.note.strokes[i];
      if (s.points.any(
        (q) => (Offset(q.x, q.y) - p).distance < math.max(14, s.width / 2 + 8),
      )) {
        setState(() {
          widget.note.strokes.removeAt(i);
          undone.clear();
        });
        _markChanged();
        break;
      }
    }
  }

  Future<void> _persist() async {
    widget.note.title = titleController.text.trim().isEmpty
        ? 'Untitled note'
        : titleController.text.trim();
    widget.note.text = textController.text;
    widget.note.updated = DateTime.now();
    await store.save(widget.note);
  }

  Future<void> save({bool showMessage = true}) async {
    await autosave.saveNow();
    if (!showMessage || !mounted) return;
    final message = autosave.status == SaveStatus.failed
        ? 'Could not save this note. Your edits are still open.'
        : 'Saved on this device';
      ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String get saveLabel => switch (autosave.status) {
    SaveStatus.saved => 'Saved',
    SaveStatus.unsaved => 'Unsaved',
    SaveStatus.saving => 'Saving…',
    SaveStatus.failed => 'Save failed',
  };

  IconData get saveIcon => switch (autosave.status) {
    SaveStatus.saved => Icons.check_circle_outline,
    SaveStatus.unsaved => Icons.edit_outlined,
    SaveStatus.saving => Icons.sync,
    SaveStatus.failed => Icons.error_outline,
  };

  Future<Uint8List> renderPreview() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(700, 420);
    InkPainter(
      widget.note.strokes,
      null,
        background: Color(widget.note.backgroundColor),
        pattern: PaperPattern.values.firstWhere(
            (item) => item.name == widget.note.backgroundPattern,
        orElse: () => PaperPattern.lined,
      ),
    ).paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return bytes!.buffer.asUint8List();
  }

  Future<void> pinWidget() async {
    await save(showMessage: false);
    if (autosave.status == SaveStatus.failed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Widget update stopped because the note is unsaved'),
          ),
        );
      }
      return;
    }
    if (!Platform.isAndroid) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Home screen widgets are Android-only')),
        );
      return;
    }
    try {
      final png = await renderPreview();
      await widgetChannel.invokeMethod('setNote', {
        'title': widget.note.title,
        'png': base64Encode(png),
      });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Widget updated. Add InkNote widget from the Android home screen.',
            ),
          ),
        );
    } on PlatformException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Widget error: ${e.message}')));
    }
  }

  Future<void> choosePaper() async {
    var selectedColor = Color(widget.note.backgroundColor);
    var selectedPattern = PaperPattern.values.firstWhere(
        (item) => item.name == widget.note.backgroundPattern,
      orElse: () => PaperPattern.lined,
    );
    final selection = await showModalBottomSheet<(Color, PaperPattern)>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setSheetState) => SafeArea(
                child: Padding(
                    padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Paper', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  children: [
                        for (final color in const [
                          Color(0xfffffdf7),
                          Color(0xfffff4cc),
                          Color(0xffeef7ff),
                          Color(0xffedf8ef),
                          Color(0xffffeeee),
                          Color(0xff202124),
                        ])
                          InkWell(
                        onTap: () => setSheetState(() => selectedColor = color),
                              child: CircleAvatar(
                                  radius: 22,
                                  backgroundColor: color,
                                  child: selectedColor == color
                              ? Icon(
                                  Icons.check,
                                          color: color.computeLuminance() > 0.5
                                              ? Colors.black
                                      : Colors.white,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
                      const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                        for (final pattern in PaperPattern.values)
                          ChoiceChip(
                              label: Text(pattern.name),
                              selected: selectedPattern == pattern,
                        onSelected: (_) =>
                            setSheetState(() => selectedPattern = pattern),
                      ),
                  ],
                ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, (selectedColor, selectedPattern)),
                          icon: const Icon(Icons.check),
                  label: const Text('Apply'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selection == null) return;
    setState(() {
      widget.note.backgroundColor = selection.$1.toARGB32();
      widget.note.backgroundPattern = selection.$2.name;
    });
    _markChanged();
  }

  void addTask() {
    final text = taskController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      widget.note.tasks.add(TaskItem(text: text));
      taskController.clear();
    });
    _markChanged();
  }

  void updateTask(int index, {bool? done, bool delete = false}) {
    setState(() {
      if (delete) {
        widget.note.tasks.removeAt(index);
      } else if (done != null) {
        widget.note.tasks[index].done = done;
      }
    });
    _markChanged();
  }

  Future<void> syncDrive() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Google Drive folder sync is Android-only for now'),
          ),
        );
      }
      return;
    }
    await save(showMessage: false);
    if (autosave.status == SaveStatus.failed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync stopped because the note could not be saved'),
          ),
        );
      }
      return;
    }
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
            Map<String, dynamic>.from(jsonDecode(content) as Map),
          );
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
        applyingExternalChange = true;
        try {
        setState(() {
          widget.note.title = syncedCurrent.title;
          widget.note.text = syncedCurrent.text;
          widget.note.updated = syncedCurrent.updated;
          widget.note.strokes = syncedCurrent.strokes;
          widget.note.tasks = syncedCurrent.tasks;
          titleController.text = syncedCurrent.title;
          textController.text = syncedCurrent.text;
        });
        } finally {
          applyingExternalChange = false;
        }
      }
      final files = <String, String>{
        for (final item in merged.values)
          '${item.id}.json': jsonEncode(item.toJson()),
      };
      await syncChannel.invokeMethod<void>('writeFolder', {'files': files});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Synced ${files.length} notes with Google Drive'),
          ),
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive sync error: ${error.message}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
      await save(showMessage: false);
        if (!context.mounted) return;
      if (autosave.status == SaveStatus.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The note is still unsaved. Try saving again.'),
          ),
        );
        return;
      }
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
                  await save(showMessage: false);
                  if (autosave.status == SaveStatus.failed) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'The note is still unsaved. Try saving again.',
                          ),
                        ),
                      );
                    }
                    return;
                  }
                        if (context.mounted)
                          await Navigator.push(
                              context,
                      MaterialPageRoute(builder: (_) => const LibraryPage()),
                    );
                      },
                icon: const Icon(Icons.library_books_outlined),
              )
                  : null,
              title: TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: 'Note title',
          ),
          style: Theme.of(context).textTheme.titleLarge,
        ),
              actions: [
                IconButton(
                    tooltip: 'Undo',
                    onPressed: widget.note.strokes.isEmpty
                        ? null
                : () {
                    setState(
                      () => undone.add(widget.note.strokes.removeLast()),
                    );
                    _markChanged();
                  },
            icon: const Icon(Icons.undo),
          ),
                IconButton(
                    tooltip: 'Redo',
                    onPressed: undone.isEmpty
                        ? null
                : () {
                    setState(
                      () => widget.note.strokes.add(undone.removeLast()),
                    );
                    _markChanged();
                  },
            icon: const Icon(Icons.redo),
          ),
          TextButton.icon(
                    onPressed: save,
            icon: Icon(saveIcon, size: 19),
            label: Text(saveLabel),
          ),
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
                      }
                    },
                    itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'text',
                              child: ListTile(
                                  leading: const Icon(Icons.text_fields),
                  title: Text(showText ? 'Hide typed text' : 'Show typed text'),
                ),
              ),
                          PopupMenuItem(
                              value: 'tasks',
                              child: ListTile(
                                  leading: const Icon(Icons.checklist_outlined),
                  title: Text(showTasks ? 'Hide checklist' : 'Show checklist'),
                ),
              ),
                          const PopupMenuItem(
                              value: 'paper',
                              child: ListTile(
                                  leading: Icon(Icons.texture),
                  title: Text('Paper style'),
                ),
              ),
                          const PopupMenuItem(
                              value: 'widget',
                              child: ListTile(
                                  leading: Icon(Icons.widgets_outlined),
                  title: Text('Update home widget'),
                ),
              ),
                          const PopupMenuItem(
                              value: 'sync',
                              child: ListTile(
                                  leading: Icon(Icons.cloud_sync_outlined),
                  title: Text('Sync Drive folder'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
            SizedBox(
                height: 58,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final entry in [
                        (DrawTool.pencil, Icons.create_outlined, 'Pencil'),
                        (DrawTool.pen, Icons.edit, 'Pen'),
                  (DrawTool.highlighter, Icons.border_color, 'Highlighter'),
                  (DrawTool.eraser, Icons.auto_fix_normal, 'Eraser'),
                      ])
                        Padding(
                            padding: const EdgeInsets.all(4),
                            child: ChoiceChip(
                                label: Text(entry.$3),
                                avatar: Icon(entry.$2, size: 18),
                                selected: tool == entry.$1,
                      onSelected: (_) => setState(() => tool = entry.$1),
                    ),
                  ),
                      for (final c in [
                        Colors.black,
                        Colors.blue,
                        Colors.red,
                        Colors.green,
                        Colors.orange,
                  Colors.purple,
                      ])
                        Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: InkWell(
                                onTap: () => setState(() => ink = c),
                                child: CircleAvatar(
                                    radius: 15,
                                    backgroundColor: c,
                                    child: ink == c
                            ? const Icon(
                                Icons.check,
                                size: 17,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            if (showTasks)
              ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Row(
                      children: [
                          Expanded(
                              child: TextField(
                                  controller: taskController,
                                  onSubmitted: (_) => addTask(),
                                  decoration: const InputDecoration(
                                      hintText: 'Add a task',
                                      isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                          IconButton(
                              tooltip: 'Add task',
                              onPressed: addTask,
                          icon: const Icon(Icons.add_task),
                        ),
                      ],
                    ),
                  ),
                    Flexible(
                        child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: widget.note.tasks.length,
                            itemBuilder: (context, index) {
                              final task = widget.note.tasks[index];
                              return CheckboxListTile(
                                  dense: true,
                                  value: task.done,
                          onChanged: (value) => updateTask(index, done: value),
                          title: Text(
                            task.text,
                                      style: task.done
                                          ? const TextStyle(
                                    decoration: TextDecoration.lineThrough,
                                  )
                                : null,
                          ),
                                  secondary: IconButton(
                                      tooltip: 'Delete task',
                            onPressed: () => updateTask(index, delete: true),
                            icon: const Icon(Icons.close),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
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
                    painter: InkPainter(
                      widget.note.strokes,
                      active,
                      background: Color(widget.note.backgroundColor),
                                    pattern: PaperPattern.values.firstWhere(
                        (item) => item.name == widget.note.backgroundPattern,
                        orElse: () => PaperPattern.lined,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class InkPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? active;
  final Color background;
  final PaperPattern pattern;
  InkPainter(
    this.strokes,
    this.active, {
    this.background = const Color(0xfffffdf7),
    this.pattern = PaperPattern.lined,
  });
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
        ..color = Color(s.color)
            .withValues(alpha: s.highlight ? 0.32 : s.opacity)
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawPoints(ui.PointMode.points, [
          Offset(s.points.first.x, s.points.first.y),
        ], p);
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
