Synthetic tone fixtures, generated locally with FFmpeg/libmp3lame. No third-party recordings.

- one.mp3: 440 Hz, 0.35 seconds, mono 44.1 kHz, 64 kbit/s constant bitrate.
- two.mp3: 880 Hz, 0.55 seconds, mono 44.1 kHz, variable bitrate quality 4.

Both include their encoder metadata; tests verify joining removes per-part headers and produces one recording with complete-file seek metadata.
- music.mp3: 330 Hz + 495 Hz tones, 8 seconds, stereo 48 kHz (Lyria's output format), 64 kbit/s. Stands in for theme music in mixer tests.
- voice-24k.mp3: 220 Hz, 1.2 seconds, mono 24 kHz, 48 kbit/s. Exercises resampling of speech to the episode rate.
