# Calc plots

These are SVG drawings. Change a value or formula to redraw the plot, and switch the editor theme to see the colors follow it.
Hover for coordinates. Shift-drag to pan, and double-click to reset. A focused plot also accepts Shift-arrow keys and Home.
Panning moves the existing samples; change the formula's bounds to calculate a wider range.
Each fence has its own scope. Arrows are optional; where present, they save a short summary in the source.

## A function

Change `factor` or the bounds. The function keeps working as a function after plotting.

```calc
factor = 1
f(x) = factor * x^2
f as plot(-5, 5)
f(3) → 9
```

## Lines, scatter points, and bars

Plain lists use zero-based indices. Coordinate pairs keep their original order.

```calc
readings = [3, 7, 4, 9, 6]
readings as plot → [plot: line, 5 points]
readings as plot("bar")
readings @sum → 29 # plotting preserves the list
[[0, 3], [1, 7], [2, 4], [4, 9]] as plot("scatter")
```

## Symbolic expressions and derivatives

```calc
symbol x
curve = x^3 - 3*x
curve as plot(x, -3, 3)
curve @diff(x) as plot(x, -3, 3)
```

## Quantities and exact fractions

Axes use canonical units. The underlying data retains its exact values and dimensions.

```calc
distance(t) = 2m/s * t
distance as plot(0s, 10s)
[[0s, 1kg], [2s, 1500g], [4s, 2kg]] as plot("scatter")
thirds = [1//3, 2//3, 1] as plot("bar")
thirds @sum → 2
```

## Domain gaps

The undefined center sample in `1/x` breaks the line. An explicit `null` breaks a data series too.
Sampling does not detect every discontinuity between points.

```calc
reciprocal(x) = 1/x
reciprocal as plot(-5, 5) → [plot: line, 201 points, 1 gaps]
[1, 3, null, 4, 2] as plot
```

## Custom presenters and sampling

A presenter can return a plot just as it can return a string. The last argument controls the sample count, up to 2000.

```calc
bars(data) = plot(data, "bar")
counts = [5, 2, 8, 3] as bars
counts @sum → 18
wave(x) = sin(x)
wave as plot(-6.28, 6.28, "line", 401)
```

An inline plot draws below its paragraph too: {{ counts as bars }}.

## Plot data from comprehensions

Change `factor` or the range to rebuild the data. Fractions give exact x coordinates before drawing.
The optional `if` filters points before computing their y values.

```calc
factor = 1
xs = [n//10 for n in range(-50, 51)]
points = [[x, factor * x^2] for x in xs] as plot
points @list.len → 101
[[x, 1/x] for x in xs if x != 0] as plot("scatter")
[n * 1kg for n in [1, 3, 2, 5]] as plot("bar")
```

One `for` and one optional `if` are supported per comprehension. Input lists and outer variables keep their values.
The result is a normal list, so it works with existing functions, `@` operations, custom presenters, and inline calc.

## Expected presentation errors

These errors are intentional. `data` remains a list, so its type can still be queried.

```calc
data = [1kg, 2m] as plot → ⚠ Plot y coordinates have incompatible dimensions.
[1, 2] as plot("pie")
[] as plot
data @type → "list"
```
