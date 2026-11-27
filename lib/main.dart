import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'extras.dart';
import 'messaging.dart';
import 'settings.dart';
import 'statement_pdf.dart';

late Database db;
Map<int, Map<String, Object?>> curs = {};
int defCur = 1;
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);

const blue = Color(0xFF0B4DA2);
const orange = Color(0xFFF59E0B);

const cats = <String, List<Object>>{
  'clients': ['العملاء', Icons.groups_rounded, Color(0xFF1E6FD9)],
  'suppliers': ['الموردين', Icons.local_shipping_rounded, Color(0xFF7B52D6)],
  'employees': ['الموظفين', Icons.badge_rounded, Color(0xFF0E9F8E)],
  'debts': ['الديون', Icons.money_off_rounded, Color(0xFFE5484D)],
  'expenses': ['الصرفيات', Icons.payments_rounded, Color(0xFFF59E0B)],
  'other': ['أخرى', Icons.category_rounded, Color(0xFF64748B)],
  'boxes': ['الصناديق', Icons.account_balance_wallet_rounded, Color(0xFF16A34A)],
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'accountant2.db'),
    version: 2,
    onCreate: (d, _) async {
      await d.execute(
          'CREATE TABLE currencies(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, symbol TEXT, sell REAL, buy REAL, is_default INTEGER DEFAULT 0)');
      await d.execute(
          "CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, cat TEXT, phone TEXT, ceiling REAL, note TEXT, box_id INTEGER, msg_app TEXT DEFAULT 'sms', msg_mode TEXT DEFAULT 'none')");
      await d.execute(
          'CREATE TABLE docs(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, date TEXT, note TEXT)');
      await d.execute(
          'CREATE TABLE lines(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id INTEGER, account_id INTEGER, currency_id INTEGER, amount REAL, rate REAL, note TEXT)');
      await d.execute('CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT)');
      await d.insert('currencies',
          {'name': 'ريال يمني', 'symbol': 'ر.ي', 'sell': 1.0, 'buy': 1.0, 'is_default': 1});
      await d.insert('accounts', {'name': 'الصندوق الرئيسي', 'cat': 'boxes'});
      await d.insert('accounts', {'name': 'الأرصدة الافتتاحية', 'cat': 'system'});
    },
    onUpgrade: (d, oldV, newV) async {
      if (oldV < 2) {
        await d.execute("ALTER TABLE accounts ADD COLUMN msg_app TEXT DEFAULT 'sms'");
        await d.execute("ALTER TABLE accounts ADD COLUMN msg_mode TEXT DEFAULT 'none'");
        await d.execute('CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT)');
      }
    },
  );
  await loadCurs();
  final th = await getSetting('theme', 'light');
  themeMode.value = th == 'dark' ? ThemeMode.dark : ThemeMode.light;
  runApp(const App());
}

// ---------- أدوات عامة ----------
// المبلغ الموجب = مدين (عليه / وارد للصندوق)، السالب = دائن (له / منصرف)

String nowIso() => DateTime.now().toIso8601String();
String dmy(DateTime d) => '${d.day}/${d.month}/${d.year}';

// وقت بنظام 12 ساعة
String t12(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String dt12(DateTime d) => '${dmy(d)} ${t12(d)}';

// تاريخ + وقت 12 ساعة (الاسم قديم وتستخدمه ملفات أخرى)
String d10(String iso) => dt12(DateTime.parse(iso));

Future<void> loadCurs() async {
  final r = await db.query('currencies', orderBy: 'id');
  curs = {for (final c in r) c['id'] as int: c};
  defCur = r.firstWhere((c) => c['is_default'] == 1)['id'] as int;
}

String sym(int id) => (curs[id]?['symbol'] ?? '') as String;
String money(double v, int cur) => '${v.abs().toStringAsFixed(2)} ${sym(cur)}';

String balText(Map<int, double>? m, {bool box = false}) {
  if (m == null) return '0';
  final parts = <String>[];
  m.forEach((c, v) {
    if (v.abs() < 0.005) return;
    parts.add(box
        ? '${v.toStringAsFixed(2)} ${sym(c)}'
        : '${money(v, c)} ${v > 0 ? 'عليه' : 'له'}');
  });
  return parts.isEmpty ? '0' : parts.join(' | ');
}

Color balColor(Map<int, double>? m) =>
    (m != null && m.values.any((v) => v > 0.005)) ? Colors.red : Colors.green.shade700;

// account_id -> currency_id -> balance
Future<Map<int, Map<int, double>>> balances() async {
  final r = await db.rawQuery(
      'SELECT account_id, currency_id, SUM(amount) AS s FROM lines GROUP BY account_id, currency_id');
  final out = <int, Map<int, double>>{};
  for (final x in r) {
    out.putIfAbsent(x['account_id'] as int, () => <int, double>{})[x['currency_id'] as int] =
        (x['s'] as num).toDouble();
  }
  return out;
}

Future<int> sysId() async {
  final r = await db.query('accounts', where: "cat='system'", limit: 1);
  return r.first['id'] as int;
}

class Ln {
  final int acc, cur;
  final double amt, rate;
  Ln(this.acc, this.cur, this.amt, [this.rate = 1]);
}

// مستند واحد بعدة أسطر: يُحفظ كله أو لا يُحفظ شيء
Future<int> postDoc(String kind, String note, List<Ln> ls) => db.transaction((tr) async {
      final id = await tr.insert('docs', {'kind': kind, 'date': nowIso(), 'note': note});
      for (final l in ls) {
        await tr.insert('lines', {
          'doc_id': id,
          'account_id': l.acc,
          'currency_id': l.cur,
          'amount': l.amt,
          'rate': l.rate,
          'note': note,
        });
      }
      return id;
    });

void snack(BuildContext c, String t) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

Future<bool> confirm(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('لا')),
              TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('نعم')),
            ],
          ));
  return r == true;
}

