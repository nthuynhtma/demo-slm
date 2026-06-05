# rules/generation-pipeline.md — Generation Pipeline

## Canonical Pipeline

```text
Send Message
-> EnsureModelLoaded
-> RetrieveContext (optional)
-> TokenBudgeting
-> Generate
-> Batch UI Updates
-> Finalize Message
```

## Stage Responsibilities

### 1. EnsureModelLoaded

- Confirm the model is available in memory.
- Allow loading of an already downloaded model.
- Do not trigger the first-time download here.

### 2. RetrieveContext

- Retrieve optional RAG context when enabled.
- Fail soft: if retrieval fails, continue without context unless product behavior says otherwise.

### 3. TokenBudgeting

- Allocate the context window across:
  - system prompt
  - conversation history
  - retrieved context
  - response headroom
- This stage exists even when RAG is disabled.

### 4. Generate

- Serialize the final prompt after budgeting decisions are complete.
- Start inference only once the final prompt is stable.

### 5. Batch UI Updates

- Aggregate raw partials before committing them to UI state.
- Preserve strict ordering of generated text.

### 6. Finalize Message

- Flush any remaining buffered partial text.
- Mark the assistant message as no longer streaming.
- Transition to the appropriate terminal state: ready, cancelled, or error.

## Guardrails

- Do not mutate committed user-visible text out of order.
- Do not skip token budgeting when context injection is enabled.
- Do not treat prompt building and token budgeting as the same concern.
- Do not leave a dangling streaming message after completion, cancellation, or error.

## Recommended Tests

- send with downloaded-and-loaded model
- send with downloaded-but-not-loaded model
- send with missing model should not auto-download
- send with RAG enabled and empty retrieval result
- send with token budget overflow
- send with cancellation during generation
