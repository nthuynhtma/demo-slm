# CLAUDE.local.md — Private Settings (KHÔNG push lên GitHub)

## Local Development Paths

```
# Model cache local (thay đổi theo máy)
MODEL_CACHE_DIR=~/Downloads/models/

# Android emulator hay physical device?
# Emulator KHÔNG chạy được LiteRT-LM GPU delegate → dùng physical device
ANDROID_TARGET=physical  # physical | emulator
```

## HuggingFace Token

```
# Optional: repo mobile hiện tại không gated, chỉ cần nếu sau này dùng repo gated khác
HF_TOKEN=hf_xxxxxxxxxxxxx  # điền token của bạn nếu cần
```

## Test Devices

```
Android: [điền tên device của bạn]
iOS:     [điền tên device của bạn]
```

## Known Local Issues

- [ ] Ghi lại issues gặp phải trên máy cụ thể ở đây

## Debug Flags

```dart
// Thêm vào launch config local
--dart-define=USE_MOCK=true          # dùng mock inference
--dart-define=SKIP_MODEL_CHECK=true  # bỏ qua kiểm tra model file
--dart-define=VERBOSE_RAG=true       # log chi tiết RAG retrieval
```
