/// Chunks text into overlapping segments for embedding and indexing.
///
/// Uses a sliding window approach with configurable [chunkSize] (in tokens)
/// and [overlapTokens]. Prioritizes splitting at sentence/paragraph boundaries.
///
/// Following the rules/rag.md specification:
/// - Default chunkSize: 512 tokens (~350 words)
/// - Default overlapTokens: 64 tokens
class TextChunker {
  final int chunkSize;
  final int overlapTokens;

  /// Rough estimate: 1 token ≈ 1.4 English words ≈ 7 characters
  static const double charsPerToken = 7.0;

  const TextChunker({
    this.chunkSize = 512,
    this.overlapTokens = 64,
  });

  /// Split [text] into a list of chunks.
  ///
  /// [docId] is used to generate chunk IDs in the format "${docId}_${i}".
  List<ChunkResult> chunk(String text, {String? docId}) {
    if (text.isEmpty) return [];

    final chunks = <ChunkResult>[];
    final maxChars = (chunkSize * charsPerToken).round();
    final overlapChars = (overlapTokens * charsPerToken).round();
    final docPrefix = docId ?? 'doc';
    int start = 0;
    int index = 0;

    while (start < text.length) {
      // Determine end position
      int end = (start + maxChars).clamp(0, text.length);

      // Try to break at a sentence boundary (., !, ?) near the end
      if (end < text.length) {
        final searchStart = (end - (maxChars ~/ 4)).clamp(0, text.length);
        final searchEnd = end;
        final breakAt = _findSentenceBoundary(text, searchStart, searchEnd);
        if (breakAt != -1) {
          end = breakAt + 1; // Include the punctuation
        }
      }

      final snippet = text.substring(start, end).trim();
      if (snippet.isNotEmpty) {
        chunks.add(ChunkResult(
          id: '${docPrefix}_$index',
          text: snippet,
          index: index,
        ));
      }

      index++;
      if (end >= text.length) break;
      start = end - overlapChars;
      if (start < 0) start = 0;
    }

    return chunks;
  }

  /// Find the last sentence boundary within [start, end).
  ///
  /// Returns the index of the boundary, or -1 if none found.
  int _findSentenceBoundary(String text, int start, int end) {
    // Search backwards from end to start for sentence-ending punctuation
    for (int i = end - 1; i >= start; i--) {
      final char = text[i];
      if (char == '.' || char == '!' || char == '?' || char == '\n') {
        // Ensure it's actually a sentence end (followed by space or end of string)
        if (i + 1 >= text.length || text[i + 1] == ' ' || text[i + 1] == '\n') {
          return i;
        }
      }
    }
    return -1;
  }

  /// Estimate the number of tokens in a text string.
  static int estimateTokens(String text) {
    return (text.length / charsPerToken).ceil();
  }
}

/// Result of a single chunk operation.
class ChunkResult {
  final String id;
  final String text;
  final int index;

  const ChunkResult({
    required this.id,
    required this.text,
    required this.index,
  });
}