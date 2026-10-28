# Asymptotes, curves and points
plot(tan, label="tan(x)")
plot("1/x")
polar("1 + cos(theta)", label="cardioid")
parametric(lambda t: 3 * cos(t), lambda t: 2 * sin(t), label="ellipse")
scatter([1, 2, 3, 4], [1, 4, 9, 16], label="squares")
vline(-2)
point(2, 3, label="A")
