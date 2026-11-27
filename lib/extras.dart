import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'main.dart';
import 'messaging.dart';

bool _ready = false;

Future<void> ensureTables() async {
  if (_ready) return;
  await db.execute(
      'CREATE TABLE IF NOT EXISTS invoices(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id INTEGER, pay_doc_id INTEGER, account_id INTEGER, kind TEXT, currency_id INTEGER, total REAL, paid REAL, discount REAL, note TEXT, date TEXT)');
  await db.execute(
      'CREATE TABLE IF NOT EXISTS invoice_items(id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id INTEGER, name TEXT, qty REAL, price REAL)');
  _ready = true;
}

// حساب نظام (المبيعات / المشتريات) يُنشأ عند أول استخدام
Future<int> sysAcc(String name) async {
  final r = await db.query('accounts',
      where: "cat='system' AND name=?", whereArgs: [name], limit: 1);
  if (r.isNotEmpty) return r.first['id'] as int;
  return db.insert('accounts', {'name': name, 'cat': 'system'});
}

Future<int> _post(Transaction tr, String kind, String note, List<Ln> ls) async {
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
}

// ---------------- الفاتورة ----------------

class _Row {
  final n = TextEditingController();
  final q = TextEditingController(text: '1');
  final p = TextEditingController();
  double get total => (double.tryParse(q.text) ?? 0) * (double.tryParse(p.text) ?? 0);
}

class InvoicePage extends StatefulWidget {
  final int? acct0;
  const InvoicePage({super.key, this.acct0});
  @override
  State<InvoicePage> createState() => _InvoicePageState();
}

