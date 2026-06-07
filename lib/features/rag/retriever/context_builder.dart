import '../vector_store/vector_store.dart';

/// Builds a formatted context string from retrieved search results.
///
/// Follows the rules/rag.md specification:
/// - Formats each result with source attribution
/// - Respects [maxContextChars] limit to stay within model context window
/// - Prepends the user query at the end
class ContextBuilder {
  final int maxContextChars;

  /// Default max context: 2000 characters (~285 tokens) to leave room
  /// for conversation history and response generation.
  static const int defaultMaxContextChars = 2000;

  const ContextBuilder({this.maxContextChars = defaultMaxContextChars});

  /// Build a formatted context string from [results] for [userQuery].
  ///
  /// Returns an empty string if [results] is empty.
  String build(List<SearchResult> results, String userQuery) {
    if (results.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('Context information is below.');
    buf.writeln('---------------------');
    
    int total = 0;

    for (final result in results) {
      final snippet = result.chunk.text;

      // Check if adding this snippet would exceed the limit
      if (total + snippet.length > maxContextChars) break;

      buf.writeln('[Source: ${result.document.title}]');
      buf.writeln(snippet);
      buf.writeln('---');
      total += snippet.length;
    }

    buf.writeln('---------------------');
    buf.writeln('Given the context information and not prior knowledge, answer the question.');
    buf.writeln('Question: $userQuery');
    buf.writeln('Answer:');

    return buf.toString();
  }
}