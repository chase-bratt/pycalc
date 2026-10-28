# Damped wave vs. parabola
# Command-Return runs · Shift-P inserts print()

def f(x):
    return 4 * sin(x) * exp(-abs(x) / 6)

g = lambda x: x**2 / 8 - 2

area = sum(f(i / 1000) / 1000 for i in range(6283))
print(f"f(π/2) = {f(pi / 2):.5f}")
print(f"area of f on [0, 2π] ≈ {area:.4f}")

plot(f)
plot(g, label="g(x)")
plot("cos(x) - 1")

sqrt(2) * pi
