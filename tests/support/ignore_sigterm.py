import sys
import time
import signal

def ignore(signum, frame):
    pass

signal.signal(signal.SIGINT, ignore)
signal.signal(signal.SIGTERM, ignore)

for line in sys.stdin:
    sys.stdout.write(line)
    sys.stdout.flush()

# Zombie
while True:
    time.sleep(100)
