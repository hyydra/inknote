import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'autosave_controller.dart';
import 'canvas_editing.dart';
import 'note_data.dart';
import 'note_store.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.4.3');

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String fileName;
  const UpdateInfo(this.version, this.downloadUrl, this.fileName);
}

class UpdateService {
  static const _channel = MethodChannel('notes/update');
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
          'https://api.github.com/repos/hyydra/pennino/releases/latest'));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Pennino/$appVersion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final release = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final version =
          (release['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (!_isNewer(version, appVersion)) return null;
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
            const SnackBar(content: Text('Pennino is up to date.')));
      }
      return;
    }
    final install = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Pennino update available'),
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
param([int]\$AppPid)
Wait-Process -Id \$AppPid -ErrorAction SilentlyContinue
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
  runApp(const NotesApp());
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Pennino',
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xff594fc8),
          scaffoldBackgroundColor: const Color(0xfffaf9f6),
        ),
        home: const LauncherCanvasPage(),
      );
}

Future<Directory> _noteDirectory() async =>
    Directory('${(await getApplicationDocumentsDirectory()).path}/notes');

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(UpdateService.prompt(context, automatic: true));
    });
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
    final n = note ??
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

enum DrawTool { hand, select, pencil, pen, highlighter, eraser }

enum PaperPattern { plain, lined, grid, dots }

