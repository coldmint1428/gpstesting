# python -I transcribe.py <ffmpeg.exe> <audio folder> <out.json>: every voice-over file, as words with start and end seconds
import json
import os
import subprocess
import sys

import numpy as np
from faster_whisper import WhisperModel

ffmpeg, folder, out = sys.argv[1], sys.argv[2], sys.argv[3]
model = WhisperModel('base.en', device='cpu', compute_type='int8')
result = {}
for name in sorted(os.listdir(folder)):
    if not name[:2].isdigit():
        continue
    # 16 kHz mono float samples, decoded by ffmpeg (the model's own decoder needs a different PyAV)
    raw = subprocess.run([ffmpeg, '-v', 'error', '-i', os.path.join(folder, name), '-f', 'f32le', '-ac', '1', '-ar', '16000', '-'],
                         capture_output=True, check=True).stdout
    audio = np.frombuffer(raw, dtype=np.float32)
    segments, _ = model.transcribe(audio, word_timestamps=True, language='en', beam_size=5)
    words = [{'w': w.word.strip(), 's': round(w.start, 2), 'e': round(w.end, 2)} for seg in segments for w in seg.words]
    result[name[:2]] = {'file': name, 'words': words}
    print(name, len(words), 'words:', ' '.join(w['w'] for w in words))
with open(out, 'w', encoding='utf8') as f:
    json.dump(result, f, indent=1)
