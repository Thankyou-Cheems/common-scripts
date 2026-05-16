# OBS 4K AV1 profiles

This directory stores two OBS Studio output profiles for the local Windows setup:

- `4K_NVENC_AV1_SameAsStream`
  - Streams with NVIDIA NVENC AV1.
  - Records with the same stream encoder (`RecEncoder=none`) to minimize encoder load.
- `4K_NVENC_AV1_QSV_HEVC_Record`
  - Streams with NVIDIA NVENC AV1.
  - Records locally with Intel Quick Sync HEVC to move recording encode work to the iGPU.

The profiles intentionally omit `service.json` because it can contain private stream
server URLs and stream keys. Copy only the profile files here into:

```text
%APPDATA%\obs-studio\basic\profiles\<profile-dir>\
```

Current assumptions:

- Canvas: 1920x1080
- Output: 3840x2160 at 60 FPS
- Stream encoder: NVIDIA NVENC AV1, CBR 24000 Kbps, 2s keyframe
- Recording format: MKV
