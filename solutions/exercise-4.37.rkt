#lang eopl

;; Exercise 4.37 [★★] Call-by-value-result is a variation on call-by-reference. In call-by-value-result, the actual
;; parameter must be a variable. When a parameter is passed, the formal parameter is bound to a new reference
;; initialized to the value of the actual parameter, just as in call-by-value. The procedure body is then executed
;; normally. When the procedure body returns, however, the value in the new reference is copied back into the reference
;; denoted by the actual parameter. This may be more efficient than call-by-reference because it can improve memory
;; locality. Implement call-by-value-result and write a program that produces different answers using
;; call-by-value-result and call-by-reference.

;; Grammar.

(define the-lexical-spec
  '([whitespace (whitespace) skip]
    [comment ("%" (arbno (not #\newline))) skip]
    [identifier (letter (arbno (or letter digit "_" "-" "?"))) symbol]
    [number (digit (arbno digit)) number]
    [number ("-" digit (arbno digit)) number]))

(define the-grammar
  '([program (expression) a-program]
    [expression (number) const-exp]
    [expression ("-" "(" expression "," expression ")") diff-exp]
    [expression ("zero?" "(" expression ")") zero?-exp]
    [expression ("if" expression "then" expression "else" expression) if-exp]
    [expression (identifier) var-exp]
    [expression ("let" identifier "=" expression "in" expression) let-exp]
    [expression ("proc" "(" identifier ")" expression) proc-exp]
    [expression ("(" expression identifier ")") call-exp]
    [expression ("letrec" (arbno identifier "(" identifier ")" "=" expression) "in" expression) letrec-exp]
    [expression ("begin" expression (arbno ";" expression) "end") begin-exp]
    [expression ("set" identifier "=" expression) assign-exp]
    [expression ("newpair" "(" expression "," expression ")") newpair-exp]
    [expression ("left" "(" expression ")") left-exp]
    [expression ("setleft" expression "=" expression) setleft-exp]
    [expression ("right" "(" expression ")") right-exp]
    [expression ("setright" expression "=" expression) setright-exp]))

(sllgen:make-define-datatypes the-lexical-spec the-grammar)

(define scan&parse
  (sllgen:make-string-parser the-lexical-spec the-grammar))

;; Data structures.

(define-datatype proc proc?
  [procedure [bvar symbol?]
             [body expression?]
             [env environment?]])

(define mutpair?
  (lambda (v)
    (reference? v)))

(define make-pair
  (lambda (val1 val2)
    (let ([ref1 (newref val1)])
      (let ([ref2 (newref val2)])
        ref1))))

(define left
  (lambda (p)
    (deref p)))

(define right
  (lambda (p)
    (deref (+ 1 p))))

(define setleft
  (lambda (p val)
    (setref! p val)))

(define setright
  (lambda (p val)
    (setref! (+ 1 p) val)))

(define-datatype expval expval?
  [num-val [value number?]]
  [bool-val [boolean boolean?]]
  [proc-val [proc proc?]]
  [mutpair-val [p mutpair?]])

(define expval-extractor-error
  (lambda (variant value)
    (eopl:error 'expval-extractors "Looking for a ~s, found ~s" variant value)))

(define expval->num
  (lambda (v)
    (cases expval v
      [num-val (num) num]
      [else (expval-extractor-error 'num v)])))

(define expval->bool
  (lambda (v)
    (cases expval v
      [bool-val (bool) bool]
      [else (expval-extractor-error 'bool v)])))

(define expval->proc
  (lambda (v)
    (cases expval v
      [proc-val (proc) proc]
      [else (expval-extractor-error 'proc v)])))

(define expval->mutpair
  (lambda (v)
    (cases expval v
      [mutpair-val (ref) ref]
      [else (expval-extractor-error 'mutable-pair v)])))

;; Environments.

(define reference?
  (lambda (v)
    (integer? v)))

(define-datatype environment environment?
  [empty-env]
  [extend-env [bvar symbol?]
              [bval reference?]
              [saved-env environment?]]
  [extend-env-rec* [proc-names (list-of symbol?)]
                   [b-vars (list-of symbol?)]
                   [proc-bodies (list-of expression?)]
                   [saved-env environment?]])

(define location
  (lambda (sym syms)
    (cond [(null? syms) #f]
          [(eqv? sym (car syms)) 0]
          [(location sym (cdr syms)) => (lambda (n)
                                          (+ n 1))]
          [else #f])))

(define apply-env
  (lambda (env search-sym)
    (cases environment env
      [empty-env () (eopl:error 'apply-env "No binding for ~s" search-sym)]
      [extend-env (bvar bval saved-env) (if (eqv? search-sym bvar)
                                            bval
                                            (apply-env saved-env search-sym))]
      [extend-env-rec* (p-names b-vars p-bodies saved-env)
                       (cond [(location search-sym p-names) => (lambda (n)
                                                                 (newref (proc-val (procedure (list-ref b-vars n)
                                                                                              (list-ref p-bodies n)
                                                                                              env))))]
                             [else (apply-env saved-env search-sym)])])))

;; Store.

(define the-store 'uninitialized)

(define empty-store
  (lambda ()
    '()))

(define initialize-store!
  (lambda ()
    (set! the-store (empty-store))))

(define newref
  (lambda (val)
    (let ([next-ref (length the-store)])
      (set! the-store (append the-store (list val)))
      next-ref)))

(define deref
  (lambda (ref)
    (list-ref the-store ref)))

(define report-invalid-reference
  (lambda (ref the-store)
    (eopl:error 'setref "illegal reference ~s in store ~s" ref the-store)))

(define setref!
  (lambda (ref val)
    (set! the-store
          (letrec ([setref-inner (lambda (store1 ref1)
                                   (cond [(null? store1) (report-invalid-reference ref the-store)]
                                         [(zero? ref1) (cons val (cdr store1))]
                                         [else (cons (car store1) (setref-inner (cdr store1) (- ref1 1)))]))])
            (setref-inner the-store ref)))))

;; Interpreter.

(define apply-procedure
  (lambda (proc1 val)
    (cases proc proc1
      [procedure (var body saved-env) (let* ([new-val (newref (deref val))]
                                             [new-env (extend-env var new-val saved-env)])
                                        (setref! val (value-of body new-env)))])))

(define value-of
  (lambda (exp env)
    (cases expression exp
      [const-exp (num) (num-val num)]
      [var-exp (var) (deref (apply-env env var))]
      [diff-exp (exp1 exp2) (let ([val1 (expval->num (value-of exp1 env))]
                                  [val2 (expval->num (value-of exp2 env))])
                              (num-val (- val1 val2)))]
      [zero?-exp (exp1) (let ([val1 (expval->num (value-of exp1 env))])
                          (if (zero? val1)
                              (bool-val #t)
                              (bool-val #f)))]
      [if-exp (exp0 exp1 exp2) (if (expval->bool (value-of exp0 env))
                                   (value-of exp1 env)
                                   (value-of exp2 env))]
      [let-exp (id rhs body) (let ([val (value-of rhs env)])
                               (value-of body (extend-env id (newref val) env)))]
      [proc-exp (var body) (proc-val (procedure var body env))]
      [call-exp (rator var) (let ([proc (expval->proc (value-of rator env))]
                                  [arg (apply-env env var)])
                              (apply-procedure proc arg)
                              (num-val 777))]
      [letrec-exp (p-names b-vars p-bodies letrec-body) (value-of letrec-body
                                                                  (extend-env-rec* p-names b-vars p-bodies env))]
      [begin-exp (exp1 exps) (letrec ([value-of-begins (lambda (e1 es)
                                                         (let ([v1 (value-of e1 env)])
                                                           (if (null? es)
                                                               v1
                                                               (value-of-begins (car es) (cdr es)))))])
                               (value-of-begins exp1 exps))]
      [assign-exp (x e) (begin (setref! (apply-env env x) (value-of e env))
                               (num-val 27))]
      [newpair-exp (exp1 exp2) (let ([v1 (value-of exp1 env)]
                                     [v2 (value-of exp2 env)])
                                 (mutpair-val (make-pair v1 v2)))]
      [left-exp (exp1) (let ([v1 (value-of exp1 env)])
                         (let ([p1 (expval->mutpair v1)])
                           (left p1)))]
      [setleft-exp (exp1 exp2) (let ([v1 (value-of exp1 env)]
                                     [v2 (value-of exp2 env)])
                                 (let ([p (expval->mutpair v1)])
                                   (begin (setleft p v2)
                                          (num-val 82))))]
      [right-exp (exp1) (let ([v1 (value-of exp1 env)])
                          (let ([p1 (expval->mutpair v1)])
                            (right p1)))]
      [setright-exp (exp1 exp2) (let ([v1 (value-of exp1 env)]
                                      [v2 (value-of exp2 env)])
                                  (let ([p (expval->mutpair v1)])
                                    (begin (setright p v2)
                                           (num-val 83))))])))

(define value-of-program
  (lambda (pgm)
    (initialize-store!)
    (cases program pgm
      [a-program (body) (value-of body (empty-env))])))

;; Interface.

(define run
  (lambda (string)
    (value-of-program (scan&parse string))))

(provide num-val bool-val run)
