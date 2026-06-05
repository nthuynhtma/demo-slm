# skills/model-loader.md — Explicit Model Download, Preload, and Release

## When to Use

Use this guidance for any feature that manages a large local model lifecycle:
- LiteRT-LM inference models
- local embedding models
- other downloadable on-device ML artifacts

## Architecture Rule

Model management is now split into separate responsibilities:
- **check status**
- **download**
- **preload/load**
- **ensure loaded**
- **release**
- **delete**

Do not collapse these into one method.

## Canonical Flow

```text
App Start
-> Check model status
-> If missing: prompt download
-> If downloaded: preload model

User Typing
-> Preload model if needed

Send Message
-> EnsureModelLoaded
-> Generate

App Background
-> Release model resources if required
```

## Key Rule

`EnsureModelLoaded` must not trigger the first download.
If no model file exists, the caller should transition into an explicit download UX instead.

## Recommended Service Shape

```dart
abstract class ModelLifecycleService {
  Future<bool> isModelDownloaded();
  Future<String> downloadModel({
    void Function(double progress)? onProgress,
  });
  Future<void> preloadModel();
  Future<void> ensureModelLoaded();
  Future<void> releaseModel();
  Future<bool> deleteModel();
}
```

## Downloader Guidance

- Support resumable downloads
- Validate free storage before download
- Verify checksum in a streaming fashion
- Persist the local file path or durable model metadata
- Keep partial download files for resume when safe

## Loader Guidance

- Preload should be safe to call more than once
- Preload should only operate on an already downloaded file
- Release should unload native resources without deleting the model file
- Delete should release before removing files

## Startup Guidance

- Run model status checks during startup
- Auto-preload if the model exists locally
- Show a download CTA if it does not

## UI Guidance

Expose distinct states:
- not downloaded
- downloading
- downloaded
- preloading
- loaded
- error

Do not label a downloaded-but-not-loaded model as fully ready.

## Gemma 4 E2B Model Info

```dart
const kGemma4E2B = ModelConfig(
  name: 'Gemma 4 E2B Instruct',
  fileName: 'gemma-4-E2B-it.litertlm',
  downloadUrl: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
  sizeBytes: 2_580_000_000,
  sha256: 'TODO_FILL_AFTER_DOWNLOAD',
  contextLength: 8192,
);
```

## Notes

- Mobile format is `.litertlm`
- Web format is `.task`
- Store the model under `ApplicationSupport`
- Treat release-from-memory and delete-from-disk as separate user-visible behaviors
