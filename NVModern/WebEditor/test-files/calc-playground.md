# Calc playground

Change the inputs and watch the results after `→` or `->` update. Both arrows work.
Each calc fence has its own scope. Inline expressions use the nearest preceding calc fence.
Presenters change the display while the variables keep their computed values and types.
This sample includes every expression in the typed-calc regression table, plus the block, parser, and editor scenarios.
The expected-error sections are intentional. Copy the optional syntax and stress cases into a calc fence one at a time.
For graphical function, data, unit, and symbolic plots, open [Calc plots](calc-plots.md).
For completion, function hints, and searchable examples, open [Discover calc](calc-discovery.md), or press F1 inside any calc expression.

## Start here: reactive assignments and comments

Edit `price`, `quantity`, or the formula for `total`. The comment stays in place when the result changes.

```calc
# Whole-line hash comment: price = ??? -> ignored

; Whole-line semicolon comment: total = ??? → ignored
price = 25 -> 25
quantity = 4 → 4
total = price * quantity -> 100 # calculate total
tax_rate = 10% as % → 10%
with_tax = total * (1 + tax_rate) as decimal(2) → 110.00 ; final amount
total + 1 → 101
label = "# and ; inside strings are literal"
label → "# and ; inside strings are literal"
```

Current total: {{ total -> 100}}. With tax: {{ with_tax as decimal(2) → 110.00}}.
Without a source arrow, this expression renders as a result when the cursor is elsewhere: {{ total + 1 }}.
This inline-code example stays literal: `{{ not_calc }}`.

## Numbers, exact fractions, and types

`//` creates an exact fraction. Mixing in an approximate real changes the arithmetic type.
The public type names appear as strings. Large integer results retain every digit.

```calc
1//3 + 1//6 → 1//2
1//3 * 3 → 1
(1 + 2)//(3 + 4) → 3//7
1//-3 → -1//3
2//4 == 1//2 → true
9007199254740993 + 2 → 9007199254740995
999999999999999999999999999999999999//3 → 333333333333333333333333333333333333
1//3 @round(2) → 33//100
1234 @round(-2) → 1200
1//3 @type → "rational"
1//3 + 0.1 @type → "real"
42 @type → "integer"
1e7 @type → "real"
1//3 as decimal(4) → 0.3333
```

## Percentages, decimal presenters, and scale presenters

Your original formula is included here. `as %(2)` fixes the percentage display to two decimal places.
`1.005 as decimal(2)` demonstrates rounding the stored binary floating-point value rather than an exact decimal.

```calc
0.375 as % → 37.5%
0.375 as %(2) → 37.50%
10% * ((1 - 0.125) / (1 - 0.3)) + 25% as % → 37.5%
100 + 3% → 100.03
0.375 as decimal(2) → 0.38
-0.375 as decimal(2) → -0.38
1//8 as decimal(2) → 0.13
1.005 as decimal(2) → 1.00
9007199254740993 == 9007199254740992.0 → false
1//10 == 0.1 → false
25000000 as Cr → 2.5Cr
25000000 as Cr(2) → 2.50Cr
```

## Complex numbers

```calc
3 + 4i @abs → 5
3 + 4i @conj → 3 - 4i
(3 + 4i) * (3 - 4i) → 25
i^2 → -1
complex(-4) @sqrt → 2i
complex(1e200, 1e200) + complex(1e200, 1e200) → 2e+200 + 2e+200i
complex(1e308, 1e308) / complex(1e308, 1e308) → 1
1//3 + 4i @re → 1//3
i * (1//3) → (1//3)*i
[i, 3i] @mean → 2i
```

## Units, conversions, and dimensional arithmetic

Unit powers attach to the unit: `10m^2` differs from `(10m)^2`.
`L` remains lakh. Use `l` or `litre` for volume. Financial scales combine with units through explicit multiplication.

```calc
10kg * 3 → 30kg
10 kg * 3 → 30kg
10m/s * 20s → 200m
1kg + 250g → 1.25kg
1km / 500m → 2
10m/s as km/h → 36km/h
10m/s as km/h(1) → 36.0km/h
2500g as kg → 2.5kg
2500g as kg(2) → 2.50kg
10mm as m → 0.01m
2Cr * 1kg → 20000000kg
10L → 1000000
2litre as l → 2l
10m^2 → 10m^2
(10m)^2 → 100m^2
10kg/(m*s^2) → 10kg/(m*s^2)
10s^-1 → 10s^-1
(10m)^-2 → 0.01m^-2
sqrt((3m)^2) → 3m
sin(90deg) → 1
```