class _InvoicePageState extends State<InvoicePage> {
  List<Map<String, Object?>> parties = [], boxes = [];
  int? party, box;
  int cur = defCur;
  bool sale = true;
  final rows = <_Row>[_Row()];
  final disc = TextEditingController(),
      paid = TextEditingController(),
      rateC = TextEditingController(),
      note = TextEditingController();

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    await ensureTables();
    final a = await db.query('accounts',
        where: "cat NOT IN ('system','boxes')", orderBy: 'name');
    final b = await db.query('accounts', where: "cat='boxes'", orderBy: 'name');
    if (!mounted) return;
    setState(() {
      parties = a;
      boxes = b;
      party = widget.acct0;
      if (b.isNotEmpty) box = b.first['id'] as int;
      pickBox();
    });
  }

  void pickBox() {
    for (final a in parties) {
      if (a['id'] == party && a['box_id'] != null) {
        final bid = a['box_id'] as int;
        if (boxes.any((b) => b['id'] == bid)) box = bid;
      }
    }
  }

  double get gross => rows.fold<double>(0, (s, r) => s + r.total);
  double get net => gross - (double.tryParse(disc.text) ?? 0);

  Future<void> save() async {
    final n = net;
    final pd = double.tryParse(paid.text) ?? 0;
    if (party == null || n <= 0) {
      snack(context, 'اختر الحساب وأضف أصنافاً بمبلغ صحيح');
      return;
    }
    if (pd < 0 || pd > n) {
      snack(context, 'المبلغ المدفوع غير صحيح');
      return;
    }
    if (pd > 0 && box == null) {
      snack(context, 'اختر الصندوق للمبلغ المدفوع');
      return;
    }
    final partyId = party!;
    final pr = parties.firstWhere((x) => x['id'] == partyId);
    final ceil = (pr['ceiling'] as num?)?.toDouble();
    if (sale && cur == defCur && ceil != null && ceil > 0) {
      final double b = (await balances())[partyId]?[defCur] ?? 0;
      if (b + (n - pd) > ceil) {
        if (!mounted) return;
        final ok = await confirm(context, 'تجاوز سقف المديونية',
            'السقف ${ceil.toStringAsFixed(2)} والرصيد بعد الفاتورة ${(b + (n - pd)).toStringAsFixed(2)}. هل تريد المتابعة؟');
        if (!ok) return;
      }
    }
    final rate = cur == defCur ? 1.0 : (double.tryParse(rateC.text) ?? 1.0);
    final sys = await sysAcc(sale ? 'المبيعات' : 'المشتريات');
    final items = rows.where((r) => r.total > 0).toList();
    final invId = await db.transaction<int>((tr) async {
      final d1 = await _post(tr, 'invoice', note.text, [
        Ln(partyId, cur, sale ? n : -n, rate),
        Ln(sys, cur, sale ? -n : n, rate),
      ]);
      int? d2;
      if (pd > 0) {
        d2 = await _post(tr, 'voucher', 'دفعة على فاتورة', [
          Ln(box!, cur, sale ? pd : -pd, rate),
          Ln(partyId, cur, sale ? -pd : pd, rate),
        ]);
      }
      final id = await tr.insert('invoices', {
        'doc_id': d1,
        'pay_doc_id': d2,
        'account_id': partyId,
        'kind': sale ? 'sale' : 'purchase',
        'currency_id': cur,
        'total': n,
        'paid': pd,
        'discount': double.tryParse(disc.text) ?? 0,
        'note': note.text,
        'date': nowIso(),
      });
      for (final r in items) {
        await tr.insert('invoice_items', {
          'invoice_id': id,
          'name': r.n.text,
          'qty': double.tryParse(r.q.text) ?? 0,
          'price': double.tryParse(r.p.text) ?? 0,
        });
      }
      return id;
    });
    if (!mounted) return;
    snack(context, 'تم حفظ الفاتورة رقم $invId');
    final lines = items
        .map((r) =>
            '• ${r.n.text.trim().isEmpty ? 'صنف' : r.n.text.trim()}  ${nf(double.tryParse(r.q.text) ?? 0)} × ${nf(double.tryParse(r.p.text) ?? 0)} = ${nf(r.total)}')
        .join('\n');
    final dsc = double.tryParse(disc.text) ?? 0;
    await afterSave(context, partyId, 'invoice', {
      'kind': sale ? 'فاتورة بيع' : 'فاتورة شراء',
      'no': '$invId',
      'cur': '$cur',
      'items': lines,
      'discount': dsc > 0 ? 'الخصم: ${pm(money(dsc, cur))}' : '',
      'paid': pd > 0 ? 'الواصل: ${pm(money(pd, cur))}' : '',
      'amount': money(n, cur),
      'rest': money(n - pd, cur),
    });
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pd = double.tryParse(paid.text) ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('فاتورة جديدة')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('فاتورة بيع')),
            ButtonSegment(value: false, label: Text('فاتورة شراء')),
          ],
          selected: {sale},
          onSelectionChanged: (s) => setState(() => sale = s.first),
        ),
        DropdownButtonFormField<int>(
          value: parties.any((a) => a['id'] == party) ? party : null,
          decoration: InputDecoration(labelText: sale ? 'العميل' : 'المورد'),
          items: parties
              .map((a) => DropdownMenuItem(
                  value: a['id'] as int,
                  child: Text('${a['name']} (${cats[a['cat']]?[0] ?? ''})')))
              .toList(),
          onChanged: (v) => setState(() {
            party = v;
            pickBox();
          }),
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
        const SizedBox(height: 12),
        const Text('الأصناف', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final r in rows)
          Row(children: [
            Expanded(
                flex: 3,
                child: TextField(
                    controller: r.n, decoration: const InputDecoration(labelText: 'الصنف'))),
            const SizedBox(width: 6),
            Expanded(
                child: TextField(
                    controller: r.q,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'الكمية'))),
            const SizedBox(width: 6),
            Expanded(
                child: TextField(
                    controller: r.p,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'السعر'))),
            if (rows.length > 1)
              IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => rows.remove(r))),
          ]),
        TextButton.icon(
            onPressed: () => setState(() => rows.add(_Row())),
            icon: const Icon(Icons.add),
            label: const Text('إضافة صنف')),
        TextField(
            controller: disc,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'الخصم')),
        TextField(
            controller: paid,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'المبلغ المدفوع')),
        DropdownButtonFormField<int>(
          value: boxes.any((b) => b['id'] == box) ? box : null,
          decoration: const InputDecoration(labelText: 'الصندوق (للمبلغ المدفوع)'),
          items: boxes
              .map((b) => DropdownMenuItem(value: b['id'] as int, child: Text(b['name'] as String)))
              .toList(),
          onChanged: (v) => setState(() => box = v),
        ),
        TextField(controller: note, decoration: const InputDecoration(labelText: 'بيان')),
        const SizedBox(height: 12),
        Text(
            'الإجمالي: ${net.toStringAsFixed(2)} ${sym(cur)}\nالمتبقي: ${(net - pd).toStringAsFixed(2)} ${sym(cur)}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        FilledButton(onPressed: save, child: const Text('حفظ الفاتورة')),
      ]),
    );
  }
}

