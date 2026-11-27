import 'package:flutter/material.dart';
import 'main.dart';
import 'messaging.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final shopC = TextEditingController();

  @override
  void initState() {
    super.initState();
    appName().then((v) {
      if (mounted) setState(() => shopC.text = v);
    });
  }

  Future<void> setTheme(ThemeMode m) async {
    themeMode.value = m;
    await setSetting('theme', m == ThemeMode.dark ? 'dark' : 'light');
    if (mounted) setState(() {});
  }

  Future<void> saveShop() async {
    final n = shopC.text.trim();
    await setSetting('app_name', n.isEmpty ? 'المحاسب' : n);
    if (mounted) snack(context, 'تم حفظ الاسم');
  }

  Future<void> editCur(Map<String, Object?>? c) async {
    final isDef = c != null && c['is_default'] == 1;
    final v = await ask(
        context,
        c == null ? 'عملة جديدة' : 'تعديل العملة',
        ['الاسم', 'الرمز', 'سعر البيع', 'سعر الشراء'],
        c == null ? null : ['${c['name']}', '${c['symbol']}', '${c['sell']}', '${c['buy']}']);
    if (v == null || v[0].isEmpty) return;
    final data = {
      'name': v[0],
      'symbol': v[1],
      'sell': isDef ? 1.0 : (double.tryParse(v[2]) ?? 1.0),
      'buy': isDef ? 1.0 : (double.tryParse(v[3]) ?? 1.0),
    };
    if (c == null) {
      await db.insert('currencies', {...data, 'is_default': 0});
    } else {
      await db.update('currencies', data, where: 'id=?', whereArgs: [c['id']]);
    }
    await loadCurs();
    if (mounted) setState(() {});
  }

  Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: bar('الإعدادات'),
        body: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
          section('المظهر'),
          tile(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_rounded),
                        label: Text('نهاري')),
                    ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_rounded),
                        label: Text('ليلي')),
                  ],
                  selected: {themeMode.value},
                  onSelectionChanged: (s) => setTheme(s.first),
                ),
              ),
            ),
          ),
          section('اسم المحل / البرنامج (يظهر في الإشعارات والكشوف)'),
          tile(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [
                TextField(controller: shopC, decoration: deco('الاسم')),
                const SizedBox(height: 10),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(onPressed: saveShop, child: const Text('حفظ الاسم'))),
              ]),
            ),
          ),
          section('العملات'),
          for (final c in curs.values)
            tile(
              onTap: () => editCur(c),
              child: ListTile(
                leading: Avatar('${c['symbol']}'.isEmpty ? '؟' : '${c['symbol']}'),
                title: Text('${c['name']} (${c['symbol']})',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(c['is_default'] == 1
                    ? 'العملة الافتراضية'
                    : 'بيع ${c['sell']}   |   شراء ${c['buy']}'),
                trailing: const Icon(Icons.edit_rounded),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: OutlinedButton.icon(
                onPressed: () => editCur(null),
                icon: const Icon(Icons.add_rounded),
                label: const Text('إضافة عملة')),
          ),
          section('الرسائل'),
          tile(
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const MessagesSettingsPage())),
            child: const ListTile(
              leading: Icon(Icons.sms_rounded),
              title: Text('قوالب الرسائل وعبارات الختام',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              trailing: Icon(Icons.chevron_left_rounded),
            ),
          ),
        ]),
      );
}
