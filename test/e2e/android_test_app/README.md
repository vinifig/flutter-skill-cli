# Flutter Skill — Android Test App

Native Android Kotlin app for E2E testing the Flutter Skill Android SDK.

## Features

- Counter with increment/decrement buttons
- Text input with submit
- CheckBox
- RecyclerView with 20 items
- Navigation to DetailActivity

## Build

```bash
./gradlew assembleDebug
```

All interactive elements have `contentDescription` set for selector-based targeting.
