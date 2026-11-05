#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         "../arbor/protocol.rkt")

(define (replace handler revision source)
  (handler
   (hasheq 'protocol protocol-version
           'id (format "replace-~a" revision)
           'op "document/replace"
           'document (hasheq 'id "doc-1" 'path "Demo.outline"
                             'revision revision 'source source))))

(define (run handler revision producer-id [mode "refresh"] [arguments (hasheq)])
  (handler
   (hasheq 'protocol protocol-version
           'id (format "run-~a-~a-~a" producer-id revision mode)
           'op "producer/run"
           'documentID "doc-1"
           'revision revision
           'producerID producer-id
           'mode mode
           'arguments arguments)))

(define (accept-mutation handler prepared)
  (define mutation (hash-ref prepared 'mutation))
  (define document (hash-ref mutation 'document))
  (define accepted
    (handler (hasheq 'protocol protocol-version
                     'id (string-append (hash-ref prepared 'id) ":replace")
                     'op "document/replace"
                     'document document)))
  (check-true (hash-ref accepted 'ok))
  (handler (hasheq 'protocol protocol-version
                   'id (string-append (hash-ref prepared 'id) ":complete")
                   'op "mutation/complete"
                   'executionID (hash-ref prepared 'id)
                   'outcome (hasheq 'ok #t))))

(define mutation-protocol-tests
  (test-suite
   "Arbor outline transaction protocol"

   (test-case
    "inserts managed nodes and refreshes their stable identity"
    (define handler (make-request-handler))
    (define source
      "#lang arbor/0\n- Root ^root\n- ! (outline/insert-child (block \"root\") \"Generated\") ^maker\n")
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define prepared (run handler 1 "maker"))
    (check-equal? (hash-ref prepared 'status) "mutation-request")
    (define mutation (hash-ref prepared 'mutation))
    (check-equal? (hash-ref mutation 'operationCount) 1)
    (check-false (hash-ref mutation 'destructive))
    (define candidate-source (hash-ref (hash-ref mutation 'document) 'source))
    (check-true (string-contains? candidate-source "  - Generated ^m_"))
    (define first-id (cadr (regexp-match #px"\\^([^~[:space:]]+)~c1~l~maker" candidate-source)))
    (define completed (accept-mutation handler prepared))
    (check-true (hash-ref completed 'ok))
    (check-equal? (hash-ref completed 'op) "mutation/complete")
    (check-equal? (hash-ref completed 'documentID) "doc-1")
    (check-equal? (hash-ref completed 'revision) 2)

    (define refreshed (run handler 2 "maker"))
    (define refreshed-source
      (hash-ref (hash-ref (hash-ref refreshed 'mutation) 'document) 'source))
    (check-equal? (length (regexp-match* #px"- Generated" refreshed-source)) 1)
    (check-true
     (string-contains? refreshed-source
                       (string-append "^" first-id "~c1~l~maker"))))

   (test-case
    "runs a query-selected transaction as one candidate source"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Alpha #todo ^alpha\n"
       "- Beta #todo ^beta\n"
       "- {{query: (find (?block) (where (block-tag ?block \"todo\")))}} ^todos\n"
       "- ! (outline/add-tag (query \"todos\") $tag) ^tagger\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define prepared (run handler 1 "tagger" "refresh" (hasheq 'tag "done")))
    (define mutation (hash-ref prepared 'mutation))
    (check-equal? (hash-ref mutation 'operationCount) 2)
    (define candidate (hash-ref (hash-ref mutation 'document) 'source))
    (check-true (string-contains? candidate "Alpha #todo #done ^alpha"))
    (check-true (string-contains? candidate "Beta #todo #done ^beta"))
    (check-true (hash-ref (accept-mutation handler prepared) 'ok)))

   (test-case
    "preserves mutation generations with append and detachment"
    (define handler (make-request-handler))
    (define source
      "#lang arbor/0\n- Parent ^parent\n- ! (outline/insert-child (block \"parent\") \"Generated\") ^maker\n")
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (check-true (hash-ref (accept-mutation handler (run handler 1 "maker")) 'ok))

    (define appended (run handler 2 "maker" "append"))
    (define appended-source
      (hash-ref (hash-ref (hash-ref appended 'mutation) 'document) 'source))
    (check-equal? (length (regexp-match* #px"- Generated" appended-source)) 2)
    (check-true (string-contains? appended-source "~c1~s~maker"))
    (check-true (hash-ref (accept-mutation handler appended) 'ok))

    (define detached-source
      (string-replace appended-source "~c1~l~maker" "~c1~d~maker"))
    (check-true (hash-ref (replace handler 4 detached-source) 'ok))
    (define refreshed (run handler 4 "maker"))
    (define refreshed-source
      (hash-ref (hash-ref (hash-ref refreshed 'mutation) 'document) 'source))
    (check-equal? (length (regexp-match* #px"- Generated" refreshed-source)) 3)
    (check-true (string-contains? refreshed-source "~c1~d~maker")))

   (test-case
    "applies structural operations atomically and preserves denial rollback"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Parent ^parent\n"
       "  - Child ^child\n"
       "- Archive ^archive\n"
       "- ! (outline/transact (set-text (block \"parent\") \"Renamed\")"
       " (move (block \"child\") (block \"archive\"))) ^change\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define prepared (run handler 1 "change"))
    (check-true (hash-ref (hash-ref prepared 'mutation) 'destructive))
    (define denied
      (handler (hasheq 'protocol protocol-version
                       'id "deny"
                       'op "mutation/complete"
                       'executionID (hash-ref prepared 'id)
                       'outcome (hasheq 'ok #f 'message "No"))))
    (check-false (hash-ref denied 'ok))
    (check-equal? (hash-ref (run handler 1 "change") 'status) "mutation-request")

    (define accepted (accept-mutation handler (run handler 1 "change")))
    (define candidate (hash-ref (hash-ref accepted 'document) 'source))
    (check-true (string-contains? candidate "- Renamed ^parent"))
    (check-true (string-contains? candidate "- Archive ^archive\n  - Child ^child")))

   (test-case
    "rejects cycles, cross-document query targets, and unsafe operation forms"
    (define handler (make-request-handler))
    (check-true
     (hash-ref (replace handler 1
                        "#lang arbor/0\n- Parent ^parent\n  - Child ^child\n- ! (outline/move (block \"parent\") (block \"child\")) ^bad\n")
               'ok))
    (check-false (hash-ref (run handler 1 "bad") 'ok))

    (define malformed-handler (make-request-handler))
    (check-true
     (hash-ref (replace malformed-handler 1
                        "#lang arbor/0\n- ! (outline/transact (unknown (self))) ^bad\n")
               'ok))
    (check-false (hash-ref (run malformed-handler 1 "bad") 'ok))

    (define cross-handler (make-request-handler))
    (check-true
     (hash-ref
      (replace cross-handler 1
               (string-append
                "#lang arbor/0\n"
                "- Local #todo ^local\n"
                "- {{query: (find (?block) (where (block-tag ?block \"todo\")))}} ^todos\n"
                "- ! (outline/add-tag (query \"todos\") \"done\") ^bad\n"))
      'ok))
    (check-true
     (hash-ref
      (cross-handler
       (hasheq 'protocol protocol-version
               'id "replace-doc-2"
               'op "document/replace"
               'document (hasheq 'id "doc-2" 'path "Other.outline" 'revision 1
                                 'source "#lang arbor/0\n- Outside #todo ^outside\n")))
      'ok))
    (check-false (hash-ref (run cross-handler 1 "bad") 'ok)))))

(module+ test
  (define failures (run-tests mutation-protocol-tests))
  (unless (zero? failures)
    (error 'mutation-protocol-test "test failures")))
