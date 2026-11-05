"""Long-lived MLX Audio speech worker for Chippy's on-device live voice.

Protocol, one JSON object per line:
  stdin:  {"type": "speak", "id": "...", "text": "...", "voice": "chosen, optional",
           "seed": 7, "defaultVoice": "af_heart", "lang": "a"}
          {"type": "cancel"}
  stdout: {"type": "ready"}
          {"type": "audio", "id": "...", "pcm": "<base64 16-bit mono PCM>", "sampleRate": 24000}
          {"type": "done", "id": "..."}
          {"type": "error", "id": "...", "message": "..."}

Keeping the model loaded is what makes spoken replies low latency; the one-shot
mlx_audio CLI reloads it for every sentence.
"""
import base64
import json
import inspect
import os
import queue
import sys
import threading

# The model was downloaded and verified by Chippy. Nothing here should reach the network.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

# Libraries print progress to stdout, so keep the real pipe for the protocol alone.
protocol_out = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
os.dup2(2, 1)
write_lock = threading.Lock()
cancel_generation = 0
jobs = queue.Queue()
# Voices the loaded model refused. Names can come from a README, so one may not really exist.
rejected_voices = set()
# Models with no preset speakers sample a new voice for every call, and each sentence is its own
# call. Cloning one generated clip keeps a whole conversation in the same voice.
voice_anchor = None
# Which voice that is. Changing it changes the voice, which is how a model without presets gets adjusted.
current_seed = 7
ANCHOR_TEXT = (
    "Hello, I'm your voice assistant. I can read your summaries aloud, answer questions "
    "about your library, and keep you company while you work."
)


def emit(message):
    with write_lock:
        protocol_out.write(json.dumps(message) + "\n")
        protocol_out.flush()


def pcm16(audio):
    import numpy as np

    samples = np.clip(np.asarray(audio, dtype=np.float32).reshape(-1), -1.0, 1.0)
    return base64.b64encode((samples * 32767).astype("<i2").tobytes()).decode("ascii")


def generate(model, text, voice=None, default_voice="af_heart", language="a"):
    # Use the loaded model's declared defaults and capabilities, not a model-name allowlist.
    parameters = inspect.signature(model.generate).parameters
    options = {"text": text}
    voice_parameter = parameters.get("voice")
    lang_parameter = parameters.get("lang_code")
    if voice_parameter is not None:
        if voice:
            options["voice"] = voice
        elif lang_parameter is not None and lang_parameter.default in ("a", "b"):
            # A single-letter language convention indicates the matching language voice IDs.
            options["voice"] = default_voice
        elif voice_parameter.default in (None, "", inspect.Parameter.empty):
            speakers = getattr(model, "supported_speakers", None)
            if callable(speakers):
                speakers = speakers()
            if speakers:
                options["voice"] = next(iter(speakers))
    if voice_anchor is not None and "voice" not in options:
        options["ref_audio"], options["ref_text"] = voice_anchor
    if lang_parameter is not None:
        default = lang_parameter.default
        if default in ("a", "b"):
            options["lang_code"] = language
        elif default not in (None, "auto", inspect.Parameter.empty):
            codes = {"a": "en", "b": "en", "z": "zh", "e": "es", "f": "fr", "i": "it", "p": "pt"}
            options["lang_code"] = codes.get(language, default)
    if "stream" in parameters:
        options["stream"] = True
    return model.generate(**options)


def make_voice_anchor(model, seed):
    """Generates the clip later sentences clone, the same for each seed. None if not needed."""
    import mlx.core as mx
    import numpy as np

    parameters = inspect.signature(model.generate).parameters
    if getattr(getattr(model, "config", None), "tts_model_type", None) != "base":
        return None
    if "ref_audio" not in parameters or "ref_text" not in parameters:
        return None
    if getattr(model, "supported_speakers", None):
        return None
    mx.random.seed(seed)
    clips = [np.asarray(result.audio, dtype=np.float32).reshape(-1) for result in generate(model, ANCHOR_TEXT)]
    clip = np.concatenate(clips) if clips else np.zeros(0, dtype=np.float32)
    # Sampling can occasionally end early or run on, and neither makes a usable reference.
    seconds = len(clip) / int(getattr(model, "sample_rate", 24000))
    if not 2 <= seconds <= 30:
        print(f"Ignoring a {seconds:.1f}s voice reference.", file=sys.stderr)
        return None
    return mx.array(clip), ANCHOR_TEXT


