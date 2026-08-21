# Build verification for v18

Before release, run in CI:
- flutter pub get
- flutter analyze
- flutter test
- flutter build apk --release

The repository workflow should build the existing Android project directly and must not run `flutter create`.
