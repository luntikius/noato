# Third-party notices

noato is derived from [Quill by kukutz](https://github.com/kukutz/quill).
The original MIT license and copyright notice are retained in `LICENSE`.

Source dependencies are pinned in `Package.resolved`. Their licenses remain applicable:

| Component | License | Source |
| --- | --- | --- |
| WhisperKit | MIT | https://github.com/argmaxinc/WhisperKit |
| FluidAudio | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| Swift Argument Parser, Swift Testing, Swift Syntax, Swift Collections, Swift Crypto, Swift ASN.1 | Apache-2.0, with Swift exceptions where provided | https://github.com/apple and https://github.com/swiftlang |
| Swift Transformers / Swift Jinja | Apache-2.0 | https://github.com/huggingface |
| yyjson | MIT | https://github.com/ibireme/yyjson |

Models are downloaded separately, not included in the source release or app bundle.
Whisper large-v3-turbo originates from OpenAI Whisper (MIT), with the Core ML conversion distributed by Argmax. Offline speaker separation uses FluidInference’s Core ML Pyannote Community-1 / WeSpeaker / VBx assets. Their individual upstream and conversion licenses apply; see the model cards linked from FluidAudio’s model catalog. No paid service or Hugging Face account is required by noato’s existing download flow.

Model sources:
- https://huggingface.co/argmaxinc/whisperkit-coreml
- https://huggingface.co/FluidInference/speaker-diarization-coreml

Full source dependency license files are included by the packaging script in the app’s Licenses folder. This notice does not replace those license texts or model-specific terms.
