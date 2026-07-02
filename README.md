# App Blueprint

Reusable Flutter starter for teams shipping multiple iOS and Android apps with:


- a real Flutter project already generated for `android` and `ios`
- Firebase Core, Firestore, and FCM dependencies already wired in
- a starter screen that proves Firestore reads and FCM token generation
- GitHub Actions for validation, Android bundle builds, Google Play release, TestFlight upload, and App Store submission
- Fastlane lanes for Google Play and App Store Connect delivery
- starter Firestore rules and indexes

This repository is intended to become a GitHub template repository.

## How To Read This README

This document is split into two operating phases:

1. `Per-App Setup`
2. `Per-Release Runbook`

Use it in that order.

## What Is Included

- `lib/`: starter app structure, Firebase bootstrap, Firestore repository, FCM permission/token flow
- `.github/workflows/`: CI/CD workflows for validation and releases
- `.github/workflows/bootstrap-template.yml`: renames the template from GitHub Actions and commits the changes back to the branch
- `.github/workflows/firestore-deploy.yml`: deploys Firestore rules and indexes from GitHub Actions
- `.github/workflows/release-train.yml`: one dispatch entry point that fans out to Android Google Play and iOS release workflows
- `fastlane/`: reusable lanes for Google Play and App Store Connect delivery
- `scripts/`: internal workflow helpers used by GitHub Actions plus one-time local secret-generation helpers
- `firebase.json` and `firebase/`: Firestore rules and indexes scaffold

## Per-App Setup

Do this every time you create a new app from the template.

### 1. Create the New Repository

1. Create a new repository from this template.
2. Push the template code to the new repo.
3. Complete the preplanning steps below before running any release workflows.

### 2. Create the Store and Apple Records First

Choose the final production identifier once and reuse it everywhere.

Example:

- bundle ID / application ID: `com.acme.customer`
- Dart package: `acme_customer`
- display name: `Acme Customer`

Create these external records first using that exact same bundle ID:

- Google Play app listing
- Apple App ID / bundle identifier
- App Store Connect app

Google Play Console:

1. Create the app listing: https://play.google.com/console/u/0/developers/4889780620286810958/app-list

Apple:

1. Create the App ID using the final bundle ID: https://developer.apple.com/account/resources/identifiers/list
2. Enable `Push Notifications` on the App ID.
3. Create the App Store Connect app using that same bundle ID: https://appstoreconnect.apple.com/
4. Record the numeric Apple app ID after creation. Convention: au.com.grovve.*APPNAME*.app

In this template:

- `application_id` is the bootstrap workflow input name
- `BUNDLE_ID` is the GitHub Actions variable name used later by release workflows

They should always be the exact same value.

### 3. Bootstrap the Template

Run `Bootstrap App Template` from the GitHub Actions UI after the external records already exist.

Inputs:

- `dart_package`: `app_name`
- `display_name`: `App Name`
- `application_id`: `au.com.grovve.*APPNAME*.app`

What this workflow does:

- runs the rename helper
- runs `flutter pub get`
- commits the changes back to the current branch

What this changes:

- Dart package name in `pubspec.yaml`
- Android `namespace`, `applicationId`, manifest label, and Kotlin package path
- iOS bundle identifiers inside `Runner.xcodeproj`
- visible app name in the starter UI and `Info.plist`

Local fallback if needed:

```bash
./scripts/bootstrap_new_app.sh \
  --dart-package acme_customer \
  --display-name "Acme Customer" \
  --application-id com.acme.customer
flutter pub get
```

### 4. Populate GitHub Secrets and Variables

After bootstrap, run the local secrets bootstrap from the target app repo root.

Copy-pasteable local example:

```bash
ruby ./scripts/bootstrap_github_secrets.rb \
  --bundle-id com.acme.customer \
  --certificate-id 2P8565M49U \
  --shared-secrets-file /Users/henry/Dev/POC/shared-secrets/android-gha-secrets.env
```
Henry will share the .env file when you need to run this

What this new script does:

- reads the shared Android and Apple credential values from `shared-secrets/android-gha-secrets.env`
- uses the App Store Connect API key from that file to create an `IOS_APP_STORE` provisioning profile for the existing Apple App ID
- attaches that new provisioning profile to the specified Apple distribution certificate
- stores the generated base64 provisioning profile as `IOS_PROVISIONING_PROFILE_BASE64`
- stores the other required GitHub Actions secrets on the current repository with `gh secret set`
- sets GitHub Actions variables for `APP_STORE_APPLE_ID`, `BUNDLE_ID`, and `IOS_TEAM_ID`


Important matching rules:

- set `BUNDLE_ID` to the same value you passed into bootstrap as `application_id`
- this template uses the same identifier for Android and iOS, so `BUNDLE_ID` should match both platform project settings after bootstrap
- `BUNDLE_ID`, `IOS_TEAM_ID`, and `APP_STORE_APPLE_ID` can be created by `./scripts/bootstrap_github_secrets.rb`
- `FIREBASE_PROJECT_ID` still needs to be created manually before running release workflows

Where the values come from:

