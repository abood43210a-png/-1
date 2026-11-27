import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'main.dart';

const tplNames = {
  'voucher_dr': 'إشعار دائن (سند عليه)',
  'voucher_cr': 'إشعار مدين (سند له)',
  'invoice': 'إشعار الفاتورة',
  'balance': 'إشعار الرصيد / المطالبة',
};

const defTpl = {
  'voucher_dr':
      'اشعار دائن\n{app}\nعليكم مبلغ {amount}\n{note}\nالرصيد {balance}\n{date}\n{close}',
  'voucher_cr':
      'اشعار مدين\n{app}\nلكم مبلغ {amount}\n{note}\nالرصيد {balance}\n{date}\n{close}',
  'invoice':
      '{app}\n{kind} رقم {no}\nحساب: {name}\nالإجمالي: {amount}\nالمتبقي: {rest}\nالرصيد {balance}\n{date}',
  'balance': '{app}\nحساب: {name}\nالرصيد {balance}\n{date}\n{close}',
};

const defCloseOwe = 'نرجو المراجعة والتسديد 😊';
const defClosePaid = 'شكراً على حسن تعاملكم 😘';

const tplHelp =
    '{app} اسم المحل   {name} اسم الحساب   {amount} المبلغ   {note} البيان   {balance} الرصيد   {date} التاريخ والوقت   {close} عبارة الختام   {kind} نوع الفاتورة   {no} الرقم   {rest} المتبقي';

// ---------- الإعدادات ----------

Future<void> _ensureSettings() =>
    db.execute('CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT)');

Future<String> getSetting(String k, String def) async {
  await _ensureSettings();
  final r = await db.query('settings', where: 'k=?', whereArgs: [k]);
  return r.isEmpty ? def : r.first['v'] as String;
}

