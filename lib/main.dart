import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const InkNoteApp()); }

class InkNoteApp extends StatelessWidget {
  const InkNoteApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false, title: 'InkNote',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff594fc8), scaffoldBackgroundColor: const Color(0xfffaf9f6)),
    home: const LibraryPage(),
  );
}

class InkPoint {
  final double x, y;
  const InkPoint(this.x,this.y);
  factory InkPoint.fromJson(Map<String,dynamic> m) => InkPoint((m['x'] as num).toDouble(), (m['y'] as num).toDouble());
  Map<String,dynamic> toJson()=>{'x':x,'y':y};
}
class Stroke {
  final List<InkPoint> points;
  final int color;
  final double width;
  final bool highlight;
  Stroke({required this.points,required this.color,required this.width,required this.highlight});
  factory Stroke.fromJson(Map<String,dynamic> m) => Stroke(points:(m['points'] as List).map((e)=>InkPoint.fromJson(Map<String,dynamic>.from(e))).toList(),color:m['color'] as int,width:(m['width'] as num).toDouble(),highlight:m['highlight'] as bool? ?? false);
  Map<String,dynamic> toJson()=>{'points':points.map((e)=>e.toJson()).toList(),'color':color,'width':width,'highlight':highlight};
}
class Note {
  String id,title;
  DateTime updated;
  List<Stroke> strokes;
  Note({required this.id,required this.title,required this.updated,required this.strokes});
  factory Note.fromJson(Map<String,dynamic> m)=> Note(id:m['id'] as String,title:m['title'] as String,updated:DateTime.parse(m['updated'] as String),strokes:(m['strokes'] as List).map((e)=>Stroke.fromJson(Map<String,dynamic>.from(e))).toList());
  Map<String,dynamic> toJson()=>{'id':id,'title':title,'updated':updated.toIso8601String(),'strokes':strokes.map((s)=>s.toJson()).toList()};
}
class NoteStore {
  Future<Directory> get folder async { final dir=Directory('${(await getApplicationDocumentsDirectory()).path}/inknote'); if(!await dir.exists()) await dir.create(recursive:true); return dir; }
  Future<List<Note>> load() async {final dir=await folder;final notes=<Note>[];await for(final entry in dir.list()){if(entry is File && entry.path.endsWith('.json')) {try {notes.add(Note.fromJson(jsonDecode(await entry.readAsString())));} catch(_) {/* Skip damaged note without deleting it. */}}}notes.sort((a,b)=>b.updated.compareTo(a.updated));return notes;}
  Future<void> save(Note n) async {final dir=await folder;final file=File('${dir.path}/${n.id}.json'); final tmp=File('${file.path}.tmp');await tmp.writeAsString(jsonEncode(n.toJson()),flush:true); if(await file.exists()) await file.delete(); await tmp.rename(file.path);}
  Future<void> delete(Note n) async { final dir=await folder;final f=File('${dir.path}/${n.id}.json');if(await f.exists())await f.delete();}
}
class LibraryPage extends StatefulWidget {const LibraryPage({super.key});@override State<LibraryPage> createState()=>_LibraryPageState();}
class _LibraryPageState extends State<LibraryPage> {
  final store=NoteStore(); List<Note> notes=[];bool loading=true;
  @override void initState(){super.initState();refresh();}
  Future<void> refresh()async{final loaded=await store.load();if(mounted)setState((){notes=loaded;loading=false;});}
  Future<void> openNote([Note? note])async{final n=note??Note(id:const Uuid().v4(),title:'Untitled note',updated:DateTime.now(),strokes:[]);await Navigator.push(context,MaterialPageRoute(builder:(_)=>EditorPage(note:n)));await refresh();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('All notes')),floatingActionButton:FloatingActionButton.extended(onPressed:()=>openNote(),icon:const Icon(Icons.add),label:const Text('New note')),body:loading?const Center(child:CircularProgressIndicator()):notes.isEmpty?Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.draw_outlined,size:64,color:Colors.grey),SizedBox(height:12),Text('Start your first handwritten note')])):ListView.builder(padding:const EdgeInsets.all(12),itemCount:notes.length,itemBuilder:(context,i){final n=notes[i];return Card(child:ListTile(leading:const Icon(Icons.note_alt_outlined),title:Text(n.title),subtitle:Text('${n.strokes.length} strokes • ${n.updated.toLocal()}'),onTap:()=>openNote(n),trailing:PopupMenuButton<String>(onSelected:(v)async{if(v=='delete'){await store.delete(n);refresh();}},itemBuilder:(_)=>[const PopupMenuItem(value:'delete',child:Text('Delete'))])));}),);
}

