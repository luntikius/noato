# Development

[Back to README](../README.md)

```sh
swift test --disable-automatic-resolution
./scripts/build-app.sh
```

The build script creates `dist/noato.app` without installing it. CI runs tests and verifies the bundle. The historical Swift module is still named `quill`; the product and executable are `noato`.

For isolated checks, `NOATO_OUTPUT_DIR` and `NOATO_INSTALL_DIR` redirect packaging and installation; `NOATO_NO_OPEN=1` skips launch. `NOATO_DATA_DIR` isolates settings and working jobs. Native screenshot fixtures can be rendered with:

```sh
NOATO_DATA_DIR=/tmp/noato-design-state \
NOATO_DESIGN_DIR=/tmp/noato-design-review \
swift test --disable-automatic-resolution --filter DesignReviewTests
```

Public-audio integration tests accept a local fixture through `QUILL_AUDIO_FIXTURE`. For example, [this FLEURS Russian speech sample](https://huggingface.co/datasets/FluidInference/fleurs/blob/main/ru_ru/ru_ru_0000.wav) is suitable; the audio is not bundled. A numeric dictation can produce only digits and is unsuitable for a Cyrillic-content assertion.

This is beta software. Clean macOS 15 installation and broader real-call validation are still required before general availability. Check mute, silence, reconnects, device changes, unrelated playback exclusion, recovery and login behavior. Browser integration and model-generated meeting titles are future work.
