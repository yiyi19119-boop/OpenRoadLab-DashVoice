# DASHVOICE

<img src="assets/dashvoice-logo.jpg" width="120" alt="DashVoice app icon">

[中文说明](README.md)

**Stop typing. Start talking.** DashVoice is a small macOS menu bar app for getting thoughts out of your head and into a text field. It started on an old Intel Mac, with one idea: your agent can handle a little rambling, so give it the whole story.

Press `⌥Space` to record, then press it again to stop. DashVoice transcribes what you said and types it into the original field when it can verify the target. Otherwise, it copies the text to the clipboard. You decide when to hit Send.

**Install** · This MIT-licensed beta is available as source code. [Build it on your Mac](#build-from-source).

Tested on macOS 13 Ventura on Intel. The app declares macOS 12 as its minimum. Apple Silicon and other macOS versions are still untested.

## Build from source

You'll need the Xcode Command Line Tools. For transcription, bring your own Alibaba Cloud DashScope API key.

```bash
git clone https://github.com/yiyi19119-boop/OpenRoadLab-DashVoice.git
cd OpenRoadLab-DashVoice
scripts/build.sh
```

The build creates `build/DashVoice.app`. To sign it locally, install it in `/Applications`, and launch it:

```bash
scripts/sign.sh --mode local --bootstrap
scripts/install.sh
open /Applications/DashVoice.app
```

Allow microphone access when prompted. For automatic typing, add DashVoice in System Settings under Privacy & Security → Accessibility. Open Settings from the DashVoice menu and enter your DashScope API key. The app stores it in your macOS Keychain.

## Models, cost, and compatibility

- **Use `qwen3-asr-flash` for everyday dictation.** It's the tested default. The `qwen-audio-3.1-asr-flash` option is reserved for a future integration and unavailable through the current endpoint.
- DashVoice is free. By default, recordings go to Alibaba Cloud Model Studio for transcription, and usage is billed to your DashScope account. Your agent's model usage is billed separately by its provider. [Privacy details](docs/PRIVACY.md)
- If the original field can't be verified, look for the text on your clipboard. That's the fallback in the Firefox and WeChat scenarios tested so far.

## Offline tests

Changing the code? Run these tests to check streaming response parsing, text cleanup, and input-target checks. The tests use fixtures and stubs, with zero API usage.

```bash
swiftc -O Sources/DashVoiceCore/*.swift Sources/DashVoiceTests/main.swift -o /tmp/dv-tests
/tmp/dv-tests
```

Ran into a snag? Share your macOS version, chip, and steps to reproduce in [GitHub Issues](https://github.com/yiyi19119-boop/OpenRoadLab-DashVoice/issues). Keep your API key, recordings, and private transcripts to yourself.

[MIT](LICENSE) © OpenRoad Lab.