Future<void> setSetting(String k, String v) async {
  await _ensureSettings();
  await db.insert('settings', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<String> getTpl(String k) => getSetting('tpl2_$k', defTpl[k]!);
Future<String> appName() => getSetting('app_name', 'المحاسب');
Future<String> closeFor(bool owe) =>
    getSetting(owe ? 'close_owe' : 'close_paid', owe ? defCloseOwe : defClosePaid);

// ---------- تنسيق ----------

String nf(double v) {
  final a = v.abs();
  final whole = (a - a.roundToDouble()).abs() < 0.005;
  final s = whole ? a.roundToDouble().toStringAsFixed(0) : a.toStringAsFixed(2);
  final parts = s.split('.');
  final ip = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '${v < 0 ? '-' : ''}$ip${parts.length > 1 ? '.${parts[1]}' : ''}';
}

// يحوّل "500.00 ر.ي" إلى "500 ر.ي"
String pm(String s) {
  final m = RegExp(r'^\s*([\d.]+)\s*(.*)$').firstMatch(s);
  if (m == null) return s;
  final v = double.tryParse(m.group(1)!);
  if (v == null) return s;
  return '${nf(v)} ${m.group(2)}'.trim();
}

String balIn(Map<int, double>? m, int cur) {
  final v = m?[cur] ?? 0;
  if (v.abs() < 0.005) return 'عليكم : 0 ${sym(cur)}';
  return '${v > 0 ? 'عليكم' : 'لكم'} : ${nf(v.abs())} ${sym(cur)}';
}

String balAll(Map<int, double>? m) {
  final parts = <String>[];
  (m ?? <int, double>{}).forEach((c, v) {
    if (v.abs() >= 0.005) {
      parts.add('${v > 0 ? 'عليكم' : 'لكم'} : ${nf(v.abs())} ${sym(c)}');
    }
  });
  return parts.isEmpty ? 'عليكم : 0 ${sym(defCur)}' : parts.join(' | ');
}

String balMsg(Map<int, double>? m) => balAll(m);

String fill(String tpl, Map<String, String> vars) {
  var s = tpl;
  vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
  s = s.replaceAll(RegExp(r'\{[a-z_]+\}'), '');
  return s.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
}

String digits(String s) {
  var d = s.replaceAll(RegExp(r'[^0-9]'), '');
  // جوال يمني من 9 خانات يبدأ بـ 7: نضيف مفتاح الدولة
  if (d.length == 9 && d.startsWith('7')) d = '967$d';
  return d;
}

Set<String> channelsOf(Map<String, Object?> a) => '${a['msg_app'] ?? ''}'
    .split(',')
    .where((e) => e == 'sms' || e == 'wa')
    .toSet();

// ---------- فتح التطبيقات ----------

Future<bool> sendMsg(String app, String phone, String text) async {
  final e = Uri.encodeComponent(text);
  final url = app == 'wa'
      ? 'https://wa.me/${digits(phone)}?text=$e'
      : 'sms:${phone.trim()}?body=$e';
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> callPhone(String phone) async {
  try {
    await launchUrl(Uri.parse('tel:${phone.trim()}'));
  } catch (_) {}
}

Future<Map<String, Object?>?> accRow(int id) async {
  final r = await db.query('accounts', where: 'id=?', whereArgs: [id]);
  return r.isEmpty ? null : r.first;
}

// إرسال ملف أو صورة مباشرة لمحادثة العميل في واتساب (كود أندرويد أصلي)، وإلا قائمة المشاركة
const _chan = MethodChannel('acc/share');

Future<bool> _waDirect(String phone, String path, String mime, String text) async {
  try {
    final r = await _chan.invokeMethod<bool>('shareToWhatsApp',
        {'phone': digits(phone), 'path': path, 'mime': mime, 'text': text});
    return r == true;
  } catch (_) {
    return false;
  }
}

Future<void> sendFileWa(
    BuildContext context, String phone, String path, String mime, String text) async {
  var ok = false;
  if (phone.trim().isNotEmpty) ok = await _waDirect(phone, path, mime, text);
  if (ok) return;
  try {
    await Share.shareXFiles([XFile(path, mimeType: mime)], text: text.isEmpty ? null : text);
  } catch (_) {
    if (context.mounted) snack(context, 'تعذر مشاركة الملف');
  }
}

class _ResumeObserver with WidgetsBindingObserver {
  final VoidCallback f;
  _ResumeObserver(this.f);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) f();
  }
}

// ينتظر رجوع المستخدم للتطبيق (بعد إرسال القناة الأولى)
Future<void> _waitResume() {
  final c = Completer<void>();
  late _ResumeObserver o;
  o = _ResumeObserver(() {
    WidgetsBinding.instance.removeObserver(o);
    if (!c.isCompleted) c.complete();
  });
  WidgetsBinding.instance.addObserver(o);
  return c.future.timeout(const Duration(minutes: 5), onTimeout: () {
    WidgetsBinding.instance.removeObserver(o);
  });
}

// ---------- بطاقة الإشعار (صورة) ----------

class NoticeData {
  final String app, title, no, date, name, headline, balance, closing;
  final List<List<String>> rows;
  final bool red;
  NoticeData({
    required this.app,
    required this.title,
    required this.no,
    required this.date,
    required this.name,
    required this.headline,
    required this.balance,
    required this.closing,
    required this.rows,
    required this.red,
  });
}

NoticeData cardFor(String kind, Map<String, String> v) {
  final note = v['note'] ?? '';
  final date = v['date'] ?? dt12(DateTime.now());
  final close = v['close'] ?? '';
  switch (kind) {
    case 'voucher_dr':
      return NoticeData(
          app: v['app']!,
          title: 'اشعار دائن',
          no: v['no'] ?? '',
          date: date,
          name: v['name']!,
          headline: 'عليكم مبلغ ${v['amount']}',
          rows: [if (note.isNotEmpty) ['البيان', note]],
          balance: v['balance']!,
          closing: close,
          red: true);
    case 'voucher_cr':
      return NoticeData(
          app: v['app']!,
          title: 'اشعار مدين',
          no: v['no'] ?? '',
          date: date,
          name: v['name']!,
          headline: 'لكم مبلغ ${v['amount']}',
          rows: [if (note.isNotEmpty) ['البيان', note]],
          balance: v['balance']!,
          closing: close,
          red: false);
    case 'invoice':
      return NoticeData(
          app: v['app']!,
          title: '${v['kind']} رقم ${v['no']}',
          no: v['no'] ?? '',
          date: date,
          name: v['name']!,
          headline: 'الإجمالي ${v['amount']}',
          rows: [
            ['المتبقي', v['rest'] ?? '']
          ],
          balance: v['balance']!,
          closing: close,
          red: true);
    default:
      return NoticeData(
          app: v['app']!,
          title: 'كشف رصيد',
          no: '',
          date: date,
          name: v['name']!,
          headline: 'الرصيد المستحق',
          rows: [],
          balance: v['balance']!,
          closing: close,
          red: true);
  }
}

class NoticeCard extends StatelessWidget {
  final NoticeData d;
  const NoticeCard(this.d, {super.key});

  @override
  Widget build(BuildContext context) {
    final accent = d.red ? const Color(0xFFC62828) : const Color(0xFF2E7D32);
    return Theme(
      data: ThemeData.light(),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          width: 340,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: blue, width: 2)),
          child: DefaultTextStyle(
            style: const TextStyle(color: Color(0xFF1B1F2A), fontSize: 14),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: blue,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    child: Column(children: [
                      Text(d.app,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 2),
                      Text(d.title, style: const TextStyle(color: Colors.white70, fontSize: 15)),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text(d.no.isEmpty ? '' : 'رقم: ${d.no}'),
                        Text(d.date, style: const TextStyle(fontSize: 12.5)),
                      ]),
                      const Divider(),
                      Text('الأخ / ${d.name}',
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                        decoration: BoxDecoration(
                            color: accent.withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: accent)),
                        child: Text(d.headline,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: accent, fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                      for (final r in d.rows)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${r[0]}: ',
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                            Expanded(child: Text(r[1])),
                          ]),
                        ),
                      const Divider(height: 24),
                      Text('الرصيد ${d.balance}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      if (d.closing.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Center(
                            child: Text(d.closing,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 15.5, fontWeight: FontWeight.w700))),
                      ],
                      const SizedBox(height: 16),
                      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text('المحاسب: ________'),
                        Text('المستلم: ________'),
                      ]),
                    ]),
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}

