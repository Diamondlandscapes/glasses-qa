# Glasses QA

iPhone app for Ray-Ban Meta and Oakley Meta glasses. It registers with the Meta AI app, takes a photo every few seconds, asks a vision model to answer any question in the frame, and speaks the answer through the current audio route (the glasses, when they are the Bluetooth headset).

Bundle id: `com.dustin.glassesqa`. Callback URL scheme: `glassesqa://`. API keys are typed into the app and stored in the iPhone Keychain. They are not in this repo.

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

## Vision provider

Settings has a picker with two options. **xAI Grok** is the default. **Google Gemini** is the other. Each provider has its own key in the Keychain.

1. For Grok, create a key at [console.x.ai](https://console.x.ai). The default model is `grok-4.20-0309-non-reasoning`, the fastest public Grok model that accepts images. It does not spend tokens on reasoning. `grok-4.7` always reasons; if you select it, the app sets reasoning effort to low.
2. For Gemini, create a free key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey). The default model is `gemini-2.5-flash-lite`. The free tier allows about 10 requests a minute.
3. In the app, tap the gear icon, paste the key for the provider you want, and tap **Save key**.
4. The same screen sets the minimum gap after an answer (1–10 seconds, default 1), the model name for the selected provider, and the speech rate. **Play a sample** checks that you can hear speech on the current route. **Snap now** takes one photo immediately.

A 429 from either provider skips that frame, shows a short status, and does not speak the error.

While **Start** is running, the next photo begins as soon as the previous answer returns, after the minimum gap. Each question is spoken as its own sentence, for example “Question 1: B, photosynthesis.” Speech already in progress is not cut off. A question number is spoken once unless its answer changes. The same list is shown on screen, along with the measured model round trip.

## Build

The workflow is `.github/workflows/build-ios.yml` (`macos-latest`, newest Xcode 26). It generates the Xcode project from `project.yml` with XcodeGen, archives with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`, then zips `Payload/GlassesQA.app` into the `.ipa`.

On a Mac you can do the same locally: install XcodeGen, run `xcodegen generate`, then archive with those signing flags.
