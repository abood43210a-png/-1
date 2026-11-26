import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'extras.dart';

late Database db;
Map<int, Map<String, Object?>> curs = {};
int defCur = 1;

const blue = Color(0xFF0B4DA2);
const orange = Color(0xFFF59E0B);

const cats = <String, List<Object>>{
  'clients': ['العملاء', Icons.groups],
  'suppliers': ['الموردين', Icons.local_shipping],
  'employees': ['الموظفين', Icons.badge],
  'debts': ['الديون', Icons.money_off],
  'expenses': ['الصرفيات', Icons.payments],
  'other': ['أخرى', Icons.shopping_cart],
  'boxes': ['الصناديق', Icons.account_balance_wallet],
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'accountant2.db'),
    version: 1,
    onCreate: (d, _) async {
      await d.execute(
          'CREATE TABLE currencies(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, symbol TEXT, sell REAL, buy REAL, is_default INTEGER DEFAULT 0)');
      await d.execute(
          'CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, cat TEXT, phone TEXT, ceiling REAL, note TEXT, box_id INTEGER)');
      await d.execute(
          'CREATE TABLE docs(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, date TEXT, note TEXT)');
      await d.execute(
          'CREATE TABLE lines(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id INTEGER, account_id INTEGER, currency_id INTEGER, amount REAL, rate REAL, note TEXT)');
      await d.insert('currencies',
          {'name': 'ريال يمني', 'symbol': 'ر.ي', 'sell': 1.0, 'buy': 1.0, 'is_default': 1});
      await d.insert('accounts', {'name': 'الصندوق الرئيسي', 'cat': 'boxes'});
      await d.insert('accounts', {'name': 'الأرصدة الافتتاحية', 'cat': 'system'});
    },
  );
  await loadCurs();
  runApp(const App());
}

// ---------- أدوات عامة ----------
// المبلغ الموجب = مدين (عليه / وارد للصندوق)، السالب = دائن (له / منصرف)

