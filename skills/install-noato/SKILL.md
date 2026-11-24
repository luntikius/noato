---
name: install-noato
description: Install, update or diagnose noato, a local macOS meeting recorder and transcriber, using its source installer.
---

# Install noato

Install noato for Apple Silicon and macOS 15+ from `https://github.com/luntikius/noato`. Read [the installation guide](../../docs/installation.md) at the selected revision before running the installer. Installation does not authorize publishing releases or changing unrelated applications.

## Source and requirements

Use the user's requested tag; otherwise use the release accompanying this skill (`v0.1.0-beta.1`). Obtain the skill and source from the same revision. Clone into a user-selected or unused directory such as `~/projects/noato`. Reuse an existing checkout without resetting local changes or switching a dirty checkout. Do not substitute upstream Quill: it does not include noato's installer. If the requested release is unavailable, report that instead of substituting another source.

Check macOS 15+, native arm64 execution and Apple Command Line Tools or Xcode with Swift 6.2.3+. Initial dependency and model downloads need internet. If tools are missing, guide the user through Apple's installation. Homebrew, Python, sudo and a paid developer account are not required.

## Install or update

Run `./scripts/install.sh` from the checkout. It builds pinned dependencies, packages and locally signs the app, verifies it, installs to `~/Applications/noato.app` and opens it. Use this same script for updates; settings, models, transcripts and pending work remain outside the application bundle.

If noato or Quill is running, let recording and transcription finish and have the user quit it before retrying. Do not kill the process or bypass the installer's guard.

Let the user complete setup: choose the transcript folder, approve microphone and system-audio access, then prepare local models. Do not change imported preferences or enable automatic recording, deletion or login unless requested. Recommend a short meeting with a consenting participant to verify both tracks; the empty-tap access check alone does not verify real recording.

## Verify and diagnose

Verify the installed bundle and report its location, version and unfinished setup. The bundled CLI is `~/Applications/noato.app/Contents/MacOS/noato`. Use `menu` if the status icon is hidden; use `doctor`, `microphones` or `audio-status` as needed for the reported issue. Consult [the usage guide](../../docs/usage.md) for storage behavior and automatic-detection limitations. Do not copy meeting audio or transcripts into diagnostic reports.

This is a local ad-hoc build, not a notarized Developer ID download. Permissions may need approval again after rebuilding. Do not disable Gatekeeper, remove quarantine recursively or reset macOS privacy permissions.
