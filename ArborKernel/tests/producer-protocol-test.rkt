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
           'document (hasheq 'id "doc-1"
                             'path "Demo.outline"
                             'revision revision
                             'source source))))

(define (run handler revision producer-id [mode "refresh"] [arguments (hasheq)])
  (handler
   (hasheq 'protocol protocol-version
           'id (format "run-~a-~a" producer-id revision)
           'op "producer/run"
           'documentID "doc-1"
           'revision revision
           'producerID producer-id
           'mode mode
           'arguments arguments)))

(define (apply-intent handler revision result-id text)
  (handler
   (hasheq 'protocol protocol-version
           'id "intent-1"
           'op "intent/apply"
           'documentID "doc-1"
           'revision revision
           'resultID result-id
           'intent (hasheq 'op "set-text" 'text text))))

(define (complete-effect handler execution-id value)
  (handler
   (hasheq 'protocol protocol-version
           'id (format "complete-~a" execution-id)
           'op "effect/complete"
           'executionID execution-id
           'outcome (hasheq 'ok #t 'value value))))

(define (cancel-effect handler execution-id)
  (handler
   (hasheq 'protocol protocol-version
           'id (format "cancel-~a" execution-id)
           'op "effect/cancel"
           'executionID execution-id)))

(define producer-protocol-tests
  (test-suite
   "Arbor producer materialization protocol"

   (test-case
    "runs an expression only when producer/run is requested"
    (define handler (make-request-handler))
    (define source "#lang arbor/0\n- = (+ 40 2) ^sum\n")
    (define accepted (replace handler 1 source))
    (check-true (hash-ref accepted 'ok))
    (check-false (hash-has-key? accepted 'results))

    (define response (run handler 1 "sum"))
    (check-true (hash-ref response 'ok))
    (check-equal? (hash-ref response 'kind) "expression")
    (check-equal? (hash-ref response 'generation) 1)
    (check-equal? (hash-ref response 'mode) "refresh")
    (check-equal? (hash-ref response 'results)
                  (list (hasheq 'key "scalar" 'markdown "42")))
    (check-equal? (string-length (hash-ref response 'inputHash)) 40))

   (test-case
    "advances generation from persisted anchor metadata"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- = (+ 40 2) ^sum\n"
       "  - 42 ^answer~c1~l~sum~scalar~3~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~1\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define response (run handler 1 "sum" "append"))
    (check-equal? (hash-ref response 'generation) 4)
    (check-equal? (hash-ref response 'mode) "append"))

   (test-case
    "formats one materialized block per deterministic query row"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Alpha #project ^alpha\n"
       "- Beta #project ^beta\n"
       "- {{query: (find (?block ?text) (where (block-text ?block ?text)))}} ^all\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define response (run handler 1 "all"))
    (check-true (hash-ref response 'ok))
    (check-equal? (hash-ref response 'kind) "query")
    (define results (hash-ref response 'results))
    (check-equal? (length results) 3)
    (check-equal? (map (lambda (result) (hash-ref result 'markdown)) results)
                  '("{{query: (find (?block ?text) (where (block-text ?block ?text)))}} · {{query: (find (?block ?text) (where (block-text ?block ?text)))}}"
                    "Alpha #project · Alpha #project"
                    "Beta #project · Beta #project"))
    (check-true (andmap (lambda (result) (= (string-length (hash-ref result 'key)) 40))
                        results)))

   (test-case
    "rejects invalid producers without changing the accepted fact world"
    (define handler (make-request-handler))
    (define source "#lang arbor/0\n- = (system \"open /tmp\") ^unsafe\n")
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define response (run handler 1 "unsafe"))
    (check-false (hash-ref response 'ok))
    (check-equal? (hash-ref (car (hash-ref response 'diagnostics)) 'code)
                  "ARBOR3304"))

   (test-case
    "projects query rows and identifies a single writable source block"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Alpha #project ^alpha\n"
       "- {{query: (find (?block ?text) (in ?tag) "
       "(where (block-tag ?block ?tag) (block-text ?block ?text)) "
       "(project \"{text}\"))}} ^projects\n"
       "  - tag:: project ^projects-tag\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define response (run handler 1 "projects"))
    (check-true (hash-ref response 'ok))
    (define result-key (hash-ref (car (hash-ref response 'results)) 'key))
    (check-equal? (hash-ref response 'results)
                  (list (hasheq
                         'key result-key
                         'markdown "Alpha #project"
                         'origin (hasheq 'blockID "alpha"
                                         'documentID "doc-1"
                                         'path "Demo.outline")
                         'updatePolicy "source-text")))
    (define renamed-source
      (string-replace source "Alpha #project" "Renamed #project"))
    (check-true (hash-ref (replace handler 2 renamed-source) 'ok))
    (check-equal? (hash-ref (car (hash-ref (run handler 2 "projects") 'results)) 'key)
                  result-key))

   (test-case
    "turns a source-backed result edit into a candidate document replacement"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Alpha #project ^alpha\n"
       "- {{query: (find (?block) (where (block-tag ?block \"project\")))}} ^projects\n"
       "  - Alpha #project ^result~c2~l~projects~row~1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~1~alpha~t\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define response (apply-intent handler 1 "result" "Renamed #project"))
    (check-true (hash-ref response 'ok))
    (check-equal? (hash-ref response 'text) "Renamed #project")
    (check-equal? (hash-ref (hash-ref response 'origin) 'blockID) "alpha")
    (check-equal?
     (hash-ref (hash-ref response 'document) 'source)
     (string-append
      "#lang arbor/0\n"
      "- Renamed #project ^alpha\n"
      "- {{query: (find (?block) (where (block-tag ?block \"project\")))}} ^projects\n"
      "  - Alpha #project ^result~c2~l~projects~row~1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~1~alpha~t\n")))

   (test-case
    "keeps decorated and composite rows detach-only"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Alpha #project ^alpha\n"
       "- {{query: (find (?block ?text) "
       "(where (block-text ?block ?text)) (project \"**{text}**\"))}} ^decorated\n"
       "- {{query: (find (?block ?text) (where (block-text ?block ?text)))}} ^composite\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (for ([producer-id (in-list '("decorated" "composite"))])
      (define result (car (hash-ref (run handler 1 producer-id) 'results)))
      (check-false (hash-has-key? result 'updatePolicy))))

   (test-case
    "plans an effect and materializes only a matching host completion"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler 1 "#lang arbor/0\n- ! (clock/now) ^now\n") 'ok))
    (define request (run handler 1 "now"))
    (check-equal? (hash-ref request 'status) "effect-request")
    (check-equal? (hash-ref (hash-ref request 'effect) 'handler) "clock/now")
    (check-equal? (hash-ref (hash-ref request 'effect) 'capability) 'null)
    (define completed (complete-effect handler (hash-ref request 'id) "2026-08-12T18:00:00Z"))
    (check-true (hash-ref completed 'ok))
    (check-equal? (hash-ref completed 'op) "effect/complete")
    (check-equal? (hash-ref completed 'documentID) "doc-1")
    (check-equal? (hash-ref completed 'kind) "effect")
    (check-equal? (hash-ref completed 'results)
                  (list (hasheq 'key "effect" 'markdown "2026-08-12T18:00:00Z")))
    (check-equal? (complete-effect handler (hash-ref request 'id) "different") completed))

   (test-case
    "reports the accepted revision when a producer request is stale"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler 2 "#lang arbor/0\n- = (+ 1 1) ^sum\n") 'ok))
    (define response (run handler 1 "sum"))
    (check-false (hash-ref response 'ok))
    (check-equal? (hash-ref response 'acceptedRevision) 2))

   (test-case
    "resolves typed effect inputs and materializes one block per list item"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- ! (fs/read $path) ^read\n"
       "  - path:: Notes.md ^path\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define request (run handler 1 "read"))
    (check-equal? (hash-ref (hash-ref request 'effect) 'arguments) '("Notes.md"))
    (define completed
      (complete-effect handler (hash-ref request 'id)
                       (list "Alpha" (hasheq 'count 2 'ready #t))))
    (check-equal?
     (hash-ref completed 'results)
     (list (hasheq 'key "item:0" 'markdown "Alpha")
           (hasheq 'key "item:1" 'markdown "count:: 2\nready:: true"))))

   (test-case
    "keeps structured action arguments inert and exposes model capabilities"
    (define action-handler (make-request-handler))
    (check-true
     (hash-ref
      (replace action-handler 1
               "#lang arbor/0\n- ! (action/run \"app.health.ping\" (record (\"count\" 2) (\"names\" (list \"a\" \"b\")))) ^action\n")
      'ok))
    (define action (hash-ref (run action-handler 1 "action") 'effect))
    (check-equal? (hash-ref (hash-ref action 'capability) 'kind) "action.execute")
    (check-equal? (cadr (hash-ref action 'arguments))
                  (hasheq 'count 2 'names '("a" "b")))

    (define model-handler (make-request-handler))
    (check-true
     (hash-ref
      (replace model-handler 1
               "#lang arbor/0\n- ! (model/complete \"Summarize this\" \"local\") ^model\n")
      'ok))
    (define model (hash-ref (run model-handler 1 "model") 'effect))
    (check-equal? (hash-ref (hash-ref model 'capability) 'kind) "model.complete")
    (check-equal? (hash-ref (hash-ref model 'limits) 'timeoutMs) 60000))

   (test-case
    "cancels pending effects idempotently"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler 1 "#lang arbor/0\n- ! (clock/now) ^now\n") 'ok))
    (define request (run handler 1 "now"))
    (check-equal? (hash-ref (cancel-effect handler (hash-ref request 'id)) 'outcome)
                  "cancelled")
    (check-equal? (hash-ref (cancel-effect handler (hash-ref request 'id)) 'outcome)
                  "idempotent")
    (check-false (hash-ref (complete-effect handler (hash-ref request 'id) "late") 'ok)))

   (test-case
    "discards a pending effect when its document revision changes"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler 1 "#lang arbor/0\n- ! (clock/now) ^now\n") 'ok))
    (define request (run handler 1 "now"))
    (check-true
     (hash-ref (replace handler 2 "#lang arbor/0\n- ! (clock/now) ^now\n- Changed ^changed\n")
               'ok))
    (check-false (hash-ref (complete-effect handler (hash-ref request 'id) "late") 'ok))
    (check-equal? (hash-ref (cancel-effect handler (hash-ref request 'id)) 'outcome)
                  "idempotent"))

   (test-case
    "does not advance a source-backed intent that leaves its source unchanged"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Original ^source\n"
       "- = 1 ^query\n"
       "  - Original ^result~c2~l~query~row~1~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa~1~source~t\n"))
    (check-true (hash-ref (replace handler 1 source) 'ok))
    (define response (apply-intent handler 1 "result" "Original"))
    (check-true (hash-ref response 'ok))
    (check-equal? (hash-ref response 'outcome) "idempotent")
    (check-false (hash-has-key? response 'document))
    (check-equal? (hash-ref (run handler 1 "query") 'revision) 1))

   (test-case
    "describes guarded effects and rejects unsafe declarations"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler 1 "#lang arbor/0\n- ! (fs/read \"Notes.md\") ^read\n") 'ok))
    (define response (run handler 1 "read"))
    (define capability (hash-ref (hash-ref response 'effect) 'capability))
    (check-equal? (hash-ref capability 'kind) "filesystem.read")
    (check-equal? (hash-ref capability 'resource) "Notes.md")
    (check-true (= (string-length (hash-ref capability 'id)) 40))

    (define unsafe-handler (make-request-handler))
    (check-true (hash-ref (replace unsafe-handler 1
                                   "#lang arbor/0\n- ! (fs/read \"../secret\") ^unsafe\n") 'ok))
    (define unsafe (run unsafe-handler 1 "unsafe"))
    (check-false (hash-ref unsafe 'ok))
    (check-equal? (hash-ref (car (hash-ref unsafe 'diagnostics)) 'code) "ARBOR3304")

    (define reader-handler (make-request-handler))
    (check-true
     (hash-ref (replace reader-handler 1
                        "#lang arbor/0\n- ! #.(system \"touch /tmp/arbor-reader\") ^unsafe\n")
               'ok))
    (check-false (hash-ref (run reader-handler 1 "unsafe") 'ok)))))

(module+ test
  (unless (zero? (run-tests producer-protocol-tests))
    (error 'producer-protocol-test "test failures")))
