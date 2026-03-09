import json
import subprocess
import os
import wave
import struct

env = os.environ.copy()
python_path = "/opt/homebrew/Caskroom/miniconda/base/bin/python3"
runner_path = "/Users/asukabot/Speechflow/Sources/SpeechflowCore/Resources/faster_whisper_runner.py"
test_wav = "/tmp/test.wav"

with wave.open(test_wav, "w") as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(16000)
    for _ in range(16000): f.writeframesraw(struct.pack('<h', 0))

print("Starting Popen")
p = subprocess.Popen([python_path, runner_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)

print("Started")
ready_msg = p.stdout.readline()
print("Ready:", ready_msg.strip())

req = json.dumps({"type": "transcribe", "audio_path": test_wav, "language": "auto"})
print("Sending:", req)
p.stdin.write(req + '\n')
p.stdin.flush()

res = p.stdout.readline()
print("Result:", res.strip())

err = p.stderr.read()
if err: print("Stderr:", err)