// ---------------- سجل الفواتير ----------------

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({super.key});
  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

class _InvoicesPageState extends State<InvoicesPage> {
  List<Map<String, Object?>> rows = [];
  String kind = 'all';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    await ensureTables();
    final r = await db.rawQuery(
        'SELECT i.*, a.name AS aname FROM invoices i JOIN accounts a ON a.id=i.account_id '
        '${kind == 'all' ? '' : "WHERE i.kind='$kind'"} ORDER BY i.id DESC');
    setState(() => rows = r);
  }

  Future<void> show(Map<String, Object?> r) async {
    final its = await db.query('invoice_items', where: 'invoice_id=?', whereArgs: [r['id']]);
    if (!mounted) return;
    final cur = r['currency_id'] as int;
    final total = (r['total'] as num).toDouble();
    final pd = (r['paid'] as num).toDouble();
    final act = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
              title: Text(
                  '${r['kind'] == 'sale' ? 'فاتورة بيع' : 'فاتورة شراء'} رقم ${r['id']}'),
              content: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r['aname']}   ${d10(r['date'] as String)}'),
                      const Divider(),
                      for (final i in its) Text('${i['name']}   ${i['qty']} × ${i['price']}'),
                      const Divider(),
                      Text('الخصم: ${(r['discount'] as num).toStringAsFixed(2)}'),
                      Text('الإجمالي: ${total.toStringAsFixed(2)} ${sym(cur)}'),
                      Text('المدفوع: ${pd.toStringAsFixed(2)} ${sym(cur)}'),
                      Text('المتبقي: ${(total - pd).toStringAsFixed(2)} ${sym(cur)}'),
                    ]),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, 'del'), child: const Text('حذف')),
                TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق')),
              ],
            ));
    if (act == 'del') {
      if (!mounted) return;
      if (!await confirm(context, 'حذف الفاتورة', 'ستُحذف الفاتورة وقيودها. هل أنت متأكد؟')) {
        return;
      }
      await db.transaction((tr) async {
        for (final k in ['doc_id', 'pay_doc_id']) {
          final dd = r[k] as int?;
          if (dd != null) {
            await tr.delete('lines', where: 'doc_id=?', whereArgs: [dd]);
            await tr.delete('docs', where: 'id=?', whereArgs: [dd]);
          }
        }
        await tr.delete('invoice_items', where: 'invoice_id=?', whereArgs: [r['id']]);
        await tr.delete('invoices', where: 'id=?', whereArgs: [r['id']]);
      });
      load();
    }
  }

  Widget chip(String label, String k) => ChoiceChip(
      label: Text(label),
      selected: kind == k,
      onSelected: (_) {
        kind = k;
        load();
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('الفواتير')),
        floatingActionButton: FloatingActionButton(
            onPressed: () async {
              await Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const InvoicePage()));
              load();
            },
            child: const Icon(Icons.add)),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(spacing: 8, children: [
              chip('الكل', 'all'),
              chip('بيع', 'sale'),
              chip('شراء', 'purchase'),
            ]),
          ),
          Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('لا توجد فواتير'))
                  : ListView(
                      children: rows
                          .map((r) => ListTile(
                                title: Text(
                                    '${r['kind'] == 'sale' ? 'بيع' : 'شراء'} رقم ${r['id']} - ${r['aname']}'),
                                subtitle: Text(d10(r['date'] as String)),
                                trailing: Text(
                                    '${(r['total'] as num).toStringAsFixed(2)} ${sym(r['currency_id'] as int)}'),
                                onTap: () => show(r),
                              ))
                          .toList())),
        ]),
      );
}

// ---------------- أرصدة الحسابات والديون ----------------

class BalancesPage extends StatefulWidget {
  const BalancesPage({super.key});
  @override
  State<BalancesPage> createState() => _BalancesPageState();
}

