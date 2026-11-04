# Glasses QA

iPhone app for Ray-Ban Meta and Oakley Meta glasses. It registers with the Meta AI app, takes a photo every few seconds, asks a vision model to answer any question in the frame, and speaks the answer through the current audio route (the glasses, when they are the Bluetooth headset).

Bundle id: `com.dustin.glassesqa`. Callback URL scheme: `glassesqa://`. The OpenAI API key is typed into the app and stored in the iPhone Keychain. It is not in this repo.

The glasses SDK is [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios) **1.0.1** (`MWDATCore` and `MWDATCamera`).

## Install with Sideloadly on Windows

There is no Mac in this setup. GitHub Actions builds an **unsigned** Release `.ipa`. You sign it on Windows with a free Apple ID.

1. On GitHub, open **Actions → Build unsigned iOS app**. It runs on every push, or you can run it with **Run workflow**.
2. When the job is green, download the **GlassesQA-unsigned-ipa** artifact and unzip it. You want `GlassesQA-unsigned.ipa`.
3. Install [Sideloadly](https://sideloadly.io/) and Apple’s device support (iTunes, or the Apple Devices app from the Microsoft Store).
4. Plug in the iPhone, unlock it, and tap Trust.
5. Drag the `.ipa` into Sideloadly. Leave the bundle id as `com.dustin.glassesqa` unless Apple says that id is already in use.
6. Sign in with your Apple ID. If Apple asks, enter the verification code. Sideloadly signs the app; this project has no app-group, push, or Hotspot Configuration entitlement, so a free Apple ID can sign it.
7. On the iPhone open **Settings → General → VPN & Device Management**, trust the developer certificate, and launch **Glasses QA**.

A free Apple ID provisioning profile expires after about 7 days. Install the latest artifact again when the app stops opening.

Wi-Fi streaming from the glasses normally uses Apple's Hotspot Configuration entitlement. A free Apple ID cannot sign that, so this build leaves it out and declares the Bluetooth accessory protocol instead. If registration works but photos never arrive, that transport limit is the first thing to suspect.

## Developer Mode on the iPhone

After the first sideload, iOS shows **Settings → Privacy & Security → Developer Mode**. Turn it on and restart the phone. The app will not launch from a sideload until this is on.

## Developer Mode in the Meta AI app

1. Install the Meta AI app and pair the glasses there, as usual.
2. In Meta AI, open the glasses and turn on **Developer Mode** (Settings → your glasses → Developer Mode).
3. In Glasses QA, tap **Connect glasses**. Meta AI opens. Approve the app, and iOS should return here. The status changes to **Registered**.
4. The first **Start** may send you back to Meta AI to allow camera access. Allow it.
5. When iOS asks, allow Bluetooth and Local Network.

`MetaAppID` is `0` on purpose. Developer Mode skips Wearables attestation, so you do not need a Wearables Developer Center app id for this personal build.

## OpenAI API key

1. Create a key at [platform.openai.com](https://platform.openai.com/api-keys) for a model that can read images. The default model is `gpt-4o-mini`.
2. In the app, tap the gear icon.
3. Paste the key and tap **Save key**. It is stored in the Keychain on this phone.
4. The same screen sets the capture interval (2–10 seconds, default 4), the model name, and the speech rate. **Play a sample** checks that you can hear speech on the current route.

While **Start** is running, the app takes one photo at a time. If a frame has a clear question, it speaks a one or two sentence answer and shows the photo, the question, and the answer. It stays quiet when the model says there is no question, and it does not repeat the last question it already answered.

## Build

The workflow is `.github/workflows/build-ios.yml` (`macos-latest`, newest Xcode 26). It generates the Xcode project from `project.yml` with XcodeGen, archives with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`, then zips `Payload/GlassesQA.app` into the `.ipa`.

On a Mac you can do the same locally: install XcodeGen, run `xcodegen generate`, then archive with those signing flags.
