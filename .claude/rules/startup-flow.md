# rules/startup-flow.md — Startup Flow

## Canonical Startup

```text
App Start
-> Check Model Status + Check Indexed Documents (in parallel)
-> Model Downloaded?
-> If not downloaded: prompt download
-> If downloaded: auto preload model
-> Ready
```

## Rules

### 1. Startup checks run in parallel

Model-status and indexed-document checks should run concurrently where practical.

### 2. Startup must branch explicitly

- Missing model -> show download prompt or clear CTA
- Downloaded model -> auto-preload

Do not silently stay idle in a "downloaded but not loaded" state if the target workflow expects preload at startup.

### 3. Ready means startup finished

The ready state should not be emitted until the startup branch has completed:
- download prompt shown, or
- preload completed successfully

### 4. Indexed-document status must be real

If startup surfaces indexed-document availability, the data source must survive app restarts.
In-memory-only reporting should be treated as temporary prototype behavior.

### 5. Startup errors must be recoverable

If preload fails, the app should move to a recoverable error state with a retry path.

## Recommended State Model

- `checkingStartup`
- `needsDownload`
- `preloading`
- `ready`
- `error`

## Recommended Events

- `StartupRequested`
- `StartupStatusResolved`
- `PreloadRequested`
- `PreloadCompleted`
- `StartupFailed`

## UX Notes

- Users should understand whether the app is downloading, preloading, or ready.
- Startup should not force a first-time large download without an explicit prompt.
