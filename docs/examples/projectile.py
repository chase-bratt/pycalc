# Projectile: every line shows its value on the right
v = 24.5          # launch speed, m/s
angle = 38        # degrees
g = 9.81

vx = v * cos(radians(angle))
vy = v * sin(radians(angle))
t_flight = 2 * vy / g
max_height = vy**2 / (2 * g)

height = lambda x: x * tan(radians(angle)) - g * x**2 / (2 * vx**2)
plot(height, label="trajectory")
point(vx * t_flight, 0, label="landing")
window(-5, 65, -10, 20)

vx * t_flight
