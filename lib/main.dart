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
import 'rich_text_controller.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.4.6');

abstract final class PenninoColors {
  static const leather = Color(0xff15191d);
  static const leatherRaised = Color(0xff20262b);
  static const leatherInset = Color(0xff0d1013);
  static const gold = Color(0xffd7a842);
  static const paleGold = Color(0xfff0d38a);
  static const steel = Color(0xffaeb5bc);
  static const ink = Color(0xfff5f0e5);
}

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String fileName;
  const UpdateInfo(this.version, this.downloadUrl, this.fileName);
}

class UpdateService {
  static const _channel = MethodChannel('notes/update');
  static bool _checked = false;

  static Map<String, dynamic>? selectAsset(
    List<Map<String, dynamic>> assets, {
    required bool windows,
  }) {
    final expectedName =
        windows ? 'Pennino-Windows-Setup.exe' : 'Pennino-Android.apk';
    for (final asset in assets) {
      if ((asset['name'] as String? ?? '').toLowerCase() ==
          expectedName.toLowerCase()) {
        return asset;
      }
    }
    return null;
  }

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
      final assets =
          (release['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
      final selected = selectAsset(assets, windows: Platform.isWindows);
      if (selected == null) return null;
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
    UpdateInfo? update;
    try {
      update = await check();
    } catch (error) {
      if (!automatic && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update check failed: $error')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final availableUpdate = update;
    if (availableUpdate == null) {
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
                  'Version ${availableUpdate.version} is available. Download and install it now?'),
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
      final request =
          await client.getUrl(Uri.parse(availableUpdate.downloadUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download failed (${response.statusCode})');
      }
      final file = File(
          '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}${availableUpdate.fileName}');
      final sink = file.openWrite();
      await response.pipe(sink);
      if (Platform.isAndroid) {
        await _channel.invokeMethod('install', {'path': file.path});
      } else {
        await Process.start(file.path, const [],
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
          brightness: Brightness.dark,
          colorScheme: const ColorScheme.dark(
            primary: PenninoColors.gold,
            onPrimary: PenninoColors.leatherInset,
            primaryContainer: Color(0xff5b461c),
            onPrimaryContainer: PenninoColors.paleGold,
            secondary: PenninoColors.steel,
            onSecondary: PenninoColors.leatherInset,
            surface: PenninoColors.leather,
            onSurface: PenninoColors.ink,
            surfaceContainerLowest: PenninoColors.leatherInset,
            surfaceContainerLow: Color(0xff191e22),
            surfaceContainer: PenninoColors.leatherRaised,
            surfaceContainerHigh: Color(0xff2a3035),
            outline: Color(0xff6d675d),
            outlineVariant: Color(0xff3f4346),
          ),
          scaffoldBackgroundColor: PenninoColors.leather,
          dividerColor: const Color(0xff4a443b),
          appBarTheme: const AppBarTheme(
            backgroundColor: PenninoColors.leatherRaised,
            foregroundColor: PenninoColors.paleGold,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.black,
            elevation: 5,
            titleTextStyle: TextStyle(
              color: PenninoColors.ink,
              fontSize: 21,
              fontWeight: FontWeight.w600,
              letterSpacing: .2,
            ),
          ),
          cardTheme: CardThemeData(
            color: PenninoColors.leatherRaised,
            surfaceTintColor: Colors.transparent,
            elevation: 3,
            shadowColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xff4b4740)),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: PenninoColors.leatherRaised,
            selectedColor: const Color(0xff5b461c),
            checkmarkColor: PenninoColors.paleGold,
            side: const BorderSide(color: Color(0xff575149)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            labelStyle: const TextStyle(color: PenninoColors.ink),
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: PenninoColors.gold,
            foregroundColor: PenninoColors.leatherInset,
            elevation: 6,
          ),
          popupMenuTheme: PopupMenuThemeData(
            color: PenninoColors.leatherRaised,
            surfaceTintColor: Colors.transparent,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xff5a544b)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: PenninoColors.leatherInset,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: Color(0xff5a544b)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(
                color: PenninoColors.gold,
                width: 1.4,
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: PenninoColors.paleGold,
            ),
          ),
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

enum DrawTool {
  hand,
  text,
  select,
  pencil,
  pen,
  highlighter,
  eraser,
  blur,
}

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
  final List<RichTextEditingController> textControllers = [];
  final List<FocusNode> textFocusNodes = [];
  final List<TextBlockFormat> textFormats = [];
  int activeTextIndex = 0;
  late final TextEditingController taskController;
  final TransformationController transformationController =
      TransformationController();
  DrawTool tool = DrawTool.pen;
  Color strokeColor = Colors.blue.shade800;
  Color highlighterColor = Colors.yellow;
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
    for (final focusNode in textFocusNodes) {
      focusNode.dispose();
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

  RichTextEditingController _textController(
    String text,
    List<TextStyleRange> styles,
  ) {
    final controller = RichTextEditingController(text: text, styles: styles);
    controller.addListener(_markChanged);
    return controller;
  }

  FocusNode _textFocusNode() {
    final node = FocusNode();
    node.addListener(() {
      if (mounted) setState(() {});
    });
    return node;
  }

  void _replaceTextControllers(
    Iterable<String> blocks, {
    Iterable<TextBlockFormat>? formats,
  }) {
    for (final controller in textControllers) {
      controller.dispose();
    }
    for (final focusNode in textFocusNodes) {
      focusNode.dispose();
    }
    final savedBlocks = blocks.toList();
    final savedFormats = formats?.toList() ?? const <TextBlockFormat>[];
    textFormats
      ..clear()
      ..addAll(List.generate(
        savedBlocks.length,
        (index) => index < savedFormats.length
            ? TextBlockFormat(
                bold: savedFormats[index].bold,
                color: savedFormats[index].color,
                fontSize: savedFormats[index].fontSize,
                x: savedFormats[index].x,
                y: savedFormats[index].y,
                width: savedFormats[index].width,
                height: savedFormats[index].height,
                styles: savedFormats[index]
                    .styles
                    .map((style) => TextStyleRange(
                          start: style.start,
                          end: style.end,
                          bold: style.bold,
                          color: style.color,
                          fontSize: style.fontSize,
                        ))
                    .toList(),
              )
            : TextBlockFormat(y: 48 + index * 184),
      ));
    textControllers
      ..clear()
      ..addAll(List.generate(
        savedBlocks.length,
        (index) =>
            _textController(savedBlocks[index], textFormats[index].styles),
      ));
    textFocusNodes
      ..clear()
      ..addAll(List.generate(textControllers.length, (_) => _textFocusNode()));
    activeTextIndex = textControllers.isEmpty
        ? 0
        : activeTextIndex.clamp(0, textControllers.length - 1);
  }

  void addTextBlock() {
    setState(() {
      showText = true;
      tool = DrawTool.text;
      final format = TextBlockFormat(
        x: 48 + (textControllers.length % 3) * 24,
        y: 48 + textControllers.length * 184,
      );
      textFormats.add(format);
      textControllers.add(_textController('', format.styles));
      textFocusNodes.add(_textFocusNode());
      activeTextIndex = textControllers.length - 1;
    });
    _markChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || textFocusNodes.isEmpty) return;
      textFocusNodes.last.requestFocus();
    });
  }

  void removeTextBlock(int index) {
    setState(() {
      textControllers.removeAt(index).dispose();
      textFocusNodes.removeAt(index).dispose();
      textFormats.removeAt(index);
      activeTextIndex = textControllers.isEmpty
          ? 0
          : activeTextIndex.clamp(0, textControllers.length - 1);
    });
    _markChanged();
  }

  RichTextEditingController? get _activeTextController => textControllers
          .isEmpty
      ? null
      : textControllers[activeTextIndex.clamp(0, textControllers.length - 1)];

  Color get _activeStrokeColor =>
      tool == DrawTool.highlighter ? highlighterColor : strokeColor;

  void _setActiveStrokeColor(Color color) {
    setState(() {
      if (tool == DrawTool.highlighter) {
        highlighterColor = color;
      } else {
        strokeColor = color;
      }
    });
  }

  void _setTextFontSize(double size) {
    final controller = _activeTextController;
    if (controller == null) return;
    final selection = controller.selection;
    setState(() {
      if (selection.isValid && !selection.isCollapsed) {
        controller.applyStyle(selection, fontSize: size);
      } else {
        textFormats[activeTextIndex].fontSize = size;
      }
    });
    _markChanged();
  }

  void _toggleTextBold() {
    final controller = _activeTextController;
    if (controller == null) return;
    final format = textFormats[activeTextIndex];
    final selection = controller.selection;
    setState(() {
      if (selection.isValid && !selection.isCollapsed) {
        final current = controller.selectedBold(selection) ?? format.bold;
        controller.applyStyle(selection, bold: !current);
      } else {
        format.bold = !format.bold;
      }
    });
    _markChanged();
  }

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
    const knownPrefixes = ['☐ ', '☑ ', '• ', '1. '];
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

  void _toggleChecklistAtSelection(int index) {
    if (index < 0 || index >= textControllers.length) return;
    final controller = textControllers[index];
    final value = controller.value;
    if (!value.selection.isValid) return;
    final cursor = value.selection.extentOffset;
    final lineStart = value.text.lastIndexOf('\n', math.max(0, cursor - 1)) + 1;
    if (cursor < lineStart || cursor > lineStart + 2) return;
    final lineEndMatch = value.text.indexOf('\n', cursor);
    final lineEnd = lineEndMatch == -1 ? value.text.length : lineEndMatch;
    final line = value.text.substring(lineStart, lineEnd);
    final replacement = line.startsWith('☐ ')
        ? '☑ '
        : line.startsWith('☑ ')
            ? '☐ '
            : null;
    if (replacement == null) return;
    controller.value = value.copyWith(
      text: value.text.replaceRange(lineStart, lineStart + 2, replacement),
      selection: TextSelection.collapsed(offset: cursor),
      composing: TextRange.empty,
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

  static const _paletteColors = <Color>[
    Colors.black,
    Colors.white,
    Colors.yellow,
    Colors.red,
    Colors.orange,
    Colors.green,
    Colors.blue,
    Colors.purple,
  ];

  String _colorName(Color color) => switch (color.toARGB32()) {
        0xff000000 => 'Black',
        0xffffffff => 'White',
        0xffffff00 => 'Yellow',
        0xfff44336 => 'Red',
        0xffff9800 => 'Orange',
        0xff4caf50 => 'Green',
        0xff2196f3 => 'Blue',
        0xff9c27b0 => 'Purple',
        _ => 'Colour',
      };

  List<PopupMenuEntry<Color>> _colorMenuItems(Color selected) => [
        for (final color in _paletteColors)
          PopupMenuItem(
            value: color,
            child: Row(
              children: [
                Icon(
                  color == selected ? Icons.check_circle : Icons.circle,
                  color: color,
                ),
                const SizedBox(width: 12),
                Text(_colorName(color)),
              ],
            ),
          ),
      ];

  void _setTextColor(Color selected) {
    if (textControllers.isEmpty) return;
    final controller = _activeTextController;
    if (controller == null) return;
    final selection = controller.selection;
    setState(() {
      if (selection.isValid && !selection.isCollapsed) {
        controller.applyStyle(selection, color: selected.toARGB32());
      } else {
        textFormats[activeTextIndex].color = selected.toARGB32();
      }
    });
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
        color: _activeStrokeColor.toARGB32(),
        width: tool == DrawTool.highlighter
            ? 22
            : tool == DrawTool.blur
                ? 44
                : tool == DrawTool.pencil
                    ? 2
                    : width,
        highlight: tool == DrawTool.highlighter,
        blur: tool == DrawTool.blur,
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
        .map((format) => TextBlockFormat(
              bold: format.bold,
              color: format.color,
              fontSize: format.fontSize,
              x: format.x,
              y: format.y,
              width: format.width,
              height: format.height,
              styles: format.styles
                  .map((style) => TextStyleRange(
                        start: style.start,
                        end: style.end,
                        bold: style.bold,
                        color: style.color,
                        fontSize: style.fontSize,
                      ))
                  .toList(),
            ))
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
        var hasFolder = false;
        if (!chooseFolder) {
          hasFolder =
              await syncChannel.invokeMethod<bool>('hasFolder') ?? false;
        }
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
                      fontSize: format.fontSize,
                      x: format.x,
                      y: format.y,
                      width: format.width,
                      height: format.height,
                      styles: format.styles
                          .map((style) => TextStyleRange(
                                start: style.start,
                                end: style.end,
                                bold: style.bold,
                                color: style.color,
                                fontSize: style.fontSize,
                              ))
                          .toList(),
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
    } on PlatformException catch (error) {
      if (mounted) {
        final message = error.message?.trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message == null || message.isEmpty
                  ? 'Drive folder access failed'
                  : message,
            ),
            action: Platform.isAndroid
                ? SnackBarAction(
                    label: 'Choose folder',
                    onPressed: () => syncDrive(chooseFolder: true),
                  )
                : null,
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

  Widget _androidDrawingToolbar() {
    final tools = [
      (DrawTool.hand, Icons.pan_tool_outlined, 'Hand'),
      (DrawTool.text, Icons.text_fields, 'Text'),
      (DrawTool.select, Icons.select_all, 'Select'),
      (DrawTool.pencil, Icons.create_outlined, 'Pencil'),
      (DrawTool.pen, Icons.edit, 'Pen'),
      (DrawTool.highlighter, Icons.border_color, 'Highlighter'),
      (DrawTool.eraser, Icons.auto_fix_normal, 'Eraser'),
      (DrawTool.blur, Icons.blur_on, 'Blur'),
    ];
    return SizedBox(
      key: const Key('android-drawing-toolbar'),
      height: 64,
      child: Material(
        elevation: 6,
        child: Row(
          children: [
            for (final entry in tools)
              Expanded(
                child: IconButton(
                  tooltip: entry.$3,
                  style: IconButton.styleFrom(
                    backgroundColor: tool == entry.$1
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                  ),
                  onPressed: () => setState(() {
                    tool = entry.$1;
                    if (tool == DrawTool.text) showText = true;
                    if (tool != DrawTool.select) selectedStrokes.clear();
                  }),
                  icon: Icon(entry.$2),
                ),
              ),
            Expanded(
              child: selectedStrokes.isNotEmpty
                  ? IconButton(
                      tooltip: 'Delete selection',
                      onPressed: deleteSelection,
                      icon: const Icon(Icons.delete_outline),
                    )
                  : PopupMenuButton<Color>(
                      tooltip: 'Drawing colour',
                      icon: Icon(Icons.circle, color: _activeStrokeColor),
                      onSelected: _setActiveStrokeColor,
                      itemBuilder: (_) => _colorMenuItems(_activeStrokeColor),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textToolbar() {
    final canFormat = textControllers.isNotEmpty;
    final format = canFormat ? textFormats[activeTextIndex] : null;
    Widget slot(Widget child) => Expanded(child: Center(child: child));
    return SizedBox(
      key: const Key('text-toolbar'),
      height: 60,
      child: Material(
        elevation: 6,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Row(
          children: [
            slot(IconButton(
              tooltip: 'Drawing tools',
              onPressed: () => setState(() => tool = DrawTool.pen),
              icon: const Icon(Icons.gesture),
            )),
            slot(IconButton(
              tooltip: 'Add text block',
              onPressed: addTextBlock,
              icon: const Icon(Icons.add_box_outlined),
            )),
            slot(PopupMenuButton<String>(
              tooltip: 'Lists',
              enabled: canFormat,
              icon: const Icon(Icons.check_box_outlined),
              onSelected: (value) {
                if (value == 'check') _toggleLinePrefix('☐ ');
                if (value == 'number') _toggleLinePrefix('1. ');
                if (value == 'bullet') _toggleLinePrefix('• ');
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'check', child: Text('Checklist')),
                PopupMenuItem(value: 'number', child: Text('Numbered list')),
                PopupMenuItem(value: 'bullet', child: Text('Bulleted list')),
              ],
            )),
            slot(PopupMenuButton<Color>(
              tooltip: 'Text colour',
              enabled: canFormat,
              onSelected: _setTextColor,
              icon: Icon(
                Icons.format_color_text,
                color: format == null ? null : Color(format.color),
              ),
              itemBuilder: (_) => _colorMenuItems(
                format == null ? Colors.black : Color(format.color),
              ),
            )),
            slot(PopupMenuButton<double>(
              tooltip: 'Font size',
              enabled: canFormat,
              icon: Text(
                format == null ? 'Aa' : '${format.fontSize.round()}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              onSelected: _setTextFontSize,
              itemBuilder: (_) => [
                for (final size in const [14.0, 18.0, 20.0, 24.0, 30.0, 36.0])
                  PopupMenuItem(value: size, child: Text('${size.round()}')),
              ],
            )),
            slot(IconButton(
              tooltip: 'Bold',
              isSelected: format?.bold ?? false,
              onPressed: canFormat ? _toggleTextBold : null,
              icon: const Icon(Icons.format_bold),
            )),
            slot(PopupMenuButton<bool>(
              tooltip: 'Indent',
              enabled: canFormat,
              icon: const Icon(Icons.format_indent_increase),
              onSelected: _changeIndent,
              itemBuilder: (_) => const [
                PopupMenuItem(value: false, child: Text('Decrease indent')),
                PopupMenuItem(value: true, child: Text('Increase indent')),
              ],
            )),
          ],
        ),
      ),
    );
  }

  Widget _canvasTextBlock(int index) {
    final format = textFormats[index];
    return Positioned(
      key: ValueKey('canvas-text-block-$index'),
      left: format.x,
      top: format.y,
      width: format.width,
      height: format.height,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() {
          activeTextIndex = index;
          tool = DrawTool.text;
        }),
        child: Padding(
          padding: const EdgeInsets.only(top: 28),
          child: TextField(
            key: ValueKey('canvas-text-field-$index'),
            controller: textControllers[index],
            focusNode: textFocusNodes[index],
            onTap: () {
              setState(() {
                activeTextIndex = index;
                tool = DrawTool.text;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _toggleChecklistAtSelection(index);
              });
            },
            expands: true,
            minLines: null,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(
              color: Color(format.color),
              fontSize: format.fontSize,
              fontWeight: format.bold ? FontWeight.bold : FontWeight.normal,
            ),
            decoration: InputDecoration(
              hintText: 'Text block ${index + 1}',
              filled: false,
              fillColor: Colors.transparent,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _canvasTextBlockControls(int index) {
    final format = textFormats[index];
    final selected = activeTextIndex == index && textFocusNodes[index].hasFocus;
    final scale = math.max(0.001, canvasTransform.scale);
    return Positioned(
      key: ValueKey('canvas-text-block-controls-$index'),
      left: format.x,
      top: format.y,
      width: format.width,
      height: format.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  border: selected
                      ? Border.all(color: Theme.of(context).colorScheme.primary)
                      : null,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 56,
            top: 0,
            height: 28,
            child: Listener(
              key: ValueKey('move-text-block-$index'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => setState(() {
                activeTextIndex = index;
                tool = DrawTool.text;
              }),
              onPointerMove: (event) => setState(() {
                format.x = math.max(0, format.x + event.delta.dx / scale);
                format.y = math.max(0, format.y + event.delta.dy / scale);
              }),
              onPointerUp: (_) => _markChanged(),
              onPointerCancel: (_) => _markChanged(),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: PenninoColors.leatherRaised,
                      borderRadius: BorderRadius.all(Radius.circular(5)),
                      border: Border.fromBorderSide(
                        BorderSide(color: PenninoColors.gold),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black38,
                          blurRadius: 3,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                    child: SizedBox(
                      width: 28,
                      height: 24,
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: PenninoColors.paleGold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (selected)
            Positioned(
              right: 24,
              top: 0,
              width: 28,
              height: 28,
              child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: 'Delete text block',
                onPressed: () => removeTextBlock(index),
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            width: 32,
            height: 32,
            child: Listener(
              key: ValueKey('resize-text-block-$index'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => setState(() {
                activeTextIndex = index;
                tool = DrawTool.text;
              }),
              onPointerMove: (event) => setState(() {
                format.width = math.max(
                  140,
                  format.width + event.delta.dx / scale,
                );
                format.height = math.max(
                  90,
                  format.height + event.delta.dy / scale,
                );
              }),
              onPointerUp: (_) => _markChanged(),
              onPointerCancel: (_) => _markChanged(),
              child: const Align(
                alignment: Alignment.bottomRight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: PenninoColors.leatherRaised,
                    borderRadius: BorderRadius.all(Radius.circular(5)),
                    border: Border.fromBorderSide(
                      BorderSide(color: PenninoColors.gold),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(
                      Icons.open_in_full,
                      size: 16,
                      color: PenninoColors.paleGold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
                  if (Platform.isAndroid || Platform.isWindows)
                    PopupMenuItem(
                      value: 'sync-folder',
                      child: ListTile(
                        leading: const Icon(Icons.folder_open_outlined),
                        title: Text(Platform.isAndroid
                            ? 'Choose Google Drive folder'
                            : 'Choose Drive folder'),
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
                        (DrawTool.text, Icons.text_fields, 'Text'),
                        (DrawTool.select, Icons.select_all, 'Select'),
                        (DrawTool.pencil, Icons.create_outlined, 'Pencil'),
                        (DrawTool.pen, Icons.edit, 'Pen'),
                        (
                          DrawTool.highlighter,
                          Icons.border_color,
                          'Highlighter'
                        ),
                        (DrawTool.eraser, Icons.auto_fix_normal, 'Eraser'),
                        (DrawTool.blur, Icons.blur_on, 'Blur'),
                      ])
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ChoiceChip(
                            label: Text(entry.$3),
                            avatar: Icon(entry.$2, size: 18),
                            selected: tool == entry.$1,
                            onSelected: (_) => setState(() {
                              tool = entry.$1;
                              if (tool == DrawTool.text) showText = true;
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
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: PopupMenuButton<Color>(
                          tooltip: 'Drawing colour',
                          onSelected: _setActiveStrokeColor,
                          itemBuilder: (_) =>
                              _colorMenuItems(_activeStrokeColor),
                          child: Chip(
                            avatar: Icon(
                              Icons.circle,
                              color: _activeStrokeColor,
                            ),
                            label: const Text('Colour'),
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
                    final isHandTool =
                        tool == DrawTool.hand || tool == DrawTool.text;
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
                            panEnabled: tool == DrawTool.hand,
                            scaleEnabled: tool == DrawTool.hand,
                            boundaryMargin: const EdgeInsets.all(500),
                            minScale: 0.25,
                            maxScale: 5,
                            child: SizedBox(
                              width: canvasWidth,
                              height: canvasHeight,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
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
                                  if (showText)
                                    for (var index = 0;
                                        index < textControllers.length;
                                        index++)
                                      _canvasTextBlock(index),
                                  for (final blurStroke in [
                                    ...widget.note.strokes
                                        .where((stroke) => stroke.blur),
                                    if (active?.blur ?? false) active!,
                                  ])
                                    Positioned.fill(
                                      child: ClipPath(
                                        clipper: BlurStrokeClipper(blurStroke),
                                        child: BackdropFilter(
                                          filter: ui.ImageFilter.blur(
                                            sigmaX: 12,
                                            sigmaY: 12,
                                          ),
                                          child: ColoredBox(
                                            color: Color(0x01ffffff),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (showText)
                                    for (var index = 0;
                                        index < textControllers.length;
                                        index++)
                                      _canvasTextBlockControls(index),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (tool == DrawTool.text)
                SafeArea(top: false, child: _textToolbar())
              else if (Theme.of(context).platform == TargetPlatform.android)
                SafeArea(
                  top: false,
                  child: _androidDrawingToolbar(),
                ),
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
      if (s.points.isEmpty || s.blur) continue;
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

class BlurStrokeClipper extends CustomClipper<Path> {
  final Stroke stroke;

  const BlurStrokeClipper(this.stroke);

  @override
  Path getClip(Size size) {
    final path = Path();
    if (stroke.points.isEmpty) return path;
    final radius = stroke.width / 2;
    void addBrush(CanvasPoint point) {
      path.addOval(Rect.fromCircle(
        center: Offset(point.x, point.y),
        radius: radius,
      ));
    }

    addBrush(stroke.points.first);
    for (var index = 1; index < stroke.points.length; index++) {
      final from = stroke.points[index - 1];
      final to = stroke.points[index];
      final dx = to.x - from.x;
      final dy = to.y - from.y;
      final distance = math.sqrt(dx * dx + dy * dy);
      final steps = math.max(1, (distance / math.max(2, radius / 2)).ceil());
      for (var step = 1; step <= steps; step++) {
        final amount = step / steps;
        addBrush(CanvasPoint(
          from.x + dx * amount,
          from.y + dy * amount,
        ));
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant BlurStrokeClipper oldClipper) => true;
}