String nowIso() => DateTime.now().toIso8601String();
String d10(String iso) => iso.substring(0, 10);
String dmy(DateTime d) => '${d.day}/${d.month}/${d.year}';

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

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'المحاسب',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: blue, useMaterial3: true),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
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
    setState(() => totals = t);
  }

  Future<void> go(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    await loadCurs();
    load();
  }

  Widget quick(String t, Widget page, [Color c = blue]) => ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: c, foregroundColor: Colors.white),
        onPressed: () => go(page),
        child: Text(t),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('المحاسب'), backgroundColor: blue, foregroundColor: Colors.white),
        floatingActionButton: FloatingActionButton(
            backgroundColor: orange,
            onPressed: () => go(const VoucherPage()),
            child: const Icon(Icons.add)),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            quick('سند جديد', const VoucherPage()),
            quick('كشف حساب', const PickAccountPage()),
            quick('الحركة اليومية', const DailyPage(), orange),
            quick('العملات', const CurrenciesPage(), orange),
            quick('فاتورة جديدة', const InvoicePage()),
            quick('الفواتير', const InvoicesPage()),
            quick('أرصدة الحسابات', const BalancesPage(), orange),
          ]),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.15,
            children: cats.entries.map((e) {
              final box = e.key == 'boxes';
              return InkWell(
                onTap: () => go(AccountsPage(e.key)),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                      border: Border.all(color: blue, width: 2),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(e.value[1] as IconData, size: 34, color: blue),
                    Text(e.value[0] as String,
                        style: const TextStyle(fontWeight: FontWeight.bold, color: blue)),
                    Text(balText(totals[e.key], box: box),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: box ? Colors.green.shade700 : Colors.red)),
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
        appBar: AppBar(title: Text(widget.acc == null ? 'إضافة جديد' : 'تعديل')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(controller: nameC, decoration: const InputDecoration(labelText: 'الاسم')),
          if (!isBox) ...[
            TextField(
                controller: phoneC,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'رقم التلفون')),
            TextField(
                controller: ceilC,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'سقف المديونية (اختياري)')),
          ],
          TextField(controller: noteC, decoration: const InputDecoration(labelText: 'ملاحظة')),
          if (!isBox)
            DropdownButtonFormField<int?>(
              value: boxes.any((b) => b['id'] == box) ? box : null,
              decoration: const InputDecoration(labelText: 'الصندوق الافتراضي'),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('بدون')),
                ...boxes.map((b) => DropdownMenuItem<int?>(
                    value: b['id'] as int, child: Text(b['name'] as String))),
              ],
              onChanged: (v) => setState(() => box = v),
            ),
          if (widget.acc == null) ...[
            const SizedBox(height: 12),
            const Text('رصيد افتتاحي'),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: openC,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'المبلغ'))),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: cur,
                items: curs.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text('${e.value['symbol']}')))
                    .toList(),
                onChanged: (v) => setState(() => cur = v!),
              ),
            ]),
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
    final phone = (r['phone'] ?? '') as String;
    final ceil = (r['ceiling'] as num?)?.toDouble();
    final m = bal[id];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Column(children: [
        ListTile(
          title: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text([
            if (phone.isNotEmpty) phone,
            if (ceil != null && ceil > 0) 'السقف: ${ceil.toStringAsFixed(0)}',
          ].join('   ')),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(balText(m, box: isBox),
                textAlign: TextAlign.end,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isBox ? Colors.green.shade700 : balColor(m))),
          ),
          onTap: () => open(StatementPage(id, r['name'] as String, widget.cat)),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(
              icon: const Icon(Icons.edit, color: blue),
              onPressed: () => open(AccountFormPage(widget.cat, acc: r))),
          IconButton(
              icon: const Icon(Icons.add_circle, color: blue),
              onPressed: () => open(VoucherPage(acct0: id))),
        ]),
      ]),
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
        ? 'الإجمالي ${sym(c)}: ${((dr[c] ?? 0) - (cr[c] ?? 0)).toStringAsFixed(2)}'
        : '${sym(c)}   عليه: ${(dr[c] ?? 0).toStringAsFixed(2)}   له: ${(cr[c] ?? 0).toStringAsFixed(2)}');
    return Container(
      color: blue,
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      child: Text(lines.isEmpty ? 'لا توجد أرصدة' : lines.join('\n'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = rows.where((r) => (r['name'] as String).contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(cats[widget.cat]![0] as String)),
      floatingActionButton: FloatingActionButton(
          onPressed: () => open(AccountFormPage(widget.cat)), child: const Icon(Icons.add)),
      bottomNavigationBar: footer(l),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: TextField(
              onChanged: (v) => setState(() => q = v),
              decoration:
                  const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم')),
        ),
        Expanded(
            child: l.isEmpty
                ? const Center(child: Text('لا توجد حسابات، اضغط + للإضافة'))
                : ListView(children: l.map(card).toList())),
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
    final b = bal[acct]?[defCur] ?? 0;
    if (cur == defCur && onHim && !isBox && ceil != null && ceil > 0 && b + a > ceil) {
      final ok = await confirm(context, 'تجاوز سقف المديونية',
          'السقف ${ceil.toStringAsFixed(2)} والرصيد بعد السند ${(b + a).toStringAsFixed(2)}. هل تريد المتابعة؟');
      if (!ok) return;
    }
    final rate = cur == defCur ? 1.0 : (double.tryParse(rateC.text) ?? 1.0);
    await postDoc('voucher', note.text, [
      Ln(acct!, cur, onHim ? a : -a, rate),
      Ln(counter!, cur, onHim ? -a : a, rate),
    ]);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final r = find(acct);
    return Scaffold(
      appBar: AppBar(title: const Text('سند جديد')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<int>(
          value: acct,
          decoration: const InputDecoration(labelText: 'الحساب'),
          items: accts
              .map((a) => DropdownMenuItem(value: a['id'] as int, child: Text(label(a))))
              .toList(),
          onChanged: (v) => setState(() {
            acct = v;
            pickCounter();
          }),
        ),
        if (r != null)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: orange, borderRadius: BorderRadius.circular(20)),
            child: Text('الرصيد الحالي: ${balText(bal[acct], box: isBox)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(isBox ? 'وارد' : 'عليه')),
            ButtonSegment(value: false, label: Text(isBox ? 'منصرف' : 'له')),
          ],
          selected: {onHim},
          onSelectionChanged: (s) => setState(() => onHim = s.first),
        ),
        DropdownButtonFormField<int>(
          value: accts.any((a) => a['id'] == counter && a['id'] != acct) ? counter : null,
          decoration: const InputDecoration(labelText: 'الطرف المقابل (صندوق أو حساب)'),
          items: accts
              .where((a) => a['id'] != acct)
              .map((a) => DropdownMenuItem(value: a['id'] as int, child: Text(label(a))))
              .toList(),
          onChanged: (v) => setState(() => counter = v),
        ),
        DropdownButtonFormField<int>(
          value: cur,
          decoration: const InputDecoration(labelText: 'العملة'),
          items: curs.entries
              .map((e) => DropdownMenuItem(
                  value: e.key, child: Text('${e.value['name']} (${e.value['symbol']})')))
              .toList(),
          onChanged: (v) => setState(() {
            cur = v!;
            rateC.text = cur == defCur ? '' : '${curs[cur]!['sell']}';
          }),
        ),
        if (cur != defCur)
          TextField(
              controller: rateC,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'سعر الصرف')),
        TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'المبلغ')),
        TextField(controller: note, decoration: const InputDecoration(labelText: 'البيان')),
        const SizedBox(height: 20),
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
    setState(() {
      all = rows;
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

  @override
  Widget build(BuildContext context) {
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      bottomNavigationBar: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            color: blue,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            child: Text(
                '${isBox ? 'وارد' : 'عليه'}: ${debit.toStringAsFixed(2)}   ${isBox ? 'منصرف' : 'له'}: ${credit.toStringAsFixed(2)}   الرصيد: ${endBal.toStringAsFixed(2)} ${sym(cur)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
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
          ),
        ]),
      ),
      body: ListView(children: [
        Container(
          color: blue.withOpacity(0.08),
          padding: const EdgeInsets.all(14),
          child: Text('الرصيد الحالي: ${balText(totalBal, box: isBox)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
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
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Wrap(spacing: 8, children: [
            chip('الكل', 'all'),
            chip('يومي', 'day'),
            chip('شهري', 'month'),
            chip('سنوي', 'year'),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
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
              : 'رصيد سابق: ${prev.toStringAsFixed(2)} ${sym(cur)}'),
        ),
        for (var i = 0; i < rows.length; i++)
          ListTile(
            isThreeLine: true,
            title: Text(
              '${(rows[i]['amount'] as num) > 0 ? (isBox ? 'وارد' : 'عليه') : (isBox ? 'منصرف' : 'له')}  ${(rows[i]['amount'] as num).abs().toStringAsFixed(2)} ${sym(cur)}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: ((rows[i]['amount'] as num) > 0) == isBox
                      ? Colors.green.shade700
                      : Colors.red),
            ),
            subtitle: Text(
                '${d10(rows[i]['date'] as String)}  ${rows[i]['other'] ?? ''}  ${rows[i]['note'] ?? ''}\nالرصيد: ${bals[i].toStringAsFixed(2)}'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => v == 'e' ? edit(rows[i]) : del(rows[i]),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'e', child: Text('تعديل')),
                PopupMenuItem(value: 'd', child: Text('حذف')),
              ],
            ),
          ),
        if (rows.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا توجد حركات'))),
      ]),
    );
  }
}

