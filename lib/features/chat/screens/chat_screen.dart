import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/chat_bloc.dart';
import '../bloc/chat_event.dart';
import '../bloc/chat_state.dart';
import '../models/chat_message.dart';

/// Main chat screen UI with streaming message display and configuration panel.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onSend() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    context.read<ChatBloc>().add(SendMessage(text));
    _inputController.clear();
    _scrollToBottom();
  }

  void _showAddDocumentDialog(BuildContext context) {
    final titleController = TextEditingController();
    final contentController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Document to RAG'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Document Title',
                hintText: 'e.g. User Manual',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              decoration: const InputDecoration(
                labelText: 'Content',
                hintText: 'Paste plain text or markdown here...',
              ),
              maxLines: 6,
              minLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final title = titleController.text.trim();
              final content = contentController.text.trim();
              if (title.isNotEmpty && content.isNotEmpty) {
                context.read<ChatBloc>().add(IndexDocument(title: title, content: content));
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Row(
          children: [
            const Text(
              'SLM Chat',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            BlocBuilder<ChatBloc, ChatState>(
              builder: (context, state) {
                String statusText = 'No Model';
                Color statusColor = Colors.grey;
                if (state.isDownloading) {
                  statusText = 'Downloading';
                  statusColor = Colors.orange;
                } else if (state.isModelLoaded) {
                  statusText = 'Ready';
                  statusColor = Colors.green;
                } else if (state.isModelDownloaded) {
                  statusText = 'Downloaded';
                  statusColor = Colors.blue;
                }

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 10,
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          // RAG toggle chip
          BlocBuilder<ChatBloc, ChatState>(
            builder: (context, state) {
              final ragActive = state.useRag;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Row(
                    children: [
                      Icon(
                        ragActive ? Icons.psychology : Icons.psychology_outlined,
                        size: 16,
                        color: ragActive ? Colors.white : Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'RAG',
                        style: TextStyle(
                          fontSize: 12,
                          color: ragActive ? Colors.white : Colors.grey[700],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  selected: ragActive,
                  selectedColor: Theme.of(context).colorScheme.primary,
                  checkmarkColor: Colors.white,
                  showCheckmark: false,
                  onSelected: (_) {
                    context.read<ChatBloc>().add(const ToggleRag());
                  },
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Model & RAG Config',
            onPressed: () {
              _scaffoldKey.currentState?.openEndDrawer();
            },
          ),
        ],
      ),
      endDrawer: _ConfigDrawer(
        onAddDocument: () => _showAddDocumentDialog(context),
      ),
      body: Column(
        children: [
          // Indexing progress banner
          BlocBuilder<ChatBloc, ChatState>(
            builder: (context, state) {
              if (state.indexingProgress == null) return const SizedBox.shrink();
              return Container(
                color: Theme.of(context).colorScheme.primaryContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Indexing document... ${(state.indexingProgress! * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // Message list
          Expanded(
            child: BlocConsumer<ChatBloc, ChatState>(
              listener: (context, state) {
                if (state.status == ChatStatus.generating) {
                  _scrollToBottom();
                }
                if (state.status == ChatStatus.error && state.errorMessage != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.errorMessage!),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              builder: (context, state) {
                if (state.messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.smart_toy_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Start a conversation with\nGemma 4 E2B',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          state.useRag
                              ? 'RAG Mode Active (${state.documentCount} docs indexed)'
                              : 'Standard Mode. Open config (tune icon) to set up RAG.',
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: state.messages.length,
                  itemBuilder: (context, index) {
                    return _MessageBubble(
                      message: state.messages[index],
                    );
                  },
                );
              },
            ),
          ),

          // Input bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _onSend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  BlocBuilder<ChatBloc, ChatState>(
                    builder: (context, state) {
                      final isGenerating = state.status == ChatStatus.generating;
                      final isLoadingModel = state.status == ChatStatus.loadingModel;
                      return CircleAvatar(
                        radius: 24,
                        backgroundColor: isGenerating || isLoadingModel
                            ? Colors.grey[200]
                            : Theme.of(context).colorScheme.primary,
                        child: IconButton(
                          onPressed: isGenerating || isLoadingModel ? null : _onSend,
                          icon: isGenerating || isLoadingModel
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send, color: Colors.white),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A configuration drawer holding Model and RAG management.
class _ConfigDrawer extends StatelessWidget {
  final VoidCallback onAddDocument;

  const _ConfigDrawer({required this.onAddDocument});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: BlocBuilder<ChatBloc, ChatState>(
          builder: (context, state) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Configuration',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(),

                // Model management section
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _buildHeader('ON-DEVICE MODEL'),
                      const SizedBox(height: 8),
                      _buildModelStatusCard(context, state),
                      const SizedBox(height: 16),

                      _buildHeader('RAG KNOWLEDGE BASE'),
                      const SizedBox(height: 8),
                      _buildRagStatusCard(context, state),
                    ],
                  ),
                ),

                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    onPressed: () {
                      context.read<ChatBloc>().add(const ClearChat());
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Clear Chat History'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.grey[600],
        letterSpacing: 1.0,
      ),
    );
  }

  Widget _buildModelStatusCard(BuildContext context, ChatState state) {
    String status = 'Not Downloaded';
    String details = 'Gemma 4 E2B (~2.58 GB)';
    IconData icon = Icons.cloud_download_outlined;
    Color color = Colors.grey;

    if (state.isDownloading) {
      status = 'Downloading...';
      details = '${(state.downloadProgress * 100).toStringAsFixed(1)}% complete';
      icon = Icons.downloading_outlined;
      color = Colors.orange;
    } else if (state.isModelLoaded) {
      status = 'Loaded in Memory';
      details = 'Ready for offline inference';
      icon = Icons.memory_outlined;
      color = Colors.green;
    } else if (state.isModelDownloaded) {
      status = 'Installed';
      details = 'Downloaded but not loaded';
      icon = Icons.check_circle_outline;
      color = Colors.blue;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        details,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (state.isDownloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: state.downloadProgress),
            ],
            const SizedBox(height: 16),
            if (!state.isModelDownloaded && !state.isDownloading)
              ElevatedButton.icon(
                onPressed: () {
                  context.read<ChatBloc>().add(const DownloadModel());
                },
                icon: const Icon(Icons.download),
                label: const Text('Download Model (~2.6GB)'),
              ),
            if (state.isModelDownloaded && !state.isModelLoaded && !state.isDownloading)
              ElevatedButton.icon(
                onPressed: () {
                  // Sending message automatically loads model, or we can trigger loaded
                  context.read<ChatBloc>().add(const SendMessage('hello'));
                },
                icon: const Icon(Icons.bolt),
                label: const Text('Load Model'),
              ),
            if (state.isModelDownloaded && !state.isDownloading) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  context.read<ChatBloc>().add(const DeleteModel());
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Delete Model File', style: TextStyle(color: Colors.red)),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildRagStatusCard(BuildContext context, ChatState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('RAG Mode Toggle'),
                Switch(
                  value: state.useRag,
                  onChanged: (_) {
                    context.read<ChatBloc>().add(const ToggleRag());
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.article_outlined, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  'Indexed Documents: ${state.documentCount}',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onAddDocument,
              icon: const Icon(Icons.add),
              label: const Text('Add Custom Document'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                // Pre-baked mock documentation about SlmApp for instant demo
                context.read<ChatBloc>().add(const IndexDocument(
                      title: 'SlmApp Offline Guide',
                      content:
                          'SlmApp is a fully offline, private AI chatbot built with Flutter, LiteRT-LM, and Gemma 4 E2B Instruct. It operates 100% on-device. Key features include a memory-efficient resumable downloader for the 2.6GB model, streaming token generation, and an offline RAG (Retrieval-Augmented Generation) pipeline using in-memory vector cosine similarity. Standard document formats supported are plain text and markdown. Designed by the TMA AI Team.',
                    ));
              },
              icon: const Icon(Icons.library_books_outlined),
              label: const Text('Index Demo Doc'),
            ),
            if (state.documentCount > 0) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  context.read<ChatBloc>().add(const ClearIndex());
                },
                icon: const Icon(Icons.clear_all, color: Colors.red),
                label: const Text('Clear Vector Store', style: TextStyle(color: Colors.red)),
              ),
            ]
          ],
        ),
      ),
    );
  }
}

/// A single chat message bubble (user or assistant).
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final alignment =
        isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: isUser
                    ? const Radius.circular(16)
                    : const Radius.circular(4),
                bottomRight: isUser
                    ? const Radius.circular(4)
                    : const Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.text.isNotEmpty)
                  Text(
                    message.text,
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                if (message.isStreaming)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: _CursorIndicator(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatTime(message.timestamp),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}

/// A custom cursor indicator that flashes/fades for streaming token effects.
class _CursorIndicator extends StatefulWidget {
  const _CursorIndicator();

  @override
  State<_CursorIndicator> createState() => _CursorIndicatorState();
}

class _CursorIndicatorState extends State<_CursorIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 15,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
      ),
    );
  }
}

