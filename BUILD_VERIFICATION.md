# Build verification for v18

Before release, run in CI:
- flutter pub get
- flutter analyze
- flutter test
- flutter build apk --release

The repository workflow builds the existing Android project directly and does not run `flutter create`.
