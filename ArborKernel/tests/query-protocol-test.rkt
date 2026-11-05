#lang racket/base

(require rackunit
         rackunit/text-ui
         "../arbor/protocol.rkt")

(define query-source
  (string-append
   "#lang arbor/0\n"
   "- Root #project [[Home]] ^root\n"
   "  - status:: active #todo ((root)) ^child\n"
   "    - Leaf [[Other]] ^leaf\n"
   "- Mention ((child)) and [[Home]] #project ^mention\n"
   "- {{query: (find (?ancestor) (in ?block) (where (block-ancestor ?block ?ancestor)))}} ^q-ancestry\n"
   "- {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^q-tag\n"
   "- {{query: (find (?block ?value) (in ?key) (where (block-attribute ?block ?key ?value)))}} ^q-attribute\n"
   "- {{query: (find (?block) (in ?page) (where (block-link-page ?block ?page)))}} ^q-link\n"
   "- {{query: (find (?block) (in ?target) (where (block-ref-block ?block ?target)))}} ^q-ref\n"))

(define (replace handler document-id revision source [path "Demo"])
  (handler
   (hasheq 'protocol protocol-version
           'id (format "replace-~a-~a" document-id revision)
           'op "document/replace"
           'document (hasheq 'id document-id
                             'path path
                             'revision revision
                             'source source))))

(define (run-query-request handler document-id revision query-id arguments)
  (handler
   (hasheq 'protocol protocol-version
           'id (format "query-~a" query-id)
           'op "query/run"
           'documentID document-id
           'revision revision
           'queryID query-id
           'arguments arguments)))

(define (first-code response)
  (hash-ref (car (hash-ref response 'diagnostics)) 'code))

(define query-protocol-tests
  (test-suite
   "Arbor query protocol"

   (test-case
    "queries ancestry, tags, attributes, links, and block references"
    (define handler (make-request-handler))
    (define accepted (replace handler "doc-1" 1 query-source))
    (check-true (hash-ref accepted 'ok))
    (check-equal? (hash-ref accepted 'worldRevision) 1)
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "q-ancestry"
                                  (hasheq 'block "leaf"))
               'rows)
     '(("child") ("root")))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "q-tag"
                                  (hasheq 'tag "project"))
               'rows)
     '(("mention") ("root")))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "q-attribute"
                                  (hasheq 'key "status"))
               'rows)
     '(("child" "active #todo ((root))")))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "q-link"
                                  (hasheq 'page "Home"))
               'rows)
     '(("mention") ("root")))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "q-ref"
                                  (hasheq 'target "child"))
               'rows)
     '(("mention"))))

   (test-case
    "rebuilds the world across documents and retracts replaced facts"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 query-source) 'ok))
    (define second-source "#lang arbor/0\n- Other #project ^other\n")
    (define second (replace handler "doc-2" 1 second-source "Other"))
    (check-equal? (hash-ref second 'worldRevision) 2)
    (define cross-document
      (run-query-request handler "doc-1" 1 "q-tag" (hasheq 'tag "project")))
    (check-equal? (hash-ref cross-document 'worldRevision) 2)
    (check-equal? (hash-ref cross-document 'rows)
                  '(("mention") ("other") ("root")))

    (define replacement
      (replace
       handler
       "doc-1"
       2
       (string-append
        "#lang arbor/0\n"
        "- Root ^root\n"
        "- {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^q-tag\n")))
    (check-true (hash-ref replacement 'ok))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 2 "q-tag"
                                  (hasheq 'tag "project"))
               'rows)
     '(("other"))))

   (test-case
    "enforces monotonic revisions and treats an exact replay as idempotent"
    (define handler (make-request-handler))
    (define accepted (replace handler "doc-1" 4 query-source))
    (define replay (replace handler "doc-1" 4 query-source))
    (check-true (hash-ref replay 'ok))
    (check-equal? (hash-ref replay 'outcome) "idempotent")
    (check-equal? (hash-ref replay 'worldRevision)
                  (hash-ref accepted 'worldRevision))
    (define conflict
      (replace handler "doc-1" 4 "#lang arbor/0\n- Changed ^changed\n"))
    (check-false (hash-ref conflict 'ok))
    (check-equal? (first-code conflict) "ARBOR3003")
    (define stale (replace handler "doc-1" 3 query-source))
    (check-false (hash-ref stale 'ok))
    (check-equal? (first-code stale) "ARBOR3002")
    (define stale-query
      (run-query-request handler "doc-1" 3 "q-tag" (hasheq 'tag "project")))
   (check-false (hash-ref stale-query 'ok))
    (check-equal? (first-code stale-query) "ARBOR3102"))

   (test-case
    "rejects missing, extra, and non-scalar query arguments"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 query-source) 'ok))
    (for ([arguments (in-list (list (hasheq)
                                    (hasheq 'tag "project" 'extra "value")
                                    (hasheq 'tag '("project"))))])
      (define response
        (run-query-request handler "doc-1" 1 "q-tag" arguments))
      (check-false (hash-ref response 'ok))
      (check-equal? (first-code response) "ARBOR3104")))

   (test-case
    "keeps the accepted world when a replacement is malformed"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 query-source) 'ok))
    (define invalid
      (replace handler "doc-1" 2
               "#lang arbor/0\n- {{query: #reader racket/base}} ^bad\n"))
    (check-false (hash-ref invalid 'ok))
    (check-equal? (first-code invalid) "ARBOR3001")
    (define still-current
      (run-query-request handler "doc-1" 1 "q-tag" (hasheq 'tag "project")))
    (check-true (hash-ref still-current 'ok))
    (check-equal? (hash-ref still-current 'rows) '(("mention") ("root"))))

   (test-case
    "rejects block UID collisions across documents"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 query-source) 'ok))
    (define collision
      (replace handler "doc-2" 1 "#lang arbor/0\n- Duplicate ^root\n" "Other"))
    (check-false (hash-ref collision 'ok))
    (check-equal? (first-code collision) "ARBOR3004"))

   (test-case
    "uses direct child attributes as overridable input defaults"
    (define handler (make-request-handler))
    (define source
      (string-append
       "#lang arbor/0\n"
       "- Alpha #project ^alpha\n"
       "- Beta #todo ^beta\n"
       "- {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^projects\n"
       "  - tag:: project ^projects-tag\n"))
    (check-true (hash-ref (replace handler "doc-1" 1 source) 'ok))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "projects" (hasheq)) 'rows)
     '(("alpha")))
    (check-equal?
     (hash-ref (run-query-request handler "doc-1" 1 "projects" (hasheq 'tag "todo")) 'rows)
     '(("beta"))))))

(module+ test
  (unless (zero? (run-tests query-protocol-tests))
    (error 'query-protocol-test "test failures")))
