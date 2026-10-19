import os, sys, time, termios, select
# usage: ser.py <seconds> [text-to-send ...]  (\r is appended)
fd = os.open('/dev/ttyUSB0', os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; a[3] = 0
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
dur = float(sys.argv[1]); cmds = sys.argv[2:]
def rd(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: sys.stdout.write(os.read(fd, 4096).decode(errors='replace')); sys.stdout.flush()
            except BlockingIOError: pass
for c in cmds:
    os.write(fd, (c.encode().decode('unicode_escape') + '\r').encode()); rd(1.5)
rd(dur)
