// Study Coach content (assets/high/coach/topics.json, built by tool/study_coach/build_topics.py). Read once, kept.
import 'dart:convert';
import 'package:high/content/content_vault.dart';

import 'package:flutter/services.dart';

class CoachTopic {
  CoachTopic(this.id, this.title, this.group, this.tone, this.icon, this.summary, this.blocks);
  final String id, title, group, tone, icon, summary;
  final List<Map<String, dynamic>> blocks;

  static const interactive = {'quiz', 'mcq', 'check', 'tool', 'try'};
  bool get hasInteractive => blocks.any((b) => interactive.contains(b['type']));
  int get stepCount => blocks.where((b) => b['type'] == 'steps').fold(0, (a, b) => a + (b['items'] as List).length);
  Iterable<String> get tools => blocks.where((b) => b['type'] == 'tool').map((b) => b['tool'] as String);
}

class CoachBook {
  CoachBook(this.topics, this.groups);
  final List<CoachTopic> topics;
  final List<String> groups;

  static const asset = 'assets/high/coach/topics.json';
  static Future<CoachBook>? _f;
  static CoachBook? cached;
  static Future<CoachBook> load([AssetBundle? bundle]) => _f ??= cached != null ? Future.value(cached) : (bundle ?? contentBundle).loadString(asset).then((s) => cached = parse(s), onError: (Object e, StackTrace st) {
        _f = null; // 1.0.6: retry after a failed read
        Error.throwWithStackTrace(e, st);
      });

  static CoachBook parse(String s) {
    final o = jsonDecode(s) as Map<String, dynamic>;
    return CoachBook(
      [
        for (final t in o['topics'] as List)
          CoachTopic(t['id'] as String, t['title'] as String, t['group'] as String, t['tone'] as String, t['icon'] as String, t['summary'] as String, [
            for (final b in t['blocks'] as List) Map<String, dynamic>.from(b as Map),
          ]),
      ],
      [for (final g in o['groups'] as List) g as String],
    );
  }

  CoachTopic? byId(String id) => topics.where((t) => t.id == id).firstOrNull;
}

/// self-check score → the band whose [max] is the first one at or above it
Map<String, dynamic> bandFor(Map<String, dynamic> quiz, int score) {
  final bands = [for (final b in quiz['bands'] as List) Map<String, dynamic>.from(b as Map)];
  return bands.firstWhere((b) => score <= (b['max'] as num), orElse: () => bands.last);
}

/// review days after the first study day (spaced repetition: 1, 3, 7, 14, 30 days)
const kReviewDays = [1, 3, 7, 14, 30];
