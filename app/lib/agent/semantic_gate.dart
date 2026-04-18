/// Semantic gate: lightweight keyword-based sanity check that the tool
/// the model just picked has at least one keyword in common with the user's
/// query — and if it doesn't, that some OTHER available tool is a better
/// match. If neither holds, we give benefit of the doubt.
///
/// Pattern ported from LocalHost Router's `_semantic_check`.
const Map<String, List<String>> _defaultSignals = {
  'send_message': ['send', 'message', 'text ', 'tell ', 'dm '],
  'create_issue': ['create', 'file ', 'open', 'issue', 'ticket', 'bug'],
  'search_issues': ['find', 'search', 'look up', 'list', 'show me'],
  'assign_issue': ['assign', 'reassign'],
  'comment_on_issue': ['comment', 'reply', 'respond'],
  'get_weather': ['weather', 'temperature', 'forecast', 'rain', 'sunny'],
  'set_alarm': ['alarm', 'wake'],
  'set_timer': ['timer', 'countdown'],
  'set_reminder': ['remind', 'reminder'],
  'play_track': ['play', 'song', 'music', 'listen', 'track'],
  'play_music': ['play', 'song', 'music', 'listen', 'track'],
  'navigate': ['navigate', 'directions', 'drive to', 'route to'],
  'call': ['call', 'ring', 'phone'],
  'email': ['email', 'mail'],
};

class SemanticGate {
  final Map<String, List<String>> signals;
  int triggerCount = 0;

  SemanticGate([Map<String, List<String>>? userSignals])
      : signals = {..._defaultSignals, ...?userSignals};

  /// Returns true if the selected tool appears consistent with the query.
  /// Returns false (and increments [triggerCount]) only when a DIFFERENT
  /// available tool has a keyword match and the selected tool has none.
  bool check({
    required String toolName,
    required String query,
    required List<String> availableTools,
  }) {
    final q = query.toLowerCase();

    // Unknown tool -> benefit of the doubt.
    final selectedKeywords = signals[toolName];
    if (selectedKeywords == null) return true;

    final selectedMatches = selectedKeywords.any((kw) => q.contains(kw));
    if (selectedMatches) return true;

    // Does any OTHER tool fit the query better?
    for (final other in availableTools) {
      if (other == toolName) continue;
      final otherKeywords = signals[other];
      if (otherKeywords == null) continue;
      if (otherKeywords.any((kw) => q.contains(kw))) {
        triggerCount += 1;
        return false;
      }
    }

    // No tool matches -> benefit of the doubt.
    return true;
  }
}
