# rules/model-lifecycle.md — Model Lifecycle

## Purpose

Define the canonical lifecycle for the LiteRT-LM model in the app.

## Lifecycle Stages

```text
Not Downloaded
-> Downloaded on Disk
-> Preloaded in Memory
-> Ready for Generation
-> Released from Memory
```

## Core Rules

### 1. Download and load are separate

- Download stores the model artifact on disk.
- Preload/load brings the model into native memory.
- Releasing unloads native resources without necessarily deleting the file.

### 2. `EnsureModelLoaded` is not a downloader

`EnsureModelLoaded` may load an already downloaded model, but it must not hide the first download inside the send-message path.

### 3. Preload must be idempotent

Calling preload multiple times should be safe and should not recreate native state unnecessarily.

### 4. Delete must release first

Deleting the model file must release the loaded model first to avoid invalid file/resource usage.

### 5. Lifecycle state must be queryable

At minimum, the app should be able to distinguish:
- not downloaded
- downloaded but not loaded
- loaded / preloaded
- loading
- releasing
- error

## Startup Implications

- If the model is not downloaded, startup should present a download prompt or CTA.
- If the model is downloaded, startup should auto-preload it.

## Typing Implications

- Typing may trigger preload if the model is downloaded but not yet loaded.
- Typing-triggered preload should be debounced and low-risk.

## Background Implications

- Background transitions may release the model if required by policy.
- Releasing from memory must not imply deleting the downloaded file.

## Testing Expectations

Test at least these cases:
- downloaded vs not-downloaded startup branch
- preload on startup
- no implicit first-time download during send
- release on background
- re-entry after release