class EditorPage extends StatefulWidget {
  final Note note;
  final bool launcherMode;
  const EditorPage({super.key, required this.note, this.launcherMode = false});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  static const widgetChannel = MethodChannel('notes/widget');
  static const syncChannel = MethodChannel('notes/sync');
  late final TextEditingController titleController;
  final List<TextEditingController> textControllers = [];
  final List<TextBlockFormat> textFormats = [];
  int activeTextIndex = 0;
  late final TextEditingController taskController;
  final TransformationController transformationController =
      TransformationController();
  DrawTool tool = DrawTool.pen;
  Color strokeColor = Colors.blue.shade800;
  double width = 3;
  Stroke? active;
  bool showText = true;
  bool showTasks = false;
  bool applyingExternalChange = false;
  final Set<int> selectedStrokes = {};
  Offset? lastSelectionViewportPoint;
  bool selectionMoved = false;
  bool gestureHistoryRecorded = false;
  late final AutosaveController autosave;
  final StrokeHistory strokeHistory = StrokeHistory();
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
    taskController = TextEditingController();
    _replaceTextControllers(
      widget.note.textBlocks,
      formats: widget.note.textBlockFormats,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    autosave.dispose();
    titleController.dispose();
    for (final controller in textControllers) {
      controller.dispose();
    }
    taskController.dispose();
    transformationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _finalizeActiveStroke();
      lastSelectionViewportPoint = null;
      selectionMoved = false;
      gestureHistoryRecorded = false;
      unawaited(autosave.saveNow());
    }
  }

  void _markChanged() {
    if (!applyingExternalChange) autosave.markChanged();
  }

  TextEditingController _textController(String text) {
    final controller = TextEditingController(text: text);
    controller.addListener(_markChanged);
    return controller;
  }

  void _replaceTextControllers(
    Iterable<String> blocks, {
    Iterable<TextBlockFormat>? formats,
  }) {
    for (final controller in textControllers) {
      controller.dispose();
    }
    textControllers
      ..clear()
      ..addAll(blocks.map(_textController));
    final savedFormats = formats?.toList() ?? const <TextBlockFormat>[];
    textFormats
      ..clear()
      ..addAll(List.generate(
        textControllers.length,
        (index) => index < savedFormats.length
            ? TextBlockFormat(
                bold: savedFormats[index].bold,
                color: savedFormats[index].color,
              )
            : TextBlockFormat(),
      ));
    activeTextIndex = textControllers.isEmpty
        ? 0
        : activeTextIndex.clamp(0, textControllers.length - 1);
  }

  void addTextBlock() {
    setState(() {
      showText = true;
      textControllers.add(_textController(''));
      textFormats.add(TextBlockFormat());
      activeTextIndex = textControllers.length - 1;
    });
    _markChanged();
  }

  void removeTextBlock(int index) {
    setState(() {
      textControllers.removeAt(index).dispose();
      textFormats.removeAt(index);
      activeTextIndex = textControllers.isEmpty
          ? 0
          : activeTextIndex.clamp(0, textControllers.length - 1);
    });
    _markChanged();
  }

  TextEditingController? get _activeTextController => textControllers.isEmpty
      ? null
      : textControllers[activeTextIndex.clamp(0, textControllers.length - 1)];

  void _toggleLinePrefix(String prefix) {
    final controller = _activeTextController;
    if (controller == null) {
      addTextBlock();
      return;
    }
    final value = controller.value;
    final cursor =
        value.selection.isValid ? value.selection.start : value.text.length;
    final lineStart = value.text.lastIndexOf('\n', math.max(0, cursor - 1)) + 1;
    final lineEndMatch = value.text.indexOf('\n', cursor);
    final lineEnd = lineEndMatch == -1 ? value.text.length : lineEndMatch;
    final line = value.text.substring(lineStart, lineEnd);
    const knownPrefixes = ['☐ ', '• ', '1. '];
    final currentPrefix = knownPrefixes.where(line.startsWith).firstOrNull;
    final removeLength = currentPrefix?.length ?? 0;
    final replacement = currentPrefix == prefix ? '' : prefix;
    final text = value.text.replaceRange(
      lineStart,
      lineStart + removeLength,
      replacement,
    );
    final nextCursor = (cursor - removeLength + replacement.length)
        .clamp(lineStart, text.length);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: nextCursor),
    );
  }

  void _changeIndent(bool increase) {
    final controller = _activeTextController;
    if (controller == null) return;
    final value = controller.value;
    final cursor =
        value.selection.isValid ? value.selection.start : value.text.length;
    final lineStart = value.text.lastIndexOf('\n', math.max(0, cursor - 1)) + 1;
    final remove =
        !increase && value.text.substring(lineStart).startsWith('    ');
    final text = value.text.replaceRange(
      lineStart,
      lineStart + (remove ? 4 : 0),
      increase ? '    ' : '',
    );
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: (cursor +
                (increase
                    ? 4
                    : remove
                        ? -4
                        : 0))
            .clamp(lineStart, text.length),
      ),
    );
  }

  Future<void> _chooseTextColor() async {
    if (textControllers.isEmpty) return;
    final colors = [
      Colors.black,
      Colors.red,
      Colors.orange,
      Colors.green,
      Colors.blue,
      Colors.purple,
    ];
    final selected = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Text colour'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final color in colors)
              InkWell(
                onTap: () => Navigator.pop(dialogContext, color),
                borderRadius: BorderRadius.circular(24),
                child: CircleAvatar(backgroundColor: color),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => textFormats[activeTextIndex].color = selected.toARGB32());
    _markChanged();
  }

  CanvasTransform get canvasTransform {
    final matrix = transformationController.value;
    return CanvasTransform(
      scale: matrix.getMaxScaleOnAxis(),
      translationX: matrix.storage[12],
      translationY: matrix.storage[13],
    );
  }

  CanvasPoint _scenePoint(Offset viewportPoint) => canvasTransform
      .sceneFromViewport(CanvasPoint(viewportPoint.dx, viewportPoint.dy));

  void begin(Offset viewportPoint) {
    if (tool == DrawTool.hand) return;
    gestureHistoryRecorded = false;
    if (tool == DrawTool.select) {
      final selected = hitTestStrokeAtViewport(
        widget.note.strokes,
        CanvasPoint(viewportPoint.dx, viewportPoint.dy),
        canvasTransform,
      );
      setState(() {
        selectedStrokes
          ..clear()
          ..addAll(selected == null ? const <int>[] : [selected]);
        lastSelectionViewportPoint = selected == null ? null : viewportPoint;
        selectionMoved = false;
      });
      return;
    }
    if (tool == DrawTool.eraser) {
      erase(viewportPoint);
      return;
    }
    final scenePoint = _scenePoint(viewportPoint);
    strokeHistory.record(widget.note.strokes);
    gestureHistoryRecorded = true;
    setState(() {
      selectedStrokes.clear();
      active = Stroke(
        points: [scenePoint],
        color: strokeColor.toARGB32(),
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

  void move(Offset viewportPoint) {
    if (tool == DrawTool.hand) return;
    if (tool == DrawTool.select) {
      final previous = lastSelectionViewportPoint;
      if (previous == null || selectedStrokes.isEmpty) return;
      if (!gestureHistoryRecorded) {
        strokeHistory.record(widget.note.strokes);
        gestureHistoryRecorded = true;
      }
      final moved = translateSelectedFromViewportDelta(
        widget.note.strokes,
        selectedStrokes,
        CanvasPoint(
          viewportPoint.dx - previous.dx,
          viewportPoint.dy - previous.dy,
        ),
        canvasTransform,
      );
      if (moved) {
        if (!selectionMoved) _markChanged();
        setState(() {
          lastSelectionViewportPoint = viewportPoint;
          selectionMoved = true;
        });
      }
      return;
    }
    if (tool == DrawTool.eraser) {
      erase(viewportPoint);
      return;
    }
    if (active == null) return;
    final scenePoint = _scenePoint(viewportPoint);
    setState(() => active!.points.add(scenePoint));
  }

  void end() {
    if (tool == DrawTool.select) {
      setState(() {
        lastSelectionViewportPoint = null;
        selectionMoved = false;
        gestureHistoryRecorded = false;
      });
      return;
    }
    _finalizeActiveStroke();
  }

  void _finalizeActiveStroke() {
    if (!commitActiveStroke(widget.note.strokes, active)) return;
    setState(() {
      active = null;
      gestureHistoryRecorded = false;
    });
    _markChanged();
  }

  void erase(Offset viewportPoint) {
    final index = hitTestStrokeAtViewport(
      widget.note.strokes,
      CanvasPoint(viewportPoint.dx, viewportPoint.dy),
      canvasTransform,
    );
    if (index == null) return;
    if (!gestureHistoryRecorded) {
      strokeHistory.record(widget.note.strokes);
      gestureHistoryRecorded = true;
    }
    setState(() {
      widget.note.strokes.removeAt(index);
      selectedStrokes.clear();
    });
    _markChanged();
  }

  void deleteSelection() {
    if (selectedStrokes.isEmpty) return;
    final indices = selectedStrokes.toList()..sort((a, b) => b.compareTo(a));
    strokeHistory.record(widget.note.strokes);
    setState(() {
      for (final index in indices) {
        if (index >= 0 && index < widget.note.strokes.length) {
          widget.note.strokes.removeAt(index);
        }
      }
      selectedStrokes.clear();
    });
    _markChanged();
  }

  Future<void> _persist() async {
    widget.note.title = titleController.text.trim().isEmpty
        ? 'Untitled note'
        : titleController.text.trim();
    widget.note.textBlocks =
        textControllers.map((controller) => controller.text).toList();
    widget.note.textBlockFormats = textFormats
        .map(
            (format) => TextBlockFormat(bold: format.bold, color: format.color))
        .toList();
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
    StrokePainter(
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
              'Widget updated. Add the Pennino widget from the Android home screen.',
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

  Future<Directory?> _windowsSyncFolder({bool choose = false}) async {
    final marker = File('${(await _noteDirectory()).path}/.sync-folder');
    if (!choose && await marker.exists()) {
      final savedPath = (await marker.readAsString()).trim();
      if (savedPath.isNotEmpty) {
        final saved = Directory(savedPath);
        if (await saved.exists()) return saved;
      }
    }
    final selected = await getDirectoryPath(
      confirmButtonText: 'Use this folder',
    );
    if (selected == null) return null;
    final directory = Directory(selected);
    await marker.writeAsString(directory.path, flush: true);
    return directory;
  }

  Future<Map<String, String>> _readWindowsSyncFolder(
      Directory directory) async {
    final files = <String, String>{};
    await for (final entry in directory.list()) {
      if (entry is File && entry.path.toLowerCase().endsWith('.json')) {
        files[entry.uri.pathSegments.last] = await entry.readAsString();
      }
    }
    return files;
  }

  Future<void> _writeWindowsSyncFolder(
    Directory directory,
    Map<String, String> files,
  ) async {
    for (final entry in files.entries) {
      await File('${directory.path}${Platform.pathSeparator}${entry.key}')
          .writeAsString(entry.value, flush: true);
    }
  }

  Future<void> syncDrive({bool chooseFolder = false}) async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Folder sync is available on Android and Windows'),
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
      Directory? windowsFolder;
      Map<String, String> remoteRaw;
      if (Platform.isAndroid) {
        var hasFolder =
            await syncChannel.invokeMethod<bool>('hasFolder') ?? false;
        if (!hasFolder) {
          hasFolder =
              await syncChannel.invokeMethod<bool>('chooseFolder') ?? false;
        }
        if (!hasFolder) return;
        remoteRaw =
            await syncChannel.invokeMapMethod<String, String>('readFolder') ??
                <String, String>{};
      } else {
        windowsFolder = await _windowsSyncFolder(choose: chooseFolder);
        if (windowsFolder == null) return;
        remoteRaw = await _readWindowsSyncFolder(windowsFolder);
      }
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
            widget.note.textBlocks = List.of(syncedCurrent.textBlocks);
            widget.note.textBlockFormats = syncedCurrent.textBlockFormats
                .map((format) => TextBlockFormat(
                      bold: format.bold,
                      color: format.color,
                    ))
                .toList();
            widget.note.updated = syncedCurrent.updated;
            widget.note.strokes = syncedCurrent.strokes;
            widget.note.tasks = syncedCurrent.tasks;
            widget.note.backgroundColor = syncedCurrent.backgroundColor;
            widget.note.backgroundPattern = syncedCurrent.backgroundPattern;
            selectedStrokes.clear();
            lastSelectionViewportPoint = null;
            selectionMoved = false;
            gestureHistoryRecorded = false;
            strokeHistory.clear();
            titleController.text = syncedCurrent.title;
            _replaceTextControllers(
              syncedCurrent.textBlocks,
              formats: syncedCurrent.textBlockFormats,
            );
          });
        } finally {
          applyingExternalChange = false;
        }
      }
      final files = <String, String>{
        for (final item in merged.values)
          '${item.id}.json': jsonEncode(item.toJson()),
      };
      if (Platform.isAndroid) {
        await syncChannel.invokeMethod<void>('writeFolder', {'files': files});
      } else {
        await _writeWindowsSyncFolder(windowsFolder!, files);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Synced ${files.length} notes with Google Drive'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive sync error: $error')),
        );
      }
    }
  }

  Widget _androidDrawingToolbar() => SizedBox(
        key: const Key('android-drawing-toolbar'),
        height: 64,
        child: Material(
          elevation: 6,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final entry in [
                (DrawTool.hand, Icons.pan_tool_outlined, 'Hand'),
                (DrawTool.select, Icons.select_all, 'Select'),
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
                    onSelected: (_) => setState(() {
                      tool = entry.$1;
                      if (tool != DrawTool.select) selectedStrokes.clear();
                    }),
                  ),
                ),
              if (selectedStrokes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: ActionChip(
                    avatar: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete selection'),
                    onPressed: deleteSelection,
                  ),
                ),
              for (final color in [
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
                    onTap: () => setState(() => strokeColor = color),
                    child: CircleAvatar(
                      radius: 15,
                      backgroundColor: color,
                      child: strokeColor == color
                          ? const Icon(Icons.check,
                              size: 17, color: Colors.white)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _textToolbar() => SizedBox(
        key: const Key('text-toolbar'),
        height: 52,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              Padding(
                padding: const EdgeInsets.all(4),
                child: ChoiceChip(
                  avatar: const Icon(Icons.text_fields, size: 18),
                  label: const Text('Text blocks'),
                  selected: showText,
                  onSelected: (selected) => setState(() => showText = selected),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(4),
                child: ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add text block'),
                  tooltip: 'Add text block',
                  onPressed: addTextBlock,
                ),
              ),
              if (textControllers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: Text(
                      '${textControllers.length} text ${textControllers.length == 1 ? 'block' : 'blocks'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              if (textControllers.isNotEmpty) ...[
                IconButton(
                  tooltip: 'Checklist',
                  onPressed: () => _toggleLinePrefix('☐ '),
                  icon: const Icon(Icons.check_box_outlined),
                ),
                IconButton(
                  tooltip: 'Numbered list',
                  onPressed: () => _toggleLinePrefix('1. '),
                  icon: const Icon(Icons.format_list_numbered),
                ),
                IconButton(
                  tooltip: 'Bulleted list',
                  onPressed: () => _toggleLinePrefix('• '),
                  icon: const Icon(Icons.format_list_bulleted),
                ),
                IconButton(
                  tooltip: 'Decrease indent',
                  onPressed: () => _changeIndent(false),
                  icon: const Icon(Icons.format_indent_decrease),
                ),
                IconButton(
                  tooltip: 'Increase indent',
                  onPressed: () => _changeIndent(true),
                  icon: const Icon(Icons.format_indent_increase),
                ),
                IconButton(
                  tooltip: 'Text colour',
                  onPressed: _chooseTextColor,
                  icon: Icon(
                    Icons.format_color_text,
                    color: Color(textFormats[activeTextIndex].color),
                  ),
                ),
                IconButton(
                  tooltip: 'Bold',
                  isSelected: textFormats[activeTextIndex].bold,
                  onPressed: () {
                    setState(() {
                      textFormats[activeTextIndex].bold =
                          !textFormats[activeTextIndex].bold;
                    });
                    _markChanged();
                  },
                  icon: const Icon(Icons.format_bold),
                ),
              ],
            ],
          ),
        ),
      );

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
                          MaterialPageRoute(
                              builder: (_) => const LibraryPage()),
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
                onPressed: !strokeHistory.canUndo
                    ? null
                    : () {
                        final restored =
                            strokeHistory.undo(widget.note.strokes);
                        if (restored == null) return;
                        setState(
                          () {
                            selectedStrokes.clear();
                            widget.note.strokes = restored;
                          },
                        );
                        _markChanged();
                      },
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Redo',
                onPressed: !strokeHistory.canRedo
                    ? null
                    : () {
                        final restored =
                            strokeHistory.redo(widget.note.strokes);
                        if (restored == null) return;
                        setState(
                          () {
                            selectedStrokes.clear();
                            widget.note.strokes = restored;
                          },
                        );
                        _markChanged();
                      },
                icon: const Icon(Icons.redo),
              ),
              if (MediaQuery.sizeOf(context).width >= 700)
                TextButton.icon(
                  onPressed: save,
                  icon: Icon(saveIcon, size: 19),
                  label: Text(saveLabel),
                )
              else
                IconButton(
                  tooltip: saveLabel,
                  onPressed: save,
                  icon: Icon(saveIcon),
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
                    case 'sync-folder':
                      syncDrive(chooseFolder: true);
                      return;
                    case 'update':
                      UpdateService.prompt(context);
                      return;
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'text',
                    child: ListTile(
                      leading: const Icon(Icons.text_fields),
                      title: Text(
                          showText ? 'Hide typed text' : 'Show typed text'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'tasks',
                    child: ListTile(
                      leading: const Icon(Icons.checklist_outlined),
                      title:
                          Text(showTasks ? 'Hide checklist' : 'Show checklist'),
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
                  if (Platform.isWindows)
                    const PopupMenuItem(
                      value: 'sync-folder',
                      child: ListTile(
                        leading: Icon(Icons.folder_open_outlined),
                        title: Text('Choose Drive folder'),
                      ),
                    ),
                  if (Platform.isAndroid || Platform.isWindows)
                    const PopupMenuItem(
                      value: 'update',
                      child: ListTile(
                        leading: Icon(Icons.system_update_outlined),
                        title: Text('Check for updates'),
                      ),
                    ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (Theme.of(context).platform != TargetPlatform.android)
                SizedBox(
                  height: 58,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final entry in [
                        (DrawTool.hand, Icons.pan_tool_outlined, 'Hand'),
                        (DrawTool.select, Icons.select_all, 'Select'),
                        (DrawTool.pencil, Icons.create_outlined, 'Pencil'),
                        (DrawTool.pen, Icons.edit, 'Pen'),
                        (
                          DrawTool.highlighter,
                          Icons.border_color,
                          'Highlighter'
                        ),
                        (DrawTool.eraser, Icons.auto_fix_normal, 'Eraser'),
                      ])
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ChoiceChip(
                            label: Text(entry.$3),
                            avatar: Icon(entry.$2, size: 18),
                            selected: tool == entry.$1,
                            onSelected: (_) => setState(() {
                              tool = entry.$1;
                              if (tool != DrawTool.select)
                                selectedStrokes.clear();
                            }),
                          ),
                        ),
                      if (Theme.of(context).platform == TargetPlatform.windows)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ActionChip(
                            avatar: const Icon(
                              Icons.system_update_outlined,
                              size: 18,
                            ),
                            label: Text('Auto updates · v$appVersion'),
                            tooltip: 'Check for updates',
                            onPressed: () => UpdateService.prompt(context),
                          ),
                        ),
                      if (selectedStrokes.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ActionChip(
                            avatar: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Delete selection'),
                            onPressed: deleteSelection,
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
                            onTap: () => setState(() => strokeColor = c),
                            child: CircleAvatar(
                              radius: 15,
                              backgroundColor: c,
                              child: strokeColor == c
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
              _textToolbar(),
              if (showText)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 230),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 4, 2),
                        child: Row(
                          children: [
                            const Expanded(child: Text('Typed text')),
                            IconButton(
                              tooltip: 'Add another text block',
                              onPressed: addTextBlock,
                              icon: const Icon(Icons.add),
                            ),
                          ],
                        ),
                      ),
                      if (textControllers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: OutlinedButton.icon(
                            onPressed: addTextBlock,
                            icon: const Icon(Icons.add),
                            label: const Text('Add text block'),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
                            itemCount: textControllers.length,
                            itemBuilder: (context, index) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: textControllers[index],
                                      onTap: () => setState(
                                        () => activeTextIndex = index,
                                      ),
                                      minLines: 2,
                                      maxLines: null,
                                      keyboardType: TextInputType.multiline,
                                      style: TextStyle(
                                        color: Color(textFormats[index].color),
                                        fontWeight: textFormats[index].bold
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: 'Text block ${index + 1}',
                                        border: const OutlineInputBorder(),
                                        filled: true,
                                        fillColor: Colors.transparent,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete text block',
                                    onPressed: () => removeTextBlock(index),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
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
                              onChanged: (value) =>
                                  updateTask(index, done: value),
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
                                onPressed: () =>
                                    updateTask(index, delete: true),
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
                  builder: (context, constraints) {
                    final canvasWidth = math.max(2000.0, constraints.maxWidth);
                    final canvasHeight =
                        math.max(3000.0, constraints.maxHeight * 3);
                    final isHandTool = tool == DrawTool.hand;
                    return ClipRect(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: isHandTool
                            ? null
                            : (event) => begin(event.localPosition),
                        onPointerMove: isHandTool
                            ? null
                            : (event) => move(event.localPosition),
                        onPointerUp: isHandTool ? null : (_) => end(),
                        onPointerCancel: isHandTool ? null : (_) => end(),
                        child: IgnorePointer(
                          ignoring: !isHandTool,
                          child: InteractiveViewer(
                            transformationController: transformationController,
                            alignment: Alignment.topLeft,
                            constrained: false,
                            boundaryMargin: const EdgeInsets.all(500),
                            minScale: 0.25,
                            maxScale: 5,
                            child: SizedBox(
                              width: canvasWidth,
                              height: canvasHeight,
                              child: CustomPaint(
                                painter: StrokePainter(
                                  widget.note.strokes,
                                  active,
                                  selectedIndices: selectedStrokes,
                                  selectionScale: canvasTransform.scale,
                                  background:
                                      Color(widget.note.backgroundColor),
                                  pattern: PaperPattern.values.firstWhere(
                                    (item) =>
                                        item.name ==
                                        widget.note.backgroundPattern,
                                    orElse: () => PaperPattern.lined,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (Theme.of(context).platform == TargetPlatform.android)
                SafeArea(top: false, child: _androidDrawingToolbar()),
            ],
          ),
        ),
      );
}

class StrokePainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? active;
  final Color background;
  final PaperPattern pattern;
  final Set<int> selectedIndices;
  final double selectionScale;
  StrokePainter(
    this.strokes,
    this.active, {
    this.background = const Color(0xfffffdf7),
    this.pattern = PaperPattern.lined,
    this.selectedIndices = const {},
    this.selectionScale = 1,
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
        ..color =
            Color(s.color).withValues(alpha: s.highlight ? 0.32 : s.opacity)
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawPoints(
            ui.PointMode.points,
            [
              Offset(s.points.first.x, s.points.first.y),
            ],
            p);
        continue;
      }
      final path = Path()..moveTo(s.points.first.x, s.points.first.y);
      for (final pt in s.points.skip(1)) path.lineTo(pt.x, pt.y);
      canvas.drawPath(path, p);
    }
    final selectionBounds = strokeBoundsForSelection(strokes, selectedIndices);
    if (selectionBounds != null) {
      final padding = 8 / selectionScale;
      final selectionPaint = Paint()
        ..color = const Color(0xff3f51b5)
        ..strokeWidth = 2 / selectionScale
        ..style = PaintingStyle.stroke;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            selectionBounds.left - padding,
            selectionBounds.top - padding,
            selectionBounds.right + padding,
            selectionBounds.bottom + padding,
          ),
          Radius.circular(6 / selectionScale),
        ),
        selectionPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter old) => true;
}
