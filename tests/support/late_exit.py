import sys
import time
import signal

class Interrupt(Exception):
    pass

def ignore(signum, frame):
    raise Interrupt()

signal.signal(signal.SIGINT, ignore)
signal.signal(signal.SIGTERM, ignore)

try:
    for line in sys.stdin:
        sys.stdout.write(line)
        sys.stdout.flush()
except Interrupt as e:
    print("INTERRUPTED")

time.sleep(2)