def use_seed(model, seed):
    global voice_anchor, current_seed
    if seed == current_seed:
        return
    current_seed = seed
    voice_anchor = None
    try:
        voice_anchor = make_voice_anchor(model, seed)
    except Exception as error:  # Speech still works, only less consistently.
        print(f"Couldn't make a voice reference: {error}", file=sys.stderr)


def speak(model, job, generation):
    global voice_anchor
    voice = job.get("voice") or None
    if isinstance(job.get("seed"), int):
        use_seed(model, job["seed"])
    if voice in rejected_voices:
        voice = None
    started = []
    while True:
        try:
            play(model, job, voice, generation, started)
            return
        except Exception as error:
            # Keep talking in the default voice rather than going silent for the whole session.
            if started:
                raise
            if voice is not None:
                print(f"Voice {voice!r} failed, using the default: {error}", file=sys.stderr)
                rejected_voices.add(voice)
                voice = None
            elif voice_anchor is not None:
                print(f"The voice reference failed, dropping it: {error}", file=sys.stderr)
                voice_anchor = None
            else:
                raise


def play(model, job, voice, generation, started):
    if voice is None:
        # The same sentence and seed always sound the same, so a sample is what chat will sound like.
        import mlx.core as mx

        mx.random.seed(current_seed)
    results = generate(model, job["text"], voice, job.get("defaultVoice") or "af_heart", job.get("lang") or "a")
    for result in results:
        if generation != cancel_generation:
            return
        import numpy as np
        samples = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        rate = int(getattr(result, "sample_rate", getattr(model, "sample_rate", 24000)))
        if rate <= 0:
            raise ValueError("The model returned an invalid audio sample rate.")
        if rate != 24000 and len(samples):
            count = max(1, round(len(samples) * 24000 / rate))
            samples = np.interp(np.arange(count) * rate / 24000, np.arange(len(samples)), samples)
        for offset in range(0, len(samples), 48000):
            if generation != cancel_generation:
                return
            started.append(True)
            emit({"type": "audio", "id": job["id"], "pcm": pcm16(samples[offset:offset + 48000]), "sampleRate": 24000})
    if generation == cancel_generation:
        emit({"type": "done", "id": job["id"]})


def run(model_path):
    global voice_anchor
    try:
        from mlx_audio.tts.utils import load_model

        model = load_model(model_path)
        try:
            voice_anchor = make_voice_anchor(model, current_seed)
        except Exception as error:  # Speech still works, only less consistently.
            print(f"Couldn't make a voice reference: {error}", file=sys.stderr)
        # A short warm-up compiles the graph, so the first real sentence isn't slow.
        for _ in generate(model, "Hello."):
            pass
    except Exception as error:  # Report any load failure to the app rather than exiting silently.
        emit({"type": "fatal", "message": f"{type(error).__name__}: {error}"})
        return
    emit({"type": "ready"})
    while True:
        job, generation = jobs.get()
        if job is None:
            return
        if generation != cancel_generation:
            continue
        try:
            speak(model, job, generation)
        except Exception as error:  # One unspeakable sentence must not end the session.
            emit({"type": "error", "id": job.get("id"), "message": f"{type(error).__name__}: {error}"})


def main():
    global cancel_generation, current_seed
    if len(sys.argv) not in (2, 3):
        print("usage: kokoro_worker.py <model-directory> [seed]", file=sys.stderr)
        return 2
    if len(sys.argv) == 3:
        current_seed = int(sys.argv[2])
    thread = threading.Thread(target=run, args=(sys.argv[1],), daemon=True)
    thread.start()
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("type") == "cancel":
            cancel_generation += 1
        elif message.get("type") == "speak":
            jobs.put((message, cancel_generation))
    # The app closed stdin: end with it rather than waiting on queued speech.
    return 0


if __name__ == "__main__":
    sys.exit(main())
