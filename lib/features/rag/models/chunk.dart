import 'dart:convert';

/// A chunk of text from a source document, with optional embedding.
class Chunk {
  final String id; // "${docId}_${chunkIndex}"
  final String docId;
  final String text;
  final int chunkIndex;
  final Map<String, dynamic> metadata;
  List<double>? embedding;

  Chunk({
    required this.id,
    required this.docId,
    required this.text,
    required this.chunkIndex,
    this.metadata = const {},
    this.embedding,
  });

  Chunk copyWith({List<double>? embedding}) {
    return Chunk(
      id: id,
      docId: docId,
      text: text,
      chunkIndex: chunkIndex,
      metadata: metadata,
      embedding: embedding ?? this.embedding,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'docId': docId,
        'text': text,
        'chunkIndex': chunkIndex,
        'metadata': metadata,
        'embedding':
            embedding != null ? jsonEncode(embedding!) : null,
      };

  factory Chunk.fromJson(Map<String, dynamic> json) => Chunk(
        id: json['id'] as String,
        docId: json['docId'] as String,
        text: json['text'] as String,
        chunkIndex: json['chunkIndex'] as int,
        metadata: json['metadata'] as Map<String, dynamic>? ?? {},
        embedding: json['embedding'] != null
            ? (jsonDecode(json['embedding'] as String) as List<dynamic>)
                .cast<double>()
            : null,
      );
}