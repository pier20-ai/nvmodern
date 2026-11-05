#lang racket/base

(require racket/list
         rackunit
         rackunit/text-ui
         "../arbor/datalog-adapter.rkt"
         "../arbor/facts.rkt")

(define (fact-summary fact)
  (list (arbor-fact-predicate fact) (arbor-fact-terms fact)))

(define facts-tests
  (test-suite
   "Arbor facts"

   (test-case
    "compiles canonical facts in source order"
    (define document
      (compile-document
       "doc-1"
       "Demo"
       1
       (string-append
        "#lang arbor/0\n"
        "- Root #project [[Home]] ^root\n"
        "  - status:: active #todo ((root)) ^child\n")))
    (check-equal? (compiled-document-diagnostics document) '())
    (check-equal?
     (map fact-summary (compiled-document-facts document))
     '((block-page ("root" "Demo"))
       (block-order ("root" 0))
       (block-text ("root" "Root #project [[Home]]"))
       (block-tag ("root" "project"))
       (block-link-page ("root" "Home"))
       (block-page ("child" "Demo"))
       (block-parent ("child" "root"))
       (block-order ("child" 0))
       (block-text ("child" "status:: active #todo ((root))"))
       (block-tag ("child" "todo"))
       (block-ref-block ("child" "root"))
       (block-attribute ("child" "status" "active #todo ((root))")))))

   (test-case
    "retains source locations without exposing engine values"
    (define fact
      (car (compiled-document-facts
            (compile-document "doc-1" "Demo" 1 "#lang arbor/0\n- One ^one\n"))))
    (check-equal?
     (fact->jsexpr fact)
     (hasheq 'predicate "block-page"
             'terms '("one" "Demo")
             'source (hasheq 'documentID "doc-1"
                             'blockID "one"
                             'line 2
                             'column 3
                             'endLine 2
                             'endColumn 6))))

   (test-case
    "uses one-based, end-exclusive authored body ranges"
    (define facts
      (compiled-document-facts
       (compile-document
        "doc-1"
        "Demo"
        1
        "#lang arbor/0\n- Root body ^root\n  - Child body ^child\n")))
    (define root (car facts))
    (define child
      (findf (lambda (fact)
               (and (eq? (arbor-fact-predicate fact) 'block-page)
                    (equal? (car (arbor-fact-terms fact)) "child")))
             facts))
    (check-equal? (list (arbor-fact-line root)
                        (arbor-fact-column root)
                        (arbor-fact-end-line root)
                        (arbor-fact-end-column root))
                  '(2 3 2 12))
    (check-equal? (list (arbor-fact-line child)
                        (arbor-fact-column child)
                        (arbor-fact-end-line child)
                        (arbor-fact-end-column child))
                  '(3 5 3 15)))

   (test-case
    "accepts an empty block with a stable UID"
    (define document
      (compile-document "doc-1" "Demo" 1 "#lang arbor/0\n- ^empty\n"))
    (check-equal? (compiled-document-diagnostics document) '())
    (define facts (compiled-document-facts document))
    (define text-fact
      (findf (lambda (fact) (eq? (arbor-fact-predicate fact) 'block-text)) facts))
    (check-equal? (arbor-fact-terms text-fact) '("empty" ""))
    (check-equal? (list (arbor-fact-column text-fact)
                        (arbor-fact-end-column text-fact))
                  '(3 3)))

   (test-case
    "keeps managed result subtrees out of the authored fact world"
    (define document
      (compile-document
       "doc-1"
       "Demo"
       1
       (string-append
        "#lang arbor/0\n"
        "- Producer ^producer\n"
        "  - Managed #result ^live~c1~l~producer~scalar~1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~2\n"
        "    - Nested #result ^nested\n"
        "  - Detached #authored ^edited~c1~d~producer~scalar~1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~2\n")))
    (check-equal? (compiled-document-diagnostics document) '())
    (define fact-block-ids
      (remove-duplicates
       (map arbor-fact-block-id (compiled-document-facts document))))
   (check-equal? fact-block-ids '("producer" "edited")))

   (test-case
    "accepts legacy boolean computation revisions"
    (define document
      (compile-document
       "doc-1"
       "Demo"
       1
       (string-append
        "#lang arbor/0\n"
        "- Producer ^producer\n"
        "  - Managed ^live~c1~l~producer~effect~true~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~true\n")))
    (check-equal? (compiled-document-diagnostics document) '())
    (check-equal?
     (remove-duplicates
      (map arbor-fact-block-id (compiled-document-facts document)))
     '("producer")))

   (test-case
    "extends a block range through continuation lines"
    (define fact
      (car (compiled-document-facts
            (compile-document
             "doc-1"
             "Demo"
             1
             "#lang arbor/0\n- First ^one\n  | second line\n"))))
    (check-equal? (list (arbor-fact-line fact)
                        (arbor-fact-column fact)
                        (arbor-fact-end-line fact)
                        (arbor-fact-end-column fact))
                  '(2 3 3 16)))

   (test-case
    "rejects malformed and reader-enabled query declarations"
    (define document
      (compile-document
       "doc-1"
       "Demo"
       1
       (string-append
        "#lang arbor/0\n"
        "- {{query: #reader racket/base}} ^unsafe\n")))
    (check-equal? (hash-ref (car (compiled-document-diagnostics document)) 'code)
                  "ARBOR3001"))

   (test-case
    "rejects projection placeholders that are not result columns"
    (define document
      (compile-document
       "doc-1"
       "Demo"
       1
       (string-append
        "#lang arbor/0\n"
        "- {{query: (find (?block ?text) (where (block-text ?block ?text)) "
        "(project \"{missing}\"))}} ^bad-project\n")))
    (check-equal? (hash-ref (car (compiled-document-diagnostics document)) 'code)
                  "ARBOR3001")
    (check-regexp-match
     #rx"Projection variable"
     (hash-ref (car (compiled-document-diagnostics document)) 'message)))

   (test-case
    "adapter assertions and retractions change query results"
    (define document
      (compile-document
       "doc-1"
       "Demo"
       1
       (string-append
        "#lang arbor/0\n"
        "- Tagged #project ^tagged\n"
        "- {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^q-tag\n")))
    (define theory (make-arbor-theory (compiled-document-facts document)))
    (define definition (car (compiled-document-queries document)))
    (check-equal? (run-query theory definition (hasheq 'tag "project"))
                  '(("tagged")))
    (define tag-facts
      (filter (lambda (fact) (eq? (arbor-fact-predicate fact) 'block-tag))
              (compiled-document-facts document)))
    (retract-facts! theory tag-facts)
    (check-equal? (run-query theory definition (hasheq 'tag "project")) '()))))

(module+ test
  (unless (zero? (run-tests facts-tests))
    (error 'facts-test "test failures")))
