# Installation

[Back to README](../README.md)

**Requires:** Apple Silicon, macOS 15+, and Apple Command Line Tools or Xcode with **Swift 6.2.3+**. Internet is needed for initial downloads; transcription then works offline.

### From source

Install Apple developer tools if missing (`xcode-select --install`), then check `xcrun swift --version`. Install the pinned beta:

```sh
mkdir -p ~/projects
git clone --branch v0.1.0-beta.1 --depth 1 https://github.com/luntikius/noato.git ~/projects/noato
cd ~/projects/noato
./scripts/install.sh
```

The script builds, locally signs and installs `~/Applications/noato.app`, then opens it. No Homebrew or `sudo` required. Use an unused checkout directory.

For updates, run the same script from the desired release checkout. Finish recording and transcription and quit noato or Quill first; data is preserved. This is an ad-hoc signed build, not a notarized download. Complete macOS approval prompts yourself without disabling security protections.

## Setup

Follow the [first-launch steps](usage.md#first-launch): choose the transcript folder, approve microphone and system-audio access, prepare the models, then check both sides in a short test meeting. Permission prompts must be completed by the user.

For agent-assisted installation, use the [installation skill](../skills/install-noato/SKILL.md) from the same release as the source.