class PickAccountPage extends StatelessWidget {
  const PickAccountPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('اختر حساباً')),
        body: FutureBuilder(
          future: db.query('accounts', where: "cat<>'system'", orderBy: 'name'),
          builder: (c, s) => ListView(
              children: (s.data ?? [])
                  .map((r) => ListTile(
                        title: Text(r['name'] as String),
                        subtitle: Text('${cats[r['cat']]?[0] ?? ''}'),
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => StatementPage(
                                    r['id'] as int, r['name'] as String, r['cat'] as String))),
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
      appBar: AppBar(title: const Text('الحركة اليومية')),
      body: FutureBuilder(
        future: db.rawQuery(
            'SELECT d.id AS id, d.note AS note, l1.amount AS amt, l1.currency_id AS cur, '
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
                  .map((r) => ListTile(
                        title: Text('مدين: ${r['dn']}   |   دائن: ${r['cn']}'),
                        subtitle: Text('${r['note'] ?? ''}'),
                        trailing: Text(money((r['amt'] as num).toDouble(), r['cur'] as int)),
                      ))
                  .toList());
        },
      ),
    );
  }
}

// ---------- العملات ----------

class CurrenciesPage extends StatefulWidget {
  const CurrenciesPage({super.key});
  @override
  State<CurrenciesPage> createState() => _CurrenciesPageState();
}

class _CurrenciesPageState extends State<CurrenciesPage> {
  Future<void> reload() async {
    await loadCurs();
    setState(() {});
  }

  Future<void> add() async {
    final v = await ask(context, 'عملة جديدة', ['الاسم', 'الرمز', 'سعر البيع', 'سعر الشراء']);
    if (v == null || v[0].isEmpty) return;
    await db.insert('currencies', {
      'name': v[0],
      'symbol': v[1],
      'sell': double.tryParse(v[2]) ?? 1.0,
      'buy': double.tryParse(v[3]) ?? 1.0,
      'is_default': 0,
    });
    reload();
  }

  Future<void> editRates(Map<String, Object?> c) async {
    final v = await ask(context, '${c['name']}', ['سعر البيع', 'سعر الشراء'],
        ['${c['sell']}', '${c['buy']}']);
    if (v == null) return;
    await db.update(
        'currencies',
        {
          'sell': double.tryParse(v[0]) ?? c['sell'],
          'buy': double.tryParse(v[1]) ?? c['buy'],
        },
        where: 'id=?',
        whereArgs: [c['id']]);
    reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('العملات')),
        floatingActionButton: FloatingActionButton(onPressed: add, child: const Icon(Icons.add)),
        body: ListView(
            children: curs.values
                .map((c) => ListTile(
                      title: Text('${c['name']} (${c['symbol']})'),
                      subtitle: Text(
                          'بيع: ${c['sell']}   شراء: ${c['buy']}  (بالعملة الافتراضية)'),
                      trailing: c['is_default'] == 1 ? const Chip(label: Text('الافتراضية')) : null,
                      onTap: c['is_default'] == 1 ? null : () => editRates(c),
                    ))
                .toList()),
      );
}
