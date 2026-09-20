import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() => runApp(const ShamikhApp());
const green = Color(0xFF102D26), gold = Color(0xFFD8B66D), cream = Color(0xFFFFF6E8);

class ShamikhApp extends StatelessWidget {
  const ShamikhApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'شامخ', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: cream, colorScheme: ColorScheme.fromSeed(seedColor: green)),
    home: const Directionality(textDirection: TextDirection.rtl, child: TaskPage()),
  );
}

class ParsedTask {
  final String title;
  final DateTime? due;
  final String reminder;
  final String repeat;
  final String? question;
  const ParsedTask(this.title, this.due, this.reminder, this.repeat, this.question);
}

// Conservative offline parser for demonstration only. Ambiguous dates/times are never guessed.
ParsedTask parseArabic(String raw, DateTime now) {
  final text = raw.replaceAll('أ', 'ا').replaceAll('إ', 'ا').replaceAll('آ', 'ا')
      .replaceAll('٠','0').replaceAll('١','1').replaceAll('٢','2').replaceAll('٣','3')
      .replaceAll('٤','4').replaceAll('٥','5').replaceAll('٦','6').replaceAll('٧','7')
      .replaceAll('٨','8').replaceAll('٩','9');
  final days = {'الاحد': 7, 'الاثنين': 1, 'الثلاثاء': 2, 'الاربعاء': 3, 'الخميس': 4, 'الجمعه': 5, 'الجمعة': 5, 'السبت': 6};
  DateTime? day;
  if (text.contains('بعد بكره') || text.contains('بعد بكرة')) {
    day = DateTime(now.year, now.month, now.day + 2);
  } else if (text.contains('بكره') || text.contains('بكرة') || text.contains('غدا')) {
    day = DateTime(now.year, now.month, now.day + 1);
  } else if (text.contains('اليوم')) {
    day = DateTime(now.year, now.month, now.day);
  } else {
    for (final entry in days.entries) {
      if (text.contains(entry.key)) {
        final offset = (entry.value - now.weekday + 7) % 7;
        day = DateTime(now.year, now.month, now.day + (offset == 0 ? 7 : offset));
        if (text.contains('الاسبوع الجاي') || text.contains('الاسبوع القادم')) day = day.add(const Duration(days: 7));
        break;
      }
    }
  }
  final match = RegExp(r'(?:الساعه|الساعة|ساعه|ساعة)\s*(\d{1,2})(?:[:٫](\d{1,2}))?').firstMatch(text);
  DateTime? due;
  if (day != null && match != null) {
    var hour = int.parse(match.group(1)!);
    final minute = int.tryParse(match.group(2) ?? '0') ?? 0;
    final pm = text.contains('العصر') || text.contains('المساء') || text.contains('الليل') || text.contains('مغرب');
    final am = text.contains('الصباح') || text.contains('الفجر') || text.contains('صباحا');
    if (hour >= 1 && hour <= 12 && minute < 60 && (pm || am)) {
      if (pm && hour < 12) hour += 12;
      if (am && hour == 12) hour = 0;
      due = DateTime(day.year, day.month, day.day, hour, minute);
      if (!due.isAfter(now)) due = null;
    }
  }
  final reminder = text.contains('نصف ساعه') || text.contains('نص ساعه') || text.contains('30 دقيقه') ? 'قبل 30 دقيقة' :
      text.contains('قبل يوم') ? 'قبل يوم' : text.contains('قبل ساعه') ? 'قبل ساعة' : 'غير محدد';
  final repeat = text.contains('كل يوم') || text.contains('يوميا') ? 'يوميًا' :
      text.contains('كل اسبوع') ? 'أسبوعيًا' : 'لا يتكرر';
  final title = raw.trim().isEmpty ? 'مهمة جديدة' : raw.trim();
  final question = day == null ? 'ما تاريخ المهمة؟' : match == null ? 'الساعة كم؟' : due == null ? 'حدد صباحًا أو مساءً، وتأكد أن الموعد في المستقبل.' : null;
  return ParsedTask(title, due, reminder, repeat, question);
}

class TaskPage extends StatefulWidget {
  const TaskPage({super.key});
  @override State<TaskPage> createState() => _TaskPageState();
}
class _TaskPageState extends State<TaskPage> {
  final speech = stt.SpeechToText();
  final textController = TextEditingController();
  bool listening = false, busy = false;
  String status = 'اضغط لبدء التسجيل';
  ParsedTask? parsed;
  List<Map<String, dynamic>> tasks = [];