Future<List<String>?> ask(BuildContext context, String title, List<String> labels,
    [List<String>? init]) {
  final cs = [
    for (var i = 0; i < labels.length; i++)
      TextEditingController(text: init != null && i < init.length ? init[i] : '')
  ];
  return showDialog<List<String>>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < labels.length; i++)
            TextField(
              controller: cs[i],
              autofocus: i == 0,
              keyboardType: (labels[i] == 'المبلغ' || labels[i].contains('سعر'))
                  ? TextInputType.number
                  : TextInputType.text,
              decoration: InputDecoration(labelText: labels[i]),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dctx, cs.map((e) => e.text.trim()).toList()),
            child: const Text('حفظ')),
      ],
    ),
  );
}

// ---------- عناصر الواجهة ----------

InputDecoration deco(String l) => InputDecoration(
    labelText: l,
    filled: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));

AppBar bar(String t, {List<Widget>? actions}) => AppBar(
    title: Text(t),
    centerTitle: true,
    backgroundColor: Colors.transparent,
    scrolledUnderElevation: 0,
    actions: actions);

Widget gap(Widget w) => Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: w);

Widget tile(
        {required Widget child,
        VoidCallback? onTap,
        EdgeInsets margin = const EdgeInsets.symmetric(horizontal: 14, vertical: 6)}) =>
    Card(
        elevation: 0,
        margin: margin,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: InkWell(onTap: onTap, child: child));

Widget pill(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration:
        BoxDecoration(color: c.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
    child: Text(t,
        style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12.5)));

class Avatar extends StatelessWidget {
  final String name;
  final Color? color;
  const Avatar(this.name, {super.key, this.color});
  @override
  Widget build(BuildContext context) {
    final c = color ?? blue;
    return CircleAvatar(
        radius: 22,
        backgroundColor: c.withValues(alpha: .14),
        child: Text(name.isEmpty ? '?' : name.substring(0, 1),
            style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 18)));
  }
}

ThemeData buildTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: b),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(0, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
      chipTheme: const ChipThemeData(shape: StadiumBorder(), side: BorderSide.none),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(shape: StadiumBorder()),
    );

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: themeMode,
        builder: (c, m, _) => MaterialApp(
          title: 'المحاسب',
          debugShowCheckedModeBanner: false,
          themeMode: m,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
          home: const Home(),
        ),
      );
}

