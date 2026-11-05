#lang racket/base

(require rackunit
         rackunit/text-ui
         "../arbor/protocol.rkt")

(define protocol-tests
  (test-suite
   "Arbor kernel protocol"

   (test-case
    "evaluates pure blocks and emits query declarations"
    (define response
      (handle-request
       (hasheq 'protocol protocol-version
               'id "request-1"
               'op "evaluate"
               'document
               (hasheq 'path "Demo.outline"
                       'revision 7
                       'source
                       (string-append
                        "#lang arbor/0\n"
                        "- Inputs ^inputs\n"
                        "  - = (+ 40 2) ^answer\n"
                        "  - = (* (ref \"answer\") 2) ^double\n"
                        "- {{query: [:find ?b :where [?b :block/uid]]}} ^query\n")))))
    (check-true (hash-ref response 'ok))
    (check-equal? (map (lambda (patch) (hash-ref patch 'display))
                       (hash-ref response 'patches))
                  '("42" "84"))
    (check-equal? (hash-ref (car (hash-ref response 'queries)) 'uid) "query"))

   (test-case
    "rejects an effectful operator without evaluating it"
    (define response
      (handle-request
       (hasheq 'protocol protocol-version
               'id "request-2"
               'op "evaluate"
               'document
               (hasheq 'path "Unsafe.outline"
                       'revision 1
                       'source "#lang arbor/0\n- = (system \"open /tmp\") ^unsafe\n"))))
    (check-false (hash-ref response 'ok))
    (check-equal? (hash-ref (car (hash-ref response 'diagnostics)) 'code) "ARBOR2001"))

   (test-case
    "reports malformed structure and duplicate UIDs"
    (define response
      (handle-request
       (hasheq 'protocol protocol-version
               'id "request-3"
               'op "evaluate"
               'document
               (hasheq 'path "Broken.outline"
                       'revision 1
                       'source "#lang arbor/0\n- One ^same\n   - Two ^same\n"))))
    (check-false (hash-ref response 'ok))
    (check-true (>= (length (hash-ref response 'diagnostics)) 2)))

   (test-case
    "clears derived values removed by the new revision"
    (define response
      (handle-request
       (hasheq 'protocol protocol-version
               'id "request-4"
               'op "evaluate"
               'previousDerivedUIDs '("old")
               'document
               (hasheq 'path "Demo.outline"
                       'revision 8
                       'source "#lang arbor/0\n- Plain ^plain\n"))))
    (check-equal? (hash-ref (car (hash-ref response 'patches)) 'op) "clear-derived"))

   (test-case
    "accepts canonical multiline blocks and the renderer UID alphabet"
    (define response
      (handle-request
       (hasheq 'protocol protocol-version
               'id "request-5"
               'op "evaluate"
               'document
               (hasheq 'path "Multiline.outline"
                       'revision 2
                       'source
                       "#lang arbor/0\n- First line ^block.with:punctuation-1\n  | second line\n"))))
    (check-true (hash-ref response 'ok))
    (check-equal? (hash-ref (car (hash-ref response 'blocks)) 'body)
                  "First line\nsecond line"))))

(module+ test
  (unless (zero? (run-tests protocol-tests))
    (error 'protocol-test "test failures")))
