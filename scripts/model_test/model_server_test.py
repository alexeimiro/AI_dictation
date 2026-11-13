"""Tests for model_server.py's own parts, without a model: python3 -m unittest scripts/model_test/model_server_test.py

Needs numpy (the server's one dependency besides onnx-asr) and ffmpeg for the decode test.
"""
import os
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import model_server  # noqa: E402


class MultipartTest(unittest.TestCase):
    def test_reads_the_fields_a_transcription_request_sends(self):
        boundary = "----model-test"
        body = (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nnemo-parakeet-tdt-0.6b-v3\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nru\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n"
            f"Content-Type: audio/mp4\r\n\r\n"
        ).encode() + bytes(range(256)) + f"\r\n--{boundary}--\r\n".encode()
        fields = model_server.parse_multipart(f"multipart/form-data; boundary={boundary}", body)
        self.assertEqual(fields["model"][0], b"nemo-parakeet-tdt-0.6b-v3")
        self.assertEqual(fields["language"][0], b"ru")
        self.assertEqual(fields["file"], (bytes(range(256)), "dictation.m4a"))

    def test_refuses_a_body_that_isnt_multipart(self):
        with self.assertRaises(ValueError):
            model_server.parse_multipart("application/json", b"{}")


class TextTest(unittest.TestCase):
    def test_a_string_or_segments_become_one_text(self):
        class Segment:
            def __init__(self, text):
                self.text = text

        self.assertEqual(model_server.text_of("  Привет.  "), "Привет.")
        self.assertEqual(model_server.text_of([Segment("One."), Segment(" "), Segment("Two.")]), "One. Two.")
        self.assertEqual(model_server.text_of(Segment(" Done. ")), "Done.")


@unittest.skipIf(shutil.which("ffmpeg") is None, "ffmpeg isn't installed")
class DecodeTest(unittest.TestCase):
    def test_a_wav_becomes_16_khz_float_samples(self):
        import numpy as np

        samples = (np.sin(np.linspace(0, 200, 8000)) * 10000).astype("<i2").tobytes()
        header = b"RIFF" + (36 + len(samples)).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little") + \
            (1).to_bytes(2, "little") + (1).to_bytes(2, "little") + (16000).to_bytes(4, "little") + \
            (32000).to_bytes(4, "little") + (2).to_bytes(2, "little") + (16).to_bytes(2, "little") + \
            b"data" + len(samples).to_bytes(4, "little")
        decoded = model_server.decode(header + samples, shutil.which("ffmpeg"))
        self.assertEqual(decoded.dtype, np.float32)
        self.assertEqual(len(decoded), 8000)
        self.assertLessEqual(float(np.abs(decoded).max()), 1.0)

    def test_audio_ffmpeg_cant_read_is_a_value_error(self):
        with self.assertRaises(ValueError):
            model_server.decode(b"not audio at all", shutil.which("ffmpeg"))


if __name__ == "__main__":
    unittest.main()
