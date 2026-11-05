# Calc reference

Generated from the discovery catalog. Run `make calc-reference` after changing catalog entries.

In the editor, use **Explore calc** or **F1** inside calc to search these functions and constructions. Completion, hover help, and argument hints use the same entries.

Short callable names work when unambiguous. Use qualified names such as `list.len` and `str.len` when a short name has multiple meanings. Parameters ending in `?` are optional; defaults are shown after `=`.

## Numbers

### math.abs

Absolute value or complex magnitude; compatible units are preserved.

`math.abs(value)`

```calc
abs(-3)
# Result: 3
```

### math.sign

Return -1, 0, or 1 for a real scalar.

`math.sign(value)`

```calc
sign(-3)
# Result: -1
```

### math.sqrt

Square root. Quantities need even unit powers; use complex(...) for negative inputs.

`math.sqrt(value)`

```calc
sqrt(9m^2)
# Result: 3m
```

### math.exp

Exponential e^value for dimensionless values.

`math.exp(value)`

```calc
exp(0)
# Result: 1
```

### math.ln

Natural logarithm; real inputs must be positive.

`math.ln(value)`

```calc
ln(1)
# Result: 0
```

### math.log10

Base-10 logarithm of a positive real scalar.

`math.log10(value)`

```calc
log10(100)
# Result: 2
```

### math.sin

Trigonometric function accepting radians or explicit angle units, and complex or symbolic values.

`math.sin(angle)`

```calc
sin(0)
# Result: 0
```

### math.cos

Trigonometric function accepting radians or explicit angle units, and complex or symbolic values.

`math.cos(angle)`

```calc
cos(0)
# Result: 1
```

### math.tan

Trigonometric function accepting radians or explicit angle units, and complex or symbolic values.

`math.tan(angle)`

```calc
tan(0)
# Result: 0
```

### math.asin

Inverse trigonometric function. Real results are dimensionless radians.

`math.asin(value)`

```calc
asin(0)
# Result: 0
```

### math.acos

Inverse trigonometric function. Real results are dimensionless radians.

`math.acos(value)`

```calc
acos(1)
# Result: 0
```

### math.atan

Inverse trigonometric function. Real results are dimensionless radians.

`math.atan(value)`

```calc
atan(0)
# Result: 0
```

### math.floor

Round a real scalar down to an integer.

`math.floor(value)`

```calc
floor(1//3)
# Result: 0
```

### math.ceil

Round a real scalar up to an integer.

`math.ceil(value)`

```calc
ceil(1//3)
# Result: 1
```

### math.re

Real component of a complex value, or the input for a real value.

`math.re(value)`

```calc
(3+4i) @re
# Result: 3
```

### math.im

Imaginary component of a complex value; zero for a real value.

`math.im(value)`

```calc
(3+4i) @im
# Result: 4
```

### math.conj

Complex conjugate; real inputs retain their value.

`math.conj(value)`

```calc
(3+4i) @conj
# Result: 3 - 4i
```

### math.approx

Convert exact numeric components to approximate machine numbers.

`math.approx(value)`

```calc
(1//2) @approx
# Result: 0.5
```

### math.round

Round a real value or quantity. Negative digits round to tens, hundreds, and beyond.

`math.round(value, digits = 0)`

```calc
1234 @round(-2)
# Result: 1200
```

### math.complex

Construct a complex number from real scalar components.

`math.complex(real, imaginary = 0)`

```calc
complex(3,4) @abs
# Result: 5
```

### math.fraction

Construct an exact rational from two integers; // is equivalent.

`math.fraction(numerator, denominator)`

```calc
fraction(2,4)
# Result: 1//2
```

### math.log

Logarithm with an optional base; positive real inputs and base other than one are required.

`math.log(value, base = e)`

```calc
log(8,2)
# Result: 3
```

### math.gcd

Greatest common divisor of integer arguments.

`math.gcd(first, second, ...values)`

```calc
gcd(18,24)
# Result: 6
```

### math.lcm

Least common multiple of integer arguments.

