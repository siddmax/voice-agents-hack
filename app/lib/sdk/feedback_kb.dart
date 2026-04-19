import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

const String kBundledKbIndexAsset = 'assets/kb/index.txt';
const String kAppKbDirectoryName = 'kb';

class FeedbackKbArticle {
  final String id;
  final String title;
  final String category;
  final List<String> keywords;
  final List<String> customerSteps;
  final String teamAction;
  final String engineeringSignal;
  final String sourcePath;
  final String body;

  const FeedbackKbArticle({
    required this.id,
    required this.title,
    required this.category,
    required this.keywords,
    required this.customerSteps,
    required this.teamAction,
    required this.engineeringSignal,
    required this.sourcePath,
    required this.body,
  });

  factory FeedbackKbArticle.fromMarkdown({
    required String sourcePath,
    required String markdown,
  }) {
    final parsed = _ParsedMarkdown(markdown);
    final meta = parsed.frontMatter;
    final title =
        meta['title'] ?? parsed.firstHeading ?? sourcePath.split('/').last;
    final id = meta['id'] ?? _slug(title);
    return FeedbackKbArticle(
      id: id,
      title: title,
      category: meta['category'] ?? 'General',
      keywords: _splitKeywords(meta['keywords'] ?? ''),
      customerSteps: parsed.listUnder('Customer Steps'),
      teamAction: parsed.textUnder('Team Action'),
      engineeringSignal: parsed.textUnder('Engineering Signal'),
      sourcePath: sourcePath,
      body: parsed.bodyWithoutFrontMatter,
    );
  }
}

class FeedbackKbMatch {
  final FeedbackKbArticle article;
  final double score;
  final List<String> matchedTerms;

  const FeedbackKbMatch({
    required this.article,
    required this.score,
    required this.matchedTerms,
  });
}

class FeedbackResolution {
  final String summary;
  final List<String> customerSteps;
  final List<String> teamActions;
  final List<FeedbackKbMatch> matches;

  const FeedbackResolution({
    required this.summary,
    required this.customerSteps,
    required this.teamActions,
    required this.matches,
  });

  bool get isNotEmpty =>
      summary.trim().isNotEmpty ||
      customerSteps.isNotEmpty ||
      teamActions.isNotEmpty ||
      matches.isNotEmpty;
}

class FeedbackKnowledgeBase {
  final Future<List<FeedbackKbArticle>> Function() _loadArticles;
  List<FeedbackKbArticle>? _cachedArticles;

  FeedbackKnowledgeBase._(this._loadArticles);

  factory FeedbackKnowledgeBase.bundled() {
    return FeedbackKnowledgeBase._(() async {
      final index = await rootBundle.loadString(kBundledKbIndexAsset);
      final paths = index
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'));
      final articles = <FeedbackKbArticle>[];
      for (final path in paths) {
        final markdown = await rootBundle.loadString(path);
        articles.add(
          FeedbackKbArticle.fromMarkdown(sourcePath: path, markdown: markdown),
        );
      }
      return articles;
    });
  }

  factory FeedbackKnowledgeBase.inMemory(List<FeedbackKbArticle> articles) {
    return FeedbackKnowledgeBase._(() async => articles);
  }