enum DrawTool { pen, highlighter, eraser }
class EditorPage extends StatefulWidget{final Note note;const EditorPage({super.key,required this.note});@override State<EditorPage> createState()=>_EditorPageState();}
class _EditorPageState extends State<EditorPage>{
  static const widgetChannel=MethodChannel('inknote/widget');
  late final TextEditingController titleController;
  DrawTool tool=DrawTool.pen; Color ink=Colors.blue.shade800; double width=3; Stroke? active; bool changed=false;
  final List<Stroke> undone=[]; final store=NoteStore();
  @override void initState(){super.initState();titleController=TextEditingController(text:widget.note.title);titleController.addListener(()=>changed=true);}
  @override void dispose(){titleController.dispose();super.dispose();}
  void begin(Offset p){if(tool==DrawTool.eraser){erase(p);return;}setState((){active=Stroke(points:[InkPoint(p.dx,p.dy)],color:ink.toARGB32(),width:tool==DrawTool.highlighter?22:width,highlight:tool==DrawTool.highlighter);});}
  void move(Offset p){if(tool==DrawTool.eraser){erase(p);return;}if(active==null)return;setState(()=>active!.points.add(InkPoint(p.dx,p.dy)));}
  void end(){if(active!=null){setState((){widget.note.strokes.add(active!);active=null;undone.clear();changed=true;});}}
  void erase(Offset p){for(int i=widget.note.strokes.length-1;i>=0;i--){final s=widget.note.strokes[i];if(s.points.any((q)=>(Offset(q.x,q.y)-p).distance<math.max(14,s.width/2+8))){setState((){widget.note.strokes.removeAt(i);changed=true;undone.clear();});break;}}}
  Future<void> save() async {widget.note.title=titleController.text.trim().isEmpty?'Untitled note':titleController.text.trim();widget.note.updated=DateTime.now();await store.save(widget.note);changed=false;if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Saved on this device')));}
  Future<Uint8List> renderPreview() async {
    final recorder=ui.PictureRecorder();final canvas=Canvas(recorder);const size=Size(700,420);
    canvas.drawColor(const Color(0xfff3f0e8),BlendMode.src); final paint=Paint()..color=const Color(0xffd6ddd9)..strokeWidth=1;
    for(double y=27;y<size.height;y+=29){canvas.drawLine(Offset(0,y),Offset(size.width,y),paint);}
    InkPainter(widget.note.strokes,null).paint(canvas,size);
    final picture=recorder.endRecording();final image=await picture.toImage(size.width.toInt(),size.height.toInt());final bytes=await image.toByteData(format:ui.ImageByteFormat.png);image.dispose();picture.dispose();return bytes!.buffer.asUint8List();
  }
  Future<void> pinWidget()async{await save();if(!Platform.isAndroid){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Home screen widgets are Android-only')));return;}try{final png=await renderPreview();await widgetChannel.invokeMethod('setNote',{'title':widget.note.title,'png':base64Encode(png)});if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Widget updated. Add InkNote widget from the Android home screen.')));}on PlatformException catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Widget error: ${e.message}')));}}
  @override Widget build(BuildContext context)=>PopScope(canPop:false,onPopInvokedWithResult:(didPop,result)async{if(didPop)return;if(changed)await save();if(context.mounted)Navigator.pop(context);},child:Scaffold(appBar:AppBar(title:TextField(controller:titleController,decoration:const InputDecoration(border:InputBorder.none,hintText:'Note title'),style:Theme.of(context).textTheme.titleLarge),actions:[IconButton(tooltip:'Undo',onPressed:widget.note.strokes.isEmpty?null:()=>setState((){undone.add(widget.note.strokes.removeLast());changed=true;}),icon:const Icon(Icons.undo)),IconButton(tooltip:'Redo',onPressed:undone.isEmpty?null:()=>setState((){widget.note.strokes.add(undone.removeLast());changed=true;}),icon:const Icon(Icons.redo)),IconButton(tooltip:'Save',onPressed:save,icon:const Icon(Icons.save_outlined)),IconButton(tooltip:'Show in Android widget',onPressed:pinWidget,icon:const Icon(Icons.widgets_outlined))]),body:Column(children:[SizedBox(height:58,child:ListView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:8),children:[for(final entry in [(DrawTool.pen,Icons.edit,'Pen'),(DrawTool.highlighter,Icons.border_color,'Highlighter'),(DrawTool.eraser,Icons.auto_fix_normal,'Eraser')]) Padding(padding:const EdgeInsets.all(4),child:ChoiceChip(label:Text(entry.$3),avatar:Icon(entry.$2,size:18),selected:tool==entry.$1,onSelected:(_)=>setState(()=>tool=entry.$1))),for(final c in [Colors.black,Colors.blue,Colors.red,Colors.green,Colors.orange,Colors.purple]) Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:InkWell(onTap:()=>setState(()=>ink=c),child:CircleAvatar(radius:15,backgroundColor:c,child:ink==c?const Icon(Icons.check,size:17,color:Colors.white):null)))])),Expanded(child:LayoutBuilder(builder:(context,constraints)=>ClipRect(child:GestureDetector(behavior:HitTestBehavior.opaque,onPanStart:(d)=>begin(d.localPosition),onPanUpdate:(d)=>move(d.localPosition),onPanEnd:(_)=>end(),child:CustomPaint(size:Size.infinite,painter:InkPainter(widget.note.strokes,active))))))])));
}
class InkPainter extends CustomPainter {
  final List<Stroke> strokes;final Stroke? active;
  InkPainter(this.strokes,this.active);
  @override void paint(Canvas canvas,Size size){canvas.drawColor(const Color(0xfffffdf7),BlendMode.src);final line=Paint()..color=const Color(0xffe0e6e4)..strokeWidth=0.8;for(double y=29;y<size.height;y+=29)canvas.drawLine(Offset(0,y),Offset(size.width,y),line);for(final s in [...strokes,if(active!=null)active!]){if(s.points.isEmpty)continue;final p=Paint()..color=Color(s.color).withValues(alpha:s.highlight?0.32:1)..strokeWidth=s.width..strokeCap=StrokeCap.round..strokeJoin=StrokeJoin.round..style=PaintingStyle.stroke;if(s.points.length==1){canvas.drawPoints(ui.PointMode.points,[Offset(s.points.first.x,s.points.first.y)],p);continue;}final path=Path()..moveTo(s.points.first.x,s.points.first.y);for(final pt in s.points.skip(1))path.lineTo(pt.x,pt.y);canvas.drawPath(path,p);}}
  @override bool shouldRepaint(covariant InkPainter old)=>true;
}
