import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Represents a single logged conversation turn.
class ConversationLogEntry {
  final String id;
  final DateTime timestamp;
  final String userQuery;
  final String aiResponse;
  final bool wasCancelled;
  final bool hadError;
  final String? errorMessage;
  final bool usedRag;

  const ConversationLogEntry({
    required this.id,
    required this.timestamp,
    required this.userQuery,
    required this.aiResponse,
    this.wasCancelled = false,
    this.hadError = false,
    this.errorMessage,
    this.usedRag = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'userQuery': userQuery,
        'aiResponse': aiResponse,
        'wasCancelled': wasCancelled,
        'hadError': hadError,
        'errorMessage': errorMessage,
        'usedRag': usedRag,
      };

  factory ConversationLogEntry.fromJson(Map<String, dynamic> json) =>
      ConversationLogEntry(
        id: json['id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        userQuery: json['userQuery'] as String,
        aiResponse: json['aiResponse'] as String,
        wasCancelled: json['wasCancelled'] as bool? ?? false,
        hadError: json['hadError'] as bool? ?? false,
        errorMessage: json['errorMessage'] as String?,
        usedRag: json['usedRag'] as bool? ?? false,
      );
}

/// Abstract interface for chat logging.
///
/// Allows for real file-based logging and no-op test implementations.
abstract class IChatLogger {
  /// Log a completed conversation turn.
  Future<void> log(ConversationLogEntry entry);

  /// Read all log entries for today.
  Future<List<ConversationLogEntry>> readTodayLogs();

  /// Read all log entries across all files.
  Future<List<ConversationLogEntry>> readAllLogs();

  /// Get the directory path where logs are stored.
  String get todayLogPath;
  String get logDirectory;
}

/// Service for logging AI conversation responses to a local file.
///
/// Each conversation turn is appended to a daily log file:
///   `{ApplicationSupportDirectory}/chat_logs/{YYYY-MM-DD}.jsonl`
///
/// JSONL format (one JSON object per line) makes it easy to append,
/// search, and parse without loading the entire file.
class ChatLogger implements IChatLogger {
  static ChatLogger? _instance;
  late final String _logDir;

  ChatLogger._();

  /// Initialize the logger and ensure the log directory exists.
  static Future<ChatLogger> create() async {
    if (_instance != null) return _instance!;

    final appDir = await getApplicationSupportDirectory();
    final logDir = Directory('${appDir.path}/chat_logs');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }

    final logger = ChatLogger._();
    logger._logDir = logDir.path;
    _instance = logger;
    return logger;
  }

  /// Create a ChatLogger with a specific log directory (for testing).
  factory ChatLogger.withDirectory(String directory) {
    final logger = ChatLogger._();
    logger._logDir = directory;
    return logger;
  }

  /// Get the path to today's log file.
  String get _todayLogPath {
    final dateStr = DateTime.now().toIso8601String().substring(0, 10);
    return '$_logDir/$dateStr.jsonl';
  }

  @override
  String get todayLogPath => _todayLogPath;

  @override
  String get logDirectory => _logDir;

  @override
  Future<void> log(ConversationLogEntry entry) async {
    try {
      final file = File(_todayLogPath);
      final line = jsonEncode(entry.toJson());
      await file.writeAsString('$line\n', mode: FileMode.append);
    } catch (e) {
      // ignore: avoid_print
      print('[ChatLogger] Failed to write log: $e');
    }
  }

  @override
  Future<List<ConversationLogEntry>> readTodayLogs() async {
    return readLogsForDate(DateTime.now());
  }

  /// Read all log entries for a specific date.
  Future<List<ConversationLogEntry>> readLogsForDate(DateTime date) async {
    final dateStr = date.toIso8601String().substring(0, 10);
    final file = File('$_logDir/$dateStr.jsonl');

    if (!await file.exists()) return [];

    try {
      final lines = await file.readAsLines();
      return lines
          .where((line) => line.trim().isNotEmpty)
          .map((line) => ConversationLogEntry.fromJson(
                jsonDecode(line) as Map<String, dynamic>,
              ))
          .toList();
    } catch (e) {
      // ignore: avoid_print
      print('[ChatLogger] Failed to read logs: $e');
      return [];
    }
  }

  @override
  Future<List<ConversationLogEntry>> readAllLogs() async {
    final dir = Directory(_logDir);
    if (!await dir.exists()) return [];

    final entries = <ConversationLogEntry>[];
    try {
      final files = await dir
          .list()
          .where((entity) => entity.path.endsWith('.jsonl'))
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        final lines = await File(file.path).readAsLines();
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            entries.add(ConversationLogEntry.fromJson(
              jsonDecode(line) as Map<String, dynamic>,
            ));
          } catch (_) {}
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ChatLogger] Failed to read all logs: $e');
    }
    return entries;
  }
}

/// No-op implementation of [IChatLogger] for testing.
/// All methods are no-ops and never touch disk.
class NullChatLogger implements IChatLogger {
  final List<ConversationLogEntry> _inMemoryLogs = [];

  @override
  Future<void> log(ConversationLogEntry entry) async {
    _inMemoryLogs.add(entry);
  }

  @override
  Future<List<ConversationLogEntry>> readTodayLogs() async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return _inMemoryLogs
        .where((e) =>
            e.timestamp.toIso8601String().substring(0, 10) == today)
        .toList();
  }

  @override
  Future<List<ConversationLogEntry>> readAllLogs() async {
    return List.unmodifiable(_inMemoryLogs);
  }

  @override
  String get todayLogPath => '/dev/null/chat_logs';

  @override
  String get logDirectory => '/dev/null/chat_logs';
}