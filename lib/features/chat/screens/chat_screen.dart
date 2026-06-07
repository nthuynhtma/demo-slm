import 'dart:async';

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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _lastFeedbackVersion = 0;

  // Debounce timer để tránh gọi scroll liên tục khi đang streaming
  Timer? _scrollDebounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _scrollDebounceTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      context.read<ChatBloc>().add(const AppBackgrounded());
    } else if (state == AppLifecycleState.resumed) {
      context.read<ChatBloc>().add(const AppForegrounded());
    }
  }

  void _scrollToBottom() {
    // Debounce: chỉ gọi scroll sau 100ms yên tĩnh để tránh conflict với SelectableText selection
    _scrollDebounceTimer?.cancel();
    _scrollDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_scrollController.hasClients) return;

        try {
          // Kiểm tra kỹ trước khi scroll
          final position = _scrollController.position;
          if (position.hasContentDimensions &&
              position.maxScrollExtent.isFinite &&
              position.maxScrollExtent > 0) {
            // Sử dụng jumpTo thay vì animateTo để tránh conflict
            // với ScrollNotificationObserverState trong quá trình streaming
            _scrollController.jumpTo(position.maxScrollExtent);
          }
        } catch (_) {
          // Bỏ qua lỗi ScrollNotificationObserverState nếu có
          // Đây là bug đã biết của Flutter khi SelectableText + scroll đồng thời
        }
      });
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
                context.read<ChatBloc>().add(
                  IndexDocument(title: title, content: content),
                );
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
                Color statusColor = Colors.red;
                if (state.status == ChatStatus.checkingStartup) {
                  statusText = 'Checking';
                  statusColor = Colors.grey;
                } else if (state.isDownloading) {
                  statusText = 'Downloading';
                  statusColor = Colors.orange;
                } else if (state.status == ChatStatus.loadingModel) {
                  statusText = 'Loading';
                  statusColor = Colors.deepPurple;
                } else if (state.isModelLoaded) {
                  statusText = 'Ready';
                  statusColor = Colors.green;
                } else if (state.isModelDownloaded) {
                  statusText = 'Downloaded';
                  statusColor = Colors.blue;
                } else if (state.status == ChatStatus.needsDownload) {
                  statusText = 'No Model';
                  statusColor = Colors.red;
                }

                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.3),
                    ),
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
                        ragActive
                            ? Icons.psychology
                            : Icons.psychology_outlined,
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
      body: Stack(
        children: [
          Column(
            children: [
              // Indexing progress banner
              BlocBuilder<ChatBloc, ChatState>(
                builder: (context, state) {
                  if (state.indexingProgress == null) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
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
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
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
                      // Chỉ scroll khi text thay đổi (phiên bản đầu tiên của tin nhắn mới)
                      // Tránh scroll quá nhiều gây conflict với SelectableText
                      _scrollToBottom();
                    }
                    if (state.feedbackVersion != _lastFeedbackVersion &&
                        state.feedbackMessage != null &&
                        state.feedbackMessage!.isNotEmpty) {
                      _lastFeedbackVersion = state.feedbackVersion;
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(state.feedbackMessage!),
                            backgroundColor: state.feedbackIsError
                                ? Colors.red
                                : Colors.black87,
                          ),
                        );
                    }
                  },
                  builder: (context, state) {
                    final isModelMissing = !state.isModelDownloaded && !state.isModelLoaded;
                    final showDownloadUI = state.status == ChatStatus.needsDownload || state.isDownloading || (state.status == ChatStatus.error && isModelMissing);

                    if (state.status == ChatStatus.checkingStartup) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              'Initializing on-device components...',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    if (showDownloadUI) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Card(
                            elevation: 4,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(32.0),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      state.status == ChatStatus.error 
                                        ? Icons.error_outline
                                        : Icons.cloud_download_outlined,
                                      size: 48,
                                      color: state.status == ChatStatus.error
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                    state.status == ChatStatus.error
                                      ? 'Download Failed'
                                      : 'On-Device AI Model Required',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: state.status == ChatStatus.error 
                                        ? Theme.of(context).colorScheme.error
                                        : null,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    state.status == ChatStatus.error && state.errorMessage != null
                                      ? state.errorMessage!
                                      : 'To start chatting completely offline, you need to download the Gemma 4 E2B model (~2.6 GB). This will be cached locally on your device.',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  if (state.isDownloading) ...[
                                    Text(
                                      state.isDownloadPaused
                                          ? 'Download paused: ${(state.downloadProgress * 100).toStringAsFixed(1)}%'
                                          : 'Downloading... ${(state.downloadProgress * 100).toStringAsFixed(1)}%',
                                      style: const TextStyle(fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 12),
                                    LinearProgressIndicator(value: state.downloadProgress),
                                    const SizedBox(height: 20),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        if (state.isDownloadPaused)
                                          ElevatedButton.icon(
                                            onPressed: () {
                                              context.read<ChatBloc>().add(const ResumeModelDownload());
                                            },
                                            icon: const Icon(Icons.play_arrow),
                                            label: const Text('Resume'),
                                          )
                                        else
                                          ElevatedButton.icon(
                                            onPressed: () {
                                              context.read<ChatBloc>().add(const PauseModelDownload());
                                            },
                                            icon: const Icon(Icons.pause),
                                            label: const Text('Pause'),
                                          ),
                                        const SizedBox(width: 12),
                                        OutlinedButton.icon(
                                          onPressed: () {
                                            context.read<ChatBloc>().add(const CancelModelDownload());
                                          },
                                          icon: const Icon(Icons.close),
                                          label: const Text('Cancel'),
                                        ),
                                      ],
                                    ),
                                  ] else
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        context.read<ChatBloc>().add(const DownloadModel());
                                      },
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(30),
                                        ),
                                        backgroundColor: state.status == ChatStatus.error
                                          ? Theme.of(context).colorScheme.errorContainer
                                          : null,
                                        foregroundColor: state.status == ChatStatus.error
                                          ? Theme.of(context).colorScheme.onErrorContainer
                                          : null,
                                      ),
                                      icon: Icon(state.status == ChatStatus.error ? Icons.refresh : Icons.download),
                                      label: Text(state.status == ChatStatus.error ? 'Retry' : 'Download Model (~2.6GB)'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }

                    if (state.messages.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.2),
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
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Colors.grey,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              state.useRag
                                  ? 'RAG Mode Active (${state.documentCount} docs indexed)'
                                  : 'Standard Mode. Open config (tune icon) to set up RAG.',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
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
                        return _MessageBubble(message: state.messages[index]);
                      },
                    );
                  },
                ),
              ),

              // Input bar
              BlocBuilder<ChatBloc, ChatState>(
                builder: (context, state) {
                  final isGenerating = state.status == ChatStatus.generating;
                  final isLoadingModel = state.status == ChatStatus.loadingModel;
                  final isChecking = state.status == ChatStatus.checkingStartup;
                  final needsDownload = state.status == ChatStatus.needsDownload || state.isDownloading;
                  final canSend = !isGenerating && !isLoadingModel && !isChecking && !needsDownload && state.isModelLoaded;

                  return Container(
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
                              enabled: canSend,
                              decoration: InputDecoration(
                                hintText: needsDownload
                                    ? 'Download model to start chatting'
                                    : (isLoadingModel
                                        ? 'Loading model into memory...'
                                        : (isChecking
                                            ? 'Initializing...'
                                            : 'Type a message...')),
                                border: const OutlineInputBorder(
                                  borderRadius: BorderRadius.all(Radius.circular(24)),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                              ),
                              maxLines: 4,
                              minLines: 1,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => canSend ? _onSend() : null,
                            ),
                          ),
                          const SizedBox(width: 8),
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: canSend
                                ? Theme.of(context).colorScheme.primary
                                : (isGenerating
                                      ? Theme.of(context).colorScheme.errorContainer
                                      : Colors.grey[200]),
                            child: IconButton(
                              onPressed: isGenerating
                                  ? () {
                                      context.read<ChatBloc>().add(
                                        const CancelGeneration(),
                                      );
                                    }
                                  : (canSend ? _onSend : null),
                              icon: isLoadingModel || isChecking
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      isGenerating ? Icons.stop : Icons.send,
                                      color: isGenerating
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onErrorContainer
                                          : (canSend ? Colors.white : Colors.grey),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          BlocBuilder<ChatBloc, ChatState>(
            builder: (context, state) {
              if (state.status != ChatStatus.loadingModel) {
                return const SizedBox.shrink();
              }

              return ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Loading model into memory...'),
                          SizedBox(height: 8),
                          Text(
                            'Please wait while LiteRT-LM is prepared.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
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
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
      status = state.isDownloadPaused ? 'Download Paused' : 'Downloading...';
      details =
          '${(state.downloadProgress * 100).toStringAsFixed(1)}% complete';
      icon = state.isDownloadPaused ? Icons.pause_circle_outline : Icons.downloading_outlined;
      color = Colors.orange;
    } else if (state.status == ChatStatus.loadingModel) {
      status = 'Loading...';
      details = 'Preparing LiteRT-LM in memory';
      icon = Icons.hourglass_top_outlined;
      color = Colors.deepPurple;
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
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (state.isDownloadPaused)
                    ElevatedButton.icon(
                      onPressed: () {
                        context.read<ChatBloc>().add(const ResumeModelDownload());
                      },
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('Resume'),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: () {
                        context.read<ChatBloc>().add(const PauseModelDownload());
                      },
                      icon: const Icon(Icons.pause, size: 16),
                      label: const Text('Pause'),
                    ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      context.read<ChatBloc>().add(const CancelModelDownload());
                    },
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
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
            if (state.isModelDownloaded &&
                !state.isModelLoaded &&
                !state.isDownloading &&
                state.status != ChatStatus.loadingModel)
              ElevatedButton.icon(
                onPressed: () {
                  context.read<ChatBloc>().add(const PreloadModel());
                },
                icon: const Icon(Icons.bolt),
                label: const Text('Load Model'),
              ),
            if (state.status == ChatStatus.loadingModel) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (state.isModelDownloaded && !state.isDownloading) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  context.read<ChatBloc>().add(const DeleteModel());
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text(
                  'Delete Model File',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
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
                const Icon(
                  Icons.article_outlined,
                  size: 20,
                  color: Colors.grey,
                ),
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
                context.read<ChatBloc>().add(
                  const IndexDocument(
                    title: 'SlmApp Offline Guide',
                    content:
                        'SlmApp is a fully offline, private AI chatbot built with Flutter, LiteRT-LM, and Gemma 4 E2B Instruct. It operates 100% on-device. Key features include a memory-efficient resumable downloader for the 2.6GB model, streaming token generation, and an offline RAG (Retrieval-Augmented Generation) pipeline using in-memory vector cosine similarity. Standard document formats supported are plain text and markdown. Designed by the TMA AI Team.',
                  ),
                );
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
                label: const Text(
                  'Clear Vector Store',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
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
    final alignment = isUser
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;

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
            child: SelectableText(
              message.text,
              style: TextStyle(
                color: isUser
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
            child: Text(
              isUser ? 'You' : 'Gemma 4 E2B',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}