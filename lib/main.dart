import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'app_version.dart';
import 'autosave_controller.dart';
import 'canvas_editing.dart';
import 'canvas_painter.dart';
import 'drive_sync_service.dart';
import 'note_data.dart';
import 'note_storage.dart';
import 'note_store.dart';
import 'pennino_theme.dart';
import 'raster_drawing.dart';
import 'rich_text_controller.dart';
import 'update_service.dart';

export 'app_version.dart' show appVersion;

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
        theme: buildPenninoTheme(),
        home: const LauncherCanvasPage(),
      );
}

class LauncherCanvasPage extends StatefulWidget {
  const LauncherCanvasPage({super.key, this.directoryProvider});

  /// Overridable so a test can make the note folder unreachable. Production
  /// always uses [noteDirectory].
  final NoteDirectoryProvider? directoryProvider;

  @override
  State<LauncherCanvasPage> createState() => _LauncherCanvasPageState();
}

class _LauncherCanvasPageState extends State<LauncherCanvasPage> {
  static const launcherNoteId = 'launcher-canvas';
  late final NoteStore store = NoteStore(
    directoryProvider: widget.directoryProvider ?? noteDirectory,
  );
  Note? note;

  /// Set when the stored note could not be read, so the app offers a retry
  /// instead of spinning at a blank screen forever.
  String? loadFailure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(UpdateService.prompt(context, automatic: true));
    });
  }

  Future<void> _load() async {
    try {
      final loaded = await store.loadNote(launcherNoteId) ??
          Note(
            id: launcherNoteId,
            title: 'Launcher note',
            text: '',
            updated: DateTime.now().toUtc(),
            strokes: [],
          );
      if (!mounted) return;
      setState(() {
        note = loaded;
        loadFailure = null;
      });
    } catch (error) {
      // Reading the folder can fail for a reason the user can fix — a Drive
      // folder that moved, a full disk, a permission revocation — and a
      // spinner says nothing about any of them.
      if (!mounted) return;
      setState(() => loadFailure = '$error');
    }
  }

  Future<void> _retryLoad() async {
    // Clearing the message first shows the spinner again: a retry that leaves
    // the old error on screen looks like a retry that did nothing.
    setState(() => loadFailure = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loaded = note;
    if (loaded == null) {
      final failure = loadFailure;
      if (failure != null) {
        return Scaffold(
          body: NoteLoadFailure(
            message: failure,
            onRetry: () => unawaited(_retryLoad()),
          ),
        );
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return EditorPage(note: loaded, launcherMode: true);
  }
}

/// Shown in place of the note list or the editor when the note folder could
/// not be read. A retry is part of the widget because the causes are usually
/// transient or user-fixable — a mounted folder that was briefly away, a full
/// disk, a revoked permission — and leaving no way back means restarting the
/// app is the only option the screen offers.
class NoteLoadFailure extends StatelessWidget {
  const NoteLoadFailure({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_outlined, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Notes could not be opened',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.directoryProvider});

  /// Overridable so a test can make the note folder unreachable. Production
  /// always uses [noteDirectory].
  final NoteDirectoryProvider? directoryProvider;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final NoteStore store = NoteStore(
    directoryProvider: widget.directoryProvider ?? noteDirectory,
  );
  late final DriveSyncService syncService;
  List<Note> notes = [];
  bool loading = true;

  /// Set when the note folder could not be read, so the library offers a retry
  /// instead of showing an empty list that hides the user's notes.
  String? loadFailure;

  /// An unreachable Drive folder is reported once per visit instead of on every
  /// automatic sync, and the flag clears as soon as a sync succeeds again.
  bool reportedSyncProblem = false;

  /// Unreadable remote files stay in the folder until the user fixes them, so
  /// they are reported once per visit as well.
  bool reportedSkippedFiles = false;

  @override
  void initState() {
    super.initState();
    syncService = sharedSyncService(store);
    unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final loaded = await store.load();
      if (!mounted) return;
      setState(() {
        notes = loaded;
        loading = false;
        loadFailure = null;
      });
      syncService.syncInBackground(onResult: _reportBackgroundSync);
    } catch (error) {
      // An empty list here would read as "you have no notes", which is the one
      // message that makes a user start writing over notes still on disk.
      if (!mounted) return;
      setState(() {
        loading = false;
        loadFailure = '$error';
      });
    }
  }

  void _reportBackgroundSync(DriveSyncResult result) {
    if (!mounted) return;
    unawaited(_reloadAfterBackgroundSync());
    if (result.isSynced) {
      reportedSyncProblem = false;
      if (result.skippedRemoteFiles > 0 && !reportedSkippedFiles) {
        reportedSkippedFiles = true;
        _showSyncProblem(
          '${result.skippedRemoteFiles} Drive file(s) could not be read '
          'and were left untouched',
        );
      }
      return;
    }
    reportedSkippedFiles = false;
    if (result.status == DriveSyncStatus.unavailable && !reportedSyncProblem) {
      reportedSyncProblem = true;
      _showSyncProblem(
        'The Google Drive folder is unavailable, so notes are not syncing',
      );
    }
  }

  void _showSyncProblem(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _reloadAfterBackgroundSync() async {
    try {
      final loaded = await store.load();
      if (!mounted) return;
      setState(() {
        notes = loaded;
        loadFailure = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loadFailure = '$error');
    }
  }

  Future<void> openNote([Note? note]) async {
    final n = note ??
        Note(
          id: const Uuid().v4(),
          title: 'Untitled note',
          text: '',
          updated: DateTime.now().toUtc(),
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
            : loadFailure != null && notes.isEmpty
                ? NoteLoadFailure(
                    message: loadFailure!,
                    onRetry: () => unawaited(refresh()),
                  )
                : notes.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.draw_outlined,
                                size: 64, color: Colors.grey),
                            SizedBox(height: 12),
                            Text('Start your first handwritten note'),
                          ],
                        ),
                      )
                    : _noteList(),
      );

  /// A failed read is never shown as an empty library: "start your first note"
  /// over notes that are still on disk invites the user to write on top of
  /// them. The retry is offered because the usual causes are fixable.
  Widget _noteList() => ListView.builder(
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
                  if (v != 'delete') return;
                  try {
                    // delete leaves a tombstone behind, so the
                    // deletion also reaches other devices.
                    await store.delete(n);
                  } catch (error) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Could not delete the note: $error',
                        ),
                      ),
                    );
                    return;
                  }
                  await refresh();
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
      );
}

enum DrawTool {
  hand,
  text,
  pencil,
  pen,
  highlighter,
  eraser,
  blur,
}

class _DrawingToolIcon extends StatelessWidget {
  final DrawTool tool;
  final double size;

  const _DrawingToolIcon(this.tool, {this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    if (tool == DrawTool.text) {
      return CustomPaint(
        key: const ValueKey('drawing-tool-icon-text'),
        size: Size.square(size),
        painter: _TextToolIconPainter(color),
      );
    }
    if (tool == DrawTool.eraser) {
      return CustomPaint(
        key: const ValueKey('drawing-tool-icon-eraser'),
        size: Size.square(size),
        painter: _EraserToolIconPainter(
          color,
          Theme.of(context).colorScheme.primary,
        ),
      );
    }
    return Icon(_toolIconData(tool), size: size);
  }

  IconData _toolIconData(DrawTool tool) => switch (tool) {
        DrawTool.hand => Icons.pan_tool_outlined,
        DrawTool.text => Icons.title,
        DrawTool.pencil => Icons.create_outlined,
        DrawTool.pen => Icons.edit,
        DrawTool.highlighter => Icons.border_color,
        DrawTool.eraser => Icons.backspace_outlined,
        DrawTool.blur => Icons.blur_on,
      };
}

class _TextToolIconPainter extends CustomPainter {
  final Color color;

  const _TextToolIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.shortestSide * 0.11
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(
      Offset(size.width * 0.2, size.height * 0.26),
      Offset(size.width * 0.8, size.height * 0.26),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.26),
      Offset(size.width * 0.5, size.height * 0.78),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _TextToolIconPainter oldDelegate) =>
      color != oldDelegate.color;
}

class _FontSizeMarkIcon extends StatelessWidget {
  const _FontSizeMarkIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return CustomPaint(
      key: key,
      size: const Size.square(24),
      painter: _FontSizeMarkIconPainter(color),
    );
  }
}

class _FontSizeMarkIconPainter extends CustomPainter {
  final Color color;

