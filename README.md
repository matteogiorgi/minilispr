# Mini-Lisp-R

A tiny Lisp that compiles to R language objects and runs on R's own `eval()`.

```
> lisp_eval("(define (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 10)")
[1] 3628800
```




## Why R's own eval()

Most toy Lisps (SICP's `metacircular-evaluator`, for example) spend most of their code on a hand-written evaluator: an `eval`/`apply` pair that manages its own environments, its own scoping rules, its own closures. This project skips that step on purpose. R already has all of it — lexically scoped environments, closures, a garbage collector — so once Lisp source has been turned into an R `call` object, plain `eval()` does the rest. What's left to build is genuinely small: a reader and a syntactic translator, not an interpreter.

A pleasant consequence: `if`, `while`, `function`, `<-` and `{` are not special syntax in R, they're ordinary calls with backtick-able names (`` `if`(cond, a, b) `` really does work). So most Lisp special forms need no special-casing in the translator at all — `(if c a b)` becomes `` as.call(list(as.name("if"), c, a, b)) `` and R runs it correctly. Only a handful of forms (`define`, `lambda`/`fn`, `let`, variadic arithmetic) need real translation logic; everything else falls through to a generic "S-expression to call" conversion.




## Architecture

```
source text --tokenize--> tokens --read_all--> S-expressions --to_r--> R call objects --eval()--> value
```

- **Tokenizer** (`tokenize`) — character-by-character lexer. Handles string literals with embedded spaces and escapes, and `;` line comments, which a naive `strsplit()`-on-whitespace tokenizer would mangle.
- **Reader** (`read_from_tokens`, `read_all`, `atom`) — classic recursive descent over the token stream, producing nested R lists as S-expressions. Atoms get their final R type here: numbers, strings (with `\n`/`\t`/`\"`/`\\` unescaped), `TRUE`/`FALSE`, or symbols (`as.name`).
- **Translator** (`to_r`) — purely syntactic S-expression -> R `call`/`name` conversion. No Lisp code is executed at this stage; closures only come into existence once the resulting call is `eval()`'d, so they capture whatever environment is active at that point with nothing threaded around by hand.
- **Driver** (`lisp_eval`) — reads and evaluates every top-level form from a source string in one shared environment, so a `define` is visible to the forms that follow it.




## Supported language

| Form | Example | Notes |
|---|---|---|
| Arithmetic | `(+ 1 2 3)`, `(* 2 (- 5 1))` | `+ - * /` are variadic, left-folded into R's binary operators |
| Comparisons | `(< 1 2)`, `(== 3 3)` | strictly binary, like R's own `<`/`==` |
| `if` | `(if (< 1 2) "yes" "no")` | maps directly to R's `` `if` `` call |
| `while` | `(while (< i 10) ...)` | maps directly to R's `` `while` `` call |
| `begin` | `(begin e1 e2 e3)` | explicit progn, becomes a `{ ... }` block |
| `define` | `(define x 5)`, `(define (f a b) (+ a b))` | both variable and function-shorthand forms |
| `lambda` / `fn` | `(lambda (x y) (+ x y))` | builds a real R closure at eval-time |
| `let` | `(let ((a 1) (b 2)) (+ a b))` | desugars to an immediately-invoked lambda (IIFE) |
| Strings | `(paste "hello" "world")` | double-quoted; supports `\n`, `\t`, `\"`, `\\` escapes |
| Closures | `(define (adder n) (lambda (x) (+ x n)))` | lexical scoping, courtesy of R |
| Recursion | `(define (fact n) (if (< n 2) 1 (* n (fact (- n 1)))))` | plain self-reference via R's own scoping |

Any symbol that isn't one of the forms above is passed straight through as a function call, so any R function is callable from Lisp for free — `(paste "a" "b")`, `(nchar "lisp")`, `(sqrt 16)`, and so on.




## Usage


### From the command line

`minilisp.r` is executable and doubles as a Lisp file runner — it evaluates every top-level form in the given file in one shared environment and prints the value of the last one:

```bash
./minilisp.r program.lisp
```

This only fires when the file is run directly; `test.r` sources it as a plain R library instead, so the two uses don't interfere with each other.

[demo.lisp](demo.lisp) is a short tour of the language — arithmetic, `if`, `lambda`, `let`, closures, recursion, strings, `while` — runnable as-is:

```bash
./minilisp.r demo.lisp
```

`minilisp.r` never looks up its own location, so it works the same whether you run it in place or through a symlink. To make it available system-wide as `minilispr`, symlink it into a directory already on your `PATH` — `~/.local/bin` is the standard per-user one on most Linux distros:

```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/minilisp.r" ~/.local/bin/minilispr
```

Then from anywhere:

```bash
minilispr demo.lisp
```

(If `~/.local/bin` isn't already on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to your shell's rc file.)


### From R

```r
source("minilisp.r")

lisp_eval("(+ 1 2)")                        # 3
lisp_eval("(define (sq x) (* x x)) (sq 7)") # 49

# inspect the intermediate stages
tokenize("(+ 1 2)")            # "(" "+" "1" "2" ")"
read_all("(+ 1 2)")            # nested list: list(list(as.name("+"), 1, 2))
to_r(read_all("(+ 1 2)")[[1]]) # quote(1 + 2)
```

Forms accumulate in a shared environment by default, so a REPL-style session just keeps calling `lisp_eval()` with the same `env`:

```r
env <- new.env(parent = globalenv())
lisp_eval("(define x 10)", env)
lisp_eval("(+ x 5)", env) # 15
```




## Tests

```bash
./test.r
# or: Rscript test.r
```

Dependency-free TAP 13 output (~15-line test framework, no `testthat`), composable with any TAP consumer. Covers the tokenizer, reader, translator and driver end-to-end, plus a golden test comparing `lisp_eval()` output against the equivalent hand-written R expression evaluated natively.




## Project layout

| File | Purpose |
|---|---|
| [minilisp.r](minilisp.r) | The whole implementation: tokenizer, reader, translator, driver, CLI entry point |
| [test.r](test.r) | TAP test suite |
| [demo.lisp](demo.lisp) | Runnable example touring the supported language |




## Roadmap

Milestones so far: arithmetic + `if` → `define`/`lambda`/`let` → strings, closures, recursion, `while`. What's next, in increasing order of how much fun it is:

- **Macros** — the reader already hands code over as data (a `call` is a list you can take apart and rebuild), so a macro is just a function that receives unevaluated code and returns code. R's `bquote()`/`.()` gives quasiquote/unquote for free.
- **Hygiene** — without care, macros get variable capture; fixed with a `gensym` that mints guaranteed-unique names to inject into expansions.
- **TCO** — R has no tail-call optimization, so deep recursion blows the stack. The plan is to recognize calls in tail position in the translator and rewrite them as a `while`/`repeat` loop instead of a recursive call.




## Known limitations

- `T`, `F`, `TRUE` and `FALSE` are consumed as boolean literals by the reader, so a Lisp program can never `define` its own variable with one of those names.
- Comparison operators (`<`, `==`, ...) are strictly binary; `(< 1 2 3)` is not supported (arithmetic operators are, via left-fold).
- No macros, no hygiene, no TCO yet — see Roadmap above.
