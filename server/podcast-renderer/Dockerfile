# Optional prebuilt container for prepare-podcast-renderer.ts, pushed to Vercel Container Registry.
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg curl ca-certificates libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
    fonts-noto-cjk fonts-noto-color-emoji && rm -rf /var/lib/apt/lists/*
WORKDIR /vercel/sandbox
