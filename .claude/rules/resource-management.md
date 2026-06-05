# rules/resource-management.md — Memory and Resource Management

## Purpose

Define how the app manages large native resources such as the LiteRT-LM model.

## Core Rules

### 1. Model resources are scarce

Treat loaded model state as a high-memory resource.
Loading and releasing it must be deliberate.

### 2. Background may trigger release

When the app moves to the background, the app may release model resources if required by policy, platform constraints, or memory pressure.

### 3. Release does not mean delete

Releasing native inference memory must not delete the downloaded model file unless the user explicitly requests deletion.

### 4. Message state must survive release

Committed conversation history must remain intact even if the model is released from memory.

### 5. Streaming must terminate cleanly

If the model is released while generation is active:
- cancel generation first
- flush any safe buffered text
- finalize the message deterministically

### 6. Startup and typing may reload

After a release, startup or typing may preload the model again according to workflow rules.

## Recommended Resource Policy

- preload on startup when downloaded
- optionally warm on typing when downloaded but not loaded
- release on background when policy requires it
- reload lazily through `EnsureModelLoaded` if a downloaded model was released

## Storage Notes

- Keep the model file in `ApplicationSupport`
- Exclude large files from backup where appropriate
- Track durable metadata for startup checks

## Testing Expectations

- background after ready
- background during generation
- foreground after release
- delete model after release
- retry preload after release failure