## Statistics, lists, and arithmetic functions

Variance defaults to the sample convention. The population examples select that convention explicitly.
`@list.len` is qualified because the short name `len` is shared by lists and strings.

```calc
[1kg, 500g] @mean → 0.75kg
[1kg, 500g] @variance("population") → 0.0625kg^2
[1kg, 500g] @std("population") → 0.25kg
[1, 2, 3, 4] @mean @round(1) → 2.5
[1, 2, 3] @sum → 6
[1, 2, 3] @map(math.sqrt) @list.len → 3
[1, 2, 3] @variance → 1
[0, 10] @quantile(0.25) → 2.5
range(1, 5) @sum → 10
[3, 1, 2] @sort @slice(1) → [2, 3]
gcd(18, 24) → 6
lcm(6, 8) → 24
5 @factorial → 120
log(8, 2) → 3
```

## List comprehensions

Use one `for` clause and an optional `if` filter. The variable stays local, and each result is an ordinary list.
Change `factor`, `readings`, or `xs` to update the results and plot.

```calc
factor = 2
squares = [n^2 * factor for n in range(5)] → [0, 2, 8, 18, 32]
readings = [3, -1, 0, 2]
[v for v in readings if v > 0] → [3, 2]
[1//n for n in [0, 1, 2, 3] if n != 0] → [1, 1//2, 1//3] # skip division by zero
[n * 1kg for n in [1, 2, 3]] → [1kg, 2kg, 3kg]
[z @conj for z in [1 + 2i, 3 - 4i]] → [1 - 2i, 3 + 4i]
[n @type for n in [1, 1//3, 2kg]] → ["integer", "rational", "quantity"]

xs = [n//10 for n in range(-50, 51)]
[[x, factor * x^2] for x in xs] as plot

n = 100
[n + 1 for n in [1, 2]] → [2, 3]
n → 100 # the outer name stays the same
doubles(values, scale) = [v * scale for v in values]
doubles(readings, factor) → [6, -2, 0, 4]
[[x*y for y in [1, 2]] for x in [3, 4]] → [[3, 6], [4, 8]]
[missing for x in []] → []
[missing for x in [1, 2] if false] → []
```

Inline comprehensions use the same preceding scope: {{ [v * factor for v in readings if v > 0] → [6, 4] }}.
Comprehensions use calc expressions (`^` for powers), evaluate eagerly, and accept lists as inputs.
They allow at most 10000 output items within the normal evaluation budget; plots retain their 2000-point limit.
For expected errors, try `[n for n in 3]`, `[1//n for n in [0]]`, or `[n for n in [1] if missing]`.
Multiple clauses such as `[x*y for x in [1, 2] for y in [3, 4]]` and destructuring are intentionally unsupported.

## All legacy numeric suffixes

The legacy mappings for `B` and `T` are retained: `B = 10^7` and `T = 10^9`.

```calc
10k → 10000
2M → 2000000
3B → 30000000
4T → 4000000000
5Cr → 50000000
6L → 600000
10k% → 100
1e7 → 10000000
6.02e23 → 6.02e+23
6.75% → 0.0675
-2^2 → -4
(-2)^2 → 4
2^3^2 → 512
```

## Presentation preserves the value

Compare `third` with `rounded`. Changing the presenter precision does not round the stored `third`.

```calc
third = 1//3 as decimal(4) → 0.3333
third * 3 → 1
third @type → "rational"
rounded = 1//3 @round(2) as decimal(2) → 0.33
rounded * 3 as decimal(2) → 0.99
rounded → 33//100
speed = 10m/s as km/h → 36km/h
speed * 20s → 200m
speed @type → "quantity"
```

The same fraction as a percentage: {{ third as %(2) -> 33.33%}}.
The same speed with a different presenter: {{ speed as km/h(1) -> 36.0km/h}}.

## Custom presenters and their dependencies

Edit `prefix`, `places`, or either presenter body. The displayed outputs update while the numeric bindings remain usable.
`as percent` renders the returned string. `@percent` makes that string the computed result.

