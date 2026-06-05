# skills/model-loader.md — Model Download & Cache

## Reusable Skill: Download LLM Model với Progress

Skill này dùng cho **bất kỳ** feature nào cần download model lớn (LiteRT, ONNX...).

## Implementation

```dart
class ModelDownloader {
  final Dio _dio;
  final Directory _cacheDir;

  /// Download model với resume support + checksum verify
  Stream<DownloadProgress> download({
    required String url,
    required String fileName,
    required String expectedSha256,
  }) async* {
    final file = File('${_cacheDir.path}/$fileName');

    // 1. Check cache
    if (await file.exists()) {
      final hash = await _sha256(file);
      if (hash == expectedSha256) {
        yield DownloadProgress.complete(file.path);
        return;
      }
      await file.delete(); // corrupt cache
    }

    // 2. Download với progress
    final tempFile = File('${file.path}.tmp');
    final existingBytes = await tempFile.exists()
        ? await tempFile.length()
        : 0;

    await _dio.download(
      url,
      tempFile.path,
      options: Options(
        headers: existingBytes > 0
            ? {'Range': 'bytes=$existingBytes-'}
            : null,
      ),
      onReceiveProgress: (received, total) {
        // yield không work trong callback → dùng StreamController
      },
      deleteOnError: false,  // giữ partial download để resume
    );

    // 3. Verify + rename
    final hash = await _sha256(tempFile);
    if (hash != expectedSha256) {
      await tempFile.delete();
      throw ModelDownloadException('Checksum mismatch');
    }
    await tempFile.rename(file.path);
    yield DownloadProgress.complete(file.path);
  }

  Future<String> _sha256(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }
}

// Progress model
class DownloadProgress {
  final double percent;      // 0.0 - 1.0
  final int bytesReceived;
  final int totalBytes;
  final bool isComplete;
  final String? filePath;    // non-null khi complete

  const DownloadProgress.complete(this.filePath)
      : percent = 1.0, bytesReceived = 0, totalBytes = 0, isComplete = true;
}
```

## Gemma 4 2B Model Info

```dart
const kGemma4_2B = ModelConfig(
  name: 'Gemma 4 2B Instruct',
  fileName: 'gemma-4-2b-it.task',
  // URL từ HuggingFace (cần token nếu gated)
  downloadUrl: 'https://huggingface.co/google/gemma-4-2b-it-litert-lm/resolve/main/gemma-4-2b-it.task',
  sizeBytes: 2_200_000_000,  // ~2.2GB (estimate)
  sha256: 'TODO_FILL_AFTER_DOWNLOAD',
  contextLength: 8192,
  dimensions: null,  // không dùng cho inference model
);
```

## UI Widget (reusable)

```dart
class ModelDownloadButton extends StatelessWidget {
  // Hiển thị:
  // - "Tải model (~2.2GB)" nếu chưa có
  // - LinearProgressIndicator + "45% - 1.2GB/2.2GB" khi đang tải
  // - "Đã sẵn sàng ✓" nếu có rồi
}
```

## Notes

- **HuggingFace gated models**: cần user login + accept terms → redirect browser
- **Storage check**: verify device có đủ 3GB free trước khi download
- **WiFi only option**: check ConnectivityResult trước khi bắt đầu
