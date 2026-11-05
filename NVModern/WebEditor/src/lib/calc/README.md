# Calc language specification

This document is the source-of-truth spec for nvModern's reactive Markdown `calc` language.

## Status

The sections through "Future extensions" preserve the v1 baseline for compatibility reference.
The [typed language revision](#typed-language-revision) specifies the current implementation.
It adds exact integers and rationals, complex values, units, symbols, postfix `@` operations, callable presenters, SVG plots, and list comprehensions.
The v1 non-goals apply to the baseline. The revision states its own scope and limits.

`calc` is intentionally **not JavaScript**. It is a small, pure, expression-oriented language for:

- inline Markdown expressions: `{{ ... }}`
- fenced reactive blocks: ```` ```calc ````

The design goal is:

> spreadsheet formulas + notebook definitions + namespaced standard library + pipes

Execution of imperative fences such as ```` ```javascript ```` or ```` ```python ```` is a separate feature and is **not part of the `calc` language**.

## Goals

- stay readable in plain Markdown
- be deterministic and side-effect free
- support local values and local helper functions
- keep built-ins namespaced (`math.ln`, `stats.mean`, etc.)
- support pipe-based composition (`|>`)
- remain small enough for a standalone parser and evaluator

## Non-goals for v1

- loops
- mutation
- imports
- I/O / network / filesystem access
- randomness / wall-clock time
- lambdas
- recursion guarantees
- symbolic algebra
- Mathematica rule syntax (`/.`, `/@`, `@@`, patterns, etc.)

## Markdown integration

### Inline expressions

Inline expressions are single-line only:

```md
The log return is {{ price_ratio |> math.ln() }}.
```

Rules:

- `{{` and `}}` delimit an inline `calc` expression
- contents are parsed as a single `Expression`
- inline expressions do not span newlines
- inline expressions are ignored inside code fences, frontmatter, and Markdown inline code spans

Reactive inline source sync is an explicit opt-in variant:

```md
Monthly payment: {{ payment(principal, rate, months) -> 2534.12 }}
Monthly payment: {{ payment(principal, rate, months) → 2534.12 }}
```

Rules for the reactive form:

- use a top-level `->` or `→` inside the inline calc body
- everything before the arrow is the `calc` expression
- everything after the arrow is derived output text stored in Markdown source
- the editor rewrites only that output segment when the expression result changes
- the arrow is intentionally narrow syntax: it is only recognized at top level, not inside strings or nested `()` / `[]`

### Fenced calc blocks

````md
```calc
principal = 400000
apr = 6.75 / 100
rate = apr / 12
months = 30 * 12

payment(p, r, n) = p * r / (1 - (1 + r)^(-n))
monthly = payment(principal, rate, months)

monthly
monthly |> math.round(2)
```
````

Rules:

- only fences whose normalized info string is `calc` are treated as reactive `calc` blocks
- block contents are parsed line-by-line as `Statement`
- blank lines and whole-line `#` or `;` comments are allowed, including indented comments
- `#` and `;` also start trailing comments after a statement or reactive output; markers inside quoted strings remain part of the string

Reactive source-sync lines are also supported inside `calc` fences:

````md
```calc
# Annual interest
principal = 400000
rate = 6.75%
; Bind a value and show its result on the same line
interest = principal * rate -> 27000 # Annual interest amount
principal * rate -> 27000
principal * rate |> math.round(2) → 27000
```
````

Rules for reactive fence lines:

- use a top-level `->` or `→` on a fence line
- everything before the arrow is parsed as a value definition (`name = expr`) or an expression query line
- text after the arrow and before any trailing comment is derived output stored in Markdown source
- the editor rewrites only that output segment when the expression result changes
- trailing comments are preserved when outputs update, including when the output is initially empty
- string outputs in fences are quoted so comment markers and quotes inside values remain part of the output
- value definitions with an arrow still bind their name for other expressions; the output shows the bound value and updates as its expression or dependencies change
- reactive fence lines use the same block scope and dependency resolution as ordinary definitions and queries
- the arrow is intentionally narrow syntax: it is only recognized at top level, not inside strings or nested `()` / `[]`

## Semantics

## Values

v1 values:

- number
- boolean
- string
- list
- null

Number syntax supports:

- integers: `12`
- decimals: `3.1415`
- scientific notation: `1e7`, `6.02e23`, `1.5e-3`
- percent literals: `10%`, `6.75%`
- scale suffixes: `10k`, `2M`, `3Cr`, `1L`

Percent literals are numeric sugar:

- `10%` parses as `0.1`
- `6.75%` parses as `0.0675`

Supported scale suffixes are:

- `k = 1000`
- `M = 1e6`
- `B = 1e7`
- `T = 1e9`
- `Cr = 1e7`
- `L = 1e5`

Scale suffixes are applied before percent if both are present, so `10k%` parses as `100`.

## Statements

Allowed statement forms inside `calc` blocks:

1. value definition

```txt
name = expr
```

2. function definition

```txt
name(arg1, arg2, ...) = expr
```

3. query / output expression

```txt
expr
```

4. whole-line comment

```txt
# comment
```

## Namespaces

Built-in functions and constants live in namespaces.

Examples:

- `math.pi`
- `math.e`
- `math.ln(x)`
- `math.round(x, 2)`
- `stats.mean(xs)`
- `str.trim(name)`

User-defined names are local and unqualified:

```txt
payment(p, r, n) = ...
currency(x) = x |> math.round(2)
```

## Pipe operator

`calc` supports a first-argument pipe operator:

```txt
lhs |> fn(a, b)
```

desugars conceptually to:

```txt
fn(lhs, a, b)
```

and:

```txt
lhs |> ns.fn()
```

conceptually becomes:

```txt
ns.fn(lhs)
```

A pipe stage may be either:

- a bare callable reference: `x |> f`
- a callable reference with arguments: `x |> f(1, 2)`
- a namespaced callable reference: `x |> math.round(2)`

## Function definitions

Function definitions are expression-bodied and pure:

```txt
square(x) = x ^ 2
payment(p, r, n) = p * r / (1 - (1 + r)^(-n))
```

v1 rules:

- only simple parameter names are allowed
- function bodies are single expressions
- no statements inside function bodies
- recursion is not guaranteed in v1; evaluators may reject recursive cycles

## Standard library shape

The parser does not hardcode the stdlib, but the language is intended to expose built-ins through namespaces such as:

- `math.*`
- `stats.*`
- `list.*`
- `str.*`
- `core.*`

Example built-ins:

- `math.abs`, `math.sqrt`, `math.exp`, `math.ln`, `math.round`, `math.min`, `math.max`
- `stats.sum`, `stats.mean`, `stats.median`
- `list.len`, `list.first`, `list.last`
- `str.trim`, `str.lower`, `str.upper`
- `core.if`, `core.coalesce`

## Implemented v1 grammar

The grammar below describes the accepted v1 surface syntax.

```ebnf
Document           ::= StatementLine* EOF
StatementLine      ::= BlankLine | CommentLine | (Statement | ReactiveStatement) S* Comment?
BlankLine          ::= /* empty or whitespace-only line */
CommentLine        ::= S* Comment
Comment            ::= ("#" | ";") CommentText?
Statement          ::= FunctionDefinition | ValueDefinition | Expression
ReactiveStatement  ::= (ValueDefinition | Expression) S* ("->" | "→") S* OutputText?

FunctionDefinition ::= Identifier S* "(" S* ParameterList? S* ")" S* "=" S* Expression
ValueDefinition    ::= Identifier S* "=" S* Expression
ParameterList      ::= Identifier (S* "," S* Identifier)*

Expression         ::= PipeExpression
PipeExpression     ::= ComparisonExpression (S* "|>" S* PipeStage)*
PipeStage          ::= CallableReference (S* "(" S* ArgumentList? S* ")")?

ComparisonExpression ::= AdditiveExpression
                       (S* ("==" | "!=" | "<" | "<=" | ">" | ">=") S* AdditiveExpression)*

AdditiveExpression ::= MultiplicativeExpression
                       (S* ("+" | "-") S* MultiplicativeExpression)*

MultiplicativeExpression ::= UnaryExpression
                             (S* ("*" | "/") S* UnaryExpression)*

UnaryExpression    ::= ("-" S*) UnaryExpression
                     | PowerExpression

PowerExpression    ::= PostfixExpression (S* "^" S* UnaryExpression)?

PostfixExpression  ::= PrimaryExpression (S* MemberAccess | S* CallSuffix)*
MemberAccess       ::= "." S* Identifier
CallSuffix         ::= "(" S* ArgumentList? S* ")"
ArgumentList       ::= Expression (S* "," S* Expression)*

PrimaryExpression  ::= Number
                     | Boolean
                     | Null
                     | String
                     | ListLiteral
                     | Identifier
                     | "(" S* Expression S* ")"

ListLiteral        ::= "[" S* ArgumentList? S* "]"
CallableReference  ::= Identifier (S* "." S* Identifier)*
Boolean            ::= "true" | "false"
Null               ::= "null"
Identifier         ::= IdentifierStart IdentifierContinue*
IdentifierStart    ::= "A".."Z" | "a".."z" | "_"
IdentifierContinue ::= IdentifierStart | Digit
Digit              ::= "0".."9"
Number             ::= NumericLiteral ScaleSuffix? "%"?
NumericLiteral     ::= IntegerPart FractionPart? ExponentPart?
IntegerPart        ::= DigitOrUnderscore+
FractionPart       ::= "." DigitOrUnderscore+
ExponentPart       ::= ("e" | "E") ("+" | "-")? DigitOrUnderscore+
ScaleSuffix        ::= "k" | "M" | "B" | "T" | "Cr" | "L"
DigitOrUnderscore  ::= Digit | "_"
String             ::= DoubleQuotedString | SingleQuotedString
S                  ::= " " | "\t"
```

## Precedence and associativity

Highest to lowest:

1. member access and function calls: `foo.bar(x)`
2. exponentiation: `x ^ y` (right-associative)
3. unary minus: `-x`
4. multiplication / division: `*`, `/`
5. addition / subtraction: `+`, `-`
6. comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`
7. pipe: `|>`

Examples:

```txt
-2^2          == -(2^2)
1 + 2 |> f()  == f(1 + 2)
```

## Parser invariants

The standalone parser must:

- accept the grammar above without depending on CodeMirror or Markdown parsing
- parse both isolated expressions and line-based block statements
- produce source ranges for AST nodes and diagnostics
- preserve enough structure for later evaluator work and CM6 decorations

## CM6 plugin responsibilities (v1)

The initial editor integration is parser-first, not evaluator-first.

The plugin should:

- detect inline `{{ ... }}` expressions in Markdown
- detect ```` ```calc ```` fences in Markdown
- parse their contents with the standalone parser
- expose parse results through editor state
- decorate inline expressions and calc fences conservatively
- highlight parse errors without altering editor geometry
- evaluate inline expressions and calc fence query lines
- support the explicit inline reactive source-sync form `{{ expr -> output }}` / `{{ expr → output }}`
- support the explicit fence reactive source-sync form `expr -> output` / `expr → output` on individual `calc` fence lines

The plugin should **not**:

- execute `javascript`, `typescript`, or `python` fences

## Future extensions

Likely next steps after parsing/evaluator basics:

- richer inline / block presentation for non-scalar values
- output widgets for query lines in `calc` fences
- explicit run buttons for imperative fences (`js`, `ts`, `python`)
- richer stdlib and notebook-style presentation

## Typed language revision

This section specifies the implemented typed language revision.
It extends the v1 baseline without adopting math.js as a dependency or expression evaluator.
Wolfram Language supplies the model of structured expression values and function application.
Math.js supplies reference behavior for numeric types and dimensional arithmetic.
The grammar and evaluation rules below define calc's own behavior.

### Core syntax

Literals construct typed values. Operators combine those values. Postfix `@` operations transform a value.
A final `as` clause passes the result to a presenter without changing the result itself.

```txt
1//3 + 1//6 → 1//2
3 + 4i @abs → 5

10kg * 3 → 30kg
10m/s * 20s → 200m
10m/s as km/h → 36km/h

[1, 2, 3, 4] @mean → 2.5
0.375 as % → 37.5%

symbol x
2*x + 3*x @simplify → 5*x

p = x^2 + 3*x
p @diff(x) → 2*x + 3
p @subs(x, 2) → 10
```

The parser, runtime, and Markdown editor support these examples.
An operation transforms a runtime value. It does not replace the source expression.
Only the derived segment after an output arrow changes during source sync.

### Discover calc in the editor

Use **Explore calc** beside the active calc fence's opening line, or press **F1** with the cursor inside a calc fence or inline expression.
In nvModern, the reference slides up from the bottom of the workspace as a native Liquid Glass help drawer, with native search and a sidebar beside React-rendered descriptions.
Standalone editors open the CodeMirror panel instead. Both search functions, constructions, units, and multipliers.
The app-wide **Help → Explore nvModern Help** command browses the same reference without an insertion target.
The shared provider and host API is documented in [Shared help service](../../../../../docs/architecture/help.md).
Search by intent, such as `percentage`, `convert units`, `graph`, or `filter list`, or choose a category.
Each entry shows its description, signatures, and executable examples with their expected results.

Arrow keys browse the search results. Enter inserts the selected template or example; the explicit insert buttons do the same.
Escape closes help and returns focus to the editor. Examples insert on a new line in a nonempty calc statement, or replace selected text within the current expression.
Templates use CodeMirror snippet fields: Tab and Shift-Tab move between editable fields.
Examples with known results include a reactive arrow so the inserted result updates immediately.
Multi-line templates and examples require a calc fence. Read-only notes can browse the reference, with insertion disabled.

Contextual completion is available inside calc fences and `{{ ... }}`, including incomplete expressions:

| At the cursor | Completion choices |
|---|---|
| `math.` | Members of the selected namespace, including constants |
| `values @` or `values \|>` | Callable operations, ranked by a statically known receiver type |
| `value as ` | Presenters, registered unit and multiplier spellings, and custom functions |
| Partially typed name | Standard-library and locally defined names |
| Empty expression, with explicit completion | Functions, namespaces, construction templates, and Explore calc |

Type to activate completion. Ctrl-Space or Cmd/Ctrl-Shift-Space explicitly opens it; Enter accepts a choice and Escape dismisses it.
Choosing a namespace reopens its member list. Selecting a function supplies editable required arguments; optional arguments remain visible in help.
Comprehension variables and function parameters are suggested in their local scope. Inline expressions use the nearest preceding calc fence.
Ambiguous short names remain qualified, such as `list.len` and `str.len`. A local binding that shadows a built-in leaves the qualified built-in available in completion.
Type ranking uses syntax and known bindings rather than evaluating incomplete expressions, and does not hide other operations.
Comments, strings, derived output text, unrelated fences, and prose do not trigger calc completion.

Hover over an operation to see its signature, explanation, and example. Argument help appears inside an incomplete call and highlights the active parameter.
After `@`, `|>`, or `as`, the implicit input is omitted from the displayed parameters. Help also covers local function signatures, overloads, and unit presenter precision.
Escape dismisses argument help; typing or moving the cursor can show it again.

The catalog in `catalog.ts` supplies completion, tooltips, the panel, and the generated [stdlib reference](REFERENCE.md).
Built-in callables carry their catalog entry and check its arity against the implementation when registered.
Tests verify registration coverage, executable example results, and reference freshness. Run `make calc-reference` after updating the catalog.
The editor uses CodeMirror's completion, snippet, hover-tooltip, tooltip-state, keymap, decoration, and panel facilities; the catalog itself has no editor dependency.

### Types and numeric values

Values carry their runtime types. Normal calculations do not require type annotations.
The initial type set is:

| Type | Construction | Meaning |
|---|---|---|
| Integer | `42` | An exact integer. |
| Real | `0.125`, `1e7` | A finite approximate real number. |
| Rational | `1//3` | An exact, reduced integer numerator and denominator. |
| Complex | `3 + 4i` | A real component and an imaginary component. |
| Quantity | `10kg` | A numeric magnitude and physical dimensions. |
| Expression | `x^2 + 3*x`, after `symbol x` | A structured symbolic expression. |
| Function | `double`, after its definition | A pure callable accepted by calls, `@`, `as`, and higher-order functions. |
| Boolean, String, List, Null | Existing v1 syntax | The existing non-numeric value types. |

`@type` reports the type of a value. Values do not require mutable objects with separate method tables.
Operations dispatch through typed function signatures in one registry.
The same registry supplies normal function calls and `@` calls.

Integers and rational numerators and denominators must not lose precision through JavaScript `Number` conversion.
Rationals have a positive denominator and use lowest terms. A denominator of one reduces to an integer.
Quantities retain their magnitude's numeric type, including an exact rational magnitude.

`//` constructs a rational from two Integer operands. A zero denominator is an error.
It has the same precedence and left associativity as `*` and `/`.
Use parentheses for a compound numerator or denominator: `(a + b)//c` and `a//(b + c)`.

Ordinary `/` between ordinary integer or real operands keeps v1's approximate division behavior.
Arithmetic between rationals and integers stays exact, including division.
An approximate real operand promotes the numeric calculation to approximate arithmetic.
`@approx` deliberately converts an exact scalar to an approximate real value.
Presentation never recovers exactness from an approximate calculation.
`@round(digits)` rounds the stored value and preserves an exact rational input as an exact rounded rational.

`i` is the reserved imaginary constant. An attached numeric coefficient constructs an imaginary literal: `4i`.
`3 + 4i` combines numeric components into a complex value.
This notation does not introduce general implicit multiplication.
Complex values support arithmetic, magnitude, real and imaginary parts, and conjugation.
Ordering comparisons and ordering-based statistics reject complex inputs.
A real-domain function does not silently switch to complex arithmetic after a domain error.
For example, a negative real square root requires an explicit complex input.

### Postfix operations and functions

`@` passes the value on its left as the first argument of the operation on its right:

```txt
value @operation           # operation(value)
value @operation()         # operation(value)
value @operation(a, b)     # operation(value, a, b)
```

A stage accepts a callable reference with optional arguments.
Zero-argument stages can omit parentheses. Additional arguments use ordinary expression syntax.
Stages run from left to right and use the same lexical scope as normal function calls.

```txt
[1, 2, 3, 4] @mean @round(1) → 2.5

double(n) = n * 2
3 @double → 6
```

Unqualified callable names resolve to local functions first, then to an unambiguous built-in short name.
Qualified names remain available: `value @math.round(2)`.
Existing `|>` stages remain valid and share the same first-argument application mechanism.
An unknown operation or ambiguous short name is an error.

Arithmetic and comparisons form the input to a pipeline. `@` and `|>` stages then run in source order.
Arithmetic after a stage requires parentheses around the pipeline result:

```txt
3 + 4i @abs          # abs(3 + 4i)
(a @abs) + b        # abs(a) + b
```

Function definitions keep the existing pure, expression-bodied form.
Each built-in declares accepted types, argument counts, domain checks, and result behavior.
User functions can accept any values that their bodies support.
Unsupported combinations report a type or domain error instead of converting through strings.

### Symbols and expression values

`symbol` declares mathematical symbols in the current calc block:

```txt
symbol x, y
formula = (x + y)^2
formula @expand → x^2 + 2*x*y + y^2
```

A declared symbol is a value. Arithmetic involving a symbol builds an expression tree.
Known functions can construct symbolic calls when their signatures support expression arguments.
Symbolic values retain structure, not source strings that later require evaluation.
Definitions and declarations belong to their calc block. Inline expressions inherit the nearest preceding block's scope, as in v1.

Unknown identifiers remain errors outside a declaration.
There is no fallback that turns a misspelled variable or function into a symbol.
A symbol declaration conflicts with a value or function definition of the same name in the same block.
Function parameters can shadow names within their local scope.
`i` cannot be declared or rebound.

Symbolic operations include `@simplify`, `@expand`, `@factor`, `@diff(symbol)`, and `@subs(symbol, value)`.
Substitution supplies values explicitly and evaluates numeric subexpressions:

```txt
symbol x
p = x^2 + 3*x
p @diff(x) → 2*x + 3
p @subs(x, 2) → 10
```

The ordinary block scope still resolves definitions reactively.
Symbols stay symbolic. A formula does not capture an unrelated later numeric binding for a declared symbol.
Operations return new values and do not mutate stored expressions.

Simplification must preserve the expression's domain unless explicit assumptions justify a restriction.
For example, `x/x` cannot become an unconditional `1` because the original expression is undefined at zero.
The implementation uses conservative transformations and reports unsupported symbolic operations explicitly.
General equation solving, unrestricted rewrite rules, and Wolfram's full evaluation-control system are outside this revision.

### List comprehensions

Comprehensions construct ordinary lists with Python's `for ... in ... if ...` syntax and calc's existing expression rules:

```calc
squares = [n^2 for n in range(5)] → [0, 1, 4, 9, 16]
readings = [3, -1, 0, 2]
positive = [v for v in readings if v > 0] → [3, 2]
reciprocals = [1//n for n in [0, 1, 2, 3] if n != 0] → [1, 1//2, 1//3]
weights = [n * 1kg for n in [1, 2, 3]] → [1kg, 2kg, 3kg]

xs = [n//10 for n in range(-50, 51)]
points = [[x, x^2] for x in xs] as plot
points @list.len → 101
```

The supported forms are `[expression for name in list]` and `[expression for name in list if condition]`.
Each comprehension has one `for` clause, one simple variable name, and at most one `if` filter.
Bodies, source lists, and filters accept existing calc expressions, including calls, pipelines, typed values, and list expressions.
Use calc's `^` for powers and lowercase `true`, `false`, and `null`.
The final `as` clause presents the completed list; it is not part of an individual element's expression.

Evaluation proceeds in source order:

1. Evaluate the source expression once in the enclosing scope. Its result must be a list; strings, numbers, and other values are errors.
2. Bind the iteration name to each item in a temporary local scope. It can shadow an outer name, and disappears after the comprehension.
3. Evaluate the optional filter using the same truth rules as `list.filter`: zero, `false`, `null`, empty strings, and empty lists are false; nonempty or nonzero values are true.
4. For each passing item, evaluate the body and append its typed result. Skipped bodies are not evaluated. An empty input or a filter that rejects every item returns `[]`.

The input list and enclosing bindings do not change. A failed body or filter fails the whole comprehension instead of exposing a partial list.
An existing function keeps its lexical block scope when called inside a comprehension; the iteration name does not become a new free variable in that function.

```calc
n = [2, 3]
[n^2 for n in n] → [4, 9]
n → [2, 3]

doubles(values, factor) = [v * factor for v in values]
doubles([1, 2, 3], 4) → [4, 8, 12]
```

Separate comprehensions can be nested as ordinary expressions, with each binding scoped independently:
`[[x*y for y in [1, 2]] for x in [3, 4]]` returns `[[3, 6], [4, 8]]`.
Multiple `for` clauses in one comprehension, multiple filter clauses, destructuring, conditional expressions, generator expressions, assignments, and statement loops are unsupported.
Comprehensions eagerly build lists; they do not add iterators, mutation, or a statement execution model.

`for`, `in`, and `if` are contextual words in this syntax. Existing variables and functions with those names remain valid elsewhere.
The existing binding restrictions on `i`, `as`, and `symbol` also apply to the iteration name.
Comprehensions work in calc functions, reactive assignments, queries, and inline Markdown expressions.
Dependency changes rebuild the list and any plot derived from it, while source sync preserves the expression and trailing comment.
A result has at most 10000 elements, and every iteration, filter, and body shares the query's 100000-step budget. Nesting retains the existing 128-level limits.

### Units, prefixes, and scale suffixes

A quantity stores a magnitude in canonical units and dimension exponents.
For velocity, the dimensions are length to power one and time to power minus one.
Compatible units share dimensions and differ by a conversion scale.
The registry retains exact rational scale factors when the unit definitions are exact.

Addition, subtraction, and ordering comparisons require compatible dimensions.
Multiplication and division combine dimensions and cancel matching factors.
A result with no physical dimensions becomes an ordinary scalar.

```txt
1kg + 250g → 1.25kg
10m/s * 20s → 200m
1km / 500m → 2
1kg + 2m → ⚠ incompatible dimensions
```

Registered unit suffixes attach to numeric literals. `10kg` and `10 kg` are equivalent.
Unit expressions support explicit `*`, `/`, integer powers, and parentheses: `kg/(m*s^2)`.
A literal's unit power belongs to the unit: `10m^2` means ten square metres.
Parentheses distinguish a quantity power: `(10m)^2` means one hundred square metres.

The unit suffix consumes compound factors only when the next factor is a registered unit.
It stops before another numeric quantity, as in `10m/s * 20s`.
Parentheses end a quantity literal before arithmetic with a variable whose name also denotes a unit: `(10m) / s`.
Unit symbols have their special meaning in unit positions. They do not reserve ordinary variable names globally.
Unknown suffixes report an error. They do not create new dimensions or imply multiplication by a variable.

Prefixes are case-sensitive parts of a unit symbol: `km`, `mm`, `ms`, and `mg`.
A prefix requires a unit. An isolated `m` denotes metres, not a standalone milli multiplier.
Gram-based prefixes normalize to the canonical mass unit, kilogram.
The registry rejects stacked prefixes and unsupported symbols.

Existing scale suffixes remain dimensionless numeric multipliers:

```txt
10M → 10000000
10m → 10m
10mm as m → 0.01m
2Cr * 1kg → 20000000kg
```

Existing `L` means lakh. Use `l` or `litre` for litres to preserve that meaning.
Standalone legacy scale suffixes take precedence over conflicting unit spellings.
New units with conflicting symbols require an unambiguous registered name.
Arbitrary financial-scale/unit suffix combinations such as `Crkg` are not inferred. Use explicit multiplication.

The current `B = 1e7` and `T = 1e9` mappings remain legacy behavior.
They must not silently become billion and trillion during this extension.
A change to those values requires a separate compatibility decision.

Without a presenter, quantities use canonical units and a stable default numeric format.
The renderer does not switch prefixes automatically as values change.
The first unit set covers mass, length, time, and their compound dimensions.
Offset temperatures, calendar durations, and currency exchange need separate contracts.

### Presenters use the same call convention

A presenter is a pure callable that accepts the computed value as its first argument and returns display text or a plot value.
It is an ordinary function value. Custom presenters need no separate declaration or registration mechanism.
`as` uses the same first-argument call convention as `@`:

```txt
value as presenter          # render presenter(value), retain value
value as presenter()        # render presenter(value), retain value
value as presenter(a, b)    # render presenter(value, a, b), retain value
```

The difference is where the return value goes.
`@` returns the operation's result to the calculation. `as` sends the presenter's result to the renderer and retains the input value.
The presenter receives the final typed value after the `@` or `|>` pipeline, not the previous text after the output arrow.

A statement has at most one `as` clause, after its value expression and before its output arrow or trailing comment.
Presenters apply to value definitions and queries in calc blocks, and to inline calc expressions.
Function bodies remain value expressions. Call a presenter directly when a function must return its text.

```txt
third = 1//3 as decimal(4) → 0.3333
third * 3 → 1

rounded = 1//3 @round(2) as decimal(2) → 0.33
rounded * 3 as decimal(2) → 0.99
```

The first definition binds the exact rational. The second binds the rounded result.
Here, `rounded` holds `33//100`, while `third` still holds `1//3`.
A presentation choice does not follow a variable into later calculations.
Each output uses its own `as` clause or the default presenter.
Equality and arithmetic do not inspect presentation text.

#### Built-in presenters and aliases

Built-in aliases resolve to callable presenters before invocation:

| Clause | Callable behavior | Example output |
|---|---|---|
| `as decimal(2)` | `present.decimal(value, 2)` | `0.375 as decimal(2)` renders `0.38`. |
| `as %` | `present.percent(value)` | `0.375 as %` renders `37.5%`. |
| `as %(2)` | `present.percent(value, 2)` | `0.375 as %(2)` renders `37.50%`. |
| `as Cr` | Generated scale presenter for `Cr` | `25000000 as Cr` renders `2.5Cr`. |
| `as kg` | Generated unit presenter for `kg` | `2500g as kg` renders `2.5kg`. |
| `as km/h(1)` | Generated unit presenter for `km/h`, with one decimal place | `10m/s as km/h(1)` renders `36.0km/h`. |
| `as plot` | `present.plot(value)` | `[3, 7, 4] as plot` draws a line plot. |

`decimal` is the short alias for `present.decimal` and is also callable directly.
`%` is presenter syntax for the callable `present.percent`.
The percent presenter multiplies the scalar by 100, formats it, and appends `%` to its text.
It does not infer a percentage from the expression's input literals.

```txt
rate = 10% * ((1 - 0.125) / (1 - 0.3)) + 25% as % → 37.5%
rate * 1000 → 375
```

`decimal(value, digits)` emits exactly `digits` fractional decimal places. Its default is two places.
Fixed-place presenters round to nearest, with ties away from zero, using the actual stored numeric value.
Approximate inputs can already contain round-off error. Presentation does not change their arithmetic precision.
Precision arguments must be nonnegative integers within the implementation's documented limit.

Without a precision argument, percent, scale, and unit presenters use the default numeric format and omit trailing fractional zeros.
With a precision argument, those presenters emit exactly that many fractional decimal places.
Scale presenters divide by the registered multiplier and append its suffix.
Unit presenters convert a quantity to compatible target units and append the target unit expression.
Percent and scale presenters require a dimensionless scalar. A unit presenter requires compatible dimensions.

Presenter syntax recognizes registered unit expressions and legacy scale aliases in their own context.
These built-in spellings take precedence there. Other callable references use ordinary lexical lookup, including qualified names.
`as %`, `as Cr`, and `as kg` are callable aliases, not changes to arithmetic or new numeric types.

#### Custom presenters

An ordinary pure function can format a value and return a string:

```txt
money(value, prefix) = prefix + decimal(value, 2)

salary = 2500 as money("$") → $2500.00
salary * 2 → 5000

percent(value) = decimal(value * 100, 1) + "%"
ratio = 0.375 as percent → 37.5%
ratio * 1000 → 375
ratio @percent → "37.5%"
```

The final line returns a string because it uses `@`. The earlier `as percent` clause leaves `ratio` numeric.
Presenter arguments can refer to values and functions in the block scope.
Dependencies in those arguments or presenter bodies trigger output updates when their values change.
They do not become part of the bound value's numeric computation.

A presenter must return a string or a plot value. An unsupported input, incompatible unit, invalid argument, or other result type is a presentation error.
The output reports the error without replacing a successfully computed binding with the error or a string.
The renderer never executes presenter output as code, HTML, Markdown expressions, or further calc input.

#### Plot presenters

`plot` is an ordinary callable alias for `present.plot`. It returns a typed plot value, which the editor draws as SVG below the expression line, sharing the code block's background without a border or heading.
`as plot` retains the original function, expression, or data binding. Calling `plot(...)` or using `@plot(...)` returns the plot itself, whose `@type` is `"plot"`.

```txt
f(x) = x^2
f as plot(-5, 5)

symbol x
(x^2 + 3*x) as plot(x, -5, 5)
(x^3) @diff(x) as plot(x, -3, 3)

[3, 7, 4, 9] as plot
[[0, 3], [1, 7], [2, 4]] as plot("scatter")
[3, 7, 4, 9] as plot("bar")

bars(data) = plot(data, "bar")
readings = [2, 5, 3] as bars
readings @sum → 10
```

Data plots accept a list of y values or a list of `[x, y]` pairs. A y list uses zero-based indices for x.
Pairs keep their source order; line plots join adjacent points in that order.
The optional kind is `"line"` (default), `"scatter"`, or `"bar"`. Bars extend from zero.

Function plots take increasing lower and upper bounds, then an optional kind and sample count:
`f as plot(from, to, "line", 201)`.
Symbolic plots require the declared independent symbol first:
`expr as plot(x, from, to, "line", 201)`.
Substitute values for every other free symbol before plotting.
Sampling uses 201 evenly spaced points by default, includes both bounds, and accepts between 2 and 2000 points.
Data lists have the same 2000-point limit. Plots use linear axes and do not perform adaptive sampling or infer discontinuities between samples.

Coordinates must be finite real numbers or quantities. Each axis requires compatible dimensions and displays canonical units.
Exact integers and fractions stay exact in the source binding; drawing converts coordinates to finite machine numbers.
For example, `distance(t) = 2m/s * t` with `distance as plot(0s, 10s)` labels the axes `x (s)` and `y (m)`.
Complex coordinates and mixed incompatible units produce a presentation error.

An explicit `null` y value leaves a gap. A sampled division by zero or real-domain error also leaves a gap, so a line never joins across that sample.
Other failures, including unknown names, wrong function arity, incompatible dimensions, and resource limits, fail the presentation.
A plot with no valid y samples is an error.

Plots work in calc fences and inline expressions, with or without an output arrow.
Changing a dependency resamples the plot. Resizing redraws the existing coordinates without reevaluating the calculation.
The SVG inherits the editor's public background, text, muted, and accent tokens, so light, dark, and custom theme changes apply immediately.
Hovering shows the nearest visible sample's coordinates, including axis units, with a marker and a vertical guide.
Shift-drag pans both axes. Shift-arrow keys pan a focused plot, and double-click or Home restores its original bounds.
Panning moves the viewport over the existing samples; it does not sample beyond the expression's declared bounds or change the note's source.
Resizing preserves the viewport. Changing plot data resets it to the new data's bounds.
Currency conversion remains deferred; plots do not fetch external data.

#### Source sync and output safety

Presenter output follows the same persistence rule as default output: only the derived segment after `->` or `→` changes.
Source sync preserves the expression, `as` clause, arrow, and trailing comment.
The renderer uses the presenter's text directly, without the default string-value quotes.
For a plot, the derived source segment contains a stable summary such as `[plot: line, 201 points]` or `[plot: line, 201 points, 1 gaps]`.
SVG markup and sampled coordinates stay out of the Markdown source. Reopening a note regenerates the plot from its expression.

Markdown source must still delimit output safely.
Presenter text containing `#`, `;`, quotes, backslashes, line breaks, or leading or trailing whitespace uses an escaped double-quoted source representation.
Empty presenter text uses `""`. Other presenter text can remain unquoted.
The renderer decodes that source representation for display. It never treats it as a value to evaluate.
For inline calc, text containing the closing delimiter `}}` must also use a safe representation and a quote-aware delimiter scanner.

```txt
tag(value) = decimal(value, 0) + " # items"
total = 3 as tag → "3 # items" # keep this comment
total + 1 → 4
```

The source quotes protect the comment boundary. They do not change the numeric type of `total`.
Output updates must stabilize after one sync, including empty outputs, presentation errors, and escaped output text.
Unit and symbolic syntax must also round-trip through the source writer without changing literal meaning.

### Standard library direction

The first extension makes existing functions work with the types that their mathematics supports.
For example, a mean preserves compatible dimensions, variance squares those dimensions, and logarithms require dimensionless inputs.
Trigonometric signatures must state angle handling explicitly. Ordering-based functions reject complex values.

The implementation adds variance, standard deviation, quantiles, greatest common divisor, least common multiple, factorial, and logarithms with a base.
List operations include range, slice, sort, and reduce.
`variance(values, mode)` and `std(values, mode)` default to `"sample"`, dividing by `n - 1` and requiring two values.
The `"population"` mode divides by `n` and requires one value. These operations accept real scalars and compatible real quantities.
`stddev` aliases `std`. Means and sums also accept complex values.
`quantile(values, p)` uses linear interpolation at index `(n - 1) * p`, with `0 <= p <= 1`.
Ranges exclude their stop value. Slices use zero-based indices and exclude their end index.
`reduce(values, function, initial)` passes the accumulator and item, with an optional third callback parameter for the index.

Arbitrary-precision decimals, matrices, general equation solving, mutation, imports, and unrestricted evaluation remain outside the initial extension.

### Grammar changes

These productions replace the corresponding v1 productions. Unchanged productions retain their v1 definitions.
An end-of-line comment is optional where shown. Output text excludes a trailing comment outside its quoted source representation.

```ebnf
StatementLine      ::= BlankLine | CommentLine
                     | (FunctionDefinition | SymbolDeclaration) S* Comment?
                     | PresentedStatement (S* Arrow S* OutputText?)? S* Comment?
PresentedStatement ::= (Identifier S* "=" S*)? PresentedValue
PresentedValue     ::= Expression (S+ "as" S+ PresenterStage)?
SymbolDeclaration  ::= "symbol" S+ Identifier (S* "," S* Identifier)*
Arrow              ::= "->" | "→"

Expression         ::= PipelineExpression
PipelineExpression ::= ComparisonExpression (S* ("@" | "|>") S* OperationStage)*
OperationStage     ::= CallableReference (S* "(" S* ArgumentList? S* ")")?
PresenterStage     ::= PresenterReference (S* "(" S* ArgumentList? S* ")")?
PresenterReference ::= CallableReference | "%" | ScaleSuffix | UnitExpression
InlineBody         ::= PresentedValue (S* Arrow S* OutputText?)?

MultiplicativeExpression ::= UnaryExpression
                             (S* ("*" | "/" | "//") S* UnaryExpression)*

PrimaryExpression  ::= Number | ImaginaryLiteral | QuantityLiteral
                     | Boolean | Null | String | ListLiteral | ListComprehension | Identifier
                     | "(" S* Expression S* ")"
ListComprehension  ::= "[" S* Expression S+ "for" S+ Identifier S+ "in" S+ Expression
                      (S+ "if" S+ Expression)? S* "]"
ImaginaryLiteral   ::= NumericLiteral "i"
QuantityLiteral    ::= NumericLiteral S* UnitExpression
UnitExpression     ::= UnitFactor (S* ("*" | "/") S* UnitFactor)*
UnitFactor         ::= UnitAtom (S* "^" S* SignedInteger)?
UnitAtom           ::= UnitSymbol | "(" S* UnitExpression S* ")"
SignedInteger      ::= ("+" | "-")? IntegerPart
UnitSymbol         ::= /* a registered, case-sensitive unit or prefixed unit */
```

The lexer recognizes `//` before `/` and resolves registered suffixes before accepting a plain numeric literal.
Legacy scale suffixes win when a complete standalone suffix conflicts with a unit spelling.
Quantity suffix parsing uses the unit registry and the boundaries defined above, not arbitrary identifier multiplication.
`as` and `symbol` are reserved keywords in this revision.
`for`, `in`, and `if` retain identifier tokens and act as contextual delimiters when parsing a comprehension.

The precedence order is calls and member access, powers, unary minus, multiplicative operators, additive operators, comparisons, then pipeline stages.
Powers remain right-associative. Pipeline stages run left to right.
The final `as` clause applies after the complete value expression. Binding and output arrows are statement structure, not value operators.

### Implementation and compatibility

The typed-value and operation contracts live in framework-independent modules under `src/lib/calc/`.
`numeric.ts` implements scalar, complex, and quantity arithmetic. `units.ts` owns the unit registry and conversions.
`symbolic.ts` implements expression values and transformations. `runtime.ts` owns scope, callable resolution, and presentation.
The parser owns syntax and source ranges. The Markdown plugin owns decorations, display widgets, and source sync.
Normal calls, postfix calls, and callable presenters share the runtime's function registry.

The public evaluation API preserves safe integer results as JavaScript numbers for compatibility.
Larger integer results remain `bigint`. Internal calculations and `@type` retain the Integer/Real distinction.
Evaluation success contains the computed `value`, optional `presentation` (`string | CalcPlot`), and an optional separate `presentationError`.
`plot.ts` owns the immutable plot model and sampling; `plotSvg.ts` draws SVG from that model without accessing editor or app state.
`formatCalcPresentation` gives nonvisual consumers a string, using the stable summary for plot values.
A presenter failure does not turn a successful computation into a failed binding.

Preserve existing notes where the approved syntax does not introduce an explicit incompatibility.
The reserved names `i`, `as`, and `symbol` need migration diagnostics for existing definitions that use those names.
The current v1 `@`-free, presenter-free calculation path remains valid.
Scale aliases retain the compatibility rules above.

Implementation checks must cover exact rational arithmetic, type promotion, complex domains, dimensional cancellation, symbolic scope, and operation dispatch.
Presenter checks must distinguish value changes from display changes and cover custom presenter dependencies and errors.
Editor checks must cover assignments, inline expressions, comments, escaped outputs, and stable source sync.
Comprehension checks must cover local shadowing, source evaluation before binding, skipped bodies, typed results, contextual names, clause diagnostics, nested scope, plot updates, source ranges, and resource limits.

### Supported operations and limits

The unit registry includes `m`, `s`, `g`, `kg`, `min`, `h`, `day`, `l`, `litre`, `rad`, and `deg`.
Supported prefixes are `T`, `G`, `M`, `k`, `h`, `da`, `d`, `c`, `m`, `u`, `µ`, `n`, and `p`.
Prefixes apply to registered prefixable units. Kilogram has its own entry, while other mass prefixes attach to gram.
Trigonometric functions accept dimensionless radians or explicit angle quantities such as `90deg`.
Inverse trigonometric functions return dimensionless radians, preserving v1 behavior.

Complex arithmetic includes addition, subtraction, multiplication, division, and powers.
Complex functions include `abs`, `re`, `im`, `conj`, `sqrt`, `exp`, `ln`, `sin`, `cos`, and `tan`.
Other numeric functions reject complex arguments unless their signature explicitly supports them.

Symbolic simplification and expansion support multivariate polynomials with exact integer or rational coefficients.
Other supported expression trees retain their structure and fold numeric subexpressions conservatively.
Factoring extracts common integer and monomial factors and factors monic integer quadratics with integer roots from -100 through 100.
Expressions outside that factoring subset remain valid expressions without a claimed complete factorization.
Differentiation supports arithmetic, integer powers, `sin`, `cos`, `exp`, and `ln`, including their chain rules.
Other derivative requests report an unsupported-operation diagnostic.
Substitution evaluates supported numeric calls after replacing a declared symbol.

The editor evaluates on document changes, so operations have explicit resource limits:

- Numeric literal source length is at most 4096 characters. Exact arithmetic is bounded to 65536 bits.
- Exact scalar and complex integer powers have exponent magnitude at most 10000, subject to the arithmetic bit limit.
- Parser and runtime expression nesting, definition nesting, and function nesting are bounded to 128 levels.
- Unit nesting and unit exponent magnitudes are bounded to 32.
- A query, including its presenter, has at most 100000 evaluation steps.
- A range or comprehension produces at most 10000 values. Comprehensions share the query's step budget, including filtered-out iterations. Presenter precision is between 0 and 100 decimal places.
- A plot contains at most 2000 points. Sampled plots default to 201 points and share the query's evaluation budget.
- Polynomial expansion has at most 512 terms, 4096 term pairs per product, and nonnegative integer powers through 12.

A limit produces a diagnostic. It does not silently truncate a numeric result or claim a completed symbolic transformation.

Validation commands:

```sh
make typecheck-calc
make test-web TEST_ARGS='src/lib/calc src/lib/plugins/calc.test.ts'
make
```

### Design references

- [Wolfram expressions](https://reference.wolfram.com/language/tutorial/Expressions.html): structured values with identifiable heads.
- [Wolfram postfix application](https://reference.wolfram.com/language/ref/Postfix.html): applying a function to an existing expression.
- [Wolfram Simplify](https://reference.wolfram.com/language/ref/Simplify.html): transformations with domain assumptions.
- [Math.js units](https://mathjs.org/docs/datatypes/units.html): dimensional operations, conversions, and prefix behavior.
- [Math.js fractions](https://mathjs.org/docs/datatypes/fractions.html): exact rational values.

These are design references. Calc does not adopt their parser syntax, global configuration, or dependency graph.
