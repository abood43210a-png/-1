import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'main.dart';

const tplNames = {
  'voucher': 'رسالة السند',
  'balance': 'رسالة الرصيد / المطالبة',
  'invoice': 'رسالة الفاتورة',
};

const defTpl = {
  'voucher': 'المحاسب\nحساب: {name}\n{side} مبلغ {amount}\n{note}\nالرصيد: {balance}',
  'balance': 'المحاسب\nحساب: {name}\nرصيدكم الحالي: {balance}\nنرجو المراجعة والتسديد.',
  'invoice':
      'المحاسب\nحساب: {name}\n{kind} رقم {no}\nالإجمالي: {amount}\nالمتبقي: {rest}\nالرصيد: {balance}',
};

const tplHelp =
    '{name} اسم الحساب   {amount} المبلغ   {side} عليكم/لكم   {note} البيان   {balance} الرصيد   {date} التاريخ   {kind} نوع الفاتورة   {no} رقم الفاتورة   {rest} المتبقي';

Future<String> getTpl(String k) async {
  final r = await db.query('settings', where: 'k=?', whereArgs: [k]);
  return r.isEmpty ? defTpl[k]! : r.first['v'] as String;
}

Future<void> setTpl(String k, String v) async {
  await db.insert('settings', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
}

String fill(String tpl, Map<String, String> vars) {
  var s = tpl;
  vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
  s = s.replaceAll(RegExp(r'\{[a-z]+\}'), '');
  return s.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
}

// نص الرصيد كما يُكتب للعميل: عليكم / لكم
String balMsg(Map<int, double>? m) {
  if (m == null) return '0';
  final parts = <String>[];
  m.forEach((c, v) {
    if (v.abs() >= 0.005) parts.add('${money(v, c)} ${v > 0 ? 'عليكم' : 'لكم'}');
  });
  return parts.isEmpty ? '0' : parts.join(' | ');
}

String digits(String s) {
  var d = s.replaceAll(RegExp(r'[^0-9]'), '');
  // جوال يمني من 9 خانات يبدأ بـ 7: نضيف مفتاح الدولة لواتساب
  if (d.length == 9 && d.startsWith('7')) d = '967$d';
  return d;
}

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

Future<void> deliver(BuildContext context, Map<String, Object?> a, String text) async {
  final ok =
      await sendMsg((a['msg_app'] ?? 'sms') as String, (a['phone'] ?? '') as String, text);
  if (!ok && context.mounted) snack(context, 'تعذر فتح تطبيق الرسائل');
}

// إرسال رصيد الحساب (زر الرسالة في البطاقة)
Future<void> sendBalanceMsg(BuildContext context, int id) async {
  final a = await accRow(id);
  if (a == null) return;
  final phone = (a['phone'] ?? '') as String;
  if (phone.isEmpty) {
    if (context.mounted) snack(context, 'لا يوجد رقم تلفون لهذا الحساب');
    return;
  }
  final bal = (await balances())[id];
  final text = fill(await getTpl('balance'),
      {'name': a['name'] as String, 'balance': balMsg(bal), 'date': dmy(DateTime.now())});
  if (!context.mounted) return;
  await deliver(context, a, text);
}

// بعد حفظ سند أو فاتورة: حسب إعداد الحساب (لا ترسل / بعد التأكيد / تلقائي)
Future<void> afterSave(
    BuildContext context, int id, String kind, Map<String, String> vars) async {
  final a = await accRow(id);
  if (a == null) return;
  final phone = (a['phone'] ?? '') as String;
  final mode = (a['msg_mode'] ?? 'none') as String;
  if (phone.isEmpty || mode == 'none' || a['cat'] == 'boxes') return;
  if (!context.mounted) return;
  if (mode == 'confirm' &&
      !await confirm(context, 'تم الحفظ', 'هل تريد إرسال رسالة للعميل؟')) {
    return;
  }
  final bal = (await balances())[id];
  final text = fill(await getTpl(kind), {
    ...vars,
    'name': a['name'] as String,
    'balance': balMsg(bal),
    'date': dmy(DateTime.now()),
  });
  if (!context.mounted) return;
  await deliver(context, a, text);
}

// إرسال نص حر (كشف الحساب). بدون رقم: يُنسخ النص
Future<void> sendText(BuildContext context, int id, String text) async {
  final a = await accRow(id);
  final phone = (a?['phone'] ?? '') as String;
  if (a == null || phone.isEmpty) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) snack(context, 'لا يوجد رقم تلفون، تم نسخ النص');
    return;
  }
  await deliver(context, a, text);
}

class MessagesSettingsPage extends StatefulWidget {
  const MessagesSettingsPage({super.key});
  @override
  State<MessagesSettingsPage> createState() => _MessagesSettingsPageState();
}

class _MessagesSettingsPageState extends State<MessagesSettingsPage> {
  final cs = {for (final k in tplNames.keys) k: TextEditingController()};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    for (final k in tplNames.keys) {
      cs[k]!.text = await getTpl(k);
    }
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    for (final k in tplNames.keys) {
      await setTpl(k, cs[k]!.text);
    }
    if (mounted) snack(context, 'تم حفظ القوالب');
  }

  void reset() {
    for (final k in tplNames.keys) {
      cs[k]!.text = defTpl[k]!;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('قوالب الرسائل')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(tplHelp, style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          for (final k in tplNames.keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: cs[k],
                maxLines: 6,
                minLines: 3,
                decoration: InputDecoration(
                    labelText: tplNames[k], border: const OutlineInputBorder()),
              ),
            ),
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
