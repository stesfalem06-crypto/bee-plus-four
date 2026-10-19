// Tutor search off the UI thread. One long-lived background isolate decodes its own copy of the tutor index (the same
// gzip'd asset TutorIndex.load reads) and answers TutorIndex.search requests, so BM25 scoring over ~100k cards never
// runs on the UI thread (it took a whole frame or more per query on low-end Android). Results are small (doc ids and
// scores), so a request costs one tiny message each way. Where isolates can't be spawned (tests with fake async) the
// caller falls back to the in-thread index.
import 'dart:async';
import 'package:high/content/content_vault.dart';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'tutor_index.dart';

typedef TutorQuery = ({String query, String? subject, int? grade, String? preferSubject, int? preferGrade, bool ignoreQueryFilters});

class TutorWorker {
  TutorWorker._(this._send, this._rx);
  final SendPort _send;
  final ReceivePort _rx;
  final _pending = <int, Completer<TutorResult>>{};
  var _next = 0;

  static Future<TutorWorker>? _one;

  /// started once per app run (first Tutor search); null when an isolate can't be started
  static Future<TutorWorker?> get([AssetBundle? bundle]) async {
    try {
      return await (_one ??= _start(bundle));
    } catch (_) {
      return null;
    }
  }

  static Future<TutorWorker> _start(AssetBundle? bundle) async {
    final data = await (bundle ?? contentBundle).load(TutorIndex.asset);
    final gz = TransferableTypedData.fromList([data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)]);
    final rx = ReceivePort();
    await Isolate.spawn(_main, (rx.sendPort, gz), debugName: 'tutor-search');
    final first = Completer<SendPort>();
    late final TutorWorker w;
    rx.listen((m) {
      if (m is SendPort) {
        first.complete(m);
      } else if (m is (int, TutorResult)) {
        w._pending.remove(m.$1)?.complete(m.$2);
      } else if (m is (int, String)) {
        w._pending.remove(m.$1)?.completeError(StateError(m.$2));
      }
    });
    w = TutorWorker._(await first.future, rx);
    return w;
  }

  Future<TutorResult> search(TutorQuery q) {
    final id = _next++;
    final c = _pending[id] = Completer<TutorResult>();
    _send.send((id, q));
    return c.future;
  }

  static void _main((SendPort, TransferableTypedData) a) {
    final ix = TutorIndex.decode(a.$2.materialize().asUint8List());
    final rx = ReceivePort();
    a.$1.send(rx.sendPort);
    rx.listen((m) {
      final (id, q) = m as (int, TutorQuery);
      try {
        a.$1.send((
          id,
          ix.search(q.query, subject: q.subject, grade: q.grade, preferSubject: q.preferSubject, preferGrade: q.preferGrade, ignoreQueryFilters: q.ignoreQueryFilters),
        ));
      } catch (e) {
        a.$1.send((id, '$e'));
      }
    });
  }

  void dispose() => _rx.close();
}

/// the search a TutorAnswerer runs: in the worker when there is one, else on [ix] in this isolate
typedef TutorSearch = Future<TutorResult> Function(TutorQuery q);

TutorSearch localSearch(TutorIndex ix) => (q) async =>
    ix.search(q.query, subject: q.subject, grade: q.grade, preferSubject: q.preferSubject, preferGrade: q.preferGrade, ignoreQueryFilters: q.ignoreQueryFilters);

TutorSearch workerSearch(TutorWorker? w, TutorIndex ix) => w == null ? localSearch(ix) : (q) => w.search(q).catchError((Object _) => localSearch(ix)(q));

