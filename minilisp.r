#!/usr/bin/env Rscript

# minilisp.r -- a micro-Lisp that compiles to R expressions and evaluates
# them with eval().
#
# Pipeline:  source text --tokenize--> tokens --read_all--> S-expressions
#            (nested lists) --to_r--> R language objects --eval--> value.
#
# There is no evaluator of our own to write: environments, lexical scoping,
# closures and garbage collection are all R's. The translator is purely
# syntactic (it never runs any Lisp code itself); closures only come into
# existence at eval-time, so they automatically capture the environment that
# is active at that point, with nothing threaded around by hand.
#
# Covered so far: arithmetic, comparisons, if/while/{ }, define, lambda, let,
# function calls, strings, closures, recursion. Macros and TCO are planned as
# follow-up extensions.


## 1. Tokenizer -- character-by-character, so that string literals containing
## spaces and line comments are handled correctly. A naive
## strsplit-on-whitespace tokenizer would break on both of those.
tokenize <- function(src) {
    chars <- strsplit(src, "", fixed = TRUE)[[1]]
    toks <- character(0)
    i <- 1L
    n <- length(chars)
    while (i <= n) {
        ch <- chars[[i]]
        if (ch %in% c(" ", "\t", "\n", "\r")) {
            i <- i + 1L
        } else if (ch == ";") {
            while (i <= n && chars[[i]] != "\n") i <- i + 1L
        } else if (ch == "(" || ch == ")") {
            toks <- c(toks, ch)
            i <- i + 1L
        } else if (ch == "\"") { # string literal: the token keeps its surrounding quotes
            j <- i + 1L
            buf <- "\""
            while (j <= n && chars[[j]] != "\"") {
                if (chars[[j]] == "\\" && j < n) {
                    # Minimal escape handling: copy the backslash and the
                    # character it escapes verbatim, unescaping happens later
                    # in atom(). This just prevents an escaped quote (\")
                    # from being mistaken for the closing quote.
                    buf <- paste0(buf, chars[[j]], chars[[j + 1L]])
                    j <- j + 2L
                } else {
                    buf <- paste0(buf, chars[[j]])
                    j <- j + 1L
                }
            }
            if (j > n) stop("unterminated string literal")
            buf <- paste0(buf, "\"")
            toks <- c(toks, buf)
            i <- j + 1L
        } else {
            j <- i
            buf <- ""
            while (j <= n && !(chars[[j]] %in% c(" ", "\t", "\n", "\r", "(", ")", ";", "\""))) {
                buf <- paste0(buf, chars[[j]])
                j <- j + 1L
            }
            toks <- c(toks, buf)
            i <- j
        }
    }
    toks
}


## 2. Reader -- turns the flat token stream into nested lists (our
## S-expressions). Atoms are given their final R type right here.

unescape_string <- function(s) { # single left-to-right scan, so \\n stays
    chars <- strsplit(s, "", fixed = TRUE)[[1]] # "escaped backslash + n" and is never confused with \n
    n <- length(chars)
    out <- character(0)
    i <- 1L
    while (i <= n) {
        if (chars[[i]] == "\\" && i < n) {
            nxt <- chars[[i + 1L]]
            repl <- switch(nxt,
                "n" = "\n",
                "t" = "\t",
                "\"" = "\"",
                "\\" = "\\",
                paste0("\\", nxt) # unrecognized escape: keep both characters as-is
            )
            out <- c(out, repl)
            i <- i + 2L
        } else {
            out <- c(out, chars[[i]])
            i <- i + 1L
        }
    }
    paste(out, collapse = "")
}

atom <- function(tok) {
    if (startsWith(tok, "\"")) { # string: strip the surrounding quotes, then unescape
        inner <- substr(tok, 2L, nchar(tok) - 1L)
        return(unescape_string(inner))
    }

    # TRUE/FALSE and their R aliases T/F are resolved to actual booleans right
    # here, instead of being left as symbols to be looked up at eval-time.
    # Trade-off: a Lisp program written against this reader can never define
    # its own variable named T, F, TRUE or FALSE (the token is consumed as a
    # literal before it ever gets a chance to become a binding target) --
    # an acceptable limitation for this MVP.
    if (tok %in% c("TRUE", "T")) {
        return(TRUE)
    }
    if (tok %in% c("FALSE", "F")) {
        return(FALSE)
    }
    num <- suppressWarnings(as.numeric(tok))
    if (!is.na(num)) {
        return(num)
    }
    as.name(tok)
}

read_from_tokens <- function(toks) {
    if (length(toks) == 0) stop("unexpected EOF while reading")
    tok <- toks[[1]]
    rest <- toks[-1]
    if (tok == "(") {
        acc <- list()
        while (length(rest) > 0 && rest[[1]] != ")") {
            res <- read_from_tokens(rest)
            acc <- c(acc, list(res$expr))
            rest <- res$rest
        }
        if (length(rest) == 0) stop("missing closing ')'")
        list(expr = acc, rest = rest[-1]) # drop the matched ")"
    } else if (tok == ")") {
        stop("unexpected ')'")
    } else {
        list(expr = atom(tok), rest = rest)
    }
}

read_all <- function(src) {
    toks <- tokenize(src)
    forms <- list()
    while (length(toks) > 0) {
        res <- read_from_tokens(toks)
        forms <- c(forms, list(res$expr))
        toks <- res$rest
    }
    forms
}


