# agents/reviewer.md — Code Reviewer

## Role

Agent review code cho project, tập trung vào **Platform Channel bridges** và **memory safety**.

## Review Checklist

### Platform Channel (Kotlin/Swift)

- [ ] Tất cả callbacks đều post về main thread trước khi gọi eventSink?
- [ ] `eventSink` được null-check trước khi gọi `.success()` / `.error()`?
- [ ] `llmInference?.cancel()` được gọi trong `onCancel` của StreamHandler?
- [ ] Native resources (LlmInference instance) được cleanup khi Flutter detach?
- [ ] Exception từ native được wrap thành PlatformException với meaningful code?

### Memory Management

- [ ] Model chỉ load 1 lần (singleton pattern)?
- [ ] `dispose()` được gọi khi user thoát chat screen?
- [ ] Embedding batch size không quá lớn gây OOM?
- [ ] StreamController được close khi generation kết thúc?

### Dart / Flutter

- [ ] Bloc state immutable (dùng copyWith, không mutate trực tiếp)?
- [ ] Không có async gap giữa check và use state?
- [ ] Error states được handle ở UI layer?
- [ ] Platform Channel calls trong try/catch?

### RAG

- [ ] SQLite transactions được dùng khi batch insert chunks?
- [ ] Vector search có index (sqlite_vec tự index)?
- [ ] `minScore` threshold ngăn irrelevant results vào context?
- [ ] Context length check trước khi append vào prompt?

## Review Output Format

```
### [File/Module]

**Critical** 🔴:
- ...

**Warning** 🟡:
- ...

**Suggestion** 🟢:
- ...
```
