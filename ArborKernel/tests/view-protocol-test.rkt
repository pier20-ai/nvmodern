#lang racket/base

(require racket/list
         rackunit
         rackunit/text-ui
         "../arbor/protocol.rkt")

(define source
  (string-append
   "#lang arbor/0\n"
   "- Tagged #project ^tagged\n"
   "- = (+ 40 2) ^answer\n"
   "- {{query: (find (?block) (where (block-tag ?block \"project\")))}} ^projects\n"
   "- {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^by-tag\n"
   "- {{query: (find (?block ?text) (where (block-text ?block ?text)))}} ^all-text\n"))

(define (replace handler document-id revision document-source [path "Demo.outline"])
  (handler
   (hasheq 'protocol protocol-version
           'id (format "replace-~a-~a" document-id revision)
           'op "document/replace"
           'document (hasheq 'id document-id
                             'path path
                             'revision revision
                             'source document-source))))

(define (get-view handler document-id revision
                  #:query [query-id #f]
                  #:arguments [arguments (hasheq)])
  (define request
    (hasheq 'protocol protocol-version
            'id (format "view-~a-~a" document-id revision)
            'op "view/get"
            'documentID document-id
            'revision revision
            'arguments arguments))
  (handler (if query-id (hash-set request 'queryID query-id) request)))

(define (view-by-producer response producer-id)
  (findf (lambda (view) (equal? producer-id (hash-ref view 'producerID)))
         (hash-ref response 'views)))

(define (row-by-block view block-id)
  (findf (lambda (row)
           (equal? block-id
                   (hash-ref (car (hash-ref row 'cells)) 'blockID #f)))
         (hash-ref view 'rows)))

(define view-protocol-tests
  (test-suite
   "Arbor resolved-view protocol"

   (test-case
    "materializes expressions and zero-input queries without renderer inference"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 source) 'ok))
    (define response (get-view handler "doc-1" 1))
    (check-true (hash-ref response 'ok))
    (check-equal? (hash-ref response 'worldRevision) 1)

    (define expression (view-by-producer response "answer"))
    (check-equal? (hash-ref expression 'presentation) "scalar")
    (check-equal? (hash-ref expression 'status) "ok")
    (check-equal? (hash-ref expression 'value) 42)
    (check-equal? (hash-ref expression 'display) "42")

    (define projects (view-by-producer response "projects"))
    (check-equal? (hash-ref projects 'presentation) "outline")
    (define project-cell
      (car (hash-ref (car (hash-ref projects 'rows)) 'cells)))
    (check-equal? (hash-ref project-cell 'kind) "block")
    (check-equal? (hash-ref project-cell 'blockID) "tagged")
    (check-equal? (hash-ref project-cell 'documentID) "doc-1")
    (check-equal? (hash-ref project-cell 'path) "Demo.outline")
    (check-equal? (hash-ref project-cell 'markdown) "Tagged #project")

    (define parameterized (view-by-producer response "by-tag"))
    (check-equal? (hash-ref parameterized 'status) "needs-arguments")
    (check-equal? (hash-ref parameterized 'inputs) '("tag"))

    (define table (view-by-producer response "all-text"))
    (check-equal? (hash-ref table 'presentation) "table")
    (check-equal? (hash-ref table 'columns) '("block" "text")))

   (test-case
    "runs an explicitly selected parameterized query"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 source) 'ok))
    (define response
      (get-view handler "doc-1" 1
                #:query "by-tag"
                #:arguments (hasheq 'tag "project")))
    (check-true (hash-ref response 'ok))
    (check-equal? (length (hash-ref response 'views)) 1)
    (define view (car (hash-ref response 'views)))
    (check-equal? (hash-ref view 'producerID) "by-tag")
    (check-equal? (hash-ref view 'presentation) "outline")
    (check-equal? (hash-ref (car (hash-ref (car (hash-ref view 'rows)) 'cells))
                            'blockID)
                  "tagged"))

   (test-case
    "keeps stable row identities while materializing cross-document results"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 1 source) 'ok))
    (define first-view (view-by-producer (get-view handler "doc-1" 1) "projects"))
    (define tagged-id (hash-ref (row-by-block first-view "tagged") 'id))

    (check-true
     (hash-ref
      (replace handler "doc-2" 1
               "#lang arbor/0\n- Other #project ^other\n"
               "Other.outline")
      'ok))
    (define response (get-view handler "doc-1" 1))
    (check-equal? (hash-ref response 'worldRevision) 2)
    (define projects (view-by-producer response "projects"))
    (check-equal? (length (hash-ref projects 'rows)) 2)
    (check-equal? (hash-ref (row-by-block projects "tagged") 'id) tagged-id)
    (define other-cell
      (car (hash-ref (row-by-block projects "other") 'cells)))
    (check-equal? (hash-ref other-cell 'documentID) "doc-2")
    (check-equal? (hash-ref other-cell 'path) "Other.outline"))

   (test-case
    "returns expression errors as read-only results without rejecting the fact world"
    (define handler (make-request-handler))
    (define unsafe "#lang arbor/0\n- = (system \"open /tmp\") ^unsafe\n")
    (check-true (hash-ref (replace handler "doc-1" 1 unsafe) 'ok))
    (define response (get-view handler "doc-1" 1))
    (check-true (hash-ref response 'ok))
    (define expression (view-by-producer response "unsafe"))
    (check-equal? (hash-ref expression 'status) "error")
    (check-equal? (hash-ref (car (hash-ref expression 'diagnostics)) 'code)
                  "ARBOR2001"))

   (test-case
    "rejects a stale view revision"
    (define handler (make-request-handler))
    (check-true (hash-ref (replace handler "doc-1" 2 source) 'ok))
    (define response (get-view handler "doc-1" 1))
    (check-false (hash-ref response 'ok))
    (check-equal? (hash-ref (car (hash-ref response 'diagnostics)) 'code)
                  "ARBOR3202"))))

(module+ test
  (unless (zero? (run-tests view-protocol-tests))
    (error 'view-protocol-test "test failures")))
