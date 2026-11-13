#!/usr/bin/env python3
"""An open speech model behind OpenAI's transcription request, for the model test.

It serves one onnx-asr model (Parakeet v3, GigaAM, Whisper, ...) at POST /v1/audio/transcriptions,
the request the `transcribe` function sends and vLLM answers, so the runner (run.ts) speaks to
every open model the same way. The same file runs on a Mac's CPU and on a rented GPU.

    python model_server.py --model nemo-parakeet-tdt-0.6b-v3 [--quantization int8] [--port 8101]
        [--device cpu|cuda|auto] [--host 127.0.0.1] [--vad-over 28]

Needs: onnx-asr (pip install "onnx-asr[cpu,hub]", or [gpu,hub] on an NVIDIA box) and ffmpeg.

    GET  /health                     200 {"ok": true, "model", "device"} once the model is loaded
    GET  /v1/models                  the model, as OpenAI lists models
    POST /v1/audio/transcriptions    multipart: file, model, language?, prompt? (ignored), response_format?
                                     -> {"text", "language", "duration"}; header x-processing-ms: decode and
                                        recognition on this machine, x-inference-ms: recognition alone

Audio longer than --vad-over seconds is split at pauses (Silero VAD) first: Whisper hears 30 s at
a time. Nothing is kept: no audio and no text is written or logged, only each request's length and
time.
"""
from __future__ import annotations

import argparse
import email.parser
import email.policy
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

SAMPLE_RATE = 16000
MAX_UPLOAD_BYTES = 64 * 1024 * 1024


def providers_for(device: str):
    """onnxruntime's providers for a device; None lets onnxruntime choose (CoreML on a Mac, CUDA on a GPU box)."""
    if device == "cpu":
        return ["CPUExecutionProvider"]
    if device == "cuda":
        return ["CUDAExecutionProvider", "CPUExecutionProvider"]
    return None


def decode(audio: bytes, ffmpeg: str) -> np.ndarray:
    """Any audio file as 16 kHz mono float32 samples, through ffmpeg."""
    process = subprocess.run(
        [ffmpeg, "-nostdin", "-loglevel", "error", "-i", "pipe:0", "-f", "s16le", "-acodec", "pcm_s16le",
         "-ac", "1", "-ar", str(SAMPLE_RATE), "pipe:1"],
        input=audio, capture_output=True, check=False,
    )
    if process.returncode != 0:
        raise ValueError("ffmpeg could not read the audio: " + process.stderr.decode(errors="replace").strip()[:200])
    return np.frombuffer(process.stdout, dtype=np.int16).astype(np.float32) / 32768.0


def parse_multipart(content_type: str, body: bytes) -> dict[str, tuple[bytes, str | None]]:
    """The form's fields: name -> (bytes, filename or None). The email parser reads multipart/form-data."""
    message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
    )
    if not message.is_multipart():
        raise ValueError("the body is not multipart/form-data")
    fields: dict[str, tuple[bytes, str | None]] = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        payload = part.get_payload(decode=True) or b""
        fields[name] = (payload, part.get_filename())
    return fields


class Recognizer:
    """One loaded model, used by one request at a time."""

    def __init__(self, model: str, quantization: str | None, device: str, vad_over: float):
        import onnx_asr  # Imported here so --help works without it.

        if device == "cuda":
            # onnxruntime-gpu[cuda,cudnn] brings CUDA and cuDNN as Python packages: load them before a session needs them.
            import onnxruntime

            if hasattr(onnxruntime, "preload_dlls"):
                onnxruntime.preload_dlls()

        self.name = model
        self.device = device
        self.lock = threading.Lock()
        self.model = onnx_asr.load_model(model, quantization=quantization, providers=providers_for(device))
        self.vad_over = vad_over
        self.vad = None
        if vad_over > 0:
            try:
                self.vad = onnx_asr.load_vad("silero", providers=providers_for(device))
            except Exception as error:  # A model without VAD still serves short clips.
                print(f"VAD not loaded ({error}); clips over {vad_over} s go through whole", file=sys.stderr)
        self.takes_language = True

    def recognize(self, samples: np.ndarray, language: str | None) -> str:
        with self.lock:
            long = self.vad is not None and len(samples) / SAMPLE_RATE > self.vad_over
            model = self.model.with_vad(self.vad) if long else self.model
            kwargs = {"sample_rate": SAMPLE_RATE}
            if language and self.takes_language:
                kwargs["language"] = language
            try:
                result = model.recognize(samples, **kwargs)
            except TypeError:
                # A model that takes no language (Parakeet, GigaAM): ask again without it, and from now on.
                self.takes_language = False
                kwargs.pop("language", None)
                result = model.recognize(samples, **kwargs)
            return text_of(result)


