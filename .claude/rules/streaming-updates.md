# rules/streaming-updates.md — Streaming Updates

## Purpose

Define how raw native partials become user-visible assistant text.

## Rules

### 1. Preserve ordering

Raw partials must be applied in the exact order received.

### 2. Batch UI commits

The app may receive per-token or sub-token native callbacks.
UI state should coalesce those callbacks into batched updates when possible.

Typical flush triggers:
- timer interval
- minimum buffered length
- stream completion
- cancellation
- error

### 3. Flush before finalization

Any buffered text must be committed before:
- marking the message complete
- surfacing an error
- finishing cancellation

### 4. Keep transport and presentation separate

- native/platform layer emits raw partials
- Dart transport layer exposes a stream of partial text
- bloc/coordinator decides batching strategy
- UI renders committed message state

### 5. Cancellation is a finalization path

Stopping generation should keep already committed assistant text and optionally flush safe buffered text before the stream closes.

## Anti-Patterns

- rebuilding message state for every raw token without considering batching
- using a UI-only animation state as the source of truth for generated text
- dropping buffered partial text on completion or cancel
- leaving the assistant message marked as streaming after terminal events

## Validation Targets

- partial text survives cancel
- buffered text flushes on done
- error path does not leak streaming state
- batching reduces excessive rebuilds without changing text order