`math.lcm(first, second, ...values)`

```calc
lcm(6,8)
# Result: 24
```

### math.factorial

Factorial of an integer from 0 through 1000.

`math.factorial(integer)`

```calc
5 @factorial
# Result: 120
```

### math.min

Smallest real value or compatible quantity in a list or argument sequence.

Aliases: `stats.min`.

`math.min(values)`

`math.min(first, ...values)`

```calc
min([3,1,2])
# Result: 1
```

### math.max

Largest real value or compatible quantity in a list or argument sequence.

Aliases: `stats.max`.

`math.max(values)`

`math.max(first, ...values)`

```calc
max([3,1,2])
# Result: 3
```

### math.clamp

Limit a real value or quantity to compatible lower and upper bounds.

`math.clamp(value, minimum, maximum)`

```calc
clamp(12,0,10)
# Result: 10
```

### math.pi

Circle constant. Angles without units use radians.

```calc
math.pi
# Result: 3.14159265359
```

### math.e

Base of the natural logarithm.

```calc
math.e
# Result: 2.71828182846
```

## Statistics

### stats.sum

Add numeric values, retaining compatible units and exact arithmetic.

Aliases: `list.sum`.

`stats.sum(values)`

`stats.sum(first, ...values)`

```calc
[1//3,1//6] @sum
# Result: 1//2
```

### stats.count

Count numeric items in a list or argument sequence. Use list.len for arbitrary lists.

`stats.count(values)`

`stats.count(first, ...values)`

```calc
count([1,2,3])
# Result: 3
```

### stats.mean

Arithmetic mean of numeric values, retaining compatible units.

`stats.mean(values)`

`stats.mean(first, ...values)`

```calc
[1kg,500g] @mean
# Result: 0.75kg
```

### stats.median

Middle of sorted real values; average the middle pair for an even count.

`stats.median(values)`

`stats.median(first, ...values)`

```calc
median([1,3,8])
# Result: 3
```

### stats.variance

Variance of compatible real values. Mode is "sample" or "population"; units are squared.

`stats.variance(values, mode = "sample")`

```calc
variance([1,2,3],"population")
# Result: 0.666666666667
```

### stats.std

Standard deviation, using "sample" or "population" normalization. Compatible units are retained.

Aliases: `stats.stddev`.

`stats.std(values, mode = "sample")`

```calc
std([1,2,3])
# Result: 1
```

### stats.quantile

Interpolated quantile at a probability between zero and one.

`stats.quantile(values, probability)`

```calc
quantile([0,10],0.25)
# Result: 2.5
```

## Lists

### list.len

Number of elements in a list.

`list.len(values)`

```calc
list.len([1,2,3])
# Result: 3
```

### list.first

First list element, or null when empty.

`list.first(values)`

```calc
first([3,4])
# Result: 3
```

### list.last

Last list element, or null when empty.

`list.last(values)`

```calc
last([3,4])
# Result: 4
```

### list.reverse

Return a reversed copy of the list.

`list.reverse(values)`

```calc
reverse([1,2,3])
# Result: [3, 2, 1]
```

### list.join

Join formatted list elements into a string.

`list.join(values, separator = ", ")`

```calc
list.join([1,2]," / ")
# Result: 1 / 2
```

### list.map

Transform each list element with a function accepting the item and optional index.

`list.map(values, function)`

```calc
[1,4,9] @map(sqrt)
# Result: [1, 2, 3]
```

### list.filter

Keep elements for which a predicate returns a truthy value; it accepts the item and optional index.

`list.filter(values, predicate)`

```calc
positive(n) = n > 0
[-1,2,3] @filter(positive)
# Result: [2, 3]
```

### list.range

Generate numbers up to, excluding, stop. Step can be negative and must advance the sequence. Limit: 10000 items.

`list.range(stop)`

`list.range(start, stop, step = 1)`

```calc
range(0,5)
# Result: [0, 1, 2, 3, 4]
```

### list.slice

Copy a portion of a list using zero-based indices; the optional end is excluded.