// ---------- الرئيسية ----------

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, Map<int, double>> totals = {};
  double cash = 0, owed = 0, owe = 0;
  String shop = 'المحاسب';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await db.rawQuery(
        'SELECT a.cat AS cat, l.currency_id AS cur, SUM(l.amount) AS s FROM lines l '
        'JOIN accounts a ON a.id=l.account_id GROUP BY a.cat, l.currency_id');
    final t = <String, Map<int, double>>{};
    for (final x in r) {
      t.putIfAbsent(x['cat'] as String, () => <int, double>{})[x['cur'] as int] =
          (x['s'] as num).toDouble();
    }
    final accts = await db.query('accounts', columns: ['id', 'cat']);
    final bal = await balances();
    double c = 0, o = 0, w = 0;
    for (final a in accts) {
      final double b = bal[a['id'] as int]?[defCur] ?? 0;
      final cat = a['cat'] as String;
      if (cat == 'system') continue;
      if (cat == 'boxes') {
        c += b;
      } else if (b > 0) {
        o += b;
      } else {
        w += -b;
      }
    }
    final s = await appName();
    if (!mounted) return;
    setState(() {
      totals = t;
      cash = c;
      owed = o;
      owe = w;
      shop = s;
    });
  }

  Future<void> go(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    await loadCurs();
    load();
  }

  Widget stat(String t, double v, Color c) => Column(children: [
        Text(t, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        const SizedBox(height: 4),
        Text('${nf(v)} ${sym(defCur)}',
            style: TextStyle(color: c, fontSize: 17, fontWeight: FontWeight.w800)),
      ]);

  Widget action(IconData ic, String t, Widget page, Color c) => Padding(
        padding: const EdgeInsetsDirectional.only(end: 12),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => go(page),
          child: SizedBox(
              width: 76,
              child: Column(children: [
                Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                        color: c.withValues(alpha: .13), borderRadius: BorderRadius.circular(18)),
                    child: Icon(ic, color: c, size: 28)),
                const SizedBox(height: 6),
                Text(t,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ])),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: bar(shop, actions: [
          IconButton(
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => go(const SettingsPage())),
        ]),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => go(const VoucherPage()),
            icon: const Icon(Icons.add_rounded),
            label: const Text('سند جديد')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF0B4DA2), Color(0xFF2B7BE4)],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft),
                borderRadius: BorderRadius.circular(26),
                boxShadow: [
                  BoxShadow(
                      color: blue.withValues(alpha: .28), blurRadius: 18, offset: const Offset(0, 8))
                ]),
            child: Column(children: [
              const Text('السيولة النقدية',
                  style: TextStyle(color: Colors.white70, fontSize: 13.5)),
              const SizedBox(height: 4),
              Text('${nf(cash)} ${sym(defCur)}',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: stat('مستحقات لنا', owed, const Color(0xFF9BF0B8))),
                Container(width: 1, height: 36, color: Colors.white24),
                Expanded(child: stat('مستحقات علينا', owe, const Color(0xFFFFD08A))),
              ]),
            ]),
          ),
          const SizedBox(height: 18),
          SizedBox(
              height: 104,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                action(Icons.receipt_long_rounded, 'سند جديد', const VoucherPage(), blue),
                action(Icons.description_rounded, 'فاتورة جديدة', const InvoicePage(),
                    const Color(0xFF0E9F8E)),
                action(Icons.article_rounded, 'كشف حساب', const PickAccountPage(),
                    const Color(0xFF7B52D6)),
                action(Icons.folder_rounded, 'الفواتير', const InvoicesPage(), orange),
                action(Icons.account_balance_rounded, 'الأرصدة', const BalancesPage(),
                    const Color(0xFFE5484D)),
                action(Icons.today_rounded, 'الحركة اليومية', const DailyPage(),
                    const Color(0xFF64748B)),
              ])),
          const SizedBox(height: 10),
          const Text('الحسابات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.05,
            children: cats.entries.map((e) {
              final box = e.key == 'boxes';
              final col = e.value[2] as Color;
              return tile(
                margin: EdgeInsets.zero,
                onTap: () => go(AccountsPage(e.key)),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                                color: col.withValues(alpha: .14), shape: BoxShape.circle),
                            child: Icon(e.value[1] as IconData, color: col)),
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.value[0] as String,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(balText(totals[e.key], box: box),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: box ? Colors.green.shade700 : Colors.red)),
                        ]),
                      ]),
                ),
              );
            }).toList(),
          ),
        ]),
      );
}

// ---------- الحسابات ----------

class AccountFormPage extends StatefulWidget {
  final String cat;
  final Map<String, Object?>? acc;
  const AccountFormPage(this.cat, {super.key, this.acc});
  @override
  State<AccountFormPage> createState() => _AccountFormPageState();
}

class _AccountFormPageState extends State<AccountFormPage> {
  final nameC = TextEditingController(),
      phoneC = TextEditingController(),
      ceilC = TextEditingController(),
      noteC = TextEditingController(),
      openC = TextEditingController();
  List<Map<String, Object?>> boxes = [];
  int? box;
  int cur = defCur;
  bool onHim = true;
  Set<String> ch = {'sms', 'wa'};
  String mode = 'auto';
  bool get isBox => widget.cat == 'boxes';

  @override
  void initState() {
    super.initState();
    final a = widget.acc;
    if (a != null) {
      nameC.text = a['name'] as String;
      phoneC.text = (a['phone'] ?? '') as String;
      final c = (a['ceiling'] as num?)?.toDouble();
      ceilC.text = c == null ? '' : c.toString();
      noteC.text = (a['note'] ?? '') as String;
      box = a['box_id'] as int?;
      ch = channelsOf(a);
      mode = (a['msg_mode'] ?? 'none') as String;
    }
    db.query('accounts', where: "cat='boxes'").then((r) => setState(() => boxes = r));
  }

