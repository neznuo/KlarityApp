# Speaker Encoder Model

## speaker_encoder.onnx

**Model:** WeSpeaker ECAPA-TDNN512-LM
**Source:** https://huggingface.co/Wespeaker/wespeaker-ecapa-tdnn512-LM
**License:** CC-BY 4.0
**Size:** ~24 MB

### Specs

| Property | Value |
|---|---|
| Architecture | ECAPA-TDNN (512 channels) |
| Training data | VoxCeleb2 Dev (5,994 speakers) |
| Loss | ArcFace large-margin |
| Output embedding dim | 192 |
| Input | Log-mel fbank [T, 80], float32 |
| Preprocessing | 16kHz mono, 25ms frame, 10ms hop, Hamming window, CMN |

### Usage

The model is loaded by `SpeakerEmbeddingService` in
`app/services/embeddings/speaker_embedding.py`.
Audio preprocessing is in `app/services/embeddings/audio_utils.py`.

### Upgrading

To swap in a different model:
1. Replace `speaker_encoder.onnx` with the new model file
2. Update `EMBEDDING_DIM` and `MODEL_NAME` in `audio_utils.py`
3. Update the fbank parameters if the new model uses different preprocessing
4. Re-enroll all voice profiles (old `.npy` files are model-specific)
5. Recalibrate the `SPEAKER_*_THRESHOLD` values in `.env`