  @override void initState() { super.initState(); loadTasks(); }
  Future<void> loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('tasks') ?? [];
    if (mounted) setState(() => tasks = stored.map((e) => Map<String,dynamic>.from(jsonDecode(e) as Map)).toList());
  }
  Future<void> toggleMic() async {
    if (listening) { await speech.stop(); if (mounted) setState(() { listening = false; status = 'انتهى التسجيل'; }); return; }
    setState(() => busy = true);
    final ready = await speech.initialize(onStatus: (s) {
      if (s == 'done' || s == 'notListening') { if (mounted) setState(() => listening = false); }
    }, onError: (e) { if (mounted) setState(() { listening = false; status = 'تعذر التعرف على الصوت: ${e.errorMsg}'; }); });
    if (!mounted) return;
    setState(() => busy = false);
    if (!ready) { setState(() => status = 'الميكروفون غير متاح. استخدم الكتابة أدناه.'); return; }
    final locales = await speech.locales();
    final arabic = locales.where((l) => l.localeId.toLowerCase().startsWith('ar')).toList();
    if (arabic.isEmpty) { setState(() => status = 'التعرف على العربية غير متوفر على الجهاز. استخدم الكتابة.'); return; }
    setState(() { listening = true; status = 'أسمعك الآن...'; });
    await speech.listen(localeId: arabic.first.localeId, onResult: (result) {
      if (!mounted) return;
      setState(() {
        textController.text = result.recognizedWords;
        if (result.finalResult) { parsed = parseArabic(textController.text, DateTime.now()); listening = false; status = 'راجع تفاصيل المهمة'; }
      });
    });
  }
  void analyze() => setState(() { parsed = parseArabic(textController.text, DateTime.now()); status = 'راجع تفاصيل المهمة'; });
  Future<void> save() async {
    final p = parsed;
    if (p == null || p.due == null) return;
    final record = {'title': p.title, 'due': p.due!.toIso8601String(), 'reminder': p.reminder, 'repeat': p.repeat};
    final prefs = await SharedPreferences.getInstance();
    tasks.insert(0, record);
    await prefs.setStringList('tasks', tasks.map(jsonEncode).toList());
    if (!mounted) return;
    setState(() { parsed = null; textController.clear(); status = 'تم حفظ المهمة محليًا'; });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ على الجهاز. الإشعارات لم تُفعّل بعد.')));
  }
  @override void dispose() { speech.stop(); textController.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: green, foregroundColor: Colors.white, title: const Text('إضافة مهمة جديدة'), centerTitle: true),
    body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(22), decoration: BoxDecoration(color: green, borderRadius: BorderRadius.circular(24)), child: Column(children: [
        const Text('وش تبي أذكّرك فيه؟', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 8), const Text('اضغط الميكروفون وتكلم بطريقتك', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 20), IconButton(onPressed: busy ? null : toggleMic, icon: Icon(listening ? Icons.stop : Icons.mic, size: 43, color: green),
          style: IconButton.styleFrom(backgroundColor: gold, fixedSize: const Size(88,88))),
        const SizedBox(height: 12), Text(status, textAlign: TextAlign.center, style: const TextStyle(color: gold)),
      ])), const SizedBox(height: 16),
      panel('النص المستخرج من صوتك', Column(children: [
        TextField(controller: textController, maxLines: 3, textDirection: TextDirection.rtl, decoration: const InputDecoration(hintText: 'مثال: ذكرني بكرة الساعة ٨ الصباح أراجع المستشفى', border: OutlineInputBorder())),
        const SizedBox(height: 8), OutlinedButton.icon(onPressed: analyze, icon: const Icon(Icons.auto_awesome), label: const Text('تحليل الأمر')),
      ])), const SizedBox(height: 16),
      if (parsed != null) ...[panel('تفاصيل المهمة المستخرجة', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        detail('المهمة', parsed!.title), detail('التاريخ والوقت', parsed!.due?.toString().substring(0,16) ?? 'غير محدد'),
        detail('التذكير', parsed!.reminder), detail('التكرار', parsed!.repeat),
        if (parsed!.question != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(parsed!.question!, style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold))),
      ])), const SizedBox(height: 12), FilledButton.icon(onPressed: parsed!.due == null ? null : save, style: FilledButton.styleFrom(backgroundColor: green, minimumSize: const Size.fromHeight(54)), icon: const Icon(Icons.check), label: const Text('تأكيد وحفظ المهمة')), const SizedBox(height: 16)],
      if (tasks.isNotEmpty) panel('المهام المحفوظة على الجهاز', Column(children: tasks.map((t) => ListTile(title: Text(t['title'] as String), subtitle: Text(t['due'] as String))).toList())),
      const SizedBox(height: 12), const Text('نسخة تجريبية: تحليل محدود دون ذكاء اصطناعي سحابي. لا توجد إشعارات مجدولة حتى الآن.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54)),
    ])),
  );
  Widget panel(String title, Widget child) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Text(title, style: const TextStyle(color: green, fontWeight: FontWeight.bold, fontSize: 17)), const SizedBox(height: 12), child]));
  Widget detail(String label, String value) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 85, child: Text(label, style: const TextStyle(color: Colors.black54))), Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)))]));
}