  Future<void> save() async {
    final name = nameC.text.trim();
    if (name.isEmpty) {
      snack(context, 'اكتب الاسم');
      return;
    }
    final data = {
      'name': name,
      'cat': widget.cat,
      'phone': phoneC.text.trim(),
      'ceiling': double.tryParse(ceilC.text),
      'note': noteC.text.trim(),
      'box_id': box,
      'msg_app': ch.join(','),
      'msg_mode': mode,
    };
    if (widget.acc == null) {
      final id = await db.insert('accounts', data);
      final o = double.tryParse(openC.text);
      if (o != null && o > 0) {
        final sys = await sysId();
        final signed = (isBox || onHim) ? o : -o;
        await postDoc('opening', 'رصيد افتتاحي', [Ln(id, cur, signed), Ln(sys, cur, -signed)]);
      }
    } else {
      await db.update('accounts', data, where: 'id=?', whereArgs: [widget.acc!['id']]);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: bar(widget.acc == null ? 'إضافة جديد' : 'تعديل'),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          gap(TextField(controller: nameC, decoration: deco('الاسم'))),
          if (!isBox) ...[
            gap(TextField(
                controller: phoneC,
                keyboardType: TextInputType.phone,
                decoration: deco('رقم التلفون'))),
            gap(TextField(
                controller: ceilC,
                keyboardType: TextInputType.number,
                decoration: deco('سقف المديونية (اختياري)'))),
          ],
          gap(TextField(controller: noteC, decoration: deco('ملاحظة'))),
          if (!isBox)
            gap(DropdownButtonFormField<int?>(
              value: boxes.any((b) => b['id'] == box) ? box : null,
              decoration: deco('الصندوق الافتراضي'),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('بدون')),
                ...boxes.map((b) => DropdownMenuItem<int?>(
                    value: b['id'] as int, child: Text(b['name'] as String))),
              ],
              onChanged: (v) => setState(() => box = v),
            )),
          if (!isBox) ...[
            const SizedBox(height: 10),
            const Text('إرسال الإشعارات عبر (اختر واحداً أو الاثنين)'),
            gap(Wrap(spacing: 8, children: [
              FilterChip(
                  label: const Text('SMS'),
                  selected: ch.contains('sms'),
                  onSelected: (v) => setState(() => v ? ch.add('sms') : ch.remove('sms'))),
              FilterChip(
                  label: const Text('واتساب'),
                  selected: ch.contains('wa'),
                  onSelected: (v) => setState(() => v ? ch.add('wa') : ch.remove('wa'))),
            ])),
            const Text('وقت الإرسال'),
            gap(SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('تلقائي')),
                ButtonSegment(value: 'confirm', label: Text('بعد التأكيد')),
                ButtonSegment(value: 'none', label: Text('لا ترسل')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setState(() => mode = s.first),
            )),
          ],
          if (widget.acc == null) ...[
            const SizedBox(height: 10),
            const Text('رصيد افتتاحي'),
            gap(Row(children: [
              Expanded(
                  child: TextField(
                      controller: openC,
                      keyboardType: TextInputType.number,
                      decoration: deco('المبلغ'))),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: cur,
                items: curs.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text('${e.value['symbol']}')))
                    .toList(),
                onChanged: (v) => setState(() => cur = v!),
              ),
            ])),
            if (!isBox)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('عليه')),
                  ButtonSegment(value: false, label: Text('له')),
                ],
                selected: {onHim},
                onSelectionChanged: (s) => setState(() => onHim = s.first),
              ),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: save, child: const Text('حفظ')),
        ]),
      );
}

class AccountsPage extends StatefulWidget {
  final String cat;
  const AccountsPage(this.cat, {super.key});
  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  List<Map<String, Object?>> rows = [];
  Map<int, Map<int, double>> bal = {};
  String q = '';
  bool get isBox => widget.cat == 'boxes';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final a = await db.query('accounts',
        where: 'cat=?', whereArgs: [widget.cat], orderBy: 'name');
    final b = await balances();
    setState(() {
      rows = a;
      bal = b;
    });
  }

  Future<void> open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    load();
  }

  Widget card(Map<String, Object?> r) {
    final id = r['id'] as int;
    final name = r['name'] as String;
    final phone = (r['phone'] ?? '') as String;
    final ceil = (r['ceiling'] as num?)?.toDouble();
    final m = bal[id];
    final col = cats[widget.cat]![2] as Color;
    final sub = [
      if (phone.isNotEmpty) phone,
      if (ceil != null && ceil > 0) 'السقف ${nf(ceil)}',
    ].join('  •  ');
    return tile(
      onTap: () => open(StatementPage(id, name, widget.cat)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Row(children: [
            Avatar(name, color: col),
            const SizedBox(width: 12),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              if (sub.isNotEmpty)
                Text(sub,
                    style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
            ])),
            pill(balText(m, box: isBox), isBox ? Colors.green.shade700 : balColor(m)),
          ]),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton.filledTonal(
                icon: const Icon(Icons.edit_rounded),
                onPressed: () => open(AccountFormPage(widget.cat, acc: r))),
            if (!isBox) ...[
              IconButton.filledTonal(
                  icon: const Icon(Icons.call_rounded),
                  onPressed: phone.isEmpty ? null : () => callPhone(phone)),
              IconButton.filledTonal(
                  icon: const Icon(Icons.send_rounded),
                  onPressed: phone.isEmpty ? null : () => sendBalanceMsg(context, id)),
            ],
            IconButton.filledTonal(
                icon: const Icon(Icons.add_rounded),
                onPressed: () => open(VoucherPage(acct0: id))),
          ]),
        ]),
      ),
    );
  }

  Widget footer(List<Map<String, Object?>> l) {
    final dr = <int, double>{}, cr = <int, double>{};
    for (final r in l) {
      final m = bal[r['id'] as int];
      if (m == null) continue;
      m.forEach((c, v) {
        if (v > 0) dr[c] = (dr[c] ?? 0) + v;
        if (v < 0) cr[c] = (cr[c] ?? 0) - v;
      });
    }
    final ids = {...dr.keys, ...cr.keys};
    final lines = ids.map((c) => isBox
        ? 'الإجمالي ${nf((dr[c] ?? 0) - (cr[c] ?? 0))} ${sym(c)}'
        : '${sym(c)}   عليه ${nf(dr[c] ?? 0)}   •   له ${nf(cr[c] ?? 0)}');
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        padding: const EdgeInsets.all(14),
        width: double.infinity,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(18)),
        child: Text(lines.isEmpty ? 'لا توجد أرصدة' : lines.join('\n'),
            textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = rows.where((r) => (r['name'] as String).contains(q)).toList();
    return Scaffold(
      appBar: bar(cats[widget.cat]![0] as String),
      floatingActionButton: FloatingActionButton(
          onPressed: () => open(AccountFormPage(widget.cat)),
          child: const Icon(Icons.add_rounded)),
      bottomNavigationBar: footer(l),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
          child: TextField(
              onChanged: (v) => setState(() => q = v),
              decoration: deco('بحث بالاسم').copyWith(prefixIcon: const Icon(Icons.search_rounded))),
        ),
        Expanded(
            child: l.isEmpty
                ? const Center(child: Text('لا توجد حسابات، اضغط + للإضافة'))
                : ListView(padding: const EdgeInsets.only(bottom: 90), children: l.map(card).toList())),
      ]),
    );
  }
}