```calc
prefix = "$"
places = 2
money(value, currency) = currency + decimal(value, places)
percent(value) = decimal(value * 100, 1) + "%"
salary = 2500 as money(prefix) → $2500.00
salary * 2 → 5000
ratio = 0.375 as percent → 37.5%
ratio * 1000 → 375
ratio @percent → "37.5%"
ratio as percent → 37.5%
```

Custom presenter inline: {{ salary as money(prefix) -> $2500.00}}.
Decimal presenter called as a regular function: {{ decimal(ratio, 4) -> 0.3750}}.

## Functions, pipes, callbacks, and lexical scope

```calc
double(n) = n * 2
square(n) = n^2
positive(n) = n > 0
add(a, b) = a + b
3 @double → 6
3 |> double @double → 12
[1, 2, 3] @map(square) → [1, 4, 9]
[1, 2, 3] |> list.map(square) → [1, 4, 9]
[-2, -1, 0, 1, 2] @filter(positive) → [1, 2]
[1, 2, 3] @reduce(add, 0) → 6
range(5) → [0, 1, 2, 3, 4]
range(5, 0, -1) → [5, 4, 3, 2, 1]
[3, 1, 2] @list.reverse → [2, 1, 3]
[3, 1, 2] @list.first → 3
[3, 1, 2] @list.last → 2
"   hello calc   " @str.trim @str.upper → "HELLO CALC"
str.len("hello") → 5
str.split("a,b,c", ",") → ["a", "b", "c"]
str.join(["a", "b", "c"], " / ") → "a / b / c"
str.includes("calc playground", "calc") → true
str.replace("hello world", "world", "calc") → "hello calc"
core.if(true, "yes", "no") → "yes"
core.coalesce(null, "", 42) → 42
x = 2
v = x
f(x) = v
f(8) → 2
v → 2
```

The final two results stay `2`: a function parameter does not leak into a global definition.

## Forward references and a longer formula

Definitions can appear after their use. Edit a rate, term, or principal to recompute the payment.

```calc
total = double(price) → 6
double(n) = n * 2
price = 3 → 3
total + 1 → 7
principal = 400000
apr = 6.75%
monthly_rate = apr / 12
months = 30 * 12
payment(p, r, n) = p * r / (1 - (1 + r)^(-n))
monthly = payment(principal, monthly_rate, months) as decimal(2) → 2594.39
monthly @round(2) → 2594.39
```

Payment inline: {{ monthly as decimal(2) -> 2594.39}}.

## Symbolic expressions and transformations

Declare symbols explicitly. `@subs` supplies their values without rebinding them.
Try different polynomials. Factoring and differentiation support the subset described in the calc spec.

```calc
symbol x, y
2*x + 3*x @simplify → 5*x
(x + y)^2 @expand → x^2 + 2*x*y + y^2
p = x^2 + 3*x
p @diff(x) → 2*x + 3
p @subs(x, 2) → 10
x^2 + 2*x + 1 @factor → (x + 1)^2
x^2 - 1 @factor → (x + 1)*(x - 1)
2*x^2 + 4*x @factor → 2*x*(x + 2)
sin(x) @diff(x) → cos(x)*1
sin(x) @subs(x, 0) → 0
exp(x) @diff(x) → exp(x)*1
ln(x) @diff(x) → 1/x
x/x @simplify → x/x
0 * (1/x) @simplify → 0*1/x
p @type → "expression"
(-2)^x → (-2)^x
(1//2)^x → (1//2)^x
(3 + 4i)*x → (3 + 4i)*x
(3m)*x → (3m)*x
f(x) = x + 1
f(2) → 3
```

Symbolic inline: {{ p @diff(x) -> 2*x + 3}}.
`x/x` stays an expression because replacing it with `1` would remove its undefined point at zero.

## Strings, escaping, and comments in rendered output

A presenter can return literal quotes, comment markers, whitespace, or closing braces.
The source writer escapes them, and the display widget shows the text. Click into the result to inspect its source.

```calc
tag(value) = decimal(value, 0) + " # items"
braces(value) = "}}"
blank(value) = ""
padded(value) = " padded "
line_break(value) = "line\nbreak"
count = 3 as tag → "3 # items" # preserve this trailing comment
count + 1 → 4
count as braces → }}
count as blank → ""
count as padded → " padded "
count as line_break → "line\nbreak"
"say \"#hello;\"" → "say \"#hello;\""
'it\'s #; fine' → "it's #; fine"
"C:\\" → "C:\\"
["#", ";", "don't"] → ["#", ";", "don't"]
```

