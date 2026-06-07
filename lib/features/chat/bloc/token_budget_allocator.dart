import '../models/chat_message.dart';

/// Allocates Gemma 4 E2B's ~8192 token context window.
///
/// Divides context across:
/// 1. Response Headroom (reserved first, e.g. 1024 tokens)
/// 2. System Prompt (reserved second, e.g. 100 tokens)
/// 3. Retrieved RAG Context (capped, e.g. 2000 tokens)
/// 4. Conversation History (remaining budget filled via sliding window)
class TokenBudgetAllocator {
  final int totalContextWindow;
  final int responseHeadroom;
  final int systemPromptEstimate;
  final int maxRagContextTokens;

  const TokenBudgetAllocator({
    this.totalContextWindow = 8192,
    this.responseHeadroom = 1024,
    this.systemPromptEstimate = 100,
    this.maxRagContextTokens = 2000,
  });

  /// Estimates tokens in a text string.
  /// Uses a word-based heuristic (1 word ≈ 1.3 tokens) which is more accurate
  /// for mixed English/Vietnamese/Code content than simple character count.
  int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    
    // Split by whitespace to count words
    final words = text.trim().split(RegExp(r'\s+')).length;
    final wordBased = (words * 1.3).ceil();
    
    // Fallback/Safety check: ensures we don't underestimate extremely long 
    // strings without spaces (like long URLs or code).
    final charBased = (text.length / 3.5).ceil();
    
    // Return the larger of the two estimates for safety
    return wordBased > charBased ? wordBased : charBased;
  }

  /// Allocates budget and returns a list of history messages that fit within the remaining history budget.
  List<ChatMessage> allocate({
    required List<ChatMessage> history,
    required String systemPrompt,
    required String? retrievedContext,
    required String currentQuery,
  }) {
    // 1. Calculate reserved budgets
    final int systemPromptCost = estimateTokens(systemPrompt);
    final int currentQueryCost = estimateTokens(currentQuery);
    final int ragContextCost = retrievedContext != null ? estimateTokens(retrievedContext) : 0;

    // 2. Cap RAG context if it exceeds max allowed
    final int actualRagCost = ragContextCost.clamp(0, maxRagContextTokens);

    // 3. Determine remaining budget for conversation history
    final int reservedCost = responseHeadroom + systemPromptCost + actualRagCost + currentQueryCost;
    final int historyBudget = (totalContextWindow - reservedCost).clamp(0, totalContextWindow);

    // 4. Fill history using a sliding window (reversed search)
    final allocatedHistory = <ChatMessage>[];
    int currentHistoryCost = 0;

    for (final message in history.reversed) {
      if (message.text.trim().isEmpty) continue;
      final cost = estimateTokens(message.text);
      if (currentHistoryCost + cost > historyBudget) break;
      currentHistoryCost += cost;
      allocatedHistory.insert(0, message);
    }

    return allocatedHistory;
  }
}