// ---------- السند ----------

class VoucherPage extends StatefulWidget {
  final int? acct0;
  final bool onHim0;
  const VoucherPage({super.key, this.acct0, this.onHim0 = true});
  @override
  State<VoucherPage> createState() => _VoucherPageState();
}

class _VoucherPageState extends State<VoucherPage> {
  List<Map<String, Object?>> accts = [];
  Map<int, Map<int, double>> bal = {};
  int? acct, counter;
  int cur = defCur;
  bool onHim = true;
  final amount = TextEditingController(),
      note = TextEditingController(),
      rateC = TextEditingController();

  @override
  void initState() {
    super.initState();
    onHim = widget.onHim0;
    init();
  }

  Future<void> init() async {
    final a = await db.query('accounts', where: "cat<>'system'", orderBy: 'name');
    final b = await balances();
    if (!mounted) return;
    setState(() {
      accts = a;
      bal = b;
      acct = widget.acct0;
      pickCounter();
    });
  }

  Map<String, Object?>? find(int? id) {
    for (final a in accts) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  bool get isBox => find(acct)?['cat'] == 'boxes';

  void pickCounter() {
    final r = find(acct);
    if (r == null) {
      counter = null;
      return;
    }
    int? c = r['box_id'] as int?;
    if (c == null || c == acct) {
      c = null;
      for (final a in accts) {
        if (a['cat'] == 'boxes' && a['id'] != acct) {
          c = a['id'] as int;
          break;
        }
      }
    }
    counter = c;
  }

  String label(Map<String, Object?> a) => '${a['name']} (${cats[a['cat']]?[0] ?? ''})';

  Future<void> save() async {
    final a = double.tryParse(amount.text);
    if (acct == null || counter == null || a == null || a <= 0) {
      snack(context, 'اختر الحساب والطرف المقابل واكتب المبلغ');
      return;
    }
    final r = find(acct)!;
    final ceil = (r['ceiling'] as num?)?.toDouble();
    final double b = bal[acct]?[defCur] ?? 0;
    if (cur == defCur && onHim && !isBox && ceil != null && ceil > 0 && b + a > ceil) {
      final ok = await confirm(context, 'تجاوز سقف المديونية',
          'السقف ${ceil.toStringAsFixed(2)} والرصيد بعد السند ${(b + a).toStringAsFixed(2)}. هل تريد المتابعة؟');
      if (!ok) return;
    }
    final rate = cur == defCur ? 1.0 : (double.tryParse(rateC.text) ?? 1.0);
    final nt = note.text.trim().isNotEmpty
        ? note.text.trim()
        : (isBox ? '' : (onHim ? 'باقي حساب ${r['name']}' : 'واصل باقي حساب ${r['name']}'));
    final docId = await postDoc('voucher', nt, [
      Ln(acct!, cur, onHim ? a : -a, rate),
      Ln(counter!, cur, onHim ? -a : a, rate),
    ]);
    if (!mounted) return;
    if (!isBox) {
      await afterSave(context, acct!, 'voucher', {
        'amount': money(a, cur),
        'side': onHim ? 'عليكم' : 'لكم',
        'note': nt,
        'cur': '$cur',
        'no': '$docId',
      });
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final r = find(acct);
    return Scaffold(
      appBar: bar('سند جديد'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        gap(DropdownButtonFormField<int>(
          value: acct,
          decoration: deco('الحساب'),
          items: accts
              .map((a) => DropdownMenuItem(value: a['id'] as int, child: Text(label(a))))
              .toList(),
          onChanged: (v) => setState(() {
            acct = v;
            pickCounter();
          }),
        )),
        if (r != null)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: orange.withValues(alpha: .16), borderRadius: BorderRadius.circular(16)),
            child: Text('الرصيد الحالي: ${balText(bal[acct], box: isBox)}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        gap(SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(isBox ? 'وارد' : 'عليه')),
            ButtonSegment(value: false, label: Text(isBox ? 'منصرف' : 'له')),
          ],
          selected: {onHim},
          onSelectionChanged: (s) => setState(() => onHim = s.first),
        )),
        gap(DropdownButtonFormField<int>(
          value: accts.any((a) => a['id'] == counter && a['id'] != acct) ? counter : null,
          decoration: deco('الطرف المقابل (صندوق أو حساب)'),
          items: accts
              .where((a) => a['id'] != acct)
              .map((a) => DropdownMenuItem(value: a['id'] as int, child: Text(label(a))))
              .toList(),
          onChanged: (v) => setState(() => counter = v),
        )),
        gap(DropdownButtonFormField<int>(
          value: cur,
          decoration: deco('العملة'),
          items: curs.entries
              .map((e) => DropdownMenuItem(
                  value: e.key, child: Text('${e.value['name']} (${e.value['symbol']})')))
              .toList(),
          onChanged: (v) => setState(() {
            cur = v!;
            rateC.text = cur == defCur ? '' : '${curs[cur]!['sell']}';
          }),
        )),
        if (cur != defCur)
          gap(TextField(
              controller: rateC,
              keyboardType: TextInputType.number,
              decoration: deco('سعر الصرف'))),
        gap(TextField(
            controller: amount, keyboardType: TextInputType.number, decoration: deco('المبلغ'))),
        gap(TextField(
            controller: note, decoration: deco('البيان (إذا تركته فارغاً يُكتب تلقائياً)'))),
        const SizedBox(height: 16),
        FilledButton(onPressed: save, child: const Text('حفظ')),
      ]),
    );
  }
}