`list.slice(values, start, end?)`

```calc
[1,2,3,4] @slice(1,3)
# Result: [2, 3]
```

### list.sort

Return a sorted copy. An optional comparator returns a negative, zero, or positive number.

`list.sort(values, comparator?)`

```calc
sort([3,1,2])
# Result: [1, 2, 3]
```

### list.reduce

Fold elements into an accumulator. The callback accepts accumulator, item, and optional index.

`list.reduce(values, function, initial)`

```calc
add(a,b) = a+b
[1,2,3] @reduce(add,0)
# Result: 6
```

## Strings

### str.len

Number of UTF-16 code units in a string.

`str.len(text)`

```calc
str.len("hello")
# Result: 5
```

### str.trim

Remove whitespace at both ends of a string.

`str.trim(text)`

```calc
trim(" hello ")
# Result: hello
```

### str.lower

Convert text to lowercase.

`str.lower(text)`

```calc
lower("HELLO")
# Result: hello
```

### str.upper

Convert text to uppercase.

`str.upper(text)`

```calc
upper("hello")
# Result: HELLO
```

### str.split

Split a string into a list. Omit the separator to split into UTF-16 code units.

`str.split(text, separator?)`

```calc
split("a,b",",") @list.len
# Result: 2
```

### str.join

Join formatted list elements into text with an optional separator.

`str.join(values, separator = "")`

```calc
str.join([1,2],"-")
# Result: 1-2
```

### str.includes

Whether text contains the search string.

`str.includes(text, search)`

```calc
includes("hello","ell")
# Result: true
```

### str.replace

Replace every occurrence of a literal search string.

`str.replace(text, search, replacement)`

```calc
replace("aba","a","x")
# Result: xbx
```

## Values

### core.if

Choose a value using calc truth rules. Arguments are evaluated eagerly; guard unsafe calculations with a comprehension filter.

`core.if(condition, yes, no = null)`

```calc
if(1<2,10,20)
# Result: 10
```

### core.coalesce

First argument that is neither null nor an empty string. Arguments are evaluated eagerly.

`core.coalesce(first, ...values)`

```calc
coalesce(null,"",3)
# Result: 3
```

### core.type

Return the value's type name without converting it.

Aliases: `core.typeof`.

`core.type(value)`

```calc
(1//3) @type
# Result: rational
```

## Symbols

### algebra.simplify

Simplify a symbolic expression conservatively, including polynomial arithmetic.

`algebra.simplify(expression)`

```calc
symbol x
(x+x) @simplify
# Result: 2*x
```

### algebra.expand

Expand polynomial products and powers within the term limit.

`algebra.expand(expression)`

```calc
symbol x
((x+1)*(x+2)) @expand
# Result: x^2 + 3*x + 2
```

### algebra.factor

Extract supported polynomial factors. Unsupported factorizations retain the expression.

`algebra.factor(expression)`

```calc
symbol x
(x^2-1) @factor
# Result: (x + 1)*(x - 1)
```

### algebra.diff

Differentiate a supported symbolic expression with respect to a declared symbol.

`algebra.diff(expression, symbol)`

```calc
symbol x
(x^2) @diff(x)
# Result: 2*x
```

### algebra.subs

Replace a declared symbol and evaluate supported numeric calls.

`algebra.subs(expression, symbol, value)`

```calc
symbol x
(x^2) @subs(x,3)
# Result: 9
```

## Presenters

### present.plot

Draw a line, scatter, or bar plot. Data lists use indices or [x,y] pairs; functions and symbols require bounds. At most 2000 samples.

`present.plot(data, kind = "line")`

`present.plot(function, from, to, kind = "line", samples = 201)`

`present.plot(expression, symbol, from, to, kind = "line", samples = 201)`

```calc
[3,7,4] as plot("bar")
# Result: [plot: bar, 3 points]
```

### present.decimal

Render a real scalar with a fixed number of decimal places, retaining its original value when used with as.

`present.decimal(value, digits = 2)`

