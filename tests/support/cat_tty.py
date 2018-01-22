import sys

with open("/dev/tty") as output:
    for line in sys.stdin:
        print(line, file=output, end="")