// ---------- كشف الحساب ----------

class StatementPage extends StatefulWidget {
  final int id;
  final String name, cat;
  const StatementPage(this.id, this.name, this.cat, {super.key});
  @override
  State<StatementPage> createState() => _StatementPageState();
}

class _StatementPageState extends State<StatementPage> {
  List<Map<String, Object?>> all = [];
  Map<int, double> totalBal = {};
  Map<String, Object?>? acc;
  int cur = defCur;
  String period = 'all';
  DateTime? from, to;
  bool prevBal = false;
  bool get isBox => widget.cat == 'boxes';

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    final r = await db.rawQuery(
        'SELECT currency_id FROM lines WHERE account_id=? ORDER BY id DESC LIMIT 1',
        [widget.id]);
    if (r.isNotEmpty) cur = r.first['currency_id'] as int;
    await load();
  }

  Future<void> load() async {
    final rows = await db.rawQuery(
        'SELECT l.id AS id, l.doc_id AS doc_id, l.amount AS amount, d.date AS date, d.note AS note, '
        '(SELECT a2.name FROM lines l2 JOIN accounts a2 ON a2.id=l2.account_id '
        'WHERE l2.doc_id=l.doc_id AND l2.id<>l.id LIMIT 1) AS other '
        'FROM lines l JOIN docs d ON d.id=l.doc_id '
        'WHERE l.account_id=? AND l.currency_id=? ORDER BY d.date, l.id',
        [widget.id, cur]);
    final tb = await db.rawQuery(
        'SELECT currency_id, SUM(amount) AS s FROM lines WHERE account_id=? GROUP BY currency_id',
        [widget.id]);
    final a = await accRow(widget.id);
    if (!mounted) return;
    setState(() {
      all = rows;
      acc = a;
      totalBal = {
        for (final x in tb) x['currency_id'] as int: (x['s'] as num).toDouble()
      };
    });
  }

  void setPeriod(String p) {
    final n = DateTime.now();
    setState(() {
      period = p;
      if (p == 'all') {
        from = null;
        to = null;
      } else if (p == 'day') {
        from = DateTime(n.year, n.month, n.day);
        to = from;
      } else if (p == 'month') {
        from = DateTime(n.year, n.month, 1);
        to = DateTime(n.year, n.month + 1, 0);
      } else if (p == 'year') {
        from = DateTime(n.year, 1, 1);
        to = DateTime(n.year, 12, 31);
      }
    });
  }

  Future<void> pickDate(bool isFrom) async {
    final init = (isFrom ? from : to) ?? DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: init,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100));
    if (d == null) return;
    setState(() {
      period = 'custom';
      if (isFrom) {
        from = d;
      } else {
        to = d;
      }
    });
  }

  String get fromIso =>
      from == null ? '' : DateTime(from!.year, from!.month, from!.day).toIso8601String();
  String get toIso => to == null
      ? '\uffff'
      : DateTime(to!.year, to!.month, to!.day, 23, 59, 59).toIso8601String();

  double get prev => from == null
      ? 0
      : all
          .where((r) => (r['date'] as String).compareTo(fromIso) < 0)
          .fold<double>(0, (s, r) => s + (r['amount'] as num).toDouble());

  List<Map<String, Object?>> get shown => all.where((r) {
        final d = r['date'] as String;
        return d.compareTo(fromIso) >= 0 && d.compareTo(toIso) <= 0;
      }).toList();

  String stText() {
    final rows = shown;
    var run = prevBal ? prev : 0.0;
    final bals = <double>[];
    for (final r in rows) {
      run += (r['amount'] as num).toDouble();
      bals.add(run);
    }
    final b = StringBuffer('كشف حساب: ${widget.name}\n');
    if (from != null) b.write('الفترة: ${dmy(from!)} - ${dmy(to ?? DateTime.now())}\n');
    final start = rows.length > 30 ? rows.length - 30 : 0;
    for (var i = start; i < rows.length; i++) {
      final a = (rows[i]['amount'] as num).toDouble();
      b.write(
          '${d10(rows[i]['date'] as String)}  ${a > 0 ? 'عليكم' : 'لكم'} ${nf(a.abs())}  | ${nf(bals[i])}\n');
    }
    b.write('الرصيد الحالي: ${balMsg(totalBal)}');
    return b.toString();
  }

  Future<void> sendStatement({bool forcePdf = false}) async {
    final a = acc;
    if (a == null) return;
    final phone = ((a['phone'] ?? '') as String).trim();
    final daily =
        period == 'day' || (from != null && to != null && DateUtils.isSameDay(from, to));
    final rows = shown;
    final pv = prev;
    if (daily && !forcePdf) {
      await sendVia(
          context,
          a,
          stText(),
          () => statementImage(context,
              customer: widget.name, cur: cur, from: from, to: to, prev: pv, rows: rows));
    } else {
      final path = await statementPdf(context,
          customer: widget.name, cur: cur, from: from, to: to, prev: pv, rows: rows);
      if (!mounted) return;
      if (path == null) {
        snack(context, 'تعذر تجهيز الملف');
        return;
      }
      await sendFileWa(context, phone, path, 'application/pdf', 'كشف حساب ${widget.name}');
    }
  }

  Future<void> open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    load();
  }

  Future<void> edit(Map<String, Object?> r) async {
    final a0 = (r['amount'] as num).toDouble();
    final v = await ask(context, 'تعديل الحركة', ['المبلغ', 'البيان'],
        [a0.abs().toString(), (r['note'] ?? '') as String]);
    if (v == null) return;
    final a = double.tryParse(v[0]);
    if (a == null || a <= 0) return;
    final na = a0 < 0 ? -a : a;
    await db.transaction((tr) async {
      await tr.update('lines', {'amount': na}, where: 'id=?', whereArgs: [r['id']]);
      await tr.update('lines', {'amount': -na},
          where: 'doc_id=? AND id<>?', whereArgs: [r['doc_id'], r['id']]);
      await tr.update('docs', {'note': v[1]}, where: 'id=?', whereArgs: [r['doc_id']]);
    });
    load();
  }

  Future<void> del(Map<String, Object?> r) async {
    if (!await confirm(context, 'حذف الحركة', 'سيُحذف السند بجميع أطرافه. هل أنت متأكد؟')) {
      return;
    }
    await db.transaction((tr) async {
      await tr.delete('lines', where: 'doc_id=?', whereArgs: [r['doc_id']]);
      await tr.delete('docs', where: 'id=?', whereArgs: [r['doc_id']]);
    });
    load();
  }

  Widget chip(String label, String p) => ChoiceChip(
      label: Text(label), selected: period == p, onSelected: (_) => setPeriod(p));

  Widget rowTile(Map<String, Object?> r, double b, String inW, String outW) {
    final a = (r['amount'] as num).toDouble();
    final isIn = a > 0;
    final c = (isIn == isBox) ? Colors.green.shade700 : Colors.red;
    final txt = [r['other'], r['note']]
        .where((e) => e != null && '$e'.isNotEmpty)
        .join('  ');
    return tile(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: ListTile(
        isThreeLine: true,
        leading: CircleAvatar(
            backgroundColor: c.withValues(alpha: .12),
            child: Icon(isIn ? Icons.south_west_rounded : Icons.north_east_rounded,
                color: c, size: 20)),
        title: Text('${isIn ? inW : outW}  ${nf(a.abs())} ${sym(cur)}',
            style: TextStyle(fontWeight: FontWeight.w800, color: c)),
        subtitle: Text(
            [d10(r['date'] as String), if (txt.isNotEmpty) txt, 'الرصيد ${nf(b)} ${sym(cur)}']
                .join('\n')),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => v == 'e' ? edit(r) : del(r),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'e', child: Text('تعديل')),
            PopupMenuItem(value: 'd', child: Text('حذف')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = shown;
    var run = prevBal ? prev : 0.0;
    final bals = <double>[];
    double debit = 0, credit = 0;
    for (final r in rows) {
      final a = (r['amount'] as num).toDouble();
      run += a;
      bals.add(run);
      if (a > 0) debit += a;
      if (a < 0) credit += -a;
    }
    final endBal = (prevBal ? prev : 0.0) + debit - credit;
    final inW = isBox ? 'وارد' : 'عليه';
    final outW = isBox ? 'منصرف' : 'له';
    return Scaffold(
      appBar: bar(widget.name, actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (v) {
            if (v == 'send') sendStatement();
            if (v == 'pdf') sendStatement(forcePdf: true);
            if (v == 'copy') {
              Clipboard.setData(ClipboardData(text: stText()));
              snack(context, 'تم نسخ الكشف');
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'send', child: Text('إرسال للعميل')),
            PopupMenuItem(value: 'pdf', child: Text('كشف PDF')),
            PopupMenuItem(value: 'copy', child: Text('نسخ كنص')),
          ],
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Text(
                  '$inW ${nf(debit)}   •   $outW ${nf(credit)}   •   الرصيد ${nf(endBal)} ${sym(cur)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: FilledButton(
                      onPressed: () => open(VoucherPage(acct0: widget.id, onHim0: isBox)),
                      child: Text(isBox ? 'سحب' : 'سند له'))),
              const SizedBox(width: 8),
              Expanded(
                  child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: orange),
                      onPressed: () => open(VoucherPage(acct0: widget.id, onHim0: !isBox)),
                      child: Text(isBox ? 'إيداع' : 'سند عليه'))),
            ]),
          ]),
        ),
      ),
      body: ListView(children: [
        tile(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Avatar(widget.name, color: cats[widget.cat]?[2] as Color?),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(widget.name,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
              pill(balText(totalBal, box: isBox),
                  isBox ? Colors.green.shade700 : balColor(totalBal)),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Wrap(
              spacing: 8,
              children: curs.entries
                  .map((e) => ChoiceChip(
                      label: Text('${e.value['name']}'),
                      selected: cur == e.key,
                      onSelected: (_) {
                        cur = e.key;
                        load();
                      }))
                  .toList()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
          child: Wrap(spacing: 8, children: [
            chip('الكل', 'all'),
            chip('يومي', 'day'),
            chip('شهري', 'month'),
            chip('سنوي', 'year'),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
          child: Row(children: [
            Expanded(
                child: OutlinedButton(
                    onPressed: () => pickDate(true),
                    child: Text('من: ${from == null ? '-' : dmy(from!)}'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton(
                    onPressed: () => pickDate(false),
                    child: Text('إلى: ${to == null ? '-' : dmy(to!)}'))),
          ]),
        ),
        CheckboxListTile(
          value: prevBal,
          onChanged: (v) => setState(() => prevBal = v ?? false),
          title: Text(from == null
              ? 'رصيد سابق (حدد تاريخ البداية)'
              : 'رصيد سابق: ${nf(prev)} ${sym(cur)}'),
        ),
        for (var i = 0; i < rows.length; i++) rowTile(rows[i], bals[i], inW, outW),
        if (rows.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا توجد حركات'))),
        const SizedBox(height: 12),
      ]),
    );
  }
}

class PickAccountPage extends StatelessWidget {
  const PickAccountPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: bar('اختر حساباً'),
        body: FutureBuilder(
          future: db.query('accounts', where: "cat<>'system'", orderBy: 'name'),
          builder: (c, s) => ListView(
              children: (s.data ?? [])
                  .map((r) => tile(
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => StatementPage(
                                    r['id'] as int, r['name'] as String, r['cat'] as String))),
                        child: ListTile(
                          leading: Avatar(r['name'] as String,
                              color: cats[r['cat']]?[2] as Color?),
                          title: Text(r['name'] as String,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${cats[r['cat']]?[0] ?? ''}'),
                        ),
                      ))
                  .toList()),
        ),
      );
}

// ---------- الحركة اليومية ----------

class DailyPage extends StatelessWidget {
  const DailyPage({super.key});
  @override
  Widget build(BuildContext context) {
    final today = nowIso().substring(0, 10);
    return Scaffold(
      appBar: bar('الحركة اليومية'),
      body: FutureBuilder(
        future: db.rawQuery(
            'SELECT d.id AS id, d.note AS note, d.date AS date, l1.amount AS amt, l1.currency_id AS cur, '
            'a1.name AS dn, a2.name AS cn FROM docs d '
            'JOIN lines l1 ON l1.doc_id=d.id AND l1.amount>0 '
            'JOIN accounts a1 ON a1.id=l1.account_id '
            'JOIN lines l2 ON l2.doc_id=d.id AND l2.amount<0 '
            'JOIN accounts a2 ON a2.id=l2.account_id '
            'WHERE d.date LIKE ? ORDER BY d.date DESC',
            ['$today%']),
        builder: (c, s) {
          final rows = s.data ?? [];
          if (rows.isEmpty) return const Center(child: Text('لا توجد حركات اليوم'));
          return ListView(
              children: rows
                  .map((r) => tile(
                        child: ListTile(
                          isThreeLine: true,
                          title: Text('مدين: ${r['dn']}   |   دائن: ${r['cn']}',
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                              '${t12(DateTime.parse(r['date'] as String))}\n${r['note'] ?? ''}'),
                          trailing: Text(money((r['amt'] as num).toDouble(), r['cur'] as int),
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      ))
                  .toList());
        },
      ),
    );
  }
}