class _BalancesPageState extends State<BalancesPage> {
  List<Map<String, Object?>> accts = [];
  Map<int, Map<int, double>> bal = {};
  Map<int, String> last = {};
  String filter = 'all', cat = 'all', q = '';
  int lateDays = 30;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final a = await db.query('accounts',
        where: "cat NOT IN ('system','boxes')", orderBy: 'name');
    final b = await balances();
    final l = await db.rawQuery(
        'SELECT l.account_id AS id, MAX(d.date) AS last FROM lines l JOIN docs d ON d.id=l.doc_id GROUP BY l.account_id');
    setState(() {
      accts = a;
      bal = b;
      last = {for (final x in l) x['id'] as int: x['last'] as String};
    });
  }

  bool pass(Map<String, Object?> a) {
    final id = a['id'] as int;
    if (q.isNotEmpty && !(a['name'] as String).contains(q)) return false;
    if (cat != 'all' && a['cat'] != cat) return false;
    final m = bal[id] ?? <int, double>{};
    final hasDr = m.values.any((v) => v > 0.005);
    final hasCr = m.values.any((v) => v < -0.005);
    if (filter == 'dr') return hasDr;
    if (filter == 'cr') return hasCr;
    if (filter == 'over') {
      final c = (a['ceiling'] as num?)?.toDouble();
      return c != null && c > 0 && (m[defCur] ?? 0) > c;
    }
    if (filter == 'late') {
      final l = last[id];
      if (!hasDr || l == null) return false;
      return DateTime.now().difference(DateTime.parse(l)).inDays >= lateDays;
    }
    return true;
  }

  Widget chip(String label, String f) => ChoiceChip(
      label: Text(label), selected: filter == f, onSelected: (_) => setState(() => filter = f));

  @override
  Widget build(BuildContext context) {
    final list = accts.where(pass).toList();
    final dr = <int, double>{}, cr = <int, double>{};
    for (final a in list) {
      (bal[a['id'] as int] ?? <int, double>{}).forEach((c, v) {
        if (v > 0) dr[c] = (dr[c] ?? 0) + v;
        if (v < 0) cr[c] = (cr[c] ?? 0) - v;
      });
    }
    final ids = {...dr.keys, ...cr.keys};
    final totals = ids.map((c) =>
        '${sym(c)}   عليه: ${(dr[c] ?? 0).toStringAsFixed(2)}   له: ${(cr[c] ?? 0).toStringAsFixed(2)}');
    return Scaffold(
      appBar: AppBar(title: const Text('أرصدة الحسابات')),
      bottomNavigationBar: Container(
        color: blue,
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        child: Text(
            'عدد الحسابات: ${list.length}${totals.isEmpty ? '' : '\n${totals.join('\n')}'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Wrap(spacing: 8, children: [
            chip('الكل', 'all'),
            chip('المدينون', 'dr'),
            chip('الدائنون', 'cr'),
            chip('تجاوز السقف', 'over'),
            chip('المتأخرون', 'late'),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
          child: Row(children: [
            Expanded(
                child: TextField(
                    onChanged: (v) => setState(() => q = v),
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم'))),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: cat,
              items: [
                const DropdownMenuItem(value: 'all', child: Text('كل الأقسام')),
                ...cats.entries.where((e) => e.key != 'boxes').map((e) =>
                    DropdownMenuItem(value: e.key, child: Text(e.value[0] as String))),
              ],
              onChanged: (v) => setState(() => cat = v!),
            ),
          ]),
        ),
        if (filter == 'late')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              const Text('متأخر منذ أكثر من:  '),
              DropdownButton<int>(
                value: lateDays,
                items: const [15, 30, 60, 90]
                    .map((d) => DropdownMenuItem(value: d, child: Text('$d يوم')))
                    .toList(),
                onChanged: (v) => setState(() => lateDays = v!),
              ),
            ]),
          ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('لا توجد حسابات مطابقة'))
              : ListView(
                  children: list.map((a) {
                  final id = a['id'] as int;
                  final m = bal[id];
                  return ListTile(
                    title: Text(a['name'] as String),
                    subtitle: Text(
                        '${cats[a['cat']]?[0] ?? ''}   ${last[id] == null ? '' : 'آخر حركة: ${d10(last[id]!)}'}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(balText(m),
                            textAlign: TextAlign.end,
                            style: TextStyle(
                                fontWeight: FontWeight.bold, color: balColor(m))),
                      ),
                      IconButton(
                          icon: const Icon(Icons.message, color: blue),
                          onPressed: () => sendBalanceMsg(context, id)),
                    ]),
                    onTap: () async {
                      await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => StatementPage(
                                  id, a['name'] as String, a['cat'] as String)));
                      load();
                    },
                  );
                }).toList()),
        ),
      ]),
    );
  }
}
