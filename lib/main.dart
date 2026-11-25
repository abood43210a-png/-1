import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

late Database db;

const cats = {
  'clients': ['العملاء', Icons.groups],
  'suppliers': ['الموردين', Icons.local_shipping],
  'employees': ['الموظفين', Icons.badge],
  'debts': ['الديون', Icons.money_off],
  'expenses': ['الصرفيات', Icons.payments],
  'other': ['أخرى', Icons.shopping_cart],
};

const blue = Color(0xFF0B4DA2);
const orange = Color(0xFFF59E0B);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'accountant.db'),
    version: 1,
    onCreate: (d, _) async {
      await d.execute(
          'CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, cat TEXT)');
      await d.execute(
          'CREATE TABLE tx(id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER, amount REAL, note TEXT, date TEXT)');
    },
  );
  runApp(const App());
}

// المبلغ الموجب = عليه (مدين)، السالب = له (دائن)
Future<List<Map<String, Object?>>> accountsWithBalance([String? cat]) => db.rawQuery(
    'SELECT a.id, a.name, a.cat, COALESCE(SUM(t.amount),0) AS bal '
    'FROM accounts a LEFT JOIN tx t ON t.account_id=a.id '
    '${cat == null ? '' : "WHERE a.cat='$cat'"} GROUP BY a.id ORDER BY a.name');

String fmt(num n) => '${n.abs().toStringAsFixed(2)} ${n < 0 ? 'له' : n > 0 ? 'عليه' : ''}';

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

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, double> totals = {};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final rows = await db.rawQuery(
        'SELECT a.cat, SUM(t.amount) s FROM accounts a JOIN tx t ON t.account_id=a.id GROUP BY a.cat');
    setState(() => totals = {for (var r in rows) r['cat'] as String: (r['s'] as num).toDouble()});
  }

  Future<void> go(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
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
          ]),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.3,
            children: cats.entries.map((e) {
              final v = e.value;
              return InkWell(
                onTap: () => go(AccountsPage(e.key)),
                child: Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: blue, width: 2),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(v[1] as IconData, size: 36, color: blue),
                    Text(v[0] as String,
                        style: const TextStyle(fontWeight: FontWeight.bold, color: blue)),
                    Text(fmt(totals[e.key] ?? 0),
                        style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ]),
                ),
              );
            }).toList(),
          ),
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

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await accountsWithBalance(widget.cat);
    setState(() => rows = r);
  }

  Future<void> add() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('حساب جديد'),
              content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'الاسم')),
              actions: [TextButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('حفظ'))],
            ));
    if (name != null && name.isNotEmpty) {
      await db.insert('accounts', {'name': name, 'cat': widget.cat});
      load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(cats[widget.cat]![0] as String)),
        floatingActionButton: FloatingActionButton(onPressed: add, child: const Icon(Icons.person_add)),
        body: rows.isEmpty
            ? const Center(child: Text('لا توجد حسابات، اضغط + للإضافة'))
            : ListView(
                children: rows
                    .map((r) => ListTile(
                          title: Text(r['name'] as String),
                          trailing: Text(fmt(r['bal'] as num)),
                          onTap: () async {
                            await Navigator.push(context,
                                MaterialPageRoute(builder: (_) => StatementPage(r['id'] as int, r['name'] as String)));
                            load();
                          },
                        ))
                    .toList()),
      );
}

class VoucherPage extends StatefulWidget {
  const VoucherPage({super.key});
  @override
  State<VoucherPage> createState() => _VoucherPageState();
}

class _VoucherPageState extends State<VoucherPage> {
  List<Map<String, Object?>> accts = [];
  int? acct;
  bool receipt = true;
  final amount = TextEditingController(), note = TextEditingController();

  @override
  void initState() {
    super.initState();
    accountsWithBalance().then((r) => setState(() => accts = r));
  }

  Future<void> save() async {
    final a = double.tryParse(amount.text);
    if (acct == null || a == null || a <= 0) return;
    await db.insert('tx', {
      'account_id': acct,
      'amount': receipt ? -a : a,
      'note': note.text,
      'date': DateTime.now().toIso8601String(),
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('سند جديد')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('سند قبض')),
              ButtonSegment(value: false, label: Text('سند دفع')),
            ],
            selected: {receipt},
            onSelectionChanged: (s) => setState(() => receipt = s.first),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            value: acct,
            decoration: const InputDecoration(labelText: 'الحساب'),
            items: accts
                .map((a) => DropdownMenuItem(value: a['id'] as int, child: Text(a['name'] as String)))
                .toList(),
            onChanged: (v) => setState(() => acct = v),
          ),
          TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'المبلغ')),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'البيان')),
          const SizedBox(height: 20),
          FilledButton(onPressed: save, child: const Text('حفظ السند')),
        ]),
      );
}

class PickAccountPage extends StatelessWidget {
  const PickAccountPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('اختر حساباً')),
        body: FutureBuilder(
          future: accountsWithBalance(),
          builder: (c, s) => ListView(
              children: (s.data ?? [])
                  .map((r) => ListTile(
                        title: Text(r['name'] as String),
                        subtitle: Text(cats[r['cat']]![0] as String),
                        trailing: Text(fmt(r['bal'] as num)),
                        onTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => StatementPage(r['id'] as int, r['name'] as String))),
                      ))
                  .toList()),
        ),
      );
}

class StatementPage extends StatelessWidget {
  final int id;
  final String name;
  const StatementPage(this.id, this.name, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('كشف حساب: $name')),
        body: FutureBuilder(
          future: db.query('tx', where: 'account_id=?', whereArgs: [id], orderBy: 'date'),
          builder: (c, s) {
            double run = 0;
            final rows = s.data ?? [];
            return ListView(children: [
              for (final r in rows)
                Builder(builder: (_) {
                  final a = (r['amount'] as num).toDouble();
                  run += a;
                  return ListTile(
                    title: Text(a < 0 ? 'قبض ${(-a).toStringAsFixed(2)}' : 'دفع ${a.toStringAsFixed(2)}'),
                    subtitle: Text('${(r['date'] as String).substring(0, 10)}  ${r['note'] ?? ''}'),
                    trailing: Text('الرصيد: ${fmt(run)}'),
                  );
                }),
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا توجد حركات'))),
            ]);
          },
        ),
      );
}

class DailyPage extends StatelessWidget {
  const DailyPage({super.key});
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return Scaffold(
      appBar: AppBar(title: const Text('الحركة اليومية')),
      body: FutureBuilder(
        future: db.rawQuery(
            "SELECT t.*, a.name FROM tx t JOIN accounts a ON a.id=t.account_id WHERE t.date LIKE '$today%' ORDER BY t.date DESC"),
        builder: (c, s) {
          final rows = s.data ?? [];
          if (rows.isEmpty) return const Center(child: Text('لا توجد حركات اليوم'));
          return ListView(
              children: rows
                  .map((r) => ListTile(
                        title: Text(r['name'] as String),
                        subtitle: Text((r['note'] ?? '') as String),
                        trailing: Text((r['amount'] as num) < 0
                            ? 'قبض ${(-(r['amount'] as num)).toStringAsFixed(2)}'
                            : 'دفع ${(r['amount'] as num).toStringAsFixed(2)}'),
                      ))
                  .toList());
        },
      ),
    );
  }
}
