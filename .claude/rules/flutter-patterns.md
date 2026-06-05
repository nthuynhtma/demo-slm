# rules/flutter-patterns.md — Flutter Conventions

## State Management

Use `flutter_bloc`. Do not introduce Provider or Riverpod for this project.

```text
App / Chat Workflow Bloc  -> startup flow, lifecycle, generation pipeline
Model Lifecycle Service   -> download status, preload, ensure-loaded, release
RAG Services              -> indexing, retrieval, document status
Settings State            -> temperature, max tokens, system prompt
```

## Architecture Pattern

Prefer a **coordinator + service boundary**:
- bloc/coordinator owns user-facing state transitions
- services own side effects and domain operations
- platform channel wrappers stay thin

Avoid a single handler that combines:
- startup checks
- implicit download
- model load
- retrieval
- token budgeting
- streaming accumulation
- finalization

These should be represented as explicit stages.

## Startup Flow Pattern

Startup should be event-driven and explicit:

```dart
abstract class AppEvent {}
class StartupRequested extends AppEvent {}
class StartupChecksCompleted extends AppEvent {}
class DownloadPromptConfirmed extends AppEvent {}
class PreloadRequested extends AppEvent {}
```

Recommended startup states:
- checking startup
- needs download
- preloading
- ready
- error

Run model-status and indexed-document checks in parallel when possible.

## Generation Pipeline Pattern

Treat send-message as a staged pipeline:

```text
SendMessage
-> EnsureModelLoaded
-> RetrieveContext (optional)
-> TokenBudgeting
-> Generate
-> Batch UI Updates
-> Finalize Message
```

Each stage should have one clear responsibility and be easy to test independently.

## Streaming UI Pattern

Do not rebuild the entire UI for every raw token if batching is available.
Prefer a short-lived buffer that flushes partial text on:
- a timer tick
- a size threshold
- completion
- cancellation
- error

Recommended rule:
- native emits raw partials
- bloc accumulates into a transient buffer
- bloc commits coalesced text into message state
- finalization flushes any remainder

## Lifecycle Pattern

Widgets or coordinators that own model-heavy features should observe app lifecycle where required:
- preload after successful startup when appropriate
- optionally warm the model while typing
- release resources on background if policy requires it

Lifecycle behavior must not discard already committed message text.

## Error Handling Convention

Wrap platform and domain failures in user-meaningful states.
Do not expose raw `PlatformException` directly to UI widgets.

```dart
sealed class InferenceError {
  const InferenceError();
}

class ModelMissing extends InferenceError {}
class ModelLoadFailed extends InferenceError {}
class OutOfMemory extends InferenceError {}
class GenerationTimeout extends InferenceError {}
class ModelCorrupted extends InferenceError {}
```

## Platform Channel Conventions

- Wrap calls in `try/catch PlatformException`
- Translate into domain-specific errors
- Keep methods asynchronous
- Keep wrappers transport-focused rather than orchestration-focused

## File and Folder Naming

```text
features/chat/
  ├── bloc/
  ├── models/
  ├── widgets/
  └── screens/

features/model_manager/
  ├── download/
  ├── loader/
  └── lifecycle/

features/rag/
  ├── indexer/
  ├── retriever/
  └── vector_store/
```

The exact migration shape can remain incremental, but names should reflect domain responsibility.

## Dependency Injection

`get_it` + `injectable` remains the preferred direction when dependency registration becomes large enough to justify it.

## Mock-First Development

Use `--dart-define=USE_MOCK=true` when validating UI and flow behavior without the native model.

Mocks should respect the architecture contract:
- mock startup should emulate downloaded vs missing model branches
- mock inference should require `loadModel()` before generation
- mock streaming should behave like raw partials, not pre-batched UI text
