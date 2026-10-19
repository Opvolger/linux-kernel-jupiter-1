import os, sys, time, termios, select
# usage: catch.py [text-to-send-repeatedly] [seconds]  e.g. catch.py '\x03' 25 to interrupt U-Boot
fd = os.open('/dev/ttyUSB0', os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd); a[0]=0; a[1]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL; a[3]=0; a[4]=a[5]=termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
spam = sys.argv[1].encode().decode('unicode_escape').encode() if len(sys.argv) > 1 else b''
end = time.time() + float(sys.argv[2] if len(sys.argv) > 2 else 25)
while time.time() < end:
    if spam: os.write(fd, spam)
    r,_,_ = select.select([fd],[],[],0.05)
    if r:
        try: sys.stdout.write(os.read(fd,4096).decode(errors='replace')); sys.stdout.flush()
        except BlockingIOError: pass
