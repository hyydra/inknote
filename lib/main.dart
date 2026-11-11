import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'autosave_controller.dart';
import 'app_version.dart';
import 'canvas_editing.dart';
import 'canvas_painter.dart';
import 'note_data.dart';
import 'note_store.dart';
import 'rich_text_controller.dart';
import 'text_block_controller.dart';
import 'update_service.dart';

export 'app_version.dart' show appVersion;

abstract final class PenninoColors {
  static const leather = Color(0xff15191d);
  static const leatherRaised = Color(0xff20262b);
  static const leatherInset = Color(0xff0d1013);
  static const gold = Color(0xffd7a842);
  static const paleGold = Color(0xfff0d38a);
  static const steel = Color(0xffaeb5bc);
  static const ink = Color(0xfff5f0e5);
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
  late final TextBlockController textBlockController;
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
  final Map<int, Offset> canvasPointerPositions = {};
  int? drawingPointer;
  double canvasViewportHeight = 0;
  double canvasPageHeight = 1200;
  late final AutosaveController autosave;
  late final CanvasEditorController canvasEditor;
  final store = NoteStore(directoryProvider: _noteDirectory);

  List<RichTextEditingController> get textControllers =>
      textBlockController.controllers;
  List<FocusNode> get textFocusNodes => textBlockController.focusNodes;
  List<TextBlockFormat> get textFormats => textBlockController.formats;
  int get activeTextIndex => textBlockController.activeIndex;
  set activeTextIndex(int index) => textBlockController.activeIndex = index;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    canvasEditor = CanvasEditorController(widget.note);
    textBlockController = TextBlockController(
      onChanged: _markChanged,
      onFocusChanged: () {
        if (mounted) setState(() {});
      },
    );
    autosave = AutosaveController(
      onSave: _persist,
      onStatusChanged: (_) {
        if (mounted) setState(() {});
      },
    );
    titleController = TextEditingController(text: widget.note.title);
    titleController.addListener(_markChanged);
    taskController = TextEditingController();
    textBlockController.replace(
      widget.note.textBlocks,
      formats: widget.note.textBlockFormats,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    autosave.dispose();
    titleController.dispose();
    textBlockController.dispose();
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

  void addTextBlock() {
    setState(() {
      showText = true;
      tool = DrawTool.text;
      textBlockController.add();
    });
    _markChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || textFocusNodes.isEmpty) return;
      textFocusNodes.last.requestFocus();
    });
  }

  void removeTextBlock(int index) {
    setState(() {
      textBlockController.removeAt(index);
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

  void _selectTool(DrawTool nextTool) {
    if (nextTool != DrawTool.text) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() {
      tool = nextTool;
      if (tool == DrawTool.text) showText = true;
      if (tool != DrawTool.select) selectedStrokes.clear();
    });
  }

  void _growTextBlockToFit(int index) {
    if (index < 0 || index >= textControllers.length) return;
    final format = textFormats[index];
    final painter = TextPainter(
      text: textControllers[index].buildTextSpan(
        context: context,
        withComposing: false,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: math.max(1, format.width - 16));
    final requiredHeight = math.max(90.0, painter.height + 48);
    if (requiredHeight <= format.height) return;
    setState(() => format.height = requiredHeight);
    _markChanged();
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

  CanvasPoint _scenePoint(PointerEvent event) {
    final viewportPoint = event.localPosition;
    final scenePoint = canvasTransform.sceneFromViewport(
      CanvasPoint(viewportPoint.dx, viewportPoint.dy),
    );
    final hasPressureRange = event.pressureMax - event.pressureMin > 0.0001;
    return CanvasPoint(
      scenePoint.x,
      scenePoint.y,
      pressure: hasPressureRange ? event.pressure : 1,
      pressureMin: hasPressureRange ? event.pressureMin : 0,
      pressureMax: hasPressureRange ? event.pressureMax : 1,
      tilt: event.tilt,
      orientation: event.orientation,
    );
  }

  void begin(PointerDownEvent event) {
    if (tool == DrawTool.hand || tool == DrawTool.text) return;
    final viewportPoint = event.localPosition;
    gestureHistoryRecorded = false;
    if (tool == DrawTool.select) {
      final selected = canvasEditor.hitTest(
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
    final scenePoint = _scenePoint(event);
    canvasEditor.recordHistory();
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
        pressureSensitive: tool == DrawTool.pen || tool == DrawTool.pencil,
      );
    });
  }

  void move(PointerMoveEvent event) {
    if (tool == DrawTool.hand || tool == DrawTool.text) return;
    final viewportPoint = event.localPosition;
    if (tool == DrawTool.select) {
      final previous = lastSelectionViewportPoint;
      if (previous == null || selectedStrokes.isEmpty) return;
      if (!gestureHistoryRecorded) {
        canvasEditor.recordHistory();
        gestureHistoryRecorded = true;
      }
      final moved = canvasEditor.translateSelection(
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
    final scenePoint = _scenePoint(event);
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

  void _canvasPointerDown(PointerDownEvent event) {
    canvasPointerPositions[event.pointer] = event.localPosition;
    if (canvasPointerPositions.length == 1) {
      drawingPointer = event.pointer;
      begin(event);
      return;
    }
    drawingPointer = null;
    if (active != null) {
      setState(() {
        active = null;
        gestureHistoryRecorded = false;
      });
    }
  }

  void _canvasPointerMove(PointerMoveEvent event) {
    final previousPositions = Map<int, Offset>.from(canvasPointerPositions);
    if (!canvasPointerPositions.containsKey(event.pointer)) return;
    canvasPointerPositions[event.pointer] = event.localPosition;
    if (canvasPointerPositions.length >= 2) {
      final pointers = canvasPointerPositions.keys.take(2).toList();
      final first = pointers[0];
      final second = pointers[1];
      final previousFirst = previousPositions[first];
      final previousSecond = previousPositions[second];
      if (previousFirst == null || previousSecond == null) return;
      final currentFirst = canvasPointerPositions[first]!;
      final currentSecond = canvasPointerPositions[second]!;
      final previousCenter = (previousFirst + previousSecond) / 2;
      final currentCenter = (currentFirst + currentSecond) / 2;
      final previousDistance = (previousFirst - previousSecond).distance;
      final currentDistance = (currentFirst - currentSecond).distance;
      final transform = canvasTransform;
      final nextScale = previousDistance < 0.001
          ? transform.scale
          : (transform.scale * currentDistance / previousDistance)
              .clamp(0.25, 5.0);
      final sceneX =
          (previousCenter.dx - transform.translationX) / transform.scale;
      final sceneY =
          (previousCenter.dy - transform.translationY) / transform.scale;
      final next = Matrix4.identity();
      next[0] = nextScale;
      next[5] = nextScale;
      next[12] = currentCenter.dx - sceneX * nextScale;
      next[13] = currentCenter.dy - sceneY * nextScale;
      transformationController.value = next;
      _refreshCanvasViewport();
      return;
    }
    if (drawingPointer == event.pointer) move(event);
  }

  void _canvasPointerEnd(PointerEvent event) {
    if (drawingPointer == event.pointer && canvasPointerPositions.length == 1) {
      end();
    }
    canvasPointerPositions.remove(event.pointer);
    if (canvasPointerPositions.isEmpty) drawingPointer = null;
  }

  void _canvasPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final next = transformationController.value.clone();
    next[12] -= event.scrollDelta.dx;
    next[13] -= event.scrollDelta.dy;
    transformationController.value = next;
    _refreshCanvasViewport();
  }

  void _refreshCanvasViewport() {
    var appendedPage = false;
    final transform = canvasTransform;
    if (canvasViewportHeight > 0 && canvasPageHeight > 0) {
      final visibleBottom =
          (canvasViewportHeight - transform.translationY) / transform.scale;
      while (visibleBottom >= widget.note.pageCount * canvasPageHeight - 180) {
        widget.note.pageCount += 1;
        appendedPage = true;
      }
    }
    setState(() {});
    if (appendedPage) _markChanged();
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
    final index = canvasEditor.hitTest(
      CanvasPoint(viewportPoint.dx, viewportPoint.dy),
      canvasTransform,
    );
    if (index == null) return;
    if (!gestureHistoryRecorded) {
      canvasEditor.recordHistory();
      gestureHistoryRecorded = true;
    }
    setState(() {
      canvasEditor.removeStrokeAt(index);
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
            widget.note.pageCount = syncedCurrent.pageCount;
            selectedStrokes.clear();
            lastSelectionViewportPoint = null;
            selectionMoved = false;
            gestureHistoryRecorded = false;
            canvasEditor.clearHistory();
            titleController.text = syncedCurrent.title;
            textBlockController.replace(
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
                  onPressed: () => _selectTool(entry.$1),
                  icon: Icon(entry.$2),
                ),
              ),
            Expanded(
              child: PopupMenuButton<Color>(
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
              onPressed: () => _selectTool(DrawTool.pen),
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
            onChanged: (_) => _growTextBlockToFit(index),
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
          if (selected)
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
          if (selected)
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
                onPointerUp: (_) {
                  _growTextBlockToFit(index);
                  _markChanged();
                },
                onPointerCancel: (_) {
                  _growTextBlockToFit(index);
                  _markChanged();
                },
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

  Widget _blurStrokeLayer(Stroke stroke, {Key? key}) {
    const passes = <(double, double, double)>[
      (1.25, 3, 0.18),
      (1.05, 6, 0.28),
      (0.85, 9, 0.42),
      (0.65, 12, 0.70),
    ];
    return Positioned.fill(
      key: key,
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final pass in passes)
              Opacity(
                opacity: pass.$3,
                child: ClipPath(
                  clipBehavior: Clip.antiAlias,
                  clipper: BlurStrokeClipper(
                    stroke,
                    widthScale: pass.$1,
                  ),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: pass.$2,
                      sigmaY: pass.$2,
                    ),
                    child: const ColoredBox(color: Color(0x01ffffff)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showOpenSourceNotice() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Open-source software'),
        content: const SingleChildScrollView(
          child: SelectableText(
            'Pennino uses Flutter and these direct open-source packages:\n\n'
            'draw_your_image\n'
            'github.com/chooyan-eng/draw_your_image\n\n'
            'file_selector, path_provider and uuid\n\n'
            'Repository links and licences are also listed in the README.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              showLicensePage(
                context: context,
                applicationName: 'Pennino',
                applicationVersion: appVersion,
              );
            },
            child: const Text('Licences'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
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
                onPressed: !canvasEditor.canUndo
                    ? null
                    : () {
                        if (!canvasEditor.undo()) return;
                        setState(selectedStrokes.clear);
                        _markChanged();
                      },
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Redo',
                onPressed: !canvasEditor.canRedo
                    ? null
                    : () {
                        if (!canvasEditor.redo()) return;
                        setState(selectedStrokes.clear);
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
                    case 'open-source':
                      _showOpenSourceNotice();
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
                  const PopupMenuItem(
                    value: 'open-source',
                    child: ListTile(
                      leading: Icon(Icons.code),
                      title: Text('Open-source software'),
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
                            onSelected: (_) => _selectTool(entry.$1),
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
                    canvasViewportHeight = constraints.maxHeight;
                    canvasPageHeight =
                        math.max(1200.0, constraints.maxHeight * 1.5);
                    final canvasHeight =
                        canvasPageHeight * widget.note.pageCount;
                    return ClipRect(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _canvasPointerDown,
                        onPointerMove: _canvasPointerMove,
                        onPointerUp: _canvasPointerEnd,
                        onPointerCancel: _canvasPointerEnd,
                        onPointerSignal: _canvasPointerSignal,
                        child: InteractiveViewer(
                          transformationController: transformationController,
                          alignment: Alignment.topLeft,
                          constrained: false,
                          panEnabled: false,
                          scaleEnabled: false,
                          boundaryMargin: const EdgeInsets.all(500),
                          minScale: 0.25,
                          maxScale: 5,
                          child: SizedBox(
                            width: canvasWidth,
                            height: canvasHeight,
                            child: Stack(
                              key: const Key('canvas-layer-stack'),
                              clipBehavior: Clip.none,
                              children: [
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: tool == DrawTool.text
                                        ? () => FocusManager
                                            .instance.primaryFocus
                                            ?.unfocus()
                                        : null,
                                    child: CustomPaint(
                                      painter: StrokePainter(
                                        const [],
                                        null,
                                        background: Color(
                                          widget.note.backgroundColor,
                                        ),
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
                                if (showText)
                                  for (var index = 0;
                                      index < textControllers.length;
                                      index++)
                                    _canvasTextBlock(index),
                                for (var index = 0;
                                    index < widget.note.strokes.length;
                                    index++)
                                  if (widget.note.strokes[index].blur)
                                    _blurStrokeLayer(
                                      widget.note.strokes[index],
                                      key: ValueKey('blur-layer-$index'),
                                    )
                                  else
                                    Positioned.fill(
                                      key: ValueKey('stroke-layer-$index'),
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          painter: StrokePainter(
                                            [widget.note.strokes[index]],
                                            null,
                                            paintBackground: false,
                                          ),
                                        ),
                                      ),
                                    ),
                                if (active != null && active!.blur)
                                  _blurStrokeLayer(
                                    active!,
                                    key: const Key('active-blur-layer'),
                                  )
                                else if (active != null)
                                  Positioned.fill(
                                    key: const Key('active-stroke-layer'),
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: StrokePainter(
                                          [active!],
                                          null,
                                          paintBackground: false,
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: StrokePainter(
                                        widget.note.strokes,
                                        null,
                                        paintBackground: false,
                                        paintStrokes: false,
                                        selectedIndices: selectedStrokes,
                                        selectionScale: canvasTransform.scale,
                                      ),
                                    ),
                                  ),
                                ),
                                if (widget.note.pageCount > 1)
                                  for (var page = 1;
                                      page < widget.note.pageCount;
                                      page++) ...[
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      top: canvasPageHeight * page - 7,
                                      height: 14,
                                      child: const IgnorePointer(
                                        child: ColoredBox(
                                          color: Color(0xff34393d),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      right: 18,
                                      top: canvasPageHeight * page - 34,
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: PenninoColors.leatherInset,
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(5),
                                            ),
                                            border: Border.fromBorderSide(
                                              BorderSide(
                                                color: PenninoColors.gold,
                                              ),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            child: Text(
                                              '$page/${widget.note.pageCount}',
                                              style: const TextStyle(
                                                color: PenninoColors.paleGold,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
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
