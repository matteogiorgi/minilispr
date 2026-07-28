; demo.lisp -- a short tour of minilispr's features.
; Run it with:  ./minilisp.r demo.lisp

; arithmetic: +, -, *, / are variadic, left-folded into R's binary operators
(define total
  (+ 1 2 3 4))

; if / comparisons
(define parity
  (if (== (- total 10) 0)
    "even"
    "odd"))

; lambda + let
(define square
  (lambda (x)
    (* x x)))

(define area
  (let ((w 3)
        (h 4))
    (* w h)))

; closures: adder captures n lexically
(define (adder n)
  (lambda (x)
    (+ x n)))

(define add10
  (adder 10))

; recursion
(define (fact n)
  (if (< n 2)
    1
    (* n (fact (- n 1)))))

; strings + calling any R function directly, e.g. paste()
(define greeting
  (paste "hello" "minilispr"))

; while + begin: imperative side effects, old-school style
(define sum1to5
  (begin
    (<- acc 0)
    (<- i 1)
    (while (< i 6)
           (begin
             (<- acc (+ acc i))
             (<- i (+ i 1))))
    acc))

; tie it all together, one line of output per computed value
(cat
  (paste0
    greeting "\n"
    "1+2+3+4 = " total " (" parity ")\n"
    "square(6) = " (square 6) "\n"
    "rect area = " area "\n"
    "add10(5) = " (add10 5) "\n"
    "fact(5) = " (fact 5) "\n"
    "sum 1..5 = " sum1to5 "\n"))