  const _FontSizeMarkIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.shortestSide * 0.1
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(
      Offset(size.width * 0.05, size.height * 0.25),
      Offset(size.width * 0.45, size.height * 0.25),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.25, size.height * 0.25),
      Offset(size.width * 0.25, size.height * 0.78),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.68, size.height * 0.36),
      Offset(size.width * 0.68, size.height * 0.78),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.54, size.height * 0.50),
      Offset(size.width * 0.85, size.height * 0.50),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _FontSizeMarkIconPainter oldDelegate) =>
      color != oldDelegate.color;
}

class _EraserToolIconPainter extends CustomPainter {
  final Color color;
  final Color accentColor;

  const _EraserToolIconPainter(this.color, this.accentColor);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final body = Rect.fromCenter(
      center: Offset.zero,
      width: size.shortestSide * 0.76,
      height: size.shortestSide * 0.40,
    );
    final rubber = RRect.fromRectAndRadius(
      body,
      Radius.circular(size.shortestSide * 0.055),
    );
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(-math.pi / 4);
    canvas.drawRRect(
      rubber,
      Paint()..color = color.withValues(alpha: 0.16),
    );
    canvas.save();
    canvas.clipRRect(rubber);
    canvas.drawRect(
      Rect.fromLTRB(body.left, body.top, 0, body.bottom),
      Paint()..color = accentColor.withValues(alpha: 0.48),
    );
    canvas.restore();
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.09
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(rubber, outline);
    canvas.drawLine(
      Offset(0, body.top),
      Offset(0, body.bottom),
      outline,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EraserToolIconPainter oldDelegate) =>
      color != oldDelegate.color || accentColor != oldDelegate.accentColor;
}

class EditorPage extends StatefulWidget {
  final Note note;
  final bool launcherMode;

  /// Overridable so a test can watch the notes the editor writes. Production
  /// always uses [noteDirectory].
  final NoteDirectoryProvider? directoryProvider;
  const EditorPage({
    super.key,
    required this.note,
    this.launcherMode = false,
    this.directoryProvider,
  });
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  static const widgetChannel = MethodChannel('notes/widget');
  late final TextEditingController titleController;
  late final RichTextEditingController textController;
  late final FocusNode textFocusNode;
  TextDocumentFormat documentFormat = TextDocumentFormat();
  late final TextEditingController taskController;
  final TransformationController transformationController =
      TransformationController();
  final ValueNotifier<int> canvasRepaint = ValueNotifier(0);
  DrawTool tool = DrawTool.pen;
  Color strokeColor = Colors.blue.shade800;
  Color highlighterColor = Colors.yellow;
  final Map<DrawTool, double> toolWidths = {
    DrawTool.pencil: 2,
    DrawTool.pen: 3,
    DrawTool.highlighter: 22,
    DrawTool.eraser: 36,
    DrawTool.blur: 44,
  };
  Stroke? active;
  Stroke? activeEraser;
  Stroke? activePreview;
  final List<Stroke> activeStrokeChunks = [];
  bool showText = true;
  bool showTasks = false;
  bool applyingExternalChange = false;
  bool hasUnsavedChanges = false;

  /// Reported once per editor visit so an unreachable Drive folder is visible
  /// without nagging after every automatic sync.
  bool reportedSyncProblem = false;
  bool isSaving = false;
  bool saveFailed = false;

  /// True while a failed save is being reported by the window-close path, so
  /// the same failure does not also arrive as an autosave message.
  bool _flushingForExit = false;
  int _editRevision = 0;
  final Map<int, Offset> canvasPointerPositions = {};

  /// Pointer positions at the start of the current pinch frame, and the
  /// pointers that have reported a movement in it. See [_trackPinchRound].
  Map<int, Offset>? pinchRoundStart;
  final Set<int> pinchRoundMoved = {};
  int? drawingPointer;
  Offset? lastSampleViewportPosition;
  double canvasViewportHeight = 0;
  double canvasPageHeight = 1200;
  double canvasWidth = 2000;
  late RasterDrawingStore rasterDrawing;

  /// The marks this editor has made since it opened the note. It dies with
  /// the page, and with any raster store it no longer describes.
  final RasterHistory undoHistory = RasterHistory();
  late Future<void> _rasterLoadOperation;
  Future<void>? _rasterMigrationOperation;
  bool rasterImagesLoaded = false;
  bool isRasterizing = false;

  /// True while an undo or redo step is being swapped back into the paper.
  bool _isReverting = false;