```calc
1//3 as decimal(2)
# Result: 0.33
```

### present.percent

Multiply by 100 and append %. Optional precision fixes the number of fractional places; as retains the numeric value.

`present.percent(value, digits?)`

```calc
0.375 as %(2)
# Result: 37.50%
```

### present.unit

Render a quantity in compatible target units. Precision is optional; use as kg or as km/h for short forms.

`present.unit(value, unit, digits?)`

```calc
present.unit(10m/s,"km/h",1)
# Result: 36.0km/h
```

### present.scale

Divide a scalar by a registered multiplier and append its suffix. Precision is optional; L is lakh and Cr is crore.

`present.scale(value, scale, digits?)`

```calc
present.scale(25000000,"Cr",2)
# Result: 2.50Cr
```

## Constructions

### List comprehension

Build a list with one for clause and an optional if filter. The loop variable stays local; filtered bodies are skipped.

```calc
[n^2 for n in range(5) if n > 1]
# Result: [4, 9, 16]
```

### Function definition

Define a pure named function. Parameters are local; free names come from the calc block.

```calc
double(x) = x*2
double(3)
# Result: 6
```

### Reactive assignment

Bind a computed value and keep the output after the arrow up to date. Trailing comments are preserved.

```calc
total = 25*4 -> 100 # calculate total
total
# Result: 100
```

### Exact fraction

Use // between integer expressions for an exact rational. Ordinary division also retains exactness for exact inputs.

```calc
1//3 + 1//6
# Result: 1//2
```

### Complex number

An attached i coefficient constructs an imaginary value. i is reserved.

```calc
(3+4i) @abs
# Result: 5
```

### Quantity

Attach a unit to a number and combine units dimensionally. Legacy L means lakh; use l or litre for volume.

```calc
10m/s * 20s
# Result: 200m
```

### Symbol declaration

Declare symbolic names before algebraic operations. Separate declared symbols with commas.

```calc
symbol x
(x+x) @simplify
# Result: 2*x
```

### Postfix operation

Pass a value as the first argument of a function using @. Pipelines run left to right.

```calc
[1,2,3] @sum
# Result: 6
```

### Presenter

Use as to render a result while keeping the original computed value in its binding.

```calc
0.375 as %
# Result: 37.5%
```

### Function plot

Plot a single-argument function over increasing bounds. Shift-drag pans the existing samples; double-click resets.

```calc
f(x) = x^2
f as plot(-5,5)
# Result: [plot: line, 201 points]
```

### Data plot

Plot a list by index or [x,y] pairs. Choose line, scatter, or bar; null y values leave gaps.

```calc
[3,7,4,9] as plot("bar")
# Result: [plot: bar, 4 points]
```

## Unit and multiplier presenters

Use `as kg`, `as km/h`, `as Cr`, or `as %(2)` to render a compatible value while retaining the original value. Each accepts optional decimal precision. The editor suggests units from the unit registry, with `u` for the micro prefix. Compound unit expressions such as `kg/(m*s^2)` can be entered directly.

Registered discovery spellings:

`%`, `k`, `M`, `B`, `T`, `Cr`, `L`, `m`, `s`, `g`, `kg`, `min`, `h`, `day`, `l`, `litre`, `rad`, `deg`, `Tm`, `Ts`, `Tg`, `Tl`, `Trad`, `Gm`, `Gs`, `Gg`, `Gl`, `Grad`, `Mm`, `Ms`, `Mg`, `Ml`, `Mrad`, `km`, `ks`, `kl`, `krad`, `hm`, `hs`, `hg`, `hl`, `hrad`, `dam`, `das`, `dag`, `dal`, `darad`, `dm`, `ds`, `dg`, `dl`, `drad`, `cm`, `cs`, `cg`, `cl`, `crad`, `mm`, `ms`, `mg`, `ml`, `mrad`, `um`, `us`, `ug`, `ul`, `urad`, `nm`, `ns`, `ng`, `nl`, `nrad`, `pm`, `ps`, `pg`, `pl`, `prad`.
