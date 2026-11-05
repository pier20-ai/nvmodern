#lang racket/base

(require datalog/ast
         datalog/runtime
         racket/list
         "facts.rkt")

(provide arbor-theory?
         assert-facts!
         make-arbor-theory
         retract-facts!
         run-query)

(struct arbor-theory (value) #:transparent)

(define (make-arbor-theory [facts '()])
  (define theory (arbor-theory (make-theory)))
  (install-ancestry-rules! theory)
  (assert-facts! theory facts)
  theory)

(define (assert-facts! theory facts)
  (for ([fact (in-list facts)])
    (assume! (arbor-theory-value theory) (fact->clause fact))))

(define (retract-facts! theory facts)
  (for ([fact (in-list facts)])
    (retract! (arbor-theory-value theory) (fact->clause fact))))

(define (run-query theory definition arguments)
  (define query-theory (hash-copy (arbor-theory-value theory)))
  (define result-variables
    (map make-variable (query-definition-columns definition)))
  (define result-head
    (literal #f 'arbor-result result-variables))
  (define body
    (for/list ([source-clause (in-list (query-definition-clauses definition))])
      (literal #f
               (car source-clause)
               (map (lambda (term) (query-term->datalog term arguments))
                    (cdr source-clause)))))
  (assume! query-theory (clause #f result-head body))
  (sort
   (for/list ([answer (in-list (prove query-theory result-head))])
     (for/list ([term (in-list (literal-terms answer))])
       (constant-value term)))
   string<?
   #:key (lambda (row) (format "~s" row))))

(define (install-ancestry-rules! theory)
  (define descendant (make-variable 'descendant))
  (define parent (make-variable 'parent))
  (define ancestor (make-variable 'ancestor))
  (define value (arbor-theory-value theory))
  (assume! value
           (clause #f
                   (literal #f 'block-ancestor (list descendant ancestor))
                   (list (literal #f 'block-parent (list descendant ancestor)))))
  (assume! value
           (clause #f
                   (literal #f 'block-ancestor (list descendant ancestor))
                   (list (literal #f 'block-parent (list descendant parent))
                         (literal #f 'block-ancestor (list parent ancestor))))))

(define (fact->clause fact)
  (clause #f
          (literal #f
                   (arbor-fact-predicate fact)
                   (map (lambda (value) (constant #f value))
                        (arbor-fact-terms fact)))
          '()))

(define (query-term->datalog term arguments)
  (cond
    [(query-variable? term)
     (define name (query-variable-name term))
     (if (hash-has-key? arguments name)
         (constant #f (hash-ref arguments name))
         (make-variable name))]
    [else (constant #f term)]))

(define (make-variable name)
  (variable #f name))