  static Future<Directory?> ensureBundledCorpusDir() async {
    try {
      final index = await rootBundle.loadString(kBundledKbIndexAsset);
      final paths = index
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList(growable: false);
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$kAppKbDirectoryName');
      await dir.create(recursive: true);
      for (final assetPath in paths) {
        final markdown = await rootBundle.loadString(assetPath);
        final name = assetPath.split('/').last;
        await File('${dir.path}/$name').writeAsString(markdown, flush: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<List<FeedbackKbArticle>> articles() async {
    final cached = _cachedArticles;
    if (cached != null) return cached;
    try {
      final loaded = await _loadArticles();
      _cachedArticles = loaded;
      return loaded;
    } catch (_) {
      _cachedArticles = const [];
      return const [];
    }
  }

  Future<List<FeedbackKbMatch>> search({
    required String transcript,
    required String category,
    required Iterable<String> themes,
    required Iterable<String> painPoints,
    int limit = 3,
  }) async {
    final queryText = [
      transcript,
      category,
      ...themes,
      ...painPoints,
    ].join(' ').toLowerCase();
    final queryTokens = _tokens(queryText);
    final scored = <FeedbackKbMatch>[];

    for (final article in await articles()) {
      final matched = <String>{};
      var score = 0.0;

      if (article.category.toLowerCase() == category.toLowerCase()) {
        score += 6;
        matched.add(article.category);
      }

      for (final keyword in article.keywords) {
        final lower = keyword.toLowerCase();
        if (queryText.contains(lower)) {
          score += lower.contains(' ') ? 5 : 4;
          matched.add(keyword);
        }
      }

      final titleTokens = _tokens(article.title);
      final bodyTokens = _tokens(article.body);
      for (final token in queryTokens) {
        if (titleTokens.contains(token)) {
          score += 1.5;
          matched.add(token);
        } else if (bodyTokens.contains(token)) {
          score += 0.5;
        }
      }

      if (score >= 4) {
        scored.add(
          FeedbackKbMatch(
            article: article,
            score: score,
            matchedTerms: matched.toList()..sort(),
          ),
        );
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList(growable: false);
  }

  FeedbackResolution? buildResolution(List<FeedbackKbMatch> matches) {
    if (matches.isEmpty) return null;
    final primary = matches.first.article;
    final customerSteps = primary.customerSteps.take(3).toList();
    final teamActions = <String>[
      if (primary.teamAction.trim().isNotEmpty) primary.teamAction.trim(),
      if (primary.engineeringSignal.trim().isNotEmpty)
        primary.engineeringSignal.trim(),
    ];
    final summary =
        'Matched "${primary.title}" in the local support knowledge base.';
    return FeedbackResolution(
      summary: summary,
      customerSteps: customerSteps,
      teamActions: teamActions,
      matches: matches,
    );
  }

  static String renderForPrompt(List<FeedbackKbMatch> matches) {
    if (matches.isEmpty) return 'No relevant KB articles matched.';
    final buf = StringBuffer();
    for (final match in matches) {
      final article = match.article;
      buf.writeln('### ${article.title}');
      buf.writeln('Source: ${article.sourcePath}');
      buf.writeln('Category: ${article.category}');
      if (article.customerSteps.isNotEmpty) {
        buf.writeln('Customer steps:');
        for (final step in article.customerSteps.take(3)) {
          buf.writeln('- $step');
        }
      }
      if (article.teamAction.trim().isNotEmpty) {
        buf.writeln('Team action: ${article.teamAction}');
      }
      if (article.engineeringSignal.trim().isNotEmpty) {
        buf.writeln('Engineering signal: ${article.engineeringSignal}');
      }
      buf.writeln();
    }
    return buf.toString().trimRight();
  }
}

class _ParsedMarkdown {
  final String markdown;
  late final Map<String, String> frontMatter = _parseFrontMatter();
  late final String bodyWithoutFrontMatter = _stripFrontMatter();
  late final List<String> _lines = bodyWithoutFrontMatter.split('\n');

  _ParsedMarkdown(this.markdown);

  String? get firstHeading {
    for (final line in _lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('# ')) return trimmed.substring(2).trim();
    }
    return null;
  }

  List<String> listUnder(String heading) {
    return _sectionLines(heading)
        .map(_stripListMarker)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String textUnder(String heading) {
    return _sectionLines(heading)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ')
        .trim();
  }

  List<String> _sectionLines(String heading) {
    final out = <String>[];
    var inSection = false;
    final target = '## ${heading.toLowerCase()}';
    for (final line in _lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('## ')) {
        if (inSection) break;
        inSection = trimmed.toLowerCase() == target;
        continue;
      }
      if (inSection) out.add(line);
    }
    return out;
  }

  Map<String, String> _parseFrontMatter() {
    final lines = markdown.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') return const {};
    final map = <String, String>{};
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line == '---') break;
      final sep = line.indexOf(':');
      if (sep <= 0) continue;
      map[line.substring(0, sep).trim()] = line.substring(sep + 1).trim();
    }
    return map;
  }

  String _stripFrontMatter() {
    final lines = markdown.split('\n');
    if (lines.isEmpty || lines.first.trim() != '---') return markdown;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        return lines.sublist(i + 1).join('\n');
      }
    }
    return markdown;
  }
}

List<String> _splitKeywords(String raw) => raw
    .split(',')
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty)
    .toList(growable: false);

Set<String> _tokens(String text) {
  const stop = {
    'a',
    'an',
    'and',
    'are',
    'but',
    'for',
    'i',
    'is',
    'it',
    'of',
    'on',
    'or',
    'the',
    'this',
    'to',
    'with',
  };
  return RegExp(r'[a-z0-9]+')
      .allMatches(text.toLowerCase())
      .map((m) => m.group(0)!)
      .where((token) => token.length > 2 && !stop.contains(token))
      .toSet();
}

String _stripListMarker(String line) {
  return line.trim().replaceFirst(RegExp(r'^(?:[-*]|\d+[.)])\s+'), '').trim();
}

String _slug(String input) {
  final slug = input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'article' : slug;
}
