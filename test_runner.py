import json
import subprocess
import os

env = os.environ.copy()
env["SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH"] = "/opt/homebrew/Caskroom/miniconda/base/bin/python3"

# Simulate exactly what the Swift code does:
python_path = "/opt/homebrew/Caskroom/miniconda/base/bin/python3"
runner_path = "/Users/asukabot/Speechflow/Sources/SpeechflowCore/Resources/faster_whisper_runner.py"

p = subprocess.Popen([python_path, runner_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)

# Try read ready message
ready_msg = p.stdout.readline()
print("Runner Output:", ready_msg)

err = p.stderr.read()
if err:
    print("Runner Error:", err)
