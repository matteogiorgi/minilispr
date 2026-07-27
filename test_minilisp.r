#!/usr/bin/env Rscript

# test_minilisp.r -- pure-R test suite for minilisp.r, TAP output, exits with
# status 1 if anything fails.
#
#   Rscript test_minilisp.r                 # run
#   Rscript test_minilisp.r | tap-difflet   # or any other TAP consumer
#
# No dependencies (no testthat): a ~15-line mini test framework, TAP 13
# output that composes with standard Unix tools, and an explicit exit-code
# contract so this plugs into any CI runner without extra glue.


.script_dir <- function() {
    # Preferred path: when run as `Rscript test_minilisp.r`, R puts the
    # script's own path in commandArgs() as a --file=... entry.
    file_arg <- grep("--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
    if (length(file_arg) > 0) {
        return(dirname(sub("--file=", "", file_arg)))
    }

    # Fallback: when the script is run via source() instead (e.g. RStudio's
    # or an editor's "Run" button), there is no --file= argument at all, but
    # source() records the file path in the current evaluation frame.
    ofile <- sys.frames()[[1]]$ofile
    if (!is.null(ofile)) {
        return(dirname(ofile))
    }

    # last resort: assume minilisp.r sits in the current working directory
    "."
}
source(file.path(.script_dir(), "minilisp.r"))




## Minimal TAP framework
.n <- 0L
.fail <- 0L
cat("TAP version 13\n")

diag <- function(...) {
    for (l in c(...)) {
        cat("# ", l, "\n", sep = "")
    }
}

ok <- function(src, expected, desc) {
    .n <<- .n + 1L
    got <- tryCatch(lisp_eval(src),
        error = function(e) structure(conditionMessage(e), class = "lisp_err")
    )
    pass <- !inherits(got, "lisp_err") && isTRUE(all.equal(got, expected))
    if (pass) {
        cat(sprintf("ok %d - %s\n", .n, desc))
    } else {
        .fail <<- .fail + 1L
        cat(sprintf("not ok %d - %s\n", .n, desc))
        got_s <- if (inherits(got, "lisp_err")) {
            paste("ERROR:", got)
        } else {
            paste(deparse(got), collapse = " ")
        }
        diag(
            paste("src:      ", src),
            paste("expected: ", paste(deparse(expected), collapse = " ")),
            paste("got:      ", got_s)
        )
    }
}


## Tokenizer / reader
# Internal sanity check, outside the TAP plan: every other test depends on
# the tokenizer working, so fail fast and loudly if it doesn't.
stopifnot(identical(
    tokenize("(+ 1 (* 2 3)) ; comment"),
    c("(", "+", "1", "(", "*", "2", "3", ")", ")")
))


## Arithmetic
ok("(+ 1 2)", 3, "addition")
ok("(* (+ 1 2) 3)", 9, "nesting")
ok("(- 10 3 2)", 5, "variadic subtraction")
ok("(/ 12 4)", 3, "division")
ok("(+ 1 2 3 4)", 10, "variadic addition (fold, R is not variadic)")


## Comparisons / logic
ok("(< 1 2)", TRUE, "less-than")
ok("(== 3 3)", TRUE, "equality")
ok("(if (< 2 1) 10 20)", 20, "if false branch")
ok("(if TRUE 1 2)", 1, "if with boolean literal")


## Define / usage
ok("(define x 5) (+ x 1)", 6, "define + reference")
ok("(define x 5) (define x 9) x", 9, "redefinition")


## Lambda / application
ok("((lambda (x) (* x x)) 4)", 16, "lambda applied inline (IIFE)")
ok("(define (sq x) (* x x)) (sq 7)", 49, "define in function form")
ok("(define (add a b) (+ a b)) (add 3 4)", 7, "two-argument function")


## Let
ok("(let ((a 1) (b 2)) (+ a b))", 3, "simple let")
ok("(let ((a 3)) (let ((b 4)) (* a b)))", 12, "nested let")


## Closures (Scheme heritage: lexical scoping)
ok(paste(
    "(define (adder n) (lambda (x) (+ x n)))",
    "(define add5 (adder 5))",
    "(add5 10)"
), 15, "closure captures n lexically")


## Recursion
ok(paste(
    "(define (fact n) (if (< n 2) 1 (* n (fact (- n 1)))))",
    "(fact 5)"
), 120, "recursive factorial")


## while + { } with side effects
ok(paste(
    "(begin (<- s 0) (<- i 1)",
    "  (while (< i 4) (begin (<- s (+ s i)) (<- i (+ i 1))))",
    "  s)"
), 6, "while + begin with assignments (1+2+3)")


## Strings
ok("(paste \"hello\" \"world\")", "hello world", "strings with spaces")
ok("(nchar \"lisp\")", 4, "string literal passed to an R function")


## Golden test: compare against native R eval
{
    .n <- .n + 1L
    got <- lisp_eval("(* (+ 2 3) (- 10 4))")
    want <- eval(quote((2 + 3) * (10 - 4)))
    if (isTRUE(all.equal(got, want))) {
        cat(sprintf("ok %d - golden vs native R eval\n", .n))
    } else {
        .fail <- .fail + 1L
        cat(sprintf("not ok %d - golden vs native R eval\n", .n))
    }
}


## Plan + exit-code contract
cat(sprintf("1..%d\n", .n))
if (.fail > 0) {
    cat(sprintf("# FAILED: %d/%d\n", .fail, .n))
    quit(status = 1L)
} else {
    cat(sprintf("# all green: %d/%d\n", .n, .n))
    quit(status = 0L)
}