  /// The swap in flight, so a released stroke waits for it instead of baking
  /// its mark into a page that is half taken back.
  Future<void>? _revertOperation;
  Object? rasterImageError;
  bool legacyRasterizationScheduled = false;
  bool rasterMigrationOnlyDirty = false;
  Future<void>? _strokeCommitOperation;
  late final NoteStore store = NoteStore(
    directoryProvider: widget.directoryProvider ?? noteDirectory,
  );
  late final AutosaveController autosave;
  late final DriveSyncService syncService;
  late final DriveSyncDebouncer driveSyncDebouncer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    rasterDrawing = _createRasterStore(
      width: widget.note.rasterWidth,
      pageHeight: widget.note.rasterPageHeight,
    );
    if (widget.note.rasterPageHeight > 0) {
      canvasPageHeight = widget.note.rasterPageHeight.toDouble();
    }
    _rasterLoadOperation = _loadRasterPages(
      rasterDrawing,
      widget.note.rasterTiles,
      legacyPages: widget.note.rasterPages,
    );
    syncService = sharedSyncService(store);
    driveSyncDebouncer = DriveSyncDebouncer(service: syncService);
    // Created before any controller can report an edit: the listeners below
    // schedule through it from the first keystroke.
    autosave = AutosaveController(
      onSave: () async {
        await _performSave();
        // _performSave keeps its error for the button instead of rethrowing,
        // so the queue has to be told out loud. A drain that reports success
        // after a failed write would never retry, and the note would go on
        // unsaved with nobody saying so.
        if (saveFailed) throw StateError('The note could not be written');
      },
      onStatusChanged: _onAutosaveStatus,
    );
    textFocusNode = FocusNode()
      ..addListener(() {
        if (mounted) setState(() {});
      });
    textController = RichTextEditingController(text: '', styles: [])
      ..addListener(_markChanged);
    titleController = TextEditingController(text: widget.note.title);
    titleController.addListener(_markChanged);
    taskController = TextEditingController();
    applyingExternalChange = true;
    try {
      _loadDocumentIntoEditor(widget.note.text, widget.note.textFormat);
    } finally {
      applyingExternalChange = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncCurrentInBackground();
    });
  }

  @override
  void dispose() {
    autosave.dispose();
    WidgetsBinding.instance.removeObserver(this);
    driveSyncDebouncer.dispose();
    titleController.dispose();
    textController.dispose();
    textFocusNode.dispose();
    taskController.dispose();
    rasterDrawing.dispose();
    transformationController.dispose();
    canvasRepaint.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // The process can be suspended and killed here, so what is on screen
      // goes to disk through the same autosave the edits schedule.
      if (hasUnsavedChanges) {
        unawaited(autosave.saveNow());
      } else {
        unawaited(_finalizeActiveStroke());
      }
    }
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    // Closing the desktop window ends the process, and the note a user was
    // looking at is the one they expect to find when they open it again.
    await _finalizeActiveStroke();
    if (hasUnsavedChanges) {
      _flushingForExit = true;
      try {
        await autosave.saveNow();
      } finally {
        _flushingForExit = false;
      }
    }
    if (!mounted) return ui.AppExitResponse.exit;
    if (saveFailed || hasUnsavedChanges) {
      // Leaving now would drop the edits with nobody to say so, which is worse
      // than a window that refuses to close and explains itself.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Pennino could not save this note, so it is staying open. '
            'Save it, or copy the note out, before closing.',
          ),
        ),
      );
      return ui.AppExitResponse.cancel;
    }
    return ui.AppExitResponse.exit;
  }

  /// The controller decides when a save is due; the editor is the part that
  /// has to say what happened, because an autosave that fails quietly is the
  /// same as an autosave that never existed.
  void _onAutosaveStatus(SaveStatus status) {
    if (status != SaveStatus.failed || !mounted || _flushingForExit) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Pennino could not write this note. Your edits are still here.',
        ),
      ),
    );
  }

  /// A store this editor owns keeps only the tiles it has looked at as
  /// pixels, and decodes the rest when the paper or a stroke reaches for them.
  /// Whichever store is current has to be able to say so, or ink that arrives
  /// after the frame it was asked for never gets painted.
  RasterDrawingStore _createRasterStore({
    required int width,
    required int pageHeight,
  }) =>
      RasterDrawingStore(width: width, pageHeight: pageHeight)
        ..onTilesDecoded = _notifyTilesDecoded;

  void _notifyTilesDecoded() {
    if (!mounted) return;
    canvasRepaint.value++;
  }

  Future<void> _loadRasterPages(
    RasterDrawingStore target,
    Map<String, String> encodedTiles, {
    Map<int, String> legacyPages = const {},
  }) async {
    Object? error;
    try {
      await target.load(encodedTiles, legacyPages: legacyPages);
    } catch (loadError) {
      error = loadError;
    }
    if (!mounted) {
      target.dispose();
      return;
    }
    if (!identical(target, rasterDrawing)) {
      target.dispose();
      return;
    }
    setState(() {
      rasterImagesLoaded = true;
      rasterImageError = error;
    });
    if (error != null) {
      _showRasterError(error);
    } else {
      _scheduleLegacyRasterization();
    }
  }

  void _showRasterError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not prepare the drawing: $error')),
    );
  }

  void _scheduleLegacyRasterization() {
    if (!rasterImagesLoaded ||
        rasterImageError != null ||
        widget.note.strokes.isEmpty ||
        legacyRasterizationScheduled) {
      return;
    }
    legacyRasterizationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => isRasterizing = true);
      unawaited(_rasterizeLegacyStrokes());
    });
  }

  Future<void> _rasterizeLegacyStrokes() async {
    try {
      await _ensureRasterized();
    } catch (error) {
      _showRasterError(error);
    } finally {
      if (mounted) setState(() => isRasterizing = false);
    }
  }

  Future<void> _ensureRasterized() async {
    await _rasterLoadOperation;
    final loadError = rasterImageError;
    if (loadError != null) {
      throw StateError('The stored drawing could not be loaded: $loadError');
    }
    if (widget.note.strokes.isEmpty) return;
    final activeMigration = _rasterMigrationOperation;
    if (activeMigration != null) {
      await activeMigration;
      return;
    }
    final operation = _migrateLegacyStrokes();
    _rasterMigrationOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_rasterMigrationOperation, operation)) {
        _rasterMigrationOperation = null;
      }
    }
  }

  Future<void> _migrateLegacyStrokes() async {
    final source = rasterDrawing;
    final legacyStrokes = List<Stroke>.of(widget.note.strokes);
    final migrationWidth = canvasWidth.ceil();
    final migrationPageHeight = canvasPageHeight.ceil();
    final migrationPageCount = widget.note.pageCount;
    final encodedTiles = await source.encode();
    final migrated = _createRasterStore(
      width: source.width,
      pageHeight: source.pageHeight,
    );
    try {
      await migrated.load(encodedTiles);
      await migrated.addStrokes(
        legacyStrokes,
        canvasWidth: migrationWidth,
        canvasPageHeight: migrationPageHeight,
        pageCount: migrationPageCount,
      );
    } catch (_) {
      migrated.dispose();
      rethrow;
    }
    if (!mounted || !identical(source, rasterDrawing)) {
      migrated.dispose();
      return;
    }
    setState(() {
      rasterDrawing = migrated;
      // The marks this history describes were made on the store that has just
      // been replaced; their tiles belong to a drawing that no longer exists.
      undoHistory.clear();
      widget.note.strokes.removeRange(0, legacyStrokes.length);
      widget.note.rasterWidth = rasterDrawing.width;
      widget.note.rasterPageHeight = rasterDrawing.pageHeight;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      source.dispose();
    });
    _markRasterMigrationDirty();
  }

  void _markChanged() {
    if (applyingExternalChange) return;
    rasterMigrationOnlyDirty = false;
    _editRevision++;
    autosave.markChanged();
    if (hasUnsavedChanges) return;
    setState(() => hasUnsavedChanges = true);
  }

  void _markRasterMigrationDirty() {
    if (isSaving || hasUnsavedChanges) return;
    rasterMigrationOnlyDirty = true;
    _editRevision++;
    autosave.markChanged();
    setState(() => hasUnsavedChanges = true);
  }

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

  double get _activeToolWidth => toolWidths[tool] ?? 3;

  void _setActiveToolWidth(double value) {
    setState(() => toolWidths[tool] = value);
  }

  void _selectTool(DrawTool nextTool) {
    if (nextTool != DrawTool.text) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    setState(() {
      tool = nextTool;
      if (tool == DrawTool.text) showText = true;
    });
  }

  void _loadDocumentIntoEditor(String text, TextDocumentFormat format) {
    documentFormat = format.copy();
    // The style list is attached after the text: `RichTextEditingController`
    // shifts every range it holds when the text changes, so loading into an
    // already-styled controller would move all the note's offsets to the end.
    textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    textController.styles
      ..clear()
      ..addAll(documentFormat.styles);
  }

  void _setTextFontSize(double size) {
    final selection = textController.selection;
    setState(() {
      if (selection.isValid && !selection.isCollapsed) {
        textController.applyStyle(selection, fontSize: size);
      } else {
        documentFormat.fontSize = size;
      }
    });
    _markChanged();
  }

  void _toggleTextBold() {
    final selection = textController.selection;
    setState(() {
      if (selection.isValid && !selection.isCollapsed) {
        final current =
            textController.selectedBold(selection) ?? documentFormat.bold;
        textController.applyStyle(selection, bold: !current);
      } else {
        documentFormat.bold = !documentFormat.bold;
      }
    });
    _markChanged();
  }

  void _toggleLinePrefix(String prefix) {
    final controller = textController;
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

  void _toggleChecklistAtSelection() {
    final controller = textController;
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
    final controller = textController;
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
    final selection = textController.selection;
    setState(() {
      if (selection.isValid && !selection.isCollapsed) {
        textController.applyStyle(selection, color: selected.toARGB32());
      } else {
        documentFormat.color = selected.toARGB32();
      }
    });
    _markChanged();
  }

  CanvasTransform get canvasTransform {
    final matrix = transformationController.value;
    return CanvasTransform(
      // getMaxScaleOnAxis also measures the untouched Z basis vector, so it
      // reports 1 for every zoom out of this 2D canvas. That made pen input and
      // the pinch gesture treat a zoomed-out page as unscaled. The canvas only
      // ever builds a uniform 2D scale, held by the X basis vector.
      scale: matrix.storage[0].abs(),
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
    // A save in flight is not a reason to refuse the pen: with autosave one
    // arrives roughly every second, and a canvas that ignores the first touch
    // after each edit loses strokes. The write itself refuses a partly drawn
    // stroke, and the revision counter picks the new one up on the next save.
    if (tool == DrawTool.hand ||
        tool == DrawTool.text ||
        isRasterizing ||
        active != null ||
        activeEraser != null ||
        !rasterImagesLoaded ||
        rasterImageError != null) {
      return;
    }
    final viewportPoint = event.localPosition;
    lastSampleViewportPosition = viewportPoint;
    final scenePoint = _scenePoint(event);
    if (tool == DrawTool.eraser) {
      final eraserWidth = _activeToolWidth / canvasTransform.scale;
      setState(() {
        active = null;
        activePreview = null;
        activeStrokeChunks.clear();
        activeEraser = Stroke(
          points: [scenePoint],
          color: Colors.black.toARGB32(),
          width: eraserWidth,
          highlight: false,
        );
      });
      return;
    }
    setState(() {
      activeEraser = null;
      active = Stroke(
        points: [scenePoint],
        color: _activeStrokeColor.toARGB32(),
        width: _activeToolWidth,
        highlight: tool == DrawTool.highlighter,
        blur: tool == DrawTool.blur,
        opacity: tool == DrawTool.pencil ? 0.58 : 1,
        pressureSensitive: tool == DrawTool.pen || tool == DrawTool.pencil,
      );
      activePreview = active!.blur ? null : _strokePreview(active!, scenePoint);
      activeStrokeChunks.clear();
    });
  }

  static const double _documentPageMargin = 48;
  static const double _documentContentTop = 4;
  static const double _documentContentBottom = 8;
  static const double _textContentLeft = 8;
  static const double _textContentWidthInset = 16;

  /// The document owns a fixed column: the full page width between the paper
  /// margins. Nothing about it is stored per note, so it cannot be moved or
  /// resized and there is no box to grow.
  double get _documentColumnWidth =>
      math.max(240, canvasWidth - 2 * _documentPageMargin);

  /// The document's own base style. `RichTextEditingController.buildTextSpan`
  /// merges each stored range onto this, so the layout used for hit-testing
  /// and page growth measures the same glyphs the field paints.
  TextStyle get _documentStyle => TextStyle(
        color: Color(documentFormat.color),
        fontSize: documentFormat.fontSize,
        fontWeight: documentFormat.bold ? FontWeight.bold : FontWeight.normal,
      );

  TextPainter _layoutDocument() {
    final painter = TextPainter(
      text: textController.buildTextSpan(
        context: context,
        style: _documentStyle,
        withComposing: false,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    painter.layout(
      maxWidth: math.max(1, _documentColumnWidth - _textContentWidthInset),
    );
    return painter;
  }

  /// True when [textLocal], measured from the first glyph of the document,
  /// falls inside one of the laid-out line boxes.
  bool _pointHitsDocumentLine(Offset textLocal) {
    if (textLocal.dx < 0 || textLocal.dy < 0) return false;
    var lineTop = 0.0;
    for (final line in _layoutDocument().computeLineMetrics()) {
      final lineBottom = lineTop + line.height;
      if (textLocal.dy <= lineBottom) {
        return textLocal.dx >= line.left &&
            textLocal.dx <= line.left + line.width;
      }
      lineTop = lineBottom;
    }
    return false;
  }

  /// The point in the document's own text coordinates, or null when the text
  /// layer is hidden.
  Offset? _documentTextLocal(Offset viewportPoint) {
    if (!showText) return null;
    final scenePoint = canvasTransform.sceneFromViewport(
      CanvasPoint(viewportPoint.dx, viewportPoint.dy),
    );
    return Offset(
      scenePoint.x - (_documentPageMargin + _textContentLeft),
      scenePoint.y - (_documentPageMargin + _documentContentTop),
    );
  }

  bool _activateDocument(Offset viewportPoint) {
    final textLocal = _documentTextLocal(viewportPoint);
    // An empty document lays out no lines, so a blank page stays paper for
    // every tool - the v0.4.20 empty-block exception went with the boxes.
    if (textLocal == null || !_pointHitsDocumentLine(textLocal)) return false;
    // The field only takes pointers in text mode, so a drawing-tool tap that
    // activates it has to place the caret where the tap landed.
    final fieldOwnedPointer = tool == DrawTool.text;
    setState(() {
      active = null;
      activeEraser = null;
      showText = true;
      tool = DrawTool.text;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!fieldOwnedPointer) {
        textController.selection = TextSelection.collapsed(
          offset: _layoutDocument().getPositionForOffset(textLocal).offset,
        );
        // The field never saw this pointer, so its tap handler - which is what
        // toggles an inline checklist mark - has to run from here.
        _toggleChecklistAtSelection();
      }
      textFocusNode.requestFocus();
    });
    return true;
  }

  /// A tap on bare paper in text mode keeps writing: the caret goes to the end
  /// of the document instead of opening another box.
  void _focusDocumentAtEnd() {
    setState(() {
      showText = true;
      tool = DrawTool.text;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      textController.selection =
          TextSelection.collapsed(offset: textController.text.length);
      textFocusNode.requestFocus();
    });
  }

  /// Text that runs past the last page pushes the page count up, using the
  /// same margin the scroll rule in `_refreshCanvasViewport` applies.
  void _growPagesForDocument() {
    if (isRasterizing || isSaving || canvasPageHeight <= 0) return;
    final bottom = _documentPageMargin +
        _documentContentTop +
        _layoutDocument().height +
        _documentContentBottom;
    var appended = false;
    while (bottom > widget.note.pageCount * canvasPageHeight - 180) {
      widget.note.pageCount += 1;
      appended = true;
    }
    if (appended) setState(() {});
  }

  void move(PointerMoveEvent event) {
    if (tool == DrawTool.hand || tool == DrawTool.text) return;
    if (tool == DrawTool.eraser) {
      if (activeEraser != null) _appendStrokePoint(event);
      return;
    }
    if (active == null) return;
    _appendStrokePoint(event);
  }

  void _appendStrokePoint(PointerEvent event, {bool force = false}) {
    final stroke = activeEraser ?? active;
    if (stroke == null) return;
    final point = _scenePoint(event);
    final previous = stroke.points.last;
    final previousViewport = lastSampleViewportPosition;
    final movedEnough = previousViewport == null ||
        (event.localPosition - previousViewport).distanceSquared >= 4;
    final pressureChanged =
        (point.normalizedPressure - previous.normalizedPressure).abs() >= 0.04;
    final tiltChanged = (point.tilt - previous.tilt).abs() >= 0.05;
    if (!force && !movedEnough && !pressureChanged && !tiltChanged) return;
    if ((point.x - previous.x).abs() < 0.0001 &&
        (point.y - previous.y).abs() < 0.0001 &&
        !pressureChanged &&
        !tiltChanged) {
      return;
    }
    stroke.points.add(point);
    if (identical(stroke, activeEraser)) {
      lastSampleViewportPosition = event.localPosition;
      canvasRepaint.value++;
      return;
    }
    final preview = activePreview;
    if (!stroke.blur && preview != null) {
      preview.points.add(point);
      if (preview.points.length >= 128) {
        setState(() {
          activeStrokeChunks.add(preview);
          activePreview = _strokePreview(stroke, point);
        });
      }
    }
    lastSampleViewportPosition = event.localPosition;
    canvasRepaint.value++;
  }

  Stroke _strokePreview(Stroke source, CanvasPoint firstPoint) => Stroke(
        points: [firstPoint],
        color: source.color,
        width: source.width,
        highlight: source.highlight,
        blur: source.blur,
        opacity: source.opacity,
        pressureSensitive: source.pressureSensitive,
      );

  void end(PointerEvent event) {
    _appendStrokePoint(event, force: true);
    unawaited(_finalizeActiveStroke());
  }

  void _canvasPointerDown(PointerDownEvent event) {
    canvasPointerPositions[event.pointer] = event.localPosition;
    pinchRoundStart = null;
    pinchRoundMoved.clear();
    if (canvasPointerPositions.length == 1) {
      if (_activateDocument(event.localPosition)) {
        drawingPointer = null;
        return;
      }
      drawingPointer = event.pointer;
      begin(event);
      return;
    }
    drawingPointer = null;
    if (active != null || activeEraser != null) {
      setState(() {
        active = null;
        activeEraser = null;
        activePreview = null;
        activeStrokeChunks.clear();
        lastSampleViewportPosition = null;
      });
    }
  }

  void _canvasPointerMove(PointerMoveEvent event) {
    final previousPosition = canvasPointerPositions[event.pointer];
    if (previousPosition == null) return;
    final beforeUpdate = Map.of(canvasPointerPositions);
    canvasPointerPositions[event.pointer] = event.localPosition;
    if (canvasPointerPositions.length >= 2) {
      final pointers = canvasPointerPositions.keys.take(2).toList();
      final first = pointers[0];
      final second = pointers[1];
      final previousFirst = first == event.pointer
          ? previousPosition
          : canvasPointerPositions[first]!;
      final previousSecond = second == event.pointer
          ? previousPosition
          : canvasPointerPositions[second]!;
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
      _trackPinchRound(beforeUpdate, event.pointer);
      return;
    }
    if (drawingPointer == event.pointer) move(event);
  }

  /// Collects the pointer events of one pinch frame, and reports whether that
  /// frame scrolled the canvas.
  ///
  /// The platform delivers a two-finger movement one pointer at a time, so a
  /// single event always changes the distance between the fingers sharply even
  /// when the whole hand only translates. Measuring over a full round, one
  /// event per finger, is what separates a pan from a spread: a pan returns the
  /// distance to where it started, a zoom does not. Without this, the upward
  /// drift of a rotating hand read as a scroll and appended a page in the
  /// middle of a zoom.
  void _trackPinchRound(Map<int, Offset> beforeUpdate, int pointer) {
    final active = canvasPointerPositions.keys.toList();
    var start = pinchRoundStart;
    // Set has identity equality, so membership is compared key by key: a round
    // only continues while exactly the same fingers are still down.
    if (start == null ||
        start.length != active.length ||
        !active.every(start.containsKey)) {
      start = beforeUpdate;
      pinchRoundStart = start;
      pinchRoundMoved.clear();
    }
    pinchRoundMoved.add(pointer);
    if (pinchRoundMoved.length < active.length) return;
    pinchRoundStart = null;
    pinchRoundMoved.clear();

    final ids = active.take(2).toList();
    final startFirst = start[ids[0]];
    final startSecond = start[ids[1]];
    final currentFirst = canvasPointerPositions[ids[0]];
    final currentSecond = canvasPointerPositions[ids[1]];
    if (startFirst == null ||
        startSecond == null ||
        currentFirst == null ||
        currentSecond == null) {
      return;
    }
    final centreDelta =
        (currentFirst + currentSecond) / 2 - (startFirst + startSecond) / 2;
    final spreadDelta =
        (currentFirst - currentSecond).distance -
        (startFirst - startSecond).distance;
    _refreshCanvasViewport(
      userScrolledDown: centreDelta.dy < -2 &&
          centreDelta.distance >= spreadDelta.abs(),
    );
  }

  void _canvasPointerEnd(PointerEvent event) {
    pinchRoundStart = null;
    pinchRoundMoved.clear();
    if (drawingPointer == event.pointer && canvasPointerPositions.length == 1) {
      end(event);
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
    _refreshCanvasViewport(userScrolledDown: event.scrollDelta.dy > 0);
  }

  void _refreshCanvasViewport({required bool userScrolledDown}) {
    var appendedPage = false;
    final transform = canvasTransform;
    if (userScrolledDown &&
        !isRasterizing &&
        !isSaving &&
        canvasViewportHeight > 0 &&
        canvasPageHeight > 0) {
      final visibleBottom =
          (canvasViewportHeight - transform.translationY) / transform.scale;
      if (visibleBottom >= widget.note.pageCount * canvasPageHeight - 180) {
        widget.note.pageCount += 1;
        appendedPage = true;
      }
    }
    if (appendedPage) {
      setState(() {});
      _markChanged();
    }
  }

  Future<void> _finalizeActiveStroke() {
    final activeCommit = _strokeCommitOperation;
    if (activeCommit != null) return activeCommit;
    final operation = _commitActiveStroke();
    _strokeCommitOperation = operation;
    return operation.whenComplete(() {
      if (identical(_strokeCommitOperation, operation)) {
        _strokeCommitOperation = null;
      }
    });
  }

  Future<void> _commitActiveStroke() async {
    final stroke = activeEraser ?? active;
    if (stroke == null) {
      lastSampleViewportPosition = null;
      return;
    }
    final erasing = activeEraser != null;
    setState(() => isRasterizing = true);
    try {
      // A revert is replacing tiles through the real codec; drawing beside it
      // would bake a mark into a page that is half-taken-back, and the
      // snapshot this stroke records would not be the one the user sees.
      await _revertOperation;
      await _ensureRasterized();
      // The mark is baked inside a recording, so taking it back costs the
      // tiles it covered and no more. The recording is also the honest answer
      // to 'did anything change at all': a mark that landed off the paper
      // replaced no tile, where the drawing path used to assume it always had.
      final covered = await rasterDrawing.record(() async {
        if (erasing) {
          await rasterDrawing.eraseStroke(
            stroke,
            canvasWidth: canvasWidth.ceil(),
            canvasPageHeight: canvasPageHeight.ceil(),
            pageCount: widget.note.pageCount,
          );
        } else {
          await rasterDrawing.addStroke(
            stroke,
            canvasWidth: canvasWidth.ceil(),
            canvasPageHeight: canvasPageHeight.ceil(),
            pageCount: widget.note.pageCount,
          );
        }
      });
      if (!mounted) return;
      if (covered != null) undoHistory.record(covered);
      setState(() {
        active = null;
        activeEraser = null;
        activePreview = null;
        activeStrokeChunks.clear();
        lastSampleViewportPosition = null;
        isRasterizing = false;
        widget.note.rasterWidth = rasterDrawing.width;
        widget.note.rasterPageHeight = rasterDrawing.pageHeight;
      });
      if (covered != null) _markChanged();
    } catch (error) {
      if (!mounted) return;
      setState(() => isRasterizing = false);
      _markChanged();
      _showRasterError(error);
    }
  }

  /// A mark that is mid-bake, or a step that is mid-swap, is not a settled
  /// state to take another step from. A save running beside either is not a
  /// reason to grey the buttons out: the store encodes and swaps tiles one
  /// operation at a time, so the write simply waits for the page to settle.
  bool get _drawingIsSettled =>
      !isRasterizing &&
      !_isReverting &&
      active == null &&
      activeEraser == null;

  bool get canUndo => undoHistory.canUndo && _drawingIsSettled;
  bool get canRedo => undoHistory.canRedo && _drawingIsSettled;

  Future<void> _undo() => _revert(
        take: undoHistory.takeUndo,
        keep: undoHistory.putRedo,
        putBack: undoHistory.putUndo,
      );

  Future<void> _redo() => _revert(
        take: undoHistory.takeRedo,
        keep: undoHistory.putUndo,
        putBack: undoHistory.putRedo,
      );

  /// Swaps one step of the journal back into the paper. What the swap
  /// replaces goes on the other stack, so undo and redo are the same
  /// operation seen from either side, and a step that could not be swapped
  /// goes back where it came from instead of vanishing from the history.
  Future<void> _revert({
    required RasterTileSnapshot? Function() take,
    required void Function(RasterTileSnapshot replaced) keep,
    required void Function(RasterTileSnapshot step) putBack,
  }) async {
    final step = take();
    if (step == null) return;
    setState(() => _isReverting = true);
    final operation = rasterDrawing.restore(step);
    _revertOperation = operation;
    RasterTileSnapshot? replaced;
    Object? failure;
    try {
      replaced = await operation;
    } catch (error) {
      failure = error;
    }
    _revertOperation = null;
    if (!mounted) return;
    if (failure != null) {
      putBack(step);
      setState(() => _isReverting = false);
      _showRasterError(failure);
      return;
    }
    if (replaced != null) keep(replaced);
    setState(() => _isReverting = false);
    _markChanged();
  }

  Future<void> _persist() async {
    await _ensureRasterized();
    if (active != null || activeEraser != null) {
      throw StateError('The active drawing could not be flattened');
    }
    widget.note.title = titleController.text.trim().isEmpty
        ? 'Untitled note'
        : titleController.text.trim();
    widget.note.text = textController.text;
    documentFormat.styles = textController.styles;
    widget.note.textFormat = documentFormat.copy();
    widget.note.rasterTiles = await rasterDrawing.encode();
    widget.note.rasterPages.clear();
    widget.note.rasterWidth = rasterDrawing.width;
    widget.note.rasterPageHeight = rasterDrawing.pageHeight;
    widget.note.strokes.clear();
    widget.note.updated = DateTime.now().toUtc();
    await store.save(widget.note);
    driveSyncDebouncer.schedule(currentNoteId: widget.note.id);
  }

  void _syncCurrentInBackground() {
    syncService.syncInBackground(
      currentNoteId: widget.note.id,
      onResult: (result) {
        if (!mounted) return;
        if (!result.isSynced) {
          // An automatic sync must not nag while the folder was never chosen,
          // but a folder that stopped working has to be surfaced once.
          if (result.status == DriveSyncStatus.unavailable &&
              !reportedSyncProblem) {
            reportedSyncProblem = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'The Google Drive folder is unavailable, '
                  'so notes are not syncing',
                ),
              ),
            );
          }
          return;
        }
        reportedSyncProblem = false;
        if ((hasUnsavedChanges && !rasterMigrationOnlyDirty) ||
            isSaving ||
            isRasterizing ||
            active != null ||
            activeEraser != null) {
          return;
        }
        final syncedCurrent = result.currentNote;
        if (syncedCurrent != null &&
            syncedCurrent.updated.isAfter(widget.note.updated)) {
          _applySyncedNote(syncedCurrent);
        }
      },
    );
  }

  /// The installer path can terminate the process, so nothing may still be
  /// waiting for the manual save when it starts.
  ///
  /// [update] is the release this screen is already showing. Without it the
  /// check runs again, which costs a round trip and can come back with
  /// nothing if the release moved in between.
  Future<void> _installAvailableUpdate({UpdateInfo? update}) async {
    await _finalizeActiveStroke();
    if (hasUnsavedChanges) {
      await autosave.saveNow();
      if (saveFailed || hasUnsavedChanges) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Update stopped because the note is unsaved'),
            ),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    final known = update;
    if (known == null) {
      await UpdateService.prompt(context);
    } else {
      await UpdateService.install(context, known);
    }
  }

  /// Flushes through the autosave queue so a manual press cannot start a
  /// second write beside a save the controller is already running.
  Future<void> _saveNow() => autosave.saveNow();

  /// The one write path. Everything that needs this note on disk — the
  /// debounce, a button press, a lifecycle pause, a window close, and the
  /// widget and sync actions that refuse to run on an unsaved note — goes
  /// through [autosave], so two of them can never race for the same file.
  /// It reports through state only: the button says what the note is, and
  /// [_onAutosaveStatus] is the single place a failed write is announced.
  Future<void> _performSave() async {
    await _finalizeActiveStroke();
    final savingRevision = _editRevision;
    setState(() {
      isSaving = true;
      saveFailed = false;
    });
    try {
      await _persist();
      if (!mounted) return;
      final hasNewerChanges = _editRevision != savingRevision;
      setState(() {
        isSaving = false;
        saveFailed = false;
        hasUnsavedChanges = hasNewerChanges;
        if (!hasNewerChanges) rasterMigrationOnlyDirty = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        isSaving = false;
        saveFailed = true;
        hasUnsavedChanges = true;
      });
    }
  }

  Future<bool> _confirmSaveBeforeLeaving() async {
    await _finalizeActiveStroke();
    if (!hasUnsavedChanges) return true;
    if (isSaving) {
      await autosave.saveNow();
      if (!mounted) return false;
      if (saveFailed || hasUnsavedChanges) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The note is still unsaved. Try saving again.'),
          ),
        );
        return false;
      }
      return true;
    }
    final saveBeforeLeaving = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Save this note before leaving?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Stay'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save and leave'),
          ),
        ],
      ),
    );
    if (!mounted || saveBeforeLeaving != true) return false;
    await autosave.saveNow();
    if (saveFailed || hasUnsavedChanges) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The note is still unsaved. Try saving again.'),
        ),
      );
      return false;
    }
    return true;
  }

  // The button used to be the only way anything reached the disk, so 'Save'
  // was the label whatever the note's state. With autosave running it says
  // what pressing it would do now: nothing, one write, or the retry that
  // failed.
  String get saveLabel => isSaving
      ? 'Saving'
      : saveFailed
          ? 'Retry save'
          : hasUnsavedChanges
              ? 'Save now'
              : 'Saved';

  IconData get saveIcon => isSaving
      ? Icons.hourglass_top
      : saveFailed
          ? Icons.error_outline
          : hasUnsavedChanges
              ? Icons.save
              : Icons.check;

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
    if (rasterDrawing.pageHasTiles(0)) {
      // The preview image is painted off the widget tree, so nothing asks the
      // store for the tiles it is about to draw: they have to be here before
      // the canvas walks them.
      await rasterDrawing.ensureResident(rasterDrawing.keysForPage(0));
      canvas.save();
      canvas.scale(
        size.width / math.max(1, rasterDrawing.width),
        size.height / math.max(1, rasterDrawing.pageHeight),
      );
      rasterDrawing.paintPage(
        canvas,
        0,
        paint: Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }
    // The document lives in canvas coordinates, so it takes the page's own
    // scale rather than the raster's; without it a typed note pins as blank
    // paper.
    final document = _layoutDocument();
    if (document.width > 0 && document.height > 0) {
      canvas.save();
      canvas.scale(
        size.width / math.max(1, canvasWidth),
        size.height / math.max(1, canvasPageHeight),
      );
      document.paint(
        canvas,
        Offset(
          _documentPageMargin + _textContentLeft,
          _documentPageMargin + _documentContentTop,
        ),
      );
      canvas.restore();
    }
    document.dispose();
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
    await autosave.saveNow();
    if (saveFailed || hasUnsavedChanges) {
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

  void _applySyncedNote(Note syncedCurrent) {
    if (identical(syncedCurrent, widget.note)) return;
    final oldRasterDrawing = rasterDrawing;
    final nextRasterDrawing = _createRasterStore(
      width: syncedCurrent.rasterWidth,
      pageHeight: syncedCurrent.rasterPageHeight,
    );
    applyingExternalChange = true;
    try {
      setState(() {
        rasterDrawing = nextRasterDrawing;
        undoHistory.clear();
        rasterImagesLoaded = false;
        rasterImageError = null;
        legacyRasterizationScheduled = false;
        widget.note.title = syncedCurrent.title;
        widget.note.text = syncedCurrent.text;
        widget.note.textFormat = syncedCurrent.textFormat.copy();
        widget.note.updated = syncedCurrent.updated;
        widget.note.strokes = List.of(syncedCurrent.strokes);
        widget.note.tasks = syncedCurrent.tasks;
        widget.note.backgroundColor = syncedCurrent.backgroundColor;
        widget.note.backgroundPattern = syncedCurrent.backgroundPattern;
        widget.note.pageCount = syncedCurrent.pageCount;
        widget.note.rasterWidth = syncedCurrent.rasterWidth;
        widget.note.rasterPageHeight = syncedCurrent.rasterPageHeight;
        widget.note.rasterPages = Map.of(syncedCurrent.rasterPages);
        widget.note.rasterTiles = Map.of(syncedCurrent.rasterTiles);
        canvasWidth = math.max(2000.0, syncedCurrent.rasterWidth.toDouble());
        if (syncedCurrent.rasterPageHeight > 0) {
          canvasPageHeight = syncedCurrent.rasterPageHeight.toDouble();
        }
        hasUnsavedChanges = false;
        saveFailed = false;
        rasterMigrationOnlyDirty = false;
        titleController.text = syncedCurrent.title;
        _loadDocumentIntoEditor(
          syncedCurrent.text,
          syncedCurrent.textFormat,
        );
      });
    } finally {
      applyingExternalChange = false;
    }
    _rasterLoadOperation = _loadRasterPages(
      rasterDrawing,
      widget.note.rasterTiles,
      legacyPages: widget.note.rasterPages,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldRasterDrawing.dispose();
    });
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
    await autosave.saveNow();
    if (saveFailed || hasUnsavedChanges) {
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
      driveSyncDebouncer.cancel();
      var result = await syncService.sync(
        chooseFolder: chooseFolder,
        currentNoteId: widget.note.id,
      );
      if (result != null && !result.isSynced && !chooseFolder) {
        result = await syncService.sync(
          chooseFolder: true,
          currentNoteId: widget.note.id,
        );
      }
      if (result == null) return;
      if (!result.isSynced) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.status == DriveSyncStatus.notConfigured
                    ? 'Choose a Google Drive folder to sync with'
                    : 'Google Drive folder is unavailable',
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
        return;
      }
      final syncedCurrent = result.currentNote;
      if (syncedCurrent != null) _applySyncedNote(syncedCurrent);
      if (mounted) {
        final skipped = result.skippedRemoteFiles;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              skipped == 0
                  ? 'Synced ${result.noteCount} notes with Google Drive'
                  : 'Synced ${result.noteCount} notes with Google Drive '
                      '($skipped remote file(s) were skipped)',
            ),
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

  /// How much of the block under the canvas the window can still carry.
  /// The rows are fixed heights and the checklist scrolls inside its own
  /// ceiling, so what is left over is worked out in the order the app
  /// needs them: the ink tools first, then the paper, then the rows that
  /// are a convenience - the stroke slider and, while typing, the ink row
  /// that already has its way back at the top of the text row.
  ({bool inkRow, bool strokeRow, double tasksHeight}) _bottomBlock(
    double height,
  ) {
    const chooserHeight = 58.0;
    const updateHeight = 44.0;
    const textRowHeight = 60.0;
    const strokeRowHeight = 52.0;
    const inkRowHeight = 64.0;
    const tasksHeaderHeight = 64.0;
    const canvasFloor = 44.0;
    final platform = Theme.of(context).platform;
    // The two rows the block has to share the window with that are not
    // part of it: the desktop tool chooser, and the update banner - which
    // only some platforms are given at all.
    final showsUpdateRow = platform == TargetPlatform.android ||
        platform == TargetPlatform.windows;
    var left = height -
        (platform == TargetPlatform.android ? 0.0 : chooserHeight) -
        (showsUpdateRow && UpdateService.availableUpdate.value != null
            ? updateHeight
            : 0.0);
    final textTool = tool == DrawTool.text;
    if (textTool) left -= textRowHeight;
    final inkRow = !textTool || left >= inkRowHeight;
    if (inkRow) left -= inkRowHeight;
    final strokeRow = toolWidths.containsKey(tool) &&
        left >= strokeRowHeight + canvasFloor;
    if (strokeRow) left -= strokeRowHeight;
    final tasks = left - canvasFloor;
    return (
      inkRow: inkRow,
      strokeRow: strokeRow,
      tasksHeight: tasks < tasksHeaderHeight ? 0.0 : math.min(220.0, tasks),
    );
  }

  Widget _drawingToolbar({required bool showStrokeRow}) {
    final tools = [
      (DrawTool.text, 'Text'),
      (DrawTool.pencil, 'Pencil'),
      (DrawTool.pen, 'Pen'),
      (DrawTool.highlighter, 'Highlighter'),
      (DrawTool.eraser, 'Eraser'),
      (DrawTool.blur, 'Blur'),
    ];
    // Seven squares with a gap between them need more width than a small
    // phone has, and a slot narrower than a fingertip is not a control.
    // Below that the row keeps its slots and slides sideways instead.
    return LayoutBuilder(
      builder: (context, constraints) {
        final tight = constraints.maxWidth / (tools.length + 1) < 40;
        Widget slot(Widget child) =>
            tight ? SizedBox(width: 44, child: child) : Expanded(child: child);
        final toolbar = SizedBox(
          key: Key(
            Theme.of(context).platform == TargetPlatform.android
                ? 'android-drawing-toolbar'
                : 'drawing-toolbar',
          ),
          height: 64,
          child: Material(
            elevation: 6,
            // The button's own padding came off the chip's width, so the
            // row was spending it on a gap the slot already provided.
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 8,
                  ),
                ),
              ),
              child: Row(
                children: [
                  for (final entry in tools)
                    slot(IconButton(
                      tooltip: entry.$2,
                      style: IconButton.styleFrom(
                        backgroundColor: tool == entry.$1
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      onPressed: () => _selectTool(entry.$1),
                      icon: _toolbarIconFrame(_DrawingToolIcon(entry.$1)),
                    )),
                  slot(PopupMenuButton<Color>(
                    tooltip: 'Drawing colour',
                    icon: _toolbarIconFrame(
                      Icon(Icons.circle, color: _activeStrokeColor),
                    ),
                    onSelected: _setActiveStrokeColor,
                    itemBuilder: (_) => _colorMenuItems(_activeStrokeColor),
                  )),
                ],
              ),
            ),
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showStrokeRow) _strokeWidthControls(),
            tight
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: toolbar,
                  )
                : toolbar,
          ],
        );
      },
    );
  }

  Widget _toolbarIconFrame(Widget child) {
    final scheme = Theme.of(context).colorScheme;
    final requested = MediaQuery.sizeOf(context).width < 360 ? 40.0 : 48.0;
    // The chip only ever gets the room its slot can hand over, and a slot
    // that is narrower than the square asked for takes it out of the width
    // alone - seven of them across a phone left every chip 39.7 wide by 48
    // tall. Ask for the largest square the slot will actually give.
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(
          requested,
          math.min(constraints.maxWidth, constraints.maxHeight),
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(7),
          ),
          child: SizedBox(
            width: side,
            height: side,
            child: child,
          ),
        );
      },
    );
  }

  Widget _strokeWidthControls() {
    final width = _activeToolWidth;
    final isEraser = tool == DrawTool.eraser;
    final label = isEraser ? 'Eraser size' : 'Stroke width';
    return SizedBox(
      key: const Key('stroke-width-controls'),
      height: 52,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Row(
          children: [
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 52,
              child: Center(
                child: Tooltip(
                  message: label,
                  child: _toolbarIconFrame(
                    const Icon(Icons.line_weight, size: 20),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Slider(
                key: const Key('stroke-width-slider'),
                min: 1,
                max: 48,
                divisions: 47,
                value: width.clamp(1, 48).toDouble(),
                label: '${width.round()} px',
                semanticFormatterCallback: (value) => '${value.round()} pixels',
                onChanged: _setActiveToolWidth,
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                '${width.round()} px',
                textAlign: TextAlign.end,
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _textToolbar() {
    Widget slot(Widget child) => Expanded(child: Center(child: child));
    return SizedBox(
      key: const Key('text-toolbar'),
      height: 60,
      child: Material(
        elevation: 6,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Row(
          children: [
            slot(_toolbarIconFrame(IconButton(
              tooltip: 'Drawing tools',
              onPressed: () => _selectTool(DrawTool.pen),
              icon: const Icon(Icons.gesture),
            ))),
            slot(_toolbarIconFrame(PopupMenuButton<String>(
              tooltip: 'Lists',
              icon: const Icon(Icons.check_box_outlined),
              onSelected: (value) {
                if (value == 'check') _toggleLinePrefix('☐ ');
                if (value == 'number') _toggleLinePrefix('1. ');
                if (value == 'bullet') _toggleLinePrefix('• ');
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'check',
                  child: Row(children: [
                    Icon(Icons.check_box_outlined),
                    SizedBox(width: 12),
                    Text('Checklist'),
                  ]),
                ),
                PopupMenuItem(
                  value: 'number',
                  child: Row(children: [
                    Icon(Icons.format_list_numbered),
                    SizedBox(width: 12),
                    Text('Numbered list'),
                  ]),
                ),
                PopupMenuItem(
                  value: 'bullet',
                  child: Row(children: [
                    Icon(Icons.format_list_bulleted),
                    SizedBox(width: 12),
                    Text('Bulleted list'),
                  ]),
                ),
              ],
            ))),
            slot(_toolbarIconFrame(PopupMenuButton<Color>(
              tooltip: 'Text colour',
              onSelected: _setTextColor,
              icon: Icon(
                Icons.format_color_text,
                color: Color(documentFormat.color),
              ),
              itemBuilder: (_) => _colorMenuItems(Color(documentFormat.color)),
            ))),
            slot(_toolbarIconFrame(PopupMenuButton<double>(
              tooltip: 'Font size',
              icon: Text(
                '${documentFormat.fontSize.round()}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              onSelected: _setTextFontSize,
              itemBuilder: (_) => [
                for (final size in const [14.0, 18.0, 20.0, 24.0, 30.0, 36.0])
                  PopupMenuItem(
                    value: size,
                    child: Row(children: [
                      _FontSizeMarkIcon(
                        key: ValueKey('font-size-mark-tt-${size.round()}'),
                      ),
                      const SizedBox(width: 12),
                      Text('${size.round()} pt'),
                    ]),
                  ),
              ],
            ))),
            slot(_toolbarIconFrame(IconButton(
              tooltip: 'Bold',
              isSelected: documentFormat.bold,
              onPressed: _toggleTextBold,
              icon: const Icon(Icons.format_bold),
            ))),
            slot(_toolbarIconFrame(PopupMenuButton<bool>(
              tooltip: 'Indent',
              icon: const Icon(Icons.format_indent_increase),
              onSelected: _changeIndent,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: false,
                  child: Row(children: [
                    Icon(Icons.format_indent_decrease),
                    SizedBox(width: 12),
                    Text('Decrease indent'),
                  ]),
                ),
                PopupMenuItem(
                  value: true,
                  child: Row(children: [
                    Icon(Icons.format_indent_increase),
                    SizedBox(width: 12),
                    Text('Increase indent'),
                  ]),
                ),
              ],
            ))),
          ],
        ),
      ),
    );
  }

  Widget _availableUpdateRow(UpdateInfo update) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('available-update-row'),
      color: scheme.secondaryContainer,
      child: DefaultTextStyle(
        style: TextStyle(color: scheme.onSecondaryContainer),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(
                Icons.system_update_outlined,
                size: 20,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Pennino ${update.version} is available',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: () => _installAvailableUpdate(update: update),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSecondaryContainer,
                ),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Update'),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _canvasTextDocument() {
    return Positioned(
      key: const ValueKey('canvas-text-block-0'),
      left: _documentPageMargin,
      top: _documentPageMargin,
      width: _documentColumnWidth,
      // The document takes pointers only in text mode; every drawing tool
      // leaves the canvas to decide, so a stroke can cross live text.
      child: IgnorePointer(
        ignoring: tool != DrawTool.text,
        child: TextField(
          key: const ValueKey('canvas-text-field-0'),
          controller: textController,
          focusNode: textFocusNode,
          onChanged: (_) {
            _growPagesForDocument();
            _markChanged();
          },
          onTap: () => WidgetsBinding.instance
              .addPostFrameCallback((_) => _toggleChecklistAtSelection()),
          minLines: 1,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          style: _documentStyle,
          decoration: const InputDecoration(
            hintText: 'Text',
            filled: false,
            fillColor: Colors.transparent,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.fromLTRB(8, 4, 8, 8),
          ),
        ),
      ),
    );
  }

  /// The eraser's live preview: blur's feather ramp, but every pass lays down
  /// paper instead of blurred content, so the mark fades out to bare paper.
  Widget _eraseStrokeLayer(Stroke stroke, {Key? key}) {
    final paperPattern = PaperPattern.values.firstWhere(
      (item) => item.name == widget.note.backgroundPattern,
      orElse: () => PaperPattern.lined,
    );
    return Positioned.fill(
      key: key,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (var index = 0; index < strokeFeatherPasses.length; index++)
                Opacity(
                  opacity: strokeFeatherPasses[index].$2,
                  child: ClipPath(
                    clipBehavior: Clip.antiAlias,
                    clipper: BlurStrokeClipper(
                      stroke,
                      widthScale: strokeFeatherPasses[index].$1,
                      reclip: canvasRepaint,
                    ),
                    child: CustomPaint(
                      key: ValueKey('erase-paper-$index'),
                      painter: StrokePainter(
                        const [],
                        null,
                        background: Color(widget.note.backgroundColor),
                        pattern: paperPattern,
                        paintStrokes: false,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _blurStrokeLayer(
    Stroke stroke, {
    required List<Stroke> priorStrokes,
    required int layerIndex,
    Key? key,
  }) {
    final paperPattern = PaperPattern.values.firstWhere(
      (item) => item.name == widget.note.backgroundPattern,
      orElse: () => PaperPattern.lined,
    );
    final layer = Stack(
      fit: StackFit.expand,
      children: [
        for (var index = 0; index < blurRampPasses.length; index++)
          Opacity(
            opacity: blurRampPasses[index].$2,
            child: ClipPath(
              clipBehavior: Clip.antiAlias,
              clipper: BlurStrokeClipper(
                stroke,
                widthScale: blurRampPasses[index].$1,
                reclip: identical(stroke, active) ? canvasRepaint : null,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    key: ValueKey('blur-paper-$index'),
                    painter: StrokePainter(
                      const [],
                      null,
                      background: Color(widget.note.backgroundColor),
                      pattern: paperPattern,
                      paintStrokes: false,
                    ),
                  ),
                  ImageFiltered(
                    key: ValueKey('blur-content-$index'),
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: blurSigma,
                      sigmaY: blurSigma,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(
                          key: ValueKey(
                            'blur-strokes-$layerIndex-$index',
                          ),
                          painter: RasterDrawingPainter(
                            tiles: rasterDrawing.tiles,
                            pageHeight: canvasPageHeight.round(),
                            allTileKeys: rasterDrawing.tileKeys,
                            onNeedTiles: rasterDrawing.requestResident,
                            legacyStrokes: priorStrokes,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    return Positioned.fill(
      key: key,
      child: IgnorePointer(
        child:
            identical(stroke, active) ? RepaintBoundary(child: layer) : layer,
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
          if (!await _confirmSaveBeforeLeaving() || !context.mounted) return;
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
                      if (!await _confirmSaveBeforeLeaving()) return;
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
                tooltip: 'Undo the last mark',
                onPressed: canUndo ? _undo : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Redo the mark you took back',
                onPressed: canRedo ? _redo : null,
                icon: const Icon(Icons.redo),
              ),
              if (MediaQuery.sizeOf(context).width >= 700)
                TextButton.icon(
                  onPressed: isSaving ? null : _saveNow,
                  icon: Icon(saveIcon, size: 19),
                  label: Text(saveLabel),
                )
              else
                IconButton(
                  tooltip: saveFailed
                      ? 'Save failed; retry'
                      : hasUnsavedChanges
                          ? 'Save now; the note saves by itself otherwise'
                          : 'All changes saved',
                  onPressed: isSaving ? null : _saveNow,
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
                      _installAvailableUpdate();
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
                      leading: const _DrawingToolIcon(DrawTool.text),
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
          body: LayoutBuilder(
            // The rows under the canvas are fixed heights and a Column
            // only ever hands its `Expanded` child what they leave behind,
            // which is nothing once a landscape screen has lost half its
            // height to the keyboard - the rows then spilled past the
            // bottom of the window instead of giving any of themselves up.
            builder: (context, body) {
              final block = _bottomBlock(body.maxHeight);
              return Column(
            children: [
              if (Theme.of(context).platform != TargetPlatform.android)
                SizedBox(
                  height: 58,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final entry in [
                        (DrawTool.text, 'Text'),
                        (DrawTool.pencil, 'Pencil'),
                        (DrawTool.pen, 'Pen'),
                        (DrawTool.highlighter, 'Highlighter'),
                        (DrawTool.eraser, 'Eraser'),
                        (DrawTool.blur, 'Blur'),
                      ])
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ChoiceChip(
                            label: Text(entry.$2),
                            avatar: _DrawingToolIcon(entry.$1, size: 18),
                            selected: tool == entry.$1,
                            onSelected: (_) => _selectTool(entry.$1),
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
              if (showTasks && block.tasksHeight > 0)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: block.tasksHeight),
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
                    canvasWidth = math.max(
                      math.max(2000.0, constraints.maxWidth),
                      rasterDrawing.width.toDouble(),
                    );
                    canvasViewportHeight = constraints.maxHeight;
                    canvasPageHeight = rasterDrawing.pageHeight > 0
                        ? rasterDrawing.pageHeight.toDouble()
                        : math.max(1200.0, constraints.maxHeight * 1.5);
                    _scheduleLegacyRasterization();
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
                                    onTapUp: tool == DrawTool.text
                                        ? (_) => _focusDocumentAtEnd()
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
                                Positioned.fill(
                                  key: const Key('raster-drawing-layer'),
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: RasterDrawingPainter(
                                        tiles: rasterDrawing.tiles,
                                        pageHeight: canvasPageHeight.round(),
                                        allTileKeys: rasterDrawing.tileKeys,
                                        onNeedTiles:
                                            rasterDrawing.requestResident,
                                        legacyStrokes: widget.note.strokes,
                                        activePreview:
                                            active == null || active!.blur
                                                ? null
                                                : activePreview,
                                        repaint: canvasRepaint,
                                      ),
                                    ),
                                  ),
                                ),
                                for (var index = 0;
                                    index < activeStrokeChunks.length;
                                    index++)
                                  Positioned.fill(
                                    key: ValueKey('active-stroke-chunk-$index'),
                                    child: IgnorePointer(
                                      child: RepaintBoundary(
                                        child: CustomPaint(
                                          painter: StrokePainter(
                                            [activeStrokeChunks[index]],
                                            null,
                                            paintBackground: false,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (active != null && active!.blur)
                                  _blurStrokeLayer(
                                    active!,
                                    priorStrokes: widget.note.strokes
                                        .where((stroke) => !stroke.blur)
                                        .toList(),
                                    layerIndex: widget.note.strokes.length,
                                    key: const Key('active-blur-layer'),
                                  ),
                                if (activeEraser != null)
                                  _eraseStrokeLayer(
                                    activeEraser!,
                                    key: const Key('active-erase-layer'),
                                  ),
                                if (!rasterImagesLoaded || isRasterizing)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    top: 0,
                                    height: 2,
                                    child: IgnorePointer(
                                      child: Semantics(
                                        label: 'Preparing drawing',
                                        liveRegion: true,
                                        child: ColoredBox(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                for (var page = 0;
                                    page < widget.note.pageCount;
                                    page++) ...[
                                  if (page < widget.note.pageCount - 1)
                                    Positioned(
                                      key: ValueKey('page-divider-${page + 1}'),
                                      left: 0,
                                      right: 0,
                                      top: canvasPageHeight * (page + 1) - 7,
                                      height: 14,
                                      child: const IgnorePointer(
                                        child: ColoredBox(
                                          color: Color(0xff34393d),
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    key: ValueKey('page-number-${page + 1}'),
                                    right: 18,
                                    top: canvasPageHeight * (page + 1) - 34,
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
                                            '${page + 1}/${widget.note.pageCount}',
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
                                if (showText) _canvasTextDocument(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (Theme.of(context).platform == TargetPlatform.android ||
                  Theme.of(context).platform == TargetPlatform.windows)
                ValueListenableBuilder<UpdateInfo?>(
                  valueListenable: UpdateService.availableUpdate,
                  builder: (context, update, _) => update == null
                      ? const SizedBox.shrink()
                      : _availableUpdateRow(update),
                ),
              if (tool == DrawTool.text)
                SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _textToolbar(),
                      if (block.inkRow)
                        _drawingToolbar(showStrokeRow: block.strokeRow),
                    ],
                  ),
                )
              else
                SafeArea(
                  top: false,
                  child: _drawingToolbar(showStrokeRow: block.strokeRow),
                ),
            ],
          );
            },
          ),
        ),
      );
}
