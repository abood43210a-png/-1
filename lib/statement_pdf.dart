import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'main.dart';
import 'messaging.dart';

class StRow {
  final String amount, note, date;
  final bool debit;
  StRow(this.amount, this.note, this.date, this.debit);
}

class StatementData {
  final String shop, customer, period, received, remaining;
  final bool remainingDebit;
  final List<StRow> rows;
  StatementData(this.shop, this.customer, this.period, this.rows, this.received,
      this.remaining, this.remainingDebit);
}

Future<StatementData> _data(String customer, int cur, DateTime? from, DateTime? to,
    double prev, List<Map<String, Object?>> rows) async {
  final shop = await appName();
  final out = <StRow>[];
  if (from != null && prev.abs() > 0.004) {
    out.add(StRow('${nf(prev.abs())} ${sym(cur)} ${prev > 0 ? 'عليه' : 'له'}', 'رصيد سابق',
        dmy(from), prev > 0));
  }
  double dr = 0, cr = 0;
  for (final r in rows) {
    final a = (r['amount'] as num).toDouble();
    if (a > 0) {
      dr += a;
    } else {
      cr += -a;
    }
    out.add(StRow('${nf(a.abs())} ${sym(cur)} ${a > 0 ? 'عليه' : 'له'}', '${r['note'] ?? ''}',
        dt12(DateTime.parse(r['date'] as String)), a > 0));
  }
  final rem = (from != null ? prev : 0.0) + dr - cr;
  final period = from == null
      ? 'جميع الحركات'
      : 'من ${dmy(from)} إلى ${dmy(to ?? DateTime.now())}';
  return StatementData(
      shop,
      customer,
      period,
      out,
      '${nf(cr)} ${sym(cur)}',
      '${nf(rem.abs())} ${sym(cur)}${rem < -0.004 ? ' (له)' : ''}',
      rem > 0.004);
}

const _ink = Color(0xFF1B1F2A);
const _red = Color(0xFFC62828);
const _green = Color(0xFF2E7D32);

Widget _head() => Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
          color: blue, borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
      child: const Row(children: [
        Expanded(
            flex: 3,
            child: Text('المبلغ',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
        Expanded(
            flex: 5,
            child: Text('البيان',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
        Expanded(
            flex: 3,
            child: Text('التاريخ',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
      ]),
    );

Widget _row(StRow r, int i) => Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: i.isOdd ? const Color(0xFFF1F5FB) : Colors.white,
      child: Row(children: [
        Expanded(
            flex: 3,
            child: Text(r.amount,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: r.debit ? _red : _green, fontWeight: FontWeight.w700))),
        Expanded(
            flex: 5, child: Text(r.note, maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(
            flex: 3,
            child: Text(r.date,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
      ]),
    );

Widget _totals(StatementData d) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: const Color(0xFFEAF1FB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: blue)),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('إجمالي الواصل', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(d.received,
              style: const TextStyle(
                  color: _green, fontWeight: FontWeight.w800, fontSize: 15)),
        ]),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('إجمالي المتبقي', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(d.remaining,
              style: TextStyle(
                  color: d.remainingDebit ? _red : _green,
                  fontWeight: FontWeight.w800,
                  fontSize: 15)),
        ]),
      ]),
    );

Widget _page(StatementData d, int k, int n, List<StRow> rows) {
  final last = k == n - 1;
  return Theme(
    data: ThemeData.light(),
    child: Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTextStyle(
        style: const TextStyle(color: _ink, fontSize: 13.5, height: 1.25),
        child: Container(
          width: 600,
          height: 848,
          color: Colors.white,
          padding: const EdgeInsets.all(28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (k == 0) ...[
              Text(d.shop,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: blue)),
              const SizedBox(height: 8),
              Container(height: 3, color: blue),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: Text('الأخ / ${d.customer}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                Text(d.period, style: const TextStyle(fontSize: 14)),
              ]),
              const SizedBox(height: 14),
            ] else ...[
              Row(children: [
                Expanded(
                    child: Text(d.shop,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800, color: blue))),
                Text(d.customer, style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 8),
              Container(height: 2, color: blue),
              const SizedBox(height: 10),
            ],
            _head(),
            for (var r = 0; r < rows.length; r++) _row(rows[r], r),
            if (last) ...[const SizedBox(height: 14), _totals(d)],
            const Spacer(),
            Text('صفحة ${k + 1} من $n',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ]),
        ),
      ),
    ),
  );
}