def text_of(result) -> str:
    """onnx-asr gives a string, or segments (with VAD) that each carry a text."""
    if isinstance(result, str):
        return result.strip()
    if hasattr(result, "text"):
        return str(result.text).strip()
    try:
        return " ".join(text_of(part) for part in result if text_of(part)).strip()
    except TypeError:
        return str(result).strip()


def make_handler(recognizer: Recognizer, ffmpeg: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "model-test/1"

        def log_message(self, format, *args):  # noqa: A002 - the base class's name
            # Only the request line and status: never the audio or the text.
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), format % args))

        def reply(self, status: int, body: dict, headers: dict | None = None):
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path in ("/health", "/healthz"):
                return self.reply(200, {"ok": True, "model": recognizer.name, "device": recognizer.device})
            if self.path == "/v1/models":
                return self.reply(200, {"object": "list", "data": [{"id": recognizer.name, "object": "model", "owned_by": "model-test"}]})
            return self.reply(404, {"error": {"type": "not_found"}})

        def do_POST(self):
            if self.path != "/v1/audio/transcriptions":
                return self.reply(404, {"error": {"type": "not_found"}})
            started = time.perf_counter()
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_UPLOAD_BYTES:
                return self.reply(413 if length > MAX_UPLOAD_BYTES else 400, {"error": {"type": "bad_request", "message": "a body up to 64 MB is required"}})
            body = self.rfile.read(length)
            try:
                fields = parse_multipart(self.headers.get("Content-Type", ""), body)
                audio = fields.get("file", (b"", None))[0]
                if not audio:
                    raise ValueError("no file in the form")
                language = (fields.get("language", (b"", None))[0].decode().strip() or None)
                response_format = fields.get("response_format", (b"json", None))[0].decode().strip() or "json"
                samples = decode(audio, ffmpeg)
            except ValueError as error:
                return self.reply(400, {"error": {"type": "bad_request", "message": str(error)}})
            inference_started = time.perf_counter()
            try:
                text = recognizer.recognize(samples, language)
            except Exception as error:  # The model failed on this clip: say so, keep serving.
                return self.reply(500, {"error": {"type": "model_error", "message": type(error).__name__}})
            done = time.perf_counter()
            headers = {
                "x-processing-ms": str(round((done - started) * 1000)),
                "x-inference-ms": str(round((done - inference_started) * 1000)),
            }
            if response_format == "text":
                data = text.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(data)
                return None
            return self.reply(200, {"text": text, "language": language, "duration": round(len(samples) / SAMPLE_RATE, 3)}, headers)

    return Handler


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--model", required=True, help="an onnx-asr model name, e.g. nemo-parakeet-tdt-0.6b-v3")
    parser.add_argument("--quantization", default=None, help="e.g. int8; full precision when left out")
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8101)
    parser.add_argument("--vad-over", type=float, default=28.0, help="split audio longer than this many seconds at pauses; 0 never")
    args = parser.parse_args(argv)

    ffmpeg = shutil.which("ffmpeg") or next((path for path in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.path.exists(path)), None)
    if not ffmpeg:
        print("ffmpeg is needed to read the audio: install it (apt-get install ffmpeg, or brew install ffmpeg)", file=sys.stderr)
        return 2
    loading = time.perf_counter()
    recognizer = Recognizer(args.model, args.quantization, args.device, args.vad_over)
    # One clip of silence first, so the first real request isn't the one that warms the model up.
    recognizer.recognize(np.zeros(SAMPLE_RATE, dtype=np.float32), None)
    print(json.dumps({"event": "ready", "model": args.model, "quantization": args.quantization, "device": args.device,
                      "loadSeconds": round(time.perf_counter() - loading, 1), "port": args.port}), flush=True)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(recognizer, ffmpeg))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