- Henry-provided shared values:
  - `ANDROID_KEYSTORE_BASE64`
  - `ANDROID_KEYSTORE_PASSWORD`
  - `ANDROID_KEY_ALIAS`
  - `ANDROID_KEY_PASSWORD`
  - `IOS_DISTRIBUTION_CERTIFICATE_P12_BASE64`
  - `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
  - `APP_STORE_CONNECT_KEY_ID`
  - `APP_STORE_CONNECT_ISSUER_ID`
  - `APP_STORE_CONNECT_API_KEY_BASE64`
  - `IOS_TEAM_ID`
  - `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
- app-specific values you create during setup:
  - `BUNDLE_ID`
  - `FIREBASE_PROJECT_ID`
  - `APP_STORE_APPLE_ID`
  - `FIREBASE_SERVICE_ACCOUNT_JSON`
  - `IOS_PROVISIONING_PROFILE_BASE64`

### 5. Create the Firebase Project

Create one Firebase project for the app, or one per environment if your team separates `dev`, `staging`, and `prod`.

Recommended minimum products:

- Cloud Firestore
- Cloud Messaging
- Analytics if needed later

### 6. Generate FlutterFire Config

This is still a one-time developer step per app because it generates app-specific source files that should be committed:

```bash
flutterfire configure \
  --project=your-firebase-project-id \
  --platforms=android,ios \
  --out=lib/firebase_options.dart
```

Commit the generated `lib/firebase_options.dart`.

### 7. Configure Firestore Rules and Indexes

The repository already includes:

- `firebase/firestore.rules`
- `firebase/firestore.indexes.json`
- `firebase.json`

Preferred path: run `Deploy Firestore Configuration` from GitHub Actions.

Required repo config:

- variable: `FIREBASE_PROJECT_ID`
- secret: `FIREBASE_SERVICE_ACCOUNT_JSON`

Local fallback:

```bash
cp .firebaserc.example .firebaserc
# edit the project id inside .firebaserc
firebase deploy --only firestore
```

The default rules allow:

- public read access to `announcements`
- authenticated writes only

Tighten these before production if your app uses private data.

### 8. Seed the Firestore Smoke-Test Collection

The starter screen reads the first 10 documents from the `announcements` collection.

Example document:

```json
{
  "title": "Welcome",
  "body": "Your Firebase scaffold is working.",
  "updatedAt": "server timestamp"
}
```

### 9. Set Up Push Notifications

Android:

- no additional native edits are required beyond valid Firebase config and a real device for token testing
- Android 13+ notification permission is already declared in the manifest

iOS:

- open `ios/Runner.xcworkspace` in Xcode
- select the `Runner` target
- add the `Push Notifications` capability
- add `Background Modes`, then enable `Remote notifications`
- make sure the Apple App ID also has Push Notifications enabled
- commit the resulting Xcode project changes after enabling the capabilities

The repo already sets `remote-notification` in `Info.plist`, but Apple capabilities still must be enabled in Xcode and in the Apple portal.

### 10. Finish Store Configuration

Before your first real release:

- complete the Google Play app content sections such as App access, Ads, Content rating, Target audience, and Data safety
- invite the Google Play service account in `Users and permissions` and grant the app-level permissions needed for CI
- add the privacy policy URL to both stores
- complete App Store Connect metadata, App Privacy, export compliance, and any required account agreements

### 11. Enroll the App in Play App Signing

Use Google Play App Signing for every app. Treat your upload keystore as the CI/CD upload key.

### 12. Local Development Quick Start

Use this when an engineer wants to run the app locally on an Android emulator or device.

From the repository root:

```bash
cd /path/to/your/app-repo
# Install Flutter on macOS if needed:
# brew install flutter
# Alternative:
# bash ./scripts/install_flutter_sdk.sh "$HOME/flutter"
# export PATH="$HOME/flutter/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
flutter pub get
```

If an emulator already exists, launch it:

```bash
flutter emulators
flutter emulators --launch <emulator_id>
```

Or start it from Android Studio Device Manager.

Confirm Flutter can see the target:

```bash
flutter devices
```

Run the app:

```bash
flutter run
```

If more than one device is connected:

```bash
flutter run -d <device_id>
```

If you want to build and install a debug APK manually:

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Expected behavior before Firebase is configured:

- the app still launches
- the starter screen shows Firebase setup guidance
- Firestore and FCM remain in not-configured mode until `lib/firebase_options.dart` is generated and committed

Useful troubleshooting commands:

```bash
flutter doctor -v
adb devices
```

## Per-Release Runbook

This is the repeatable operator workflow after an app has already been set up.

### Default Entry Point

Use `Release Train` when you want one operator action to kick off Android and iOS release workflows together.

It can trigger:

- Android Google Play release
- iOS TestFlight upload
- iOS App Store submission

Guardrails built into `Release Train`:

- at least one release target must be selected
- TestFlight and App Store submission cannot run in the same execution
- one shared CI build number is passed to every selected platform in the same run

Do not use `Release Train` for the first-ever Android upload to a new Play app. Do that first upload manually after running `Build Android App Bundle`.

