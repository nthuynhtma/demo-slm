/// Represents a source document that has been indexed.
class Document {
  final String id;
  final String title;
  final String? source;
  final int indexedAt;
  final int chunkCount;

  const Document({
    required this.id,
    required this.title,
    this.source,
    required this.indexedAt,
    this.chunkCount = 0,
  });

  Document copyWith({int? chunkCount}) {
    return Document(
      id: id,
      title: title,
      source: source,
      indexedAt: indexedAt,
      chunkCount: chunkCount ?? this.chunkCount,
    );
  }
}