// يعرض البطاقة لحظة قصيرة ثم يلتقطها كصورة PNG
class _CaptureDialog extends StatefulWidget {
  final Widget child;
  const _CaptureDialog(this.child);
  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  final key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => capture());
  }

  Future<void> capture() async {
    await Future.delayed(const Duration(milliseconds: 350));
    String? path;
    try {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 3);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      final f = File(
          '${Directory.systemTemp.path}/notice_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes!.buffer.asUint8List());
      path = f.path;
    } catch (_) {}
    if (mounted) Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(12),
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: Container(
                color: Colors.white, padding: const EdgeInsets.all(10), child: widget.child),
          ),
        ),
      );
}

Future<String?> renderCard(BuildContext context, NoticeData d) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CaptureDialog(NoticeCard(d)));

// ---------- الإرسال ----------

// يرسل حسب قنوات الحساب: SMS نص، وواتساب صورة مباشرة لرقم العميل
Future<void> sendVia(BuildContext context, Map<String, Object?> a, String text,
    Future<String?> Function() makeImage) async {
  final phone = ((a['phone'] ?? '') as String).trim();
  var ch = channelsOf(a);
  if (ch.isEmpty) ch = {'sms'};
  var first = true;
  for (final c in ['sms', 'wa']) {
    if (!ch.contains(c)) continue;
    if (!first) await _waitResume();
    first = false;
    if (!context.mounted) return;
    if (c == 'sms') {
      if (phone.isEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) snack(context, 'لا يوجد رقم تلفون، تم نسخ النص');
      } else {
        final ok = await sendMsg('sms', phone, text);
        if (!ok && context.mounted) snack(context, 'تعذر فتح تطبيق الرسائل');
      }
    } else {
      final path = await makeImage();
      if (!context.mounted) return;
      if (path != null) {
        await sendFileWa(context, phone, path, 'image/png', '');
      } else if (phone.isNotEmpty) {
        await sendMsg('wa', phone, text);
      }
    }
  }
}