## 3. Translator -- S-expression -> R language object (a call/name/atom that
## eval() can run directly, with no separate evaluator of our own).
make_formals <- function(params) { # build a formals pairlist, no default values
    if (length(params) == 0) {
        return(NULL)
    }

    # Every parameter needs the "argument is missing" placeholder as its
    # default value in the formals pairlist; quote(expr = ) is the idiomatic
    # way to produce that special empty symbol in R. Building formals() by
    # hand like this (rather than manipulating an existing function's
    # formals()/body()) is the first real R-specific trap in this project.
    fmls <- replicate(length(params), quote(expr = ), simplify = FALSE)
    names(fmls) <- params
    as.pairlist(fmls)
}

make_fn_expr <- function(params, body_expr) { # -> a `function` call; becomes a real closure only once eval()'d
    as.call(list(as.name("function"), make_formals(params), body_expr))
}

wrap_body <- function(exprs) { # implicit progn: multiple expressions become a `{ ... }` block
    if (length(exprs) == 1) {
        exprs[[1]]
    } else {
        as.call(c(list(as.name("{")), exprs))
    }
}

to_r <- function(x) {
    if (!is.list(x)) {
        return(x) # already an atom (number, string, boolean or symbol) -- nothing to translate
    }
    if (length(x) == 0) {
        return(NULL) # empty list () -> NULL
    }

    head <- x[[1]]
    if (is.name(head)) {
        op <- as.character(head)

        if (op == "begin") { # explicit progn -> a `{ ... }` block
            return(wrap_body(lapply(x[-1], to_r)))
        }

        # +, -, *, / are binary operators in R but variadic in Lisp, so a call
        # with more than two arguments gets left-folded into nested binary
        # calls: (+ 1 2 3) -> (1 + 2) + 3. This branch only fires for more
        # than two arguments (length(x) > 3, i.e. op plus 3+ operands); with
        # exactly one or two arguments the generic call path at the bottom of
        # this function already produces valid R as-is (including R's own
        # unary minus for the one-argument case). Comparison operators
        # (<, ==, ...) are deliberately left out of this fold and stay
        # strictly binary, matching R's own comparison operators.
        if (op %in% c("+", "-", "*", "/") && length(x) > 3) {
            args <- lapply(x[-1], to_r)
            acc <- args[[1]]
            for (k in 2:length(args)) acc <- as.call(list(as.name(op), acc, args[[k]]))
            return(acc)
        }

        if (op == "lambda" || op == "fn") {
            params <- vapply(x[[2]], as.character, character(1))
            body <- lapply(x[-(1:2)], to_r)
            return(make_fn_expr(params, wrap_body(body)))
        }

        if (op == "let") {
            # (let ((a v1) (b v2)) body...) has no direct R equivalent (R's
            # scoping is function-level, not block-level), so it is desugared
            # into the classic Scheme translation: an immediately-invoked
            # lambda. (let ((a 1) (b 2)) (+ a b)) becomes
            # (function(a, b) a + b)(1, 2).
            binds <- x[[2]]
            params <- vapply(binds, function(b) as.character(b[[1]]), character(1))
            vals <- lapply(binds, function(b) to_r(b[[2]]))
            body <- lapply(x[-(1:2)], to_r)
            fn <- make_fn_expr(params, wrap_body(body))
            return(as.call(c(list(fn), vals)))
        }

        if (op == "define") {
            target <- x[[2]]
            if (is.list(target)) { # (define (f a b) body...) -> f <- function(a, b) body
                fname <- as.character(target[[1]])
                params <- vapply(target[-1], as.character, character(1))
                body <- lapply(x[-(1:2)], to_r)
                fn <- make_fn_expr(params, wrap_body(body))
                return(as.call(list(as.name("<-"), as.name(fname), fn)))
            } else { # (define x val) -> x <- val
                return(as.call(list(as.name("<-"), target, to_r(x[[3]]))))
            }
        }
    }

    # Generic call: everything not special-cased above falls through here,
    # including if/while/{ (which are already ordinary R calls under the
    # hood) and plain function application, e.g. the ((lambda (x) x) 5)
    # case where head is itself a nested list.
    as.call(lapply(x, to_r))
}


## 4. Driver -- reads and evaluates every top-level form from src in a single
## shared environment, so later forms can see bindings made by earlier ones
## (e.g. define followed by a reference).
lisp_eval <- function(src, env = new.env(parent = globalenv())) {
    forms <- read_all(src)
    result <- NULL
    for (f in forms) result <- eval(to_r(f), env)
    result
}


## CLI entry point -- runs a Lisp source file and prints its result. Guarded
## by sys.nframe() == 0L so it only fires when this file is executed
## directly (`./minilisp.r program.lisp` or `Rscript minilisp.r program.lisp`)
## and stays inert when the file is source()'d as a library, which is what
## test.r does (sourcing always happens from inside a deeper call
## frame, so sys.nframe() is > 0 there).
if (sys.nframe() == 0L) {
    args <- commandArgs(trailingOnly = TRUE)
    if (length(args) == 0) {
        stop("usage: minilisp.r <file.lisp>")
    }
    src <- paste(readLines(args[[1]]), collapse = "\n")
    result <- lisp_eval(src)
    if (!is.null(result)) print(result)
}