### Versioning Behavior

- the marketing version comes from `pubspec.yaml`
- the CI build number is generated automatically in GitHub Actions using a UTC timestamp
- rerunning a failed workflow produces a new build number automatically

### Recommended Release Paths

Android first app setup:

- run `Build Android App Bundle`
- manually upload the `.aab` to the Play Console app record
- confirm the package name, signing, and internal testing setup are accepted

Android internal testing after first manual upload:

- run `Release Train`
- set `release_android=true`
- set `android_track=internal`
- leave iOS release targets disabled

Android plus TestFlight:

- run `Release Train`
- set `release_android=true`
- set `android_track=internal`
- set `release_ios_testflight=true`
- optionally set `ios_groups`
- leave `release_ios_app_store=false`

iOS App Store submission only:

- run `Release Train`
- set `release_android=false`
- set `release_ios_testflight=false`
- set `release_ios_app_store=true`

Apple testing only:

- run `Upload iOS Build to TestFlight` or use `Release Train` with only TestFlight enabled
- use this for internal or external testing

Apple App Store submission:

- run `Submit iOS Build to App Store` or use `Release Train` with only App Store enabled
- use this only after TestFlight testing is complete and the build is ready for review

### Lower-Level Workflows

Use these only when you need a platform-specific action:

- `Validate Flutter Starter`: runs `flutter analyze` and `flutter test`
- `Build Android App Bundle`: creates a signed `.aab` artifact for manual upload or inspection
- `Release Android to Google Play`: builds the `.aab` and uploads it to the chosen Play track
- `Upload iOS Build to TestFlight`: builds a signed IPA and uploads it to TestFlight for testing
- `Submit iOS Build to App Store`: builds a signed IPA and submits it for App Store review
- `Bootstrap App Template`: renames the template and commits the changes back to the branch
- `Deploy Firestore Configuration`: deploys Firestore rules and indexes

When to use each:

- `Build Android App Bundle`
  - use for the first Android upload to a brand new Play app
  - use when you want to manually inspect or upload the `.aab`
- `Release Android to Google Play`
  - use after the first manual Play Console upload is complete
  - use to send builds into `internal` or later tracks
- `Upload iOS Build to TestFlight`
  - use for internal and external Apple testing
  - this does not submit the app for App Store review
- `Submit iOS Build to App Store`
  - use only when testing is finished and you want Apple review to begin
- `Release Train`
  - use when you want one dispatch to kick off Android internal release plus TestFlight, or any approved cross-platform release combination
  - avoid it for one-off setup tasks where a single lower-level workflow is clearer

### Workflow Requirements

`Validate Flutter Starter`:

- no signing secrets required

`Build Android App Bundle`:

- Android signing secrets required

`Release Android to Google Play`:

- Android signing secrets required
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
- `BUNDLE_ID`

`Deploy Firestore Configuration`:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_SERVICE_ACCOUNT_JSON`

`Upload iOS Build to TestFlight`:

- Apple signing secrets required
- App Store Connect API secrets required
- `BUNDLE_ID`
- `IOS_TEAM_ID`
- optionally `APP_STORE_APPLE_ID`

`Submit iOS Build to App Store`:

- same requirements as TestFlight upload

`Release Train`:

- uses the same secrets as the platform workflows it triggers
- requires at least one selected release target

## Suggested Repository Settings

Recommended GitHub repository settings for each duplicated app repo:

- mark the original blueprint repo as a template
- protect `main`
- require pull request review
- require the `Validate Flutter Starter` workflow before merge
- store production release workflows behind GitHub Environments if you want approval gates

## Privacy Policy Dependency

Both stores expect a live privacy policy URL. Use the separate `privacy-policy-template` repository in this workspace, publish it with GitHub Pages, and place that public URL into:

- Google Play store listing
- App Store Connect app information
- Firebase Auth or other provider dashboards if needed later

## Additional Considerations

- Create separate Firebase projects for `dev`, `staging`, and `prod` if release safety matters.
- Keep the keystore, `.p12`, `.mobileprovision`, and `.p8` out of git forever.
- Commit `lib/firebase_options.dart`.
- Commit the Xcode project changes required for iOS capabilities.
- Add app icons, splash screens, and real bundle ids before the first store build.
- Decide early whether each app will share one Firebase project or use one project per app.
- Consider adding store metadata automation later through `fastlane/metadata` once your team settles on a content process.
- Consider adding a backend-triggered push workflow later if you want scheduled or server-side FCM sends.

## Official References Used For This Scaffold

- FlutterFire overview: https://firebase.google.com/docs/flutter/setup
- Firestore for Flutter: https://firebase.google.com/docs/firestore/quickstart
- FCM for Flutter: https://firebase.google.com/docs/cloud-messaging/flutter/client
- Android app signing: https://developer.android.com/studio/publish/app-signing
- Google Play Developer API and service accounts: https://developers.google.com/android-publisher
- Google Play Console app setup: https://support.google.com/googleplay/android-developer
- App Store Connect app setup: https://developer.apple.com/help/app-store-connect/create-an-app-record
- App Store Connect API keys: https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