Future<void> sendNotice(BuildContext context, Map<String, Object?> a, String kind,
    Map<String, String> vars) async {
  final v = {
    ...vars,
    'app': await appName(),
    'name': a['name'] as String,
    'date': dt12(DateTime.now()),
  };
  final text = fill(await getTpl(kind), v);
  if (!context.mounted) return;
  await sendVia(context, a, text, () => renderCard(context, cardFor(kind, v)));
}

// زر الرسالة في بطاقة الحساب وفي أرصدة الحسابات
Future<void> sendBalanceMsg(BuildContext context, int id) async {
  final a = await accRow(id);
  if (a == null) return;
  if (((a['phone'] ?? '') as String).trim().isEmpty) {
    if (context.mounted) snack(context, 'لا يوجد رقم تلفون لهذا الحساب');
    return;
  }
  final bal = (await balances())[id];
  final owe = (bal ?? <int, double>{}).values.any((v) => v > 0.005);
  final close = await closeFor(owe);
  if (!context.mounted) return;
  await sendNotice(context, a, 'balance', {'balance': balAll(bal), 'close': close});
}

// بعد حفظ سند أو فاتورة: حسب إعداد الحساب (لا ترسل / بعد التأكيد / تلقائي)
Future<void> afterSave(
    BuildContext context, int id, String kind, Map<String, String> vars) async {
  final a = await accRow(id);
  if (a == null) return;
  final phone = ((a['phone'] ?? '') as String).trim();
  final mode = (a['msg_mode'] ?? 'none') as String;
  if (phone.isEmpty || mode == 'none' || a['cat'] == 'boxes') return;
  if (channelsOf(a).isEmpty) return;
  if (!context.mounted) return;
  if (mode == 'confirm' &&
      !await confirm(context, 'تم الحفظ', 'هل تريد إرسال إشعار للعميل؟')) {
    return;
  }
  final bal = (await balances())[id];
  final cur = int.tryParse(vars['cur'] ?? '');
  var k = kind;
  var close = '';
  if (kind == 'voucher') {
    final owe = vars['side'] == 'عليكم';
    k = owe ? 'voucher_dr' : 'voucher_cr';
    close = await closeFor(owe);
  }
  final v = {...vars, 'close': close};
  v['amount'] = pm(vars['amount'] ?? '');
  if (vars.containsKey('rest')) v['rest'] = pm(vars['rest']!);
  v['balance'] = cur != null ? balIn(bal, cur) : balAll(bal);
  if (!context.mounted) return;
  await sendNotice(context, a, k, v);
}

// ---------- شاشة قوالب الرسائل ----------

class MessagesSettingsPage extends StatefulWidget {
  const MessagesSettingsPage({super.key});
  @override
  State<MessagesSettingsPage> createState() => _MessagesSettingsPageState();
}

class _MessagesSettingsPageState extends State<MessagesSettingsPage> {
  final cs = {for (final k in tplNames.keys) k: TextEditingController()};
  final owe = TextEditingController(), paid = TextEditingController();

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    owe.text = await closeFor(true);
    paid.text = await closeFor(false);
    for (final k in tplNames.keys) {
      cs[k]!.text = await getTpl(k);
    }
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    await setSetting('close_owe', owe.text);
    await setSetting('close_paid', paid.text);
    for (final k in tplNames.keys) {
      await setSetting('tpl2_$k', cs[k]!.text);
    }
    if (mounted) snack(context, 'تم الحفظ');
  }

  void reset() {
    owe.text = defCloseOwe;
    paid.text = defClosePaid;
    for (final k in tplNames.keys) {
      cs[k]!.text = defTpl[k]!;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: bar('قوالب الرسائل'),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          gap(TextField(
              controller: owe, decoration: deco('عبارة الختام عند "عليكم" (اشعار دائن)'))),
          gap(TextField(
              controller: paid, decoration: deco('عبارة الختام عند "لكم / واصل" (اشعار مدين)'))),
          const SizedBox(height: 6),
          const Text(tplHelp, style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          for (final k in tplNames.keys)
            gap(TextField(
              controller: cs[k],
              maxLines: 8,
              minLines: 4,
              decoration: deco(tplNames[k]!),
            )),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: FilledButton(onPressed: save, child: const Text('حفظ'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton(
                    onPressed: reset, child: const Text('استعادة الافتراضي'))),
          ]),
        ]),
      );
}
