import math

n = 8
scale = 0x10000

def fmt(x):
    s = f"{abs(x):05X}"
    return f"-0x{s}" if x < 0 else f"0x{s}"

for k in range(n):
    theta = k * (2 * math.pi / n)
    c = int(math.cos(theta) * scale)
    s = int(math.sin(theta) * scale)
    deg = k * (360 // n)
    print(f"\t\tdd {fmt(c)}, {fmt(s)}\t; {deg}")