Custom tag: {{ count as tag -> "3 # items"}}. Closing braces: {{ count as braces -> "}}"}}.
Empty presentation: [{{ count as blank -> ""}}]. Padded text: [{{ count as padded -> " padded "}}].
Legacy string output: {{ "can't" -> "can't" }}.
Quoted closing delimiter: {{ "can't }} stop" -> "can't }} stop"}}.
List output: {{ ["can't", "}}", "#;"] -> ["can't", "}}", "#;"]}}.

## Inline scope follows the nearest preceding calc fence

```calc
speed = 10m/s
```

First scope: {{ speed as km/h -> 36km/h}}.

```calc
speed = 20m/s
```

Second scope: {{ speed as km/h -> 72km/h}}.
Editing this second block does not change the first inline result.

## Expected runtime errors

Every line in the next fence intentionally reports an error. Change the input to make it valid.

```calc
# EXPECTED ERRORS

1//0 → ⚠ Division by zero.
1.5//3 → ⚠ Numerator must be an Integer.
1kg + 2m → ⚠ Incompatible dimensions.
1kg as % → ⚠ Value must be a dimensionless real number.
1kg as s → ⚠ Incompatible dimensions.
ln(1kg) → "⚠ 'ln' requires a dimensionless input."
sqrt(-1) → ⚠ Square root requires a nonnegative real input.
3i < 4i → ⚠ Complex values cannot be ordered.
median([i]) → ⚠ Complex values cannot be ordered.
factorial(-1) → ⚠ Factorial input must be between 0 and 1000.
range(0, 1, 0) → ⚠ Range step cannot be zero.
decimal(1, 101) → ⚠ Precision must be between 0 and 100.
abs(1, 2) → "⚠ Function 'math.abs' expects 1 argument(s), got 2."
missing + 1 → "⚠ Unknown identifier 'missing'."
[1, 2] @len → "⚠ Ambiguous operation 'len'. Use a qualified name."
```

## Expected presenter error with a valid binding

`bad` returns a number instead of display text. Its presentation fails, but `amount * 4` still works.

```calc
# EXPECTED ERRORS

bad(value) = value + 1
amount = 3 as bad → ⚠ Presenter must return a string or plot. # presenter must return a string
amount * 4 → 12
```

## Expected circular-definition error

```calc
# EXPECTED ERRORS

a = b + 1
b = a + 1
a → "⚠ Circular value definition detected for 'a'."
```

## Expected symbol-conflict error

Comment out `x = 2` to keep `x` symbolic, or remove the symbol declaration to make it numeric.

```calc
# EXPECTED ERRORS

symbol x
x = 2
x + 1 → "⚠ Symbol 'x' conflicts with a definition."
```

## Optional parser diagnostics

These cases stay in a text fence so the rest of the sample opens without syntax errors.
Copy one line into a calc fence to inspect the diagnostic.

```text
i = 2
as = 2
symbol = 2
f(i) = i
symbol i
f(x, x) = x
1 @
1 as
1 as decimal(2) as %
f(x) = x as %
10foo
10constructor
2kkg
1m^1000
value |> 2
broken =
total = ->
f(x) = x + 1 ->
```

## Optional resource-limit and large-literal cases

Copy one case at a time into a calc fence. The first four should report a resource limit.
The large fraction demonstrates an approximate ratio whose exact numerator and denominator each exceed floating-point range.

```text
99999999999999999999^10000
range(0, 10001)
1m^32 * 1m
(1m^32)^2
```

```text
symbol x
(x + 1)^13 @expand
```

```text
((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((1))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
```

```text
9999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999
(9999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999//8888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888) @approx
```

## Parser boundary examples

The following JavaScript fence is a literal syntax sample. Its braces are not calc expressions.

```js
const ignored = "{{ not_calc }}";
```

These examples deliberately omit a closing delimiter. Copy them separately to try the scanner diagnostics.

Start a new note with `` ```calc `` and the following two lines, without a closing fence.

```text
x = 1
y = x + 1
```

```text
Unclosed inline: {{ 1 + 2
```
