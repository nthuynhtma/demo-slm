/// Represents a single message in the chat conversation.
class ChatMessage {
  final String id;
  final String text;
  final MessageRole role;
  final DateTime timestamp;
  final bool isStreaming;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.role,
    required this.timestamp,
    this.isStreaming = false,
  });

  ChatMessage copyWith({
    String? id,
    String? text,
    MessageRole? role,
    DateTime? timestamp,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      text: text ?? this.text,
      role: role ?? this.role,
      timestamp: timestamp ?? this.timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }

  @override
  String toString() =>
      'ChatMessage(id: $id, role: $role, text: ${text.length} chars, streaming: $isStreaming)';
}

/// The role of the message sender.
enum MessageRole {
  user,
  assistant,
  system,
}