List<Widget> statementPages(StatementData d) {
  const firstCap = 17, otherCap = 22;
  final chunks = <List<StRow>>[];
  var i = 0;
  do {
    final cap = chunks.isEmpty ? firstCap : otherCap;
    final end = math.min(i + cap, d.rows.length);
    chunks.add(d.rows.sublist(i, end));
    i = end;
  } while (i < d.rows.length);
  final lastCap = chunks.length == 1 ? firstCap : otherCap;
  if (chunks.last.length > lastCap - 3) chunks.add(<StRow>[]);
  return [for (var k = 0; k < chunks.length; k++) _page(d, k, chunks.length, chunks[k])];
}

// يلتقط الصفحات واحدة تلو الأخرى كصور PNG
class _MultiCapture extends StatefulWidget {
  final List<Widget> pages;
  const _MultiCapture(this.pages);
  @override
  State<_MultiCapture> createState() => _MultiCaptureState();
}

class _MultiCaptureState extends State<_MultiCapture> {
  late final List<GlobalKey> keys = List.generate(widget.pages.length, (_) => GlobalKey());
  final out = <Uint8List>[];
  int i = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => step());
  }

  Future<void> step() async {
    await Future.delayed(const Duration(milliseconds: 300));
    try {
      final b = keys[i].currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2.2);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      out.add(bd!.buffer.asUint8List());
    } catch (_) {
      if (mounted) Navigator.pop(context, null);
      return;
    }
    if (!mounted) return;
    if (i + 1 < widget.pages.length) {
      setState(() => i++);
      WidgetsBinding.instance.addPostFrameCallback((_) => step());
    } else {
      Navigator.pop(context, out);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('جاري تجهيز الملف  ${i + 1} / ${widget.pages.length}'),
            const SizedBox(height: 12),
            SizedBox(
              width: 260,
              height: 368,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                    width: 600,
                    height: 848,
                    child: RepaintBoundary(key: keys[i], child: widget.pages[i])),
              ),
            ),
          ]),
        ),
      );
}

Future<List<Uint8List>?> _render(BuildContext ctx, String customer, int cur, DateTime? from,
    DateTime? to, double prev, List<Map<String, Object?>> rows) async {
  final d = await _data(customer, cur, from, to, prev, rows);
  if (!ctx.mounted) return null;
  final r = await showDialog<List<Uint8List>>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _MultiCapture(statementPages(d)));
  return (r == null || r.isEmpty) ? null : r;
}

Future<String?> statementPdf(BuildContext ctx,
    {required String customer,
    required int cur,
    DateTime? from,
    DateTime? to,
    required double prev,
    required List<Map<String, Object?>> rows}) async {
  final pngs = await _render(ctx, customer, cur, from, to, prev, rows);
  if (pngs == null) return null;
  final doc = pw.Document();
  for (final b in pngs) {
    final img = pw.MemoryImage(b);
    doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(img, fit: pw.BoxFit.fill)));
  }
  final f = File(
      '${Directory.systemTemp.path}/Statement_${DateTime.now().millisecondsSinceEpoch}.pdf');
  await f.writeAsBytes(await doc.save());
  return f.path;
}

// صورة الكشف اليومي (صفحة واحدة فقط، وإلا null)
Future<String?> statementImage(BuildContext ctx,
    {required String customer,
    required int cur,
    DateTime? from,
    DateTime? to,
    required double prev,
    required List<Map<String, Object?>> rows}) async {
  final pngs = await _render(ctx, customer, cur, from, to, prev, rows);
  if (pngs == null || pngs.length != 1) return null;
  final f = File(
      '${Directory.systemTemp.path}/Statement_${DateTime.now().millisecondsSinceEpoch}.png');
  await f.writeAsBytes(pngs.first);
  return f.path;
}
