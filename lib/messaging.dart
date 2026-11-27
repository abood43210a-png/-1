import 'dart:async';
import 'package:flutter/material.dart';
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
      'اشعار دائن\n{app}\nعليكم مبلغ {amount}\n{note}\nالرصيد {balance}\nسند رقم {no}\n{date}\n{close}',
  'voucher_cr':
      'اشعار مدين\n{app}\nلكم مبلغ {amount}\n{note}\nالرصيد {balance}\nسند رقم {no}\n{date}\n{close}',
  'invoice':
      '{app}\n{kind} رقم {no}\nحساب: {name}\n{items}\n{discount}\nالإجمالي: {amount}\n{paid}\nالمتبقي: {rest}\nالرصيد {balance}\n{date}',
  'balance': '{app}\nحساب: {name}\nالرصيد {balance}\n{date}\n{close}',
};

const defCloseOwe = 'نرجو المراجعة والتسديد 😊';
const defClosePaid = 'شكراً على حسن تعاملكم 😘';

const tplHelp =
    '{app} اسم المحل   {name} اسم الحساب   {amount} المبلغ   {note} البيان   {balance} الرصيد   {date} التاريخ والوقت   {close} عبارة الختام   {kind} نوع الفاتورة   {no} الرقم   {items} أصناف الفاتورة   {discount} الخصم   {paid} الواصل   {rest} المتبقي';

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

Future<String> getTpl(String k) => getSetting('tpl3_$k', defTpl[k]!);
Future<String> appName() => getSetting('app_name', 'المحاسب');
Future<String> closeFor(bool owe) =>
    getSetting(owe ? 'close_owe' : 'close_paid', owe ? defCloseOwe : defClosePaid);

// مفتاح الدولة لأرقام واتساب
String waCc = '967';

Future<void> loadCc() async {
  final v = (await getSetting('country_code', '967')).replaceAll(RegExp(r'[^0-9]'), '');
  waCc = v.isEmpty ? '967' : v;
}

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

// يحوّل أي صيغة رقم إلى الصيغة الدولية بدون + أو أصفار
String digits(String s) {
  var d = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('00')) {
    d = d.substring(2);
  } else if (d.startsWith('0')) {
    d = waCc + d.replaceFirst(RegExp(r'^0+'), '');
  } else if (!(d.startsWith(waCc) && d.length >= waCc.length + 8)) {
    d = waCc + d;
  }
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

// إرسال ملف (PDF) مباشرة لمحادثة العميل في واتساب (كود أندرويد أصلي)، وإلا قائمة المشاركة
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

// ---------- الإرسال (نص لكل القنوات) ----------

Future<void> sendVia(BuildContext context, Map<String, Object?> a, String text) async {
  final phone = ((a['phone'] ?? '') as String).trim();
  var ch = channelsOf(a);
  if (ch.isEmpty) ch = {'sms'};
  var first = true;
  for (final c in ['sms', 'wa']) {
    if (!ch.contains(c)) continue;
    if (!first) await _waitResume();
    first = false;
    if (!context.mounted) return;
    if (phone.isEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) snack(context, 'لا يوجد رقم تلفون، تم نسخ النص');
      return;
    }
    final ok = await sendMsg(c, phone, text);
    if (!ok && context.mounted) {
      snack(context, c == 'wa' ? 'تعذر فتح واتساب' : 'تعذر فتح تطبيق الرسائل');
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
  await sendVia(context, a, text);
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
  final owe = TextEditingController(),
      paid = TextEditingController(),
      cc = TextEditingController();

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    owe.text = await closeFor(true);
    paid.text = await closeFor(false);
    cc.text = await getSetting('country_code', '967');
    for (final k in tplNames.keys) {
      cs[k]!.text = await getTpl(k);
    }
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    await setSetting('close_owe', owe.text);
    await setSetting('close_paid', paid.text);
    await setSetting('country_code', cc.text.replaceAll(RegExp(r'[^0-9]'), ''));
    await loadCc();
    for (final k in tplNames.keys) {
      await setSetting('tpl3_$k', cs[k]!.text);
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
              controller: cc,
              keyboardType: TextInputType.number,
              decoration: deco('مفتاح الدولة لأرقام واتساب (اليمن 967)'))),
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
