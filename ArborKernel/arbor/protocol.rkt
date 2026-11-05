#lang racket/base

(require file/sha1
         json
         racket/list
         racket/match
         racket/set
         racket/string
         "datalog-adapter.rkt"
         "effects.rkt"
         "facts.rkt"
         "mutations.rkt"
         "outline.rkt")

(provide handle-request
         make-request-handler
         protocol-version)

(define protocol-version "arbor-kernel/1")
(define maximum-expression-nodes 512)
(define maximum-expression-depth 64)
(define maximum-derived-string-bytes (* 1024 1024))
(define maximum-derived-integer-bits 4096)
(define maximum-completed-effects 128)
(define maximum-pending-effects 64)

(struct kernel-state
  (documents theory world-revision pending-effects pending-mutations
             completed-effects completed-effect-order)
  #:mutable #:transparent)
(struct pending-effect
  (document-id revision producer-id mode generation input-hash descriptor)
  #:transparent)
(struct pending-mutation
  (document-id revision producer-id mode generation input-hash descriptor candidate-source)
  #:transparent)

(define missing-value (gensym 'missing))

(define (object-ref object key [default missing-value])
  (cond
    [(and (hash? object) (hash-has-key? object key)) (hash-ref object key)]
    [(eq? default missing-value)
     (raise-user-error 'arbor-kernel (format "missing required field: ~a" key))]
    [else default]))

(define (request-id request)
  (define candidate (and (hash? request) (object-ref request 'id "")))
  (if (string? candidate) candidate ""))

(define (failure-response request code message)
  (hasheq 'protocol protocol-version
          'id (request-id request)
          'ok #f
          'revision 0
          'blocks '()
          'patches '()
          'queries '()
          'diagnostics (list (diagnostic "error" code message))))

(define (make-request-handler)
  (define state
    (kernel-state (make-hash) (make-arbor-theory) 0
                  (make-hash) (make-hash) (make-hash) '()))
  (lambda (request)
    (with-handlers ([exn:fail?
                     (lambda (error)
                       (failure-response request "ARBOR0001" (exn-message error)))])
      (unless (hash? request)
        (raise-user-error 'arbor-kernel "request must be a JSON object"))
      (unless (equal? (object-ref request 'protocol #f) protocol-version)
        (raise-user-error 'arbor-kernel
                          (format "unsupported protocol; expected ~a" protocol-version)))
      (case (string->symbol (object-ref request 'op ""))
        [(evaluate) (handle-evaluate request)]
        [(document/replace) (handle-document-replace state request)]
        [(query/run) (handle-query-run state request)]
        [(view/get) (handle-view-get state request)]
        [(producer/run) (handle-producer-run state request)]
        [(intent/apply) (handle-intent-apply state request)]
        [(effect/complete) (handle-effect-complete state request)]
        [(effect/cancel) (handle-effect-cancel state request)]
        [(mutation/complete) (handle-mutation-complete state request)]
        [else (raise-user-error 'arbor-kernel "unsupported operation")]))))

(define handle-request (make-request-handler))

(define (request-document request)
  (define document (object-ref request 'document))
  (unless (hash? document)
    (raise-user-error 'arbor-kernel "document must be a JSON object"))
  document)

(define (document-fields request #:id? [needs-id? #f])
  (define document (request-document request))
  (define document-id
    (object-ref document 'id
                (if needs-id? #f (object-ref document 'path "Untitled.outline"))))
  (define path (object-ref document 'path "Untitled.outline"))
  (define revision (object-ref document 'revision 0))
  (define source (object-ref document 'source ""))
  (when (and needs-id? (not (string? document-id)))
    (raise-user-error 'arbor-kernel "document.id must be a string"))
  (unless (string? path)
    (raise-user-error 'arbor-kernel "document.path must be a string"))
  (unless (exact-nonnegative-integer? revision)
    (raise-user-error 'arbor-kernel "document.revision must be a non-negative integer"))
  (unless (string? source)
    (raise-user-error 'arbor-kernel "document.source must be a string"))
  (when (> (bytes-length (string->bytes/utf-8 source)) maximum-source-bytes)
    (raise-user-error 'arbor-kernel
                      (format "document exceeds the ~a byte kernel limit" maximum-source-bytes)))
  (values document-id path revision source))

(define (handle-evaluate request)
  (define-values (_document-id path revision source) (document-fields request))
  (define previous-derived-uids
    (let ([candidate (object-ref request 'previousDerivedUIDs '())])
      (if (and (list? candidate) (andmap string? candidate)) candidate '())))
  (define-values (blocks parse-diagnostics) (parse-outline source))
  (define-values (patches queries evaluation-diagnostics)
    (evaluate-outline blocks revision previous-derived-uids))
  (define diagnostics (append parse-diagnostics evaluation-diagnostics))
  (define ok?
    (not (ormap (lambda (item) (equal? (hash-ref item 'severity) "error")) diagnostics)))

  (hasheq 'protocol protocol-version
          'id (request-id request)
          'ok ok?
          'revision revision
          'document (hasheq 'path path)
          'blocks (map block->jsexpr blocks)
          'patches patches
          'queries queries
          'diagnostics diagnostics))

(define (handle-document-replace state request)
  (define started (current-inexact-milliseconds))
  (define-values (document-id path revision source)
    (document-fields request #:id? #t))
  (define previous (hash-ref (kernel-state-documents state) document-id #f))
  (cond
    [(and previous (< revision (compiled-document-revision previous)))
     (log-replace request document-id revision started 0 "stale")
     (revision-failure state request "document/replace" revision
                       (compiled-document-revision previous) "ARBOR3002"
                       "Document revision is older than the accepted revision.")]
    [(and previous (= revision (compiled-document-revision previous)))
     (if (and (equal? path (compiled-document-path previous))
              (equal? source (compiled-document-source previous)))
         (begin
           (log-replace request document-id revision started
                        (length (compiled-document-facts previous)) "idempotent")
           (replace-response state request previous "idempotent"))
         (begin
           (log-replace request document-id revision started 0 "conflict")
           (operation-failure state request "document/replace" revision "ARBOR3003"
                              "Document revision already names different source.")))]
    [else
     (define compiled (compile-document document-id path revision source))
     (define facts (compiled-document-facts compiled))
     (cond
       [(has-errors? (compiled-document-diagnostics compiled))
        (log-replace request document-id revision started (length facts) "invalid")
        (hasheq 'protocol protocol-version
                'id (request-id request)
                'op "document/replace"
                'ok #f
                'revision revision
                'worldRevision (kernel-state-world-revision state)
                'document (hasheq 'id document-id 'path path)
                'factCount (length facts)
                'queryIDs '()
                'diagnostics (compiled-document-diagnostics compiled))]
       [else
        (define candidate-documents (hash-copy (kernel-state-documents state)))
        (hash-set! candidate-documents document-id compiled)
        (define collision (find-block-collision candidate-documents))
        (if collision
            (begin
              (log-replace request document-id revision started (length facts) "collision")
              (operation-failure
               state request "document/replace" revision "ARBOR3004"
               (format "Block UID occurs in more than one document: ~a" collision)))
            (let ([candidate-theory
                   (make-arbor-theory
                    (append-map compiled-document-facts
                                (documents-in-order candidate-documents)))])
              (set-kernel-state-documents! state candidate-documents)
              (set-kernel-state-theory! state candidate-theory)
              (set-kernel-state-world-revision!
               state (add1 (kernel-state-world-revision state)))
              (log-replace request document-id revision started (length facts) "ok")
              (replace-response state request compiled "replaced")))])]))

(define (replace-response state request compiled outcome)
  (hasheq 'protocol protocol-version
          'id (request-id request)
          'op "document/replace"
          'ok #t
          'outcome outcome
          'revision (compiled-document-revision compiled)
          'worldRevision (kernel-state-world-revision state)
          'document (hasheq 'id (compiled-document-id compiled)
                            'path (compiled-document-path compiled))
          'factCount (length (compiled-document-facts compiled))
          'queryIDs (map query-definition-id (compiled-document-queries compiled))
          'diagnostics (compiled-document-diagnostics compiled)))

(define (handle-query-run state request)
  (define started (current-inexact-milliseconds))
  (define document-id (object-ref request 'documentID))
  (define revision (object-ref request 'revision))
  (define query-id (object-ref request 'queryID))
  (define raw-arguments (object-ref request 'arguments (hasheq)))
  (unless (string? document-id)
    (raise-user-error 'arbor-kernel "documentID must be a string"))
  (unless (exact-nonnegative-integer? revision)
    (raise-user-error 'arbor-kernel "revision must be a non-negative integer"))
  (unless (string? query-id)
    (raise-user-error 'arbor-kernel "queryID must be a string"))
  (define document (hash-ref (kernel-state-documents state) document-id #f))
  (cond
    [(not document)
     (log-query request document-id revision query-id started 0 "missing-document")
     (operation-failure state request "query/run" revision "ARBOR3101"
                        "Document has not been accepted.")]
    [(not (= revision (compiled-document-revision document)))
     (log-query request document-id revision query-id started 0 "stale")
     (revision-failure state request "query/run" revision
                       (compiled-document-revision document) "ARBOR3102"
                       "Query revision does not match the accepted document revision.")]
    [else
     (define definition
       (findf (lambda (candidate)
                (equal? query-id (query-definition-id candidate)))
              (compiled-document-queries document)))
     (if (not definition)
         (begin
           (log-query request document-id revision query-id started 0 "missing-query")
           (operation-failure state request "query/run" revision "ARBOR3103"
                              "Query block does not exist at this revision."))
         (with-handlers ([exn:fail?
                          (lambda (error)
                            (log-query request document-id revision query-id started 0 "invalid")
                            (operation-failure state request "query/run" revision "ARBOR3104"
                                               (exn-message error)))])
           (define arguments (checked-arguments definition raw-arguments))
           (define rows (run-query (kernel-state-theory state) definition arguments))
           (log-query request document-id revision query-id started (length rows) "ok")
           (hasheq 'protocol protocol-version
                   'id (request-id request)
                   'op "query/run"
                   'ok #t
                   'revision revision
                   'worldRevision (kernel-state-world-revision state)
                   'queryID query-id
                   'columns (map symbol->string (query-definition-columns definition))
                   'rows rows
                   'diagnostics '())))]))

(define (handle-view-get state request)
  (define started (current-inexact-milliseconds))
  (define document-id (object-ref request 'documentID))
  (define revision (object-ref request 'revision))
  (define query-id (object-ref request 'queryID #f))
  (define raw-arguments (object-ref request 'arguments (hasheq)))
  (unless (string? document-id)
    (raise-user-error 'arbor-kernel "documentID must be a string"))
  (unless (exact-nonnegative-integer? revision)
    (raise-user-error 'arbor-kernel "revision must be a non-negative integer"))
  (unless (or (not query-id) (string? query-id))
    (raise-user-error 'arbor-kernel "queryID must be a string"))
  (define document (hash-ref (kernel-state-documents state) document-id #f))
  (cond
    [(not document)
     (log-view request document-id revision query-id started 0 0 "missing-document")
     (operation-failure state request "view/get" revision "ARBOR3201"
                        "Document has not been accepted.")]
    [(not (= revision (compiled-document-revision document)))
     (log-view request document-id revision query-id started 0 0 "stale")
     (revision-failure state request "view/get" revision
                       (compiled-document-revision document) "ARBOR3202"
                       "View revision does not match the accepted document revision.")]
    [else
     (with-handlers ([exn:fail?
                      (lambda (error)
                        (log-view request document-id revision query-id started 0 0 "invalid")
                        (operation-failure state request "view/get" revision "ARBOR3204"
                                           (exn-message error)))])
       (define views
         (if query-id
             (list (selected-query-view state document query-id raw-arguments))
             (append (expression-views document)
                     (document-query-views state document))))
       (define row-count
         (for/sum ([view (in-list views)])
           (length (hash-ref view 'rows '()))))
       (log-view request document-id revision query-id started
                 (length views) row-count "ok")
       (hasheq 'protocol protocol-version
               'id (request-id request)
               'op "view/get"
               'ok #t
               'revision revision
               'worldRevision (kernel-state-world-revision state)
               'document (hasheq 'id document-id
                                 'path (compiled-document-path document))
               'views views
               'diagnostics '()))]))

(define (handle-producer-run state request)
  (define started (current-inexact-milliseconds))
  (define document-id (object-ref request 'documentID))
  (define revision (object-ref request 'revision))
  (define producer-id (object-ref request 'producerID))
  (define mode (object-ref request 'mode "refresh"))
  (define raw-arguments (object-ref request 'arguments (hasheq)))
  (unless (string? document-id)
    (raise-user-error 'arbor-kernel "documentID must be a string"))
  (unless (exact-nonnegative-integer? revision)
    (raise-user-error 'arbor-kernel "revision must be a non-negative integer"))
  (unless (string? producer-id)
    (raise-user-error 'arbor-kernel "producerID must be a string"))
  (unless (member mode '("refresh" "append"))
    (raise-user-error 'arbor-kernel "mode must be refresh or append"))
  (define document (hash-ref (kernel-state-documents state) document-id #f))
  (cond
    [(not document)
     (log-producer request document-id revision producer-id mode started 0 "missing-document")
     (operation-failure state request "producer/run" revision "ARBOR3301"
                        "Document has not been accepted.")]
    [(not (= revision (compiled-document-revision document)))
     (log-producer request document-id revision producer-id mode started 0 "stale")
     (revision-failure state request "producer/run" revision
                       (compiled-document-revision document) "ARBOR3302"
                       "Producer revision does not match the accepted document revision.")]
    [else
     (define completed
       (hash-ref (kernel-state-completed-effects state) (request-id request) #f))
     (if completed
         (if (and (equal? document-id (hash-ref completed 'documentID #f))
                  (= revision (hash-ref completed 'revision -1))
                  (equal? producer-id (hash-ref completed 'producerID #f))
                  (equal? mode (hash-ref completed 'mode #f)))
             (hash-set completed 'id (request-id request))
             (operation-failure state request "producer/run" revision "ARBOR3305"
                                "Producer request ID already belongs to another completed run."))
         (run-current-producer state request document document-id revision
                               producer-id mode raw-arguments started))]))

(define (run-current-producer state request document document-id revision
                              producer-id mode raw-arguments started)
  (define producer
    (findf (lambda (block)
             (and (arbor-block-stable-uid? block)
                  (equal? producer-id (arbor-block-uid block))))
           (compiled-document-blocks document)))
  (if (not producer)
      (begin
        (log-producer request document-id revision producer-id mode started 0 "missing-producer")
        (operation-failure state request "producer/run" revision "ARBOR3303"
                           "Producer block does not exist at this revision."))
      (with-handlers ([exn:fail?
                       (lambda (error)
                         (log-producer request document-id revision producer-id mode
                                       started 0 "invalid")
                         (operation-failure state request "producer/run" revision "ARBOR3304"
                                            (exn-message error)))])
        (define body (arbor-block-body producer))
        (define query-definition
          (findf (lambda (definition)
                   (equal? producer-id (query-definition-id definition)))
                 (compiled-document-queries document)))
        (define kind
          (cond
            [(string-prefix? body "=") "expression"]
            [query-definition "query"]
            [(string-prefix? body "!") "effect"]
            [else
             (raise-user-error 'arbor-kernel
                               "The selected block is not an expression, query, or effect.")]))
        (define arguments
          (and query-definition
               (checked-arguments query-definition raw-arguments)))
        (define generation (next-generation document producer-id))
        (define input-hash
          (sha1
           (open-input-string
            (if arguments
                (format "~s\n~s"
                        body
                        (sort (hash->list arguments) symbol<? #:key car))
                body))))
        (if (equal? kind "effect")
            (if (outline-effect? body)
                (prepare-mutation state request document document-id revision producer-id mode
                                  generation body raw-arguments started)
                (prepare-effect state request document document-id revision producer-id mode
                                generation body raw-arguments started))
            (let ([results
                   (if (equal? kind "expression")
                       (expression-materialization document producer)
                       (query-materialization state query-definition arguments))])
              (log-producer request document-id revision producer-id mode started
                            (length results) "ok")
              (producer-response state request document-id revision producer-id kind mode
                                 generation input-hash results))))))

(define (prepare-effect state request document document-id revision producer-id mode
                        generation body raw-arguments started)
  (define execution-id (request-id request))
  (define existing (hash-ref (kernel-state-pending-effects state) execution-id #f))
  (when (and existing
             (not (and (equal? document-id (pending-effect-document-id existing))
                       (= revision (pending-effect-revision existing))
                       (equal? producer-id (pending-effect-producer-id existing))
                       (equal? mode (pending-effect-mode existing)))))
    (raise-user-error 'arbor-kernel "Effect execution ID is already pending for another run."))
  (define descriptor
    (if existing
        (pending-effect-descriptor existing)
        (effect-plan->jsexpr
         (parse-effect-call document-id producer-id body
                            (block-attribute-defaults
                             (compiled-document-blocks document) producer-id)
                            raw-arguments execution-id)
         execution-id)))
  (define input-hash
    (if existing
        (pending-effect-input-hash existing)
        (sha1 (open-input-string
               (format "~s\n~s" body (hash-ref descriptor 'arguments))))))
  (unless existing
    (when (>= (hash-count (kernel-state-pending-effects state)) maximum-pending-effects)
      (raise-user-error 'arbor-kernel "Too many effects are waiting for host completion."))
    (hash-set! (kernel-state-pending-effects state)
               execution-id
               (pending-effect document-id revision producer-id mode
                               generation input-hash descriptor)))
  (log-producer request document-id revision producer-id mode started 0 "effect-request")
  (hasheq 'protocol protocol-version
          'id execution-id
          'op "producer/run"
          'ok #t
          'status "effect-request"
          'revision revision
          'worldRevision (kernel-state-world-revision state)
          'documentID document-id
          'producerID producer-id
          'kind "effect"
          'mode mode
          'effect descriptor
          'diagnostics '()))

(define (producer-response state request document-id revision producer-id kind mode
                           generation input-hash results)
  (hasheq 'protocol protocol-version
          'id (request-id request)
          'op "producer/run"
          'ok #t
          'revision revision
          'worldRevision (kernel-state-world-revision state)
          'documentID document-id
          'producerID producer-id
          'kind kind
          'mode mode
          'generation generation
          'inputHash input-hash
          'results results
          'diagnostics '()))

(define (outline-effect? body)
  (define datum (read-effect-datum (string-trim (substring body 1))))
  (and (list? datum) (pair? datum) (symbol? (car datum))
       (string-prefix? (symbol->string (car datum)) "outline/")))

(define (prepare-mutation state request document document-id revision producer-id mode
                          generation body raw-arguments started)
  (define execution-id (request-id request))
  (define existing (hash-ref (kernel-state-pending-mutations state) execution-id #f))
  (when (and existing
             (not (and (equal? document-id (pending-mutation-document-id existing))
                       (= revision (pending-mutation-revision existing))
                       (equal? producer-id (pending-mutation-producer-id existing))
                       (equal? mode (pending-mutation-mode existing)))))
    (raise-user-error 'arbor-kernel
                      "Outline transaction execution ID is already pending for another run."))
  (if existing
      (mutation-request-response state execution-id document-id revision producer-id mode
                                 (pending-mutation-descriptor existing))
      (let* ([defaults (block-attribute-defaults
                        (compiled-document-blocks document) producer-id)]
             [operations (parse-mutation-operations
                          state document producer-id body defaults raw-arguments)]
             [input-hash
              (sha1 (open-input-string (format "~s\n~s" body operations)))]
             [candidate
              (apply-source-operations document operations producer-id mode generation
                                       input-hash (kernel-state-world-revision state))]
             [candidate-source (compiled-document-source candidate)]
             [descriptor
              (mutation-descriptor document producer-id execution-id operations
                                   candidate-source)])
        (if (equal? candidate-source (compiled-document-source document))
            (begin
              (log-producer request document-id revision producer-id mode started 0 "idempotent")
              (hash-set
               (hash-set
                (producer-response state request document-id revision producer-id "mutation" mode
                                   generation input-hash '())
                'outcome "idempotent")
               'document
               (hasheq 'id document-id
                       'path (compiled-document-path document)
                       'revision revision
                       'source candidate-source)))
            (begin
              (when (>= (hash-count (kernel-state-pending-mutations state))
                        maximum-pending-effects)
                (raise-user-error 'arbor-kernel
                                  "Too many outline transactions are waiting for host completion."))
              (hash-set! (kernel-state-pending-mutations state)
                         execution-id
                         (pending-mutation document-id revision producer-id mode generation
                                           input-hash descriptor candidate-source))
              (log-producer request document-id revision producer-id mode started 0 "mutation-request")
              (mutation-request-response state execution-id document-id revision producer-id mode
                                         descriptor))))))

(define (mutation-request-response state execution-id document-id revision producer-id mode descriptor)
  (hasheq 'protocol protocol-version
          'id execution-id
          'op "producer/run"
          'ok #t
          'status "mutation-request"
          'revision revision
          'worldRevision (kernel-state-world-revision state)
          'documentID document-id
          'producerID producer-id
          'kind "mutation"
          'mode mode
          'mutation descriptor
          'diagnostics '()))

(define (mutation-descriptor document producer-id execution-id operations candidate-source)
  (define destructive? (and (ormap source-operation-destructive? operations) #t))
  (define summaries (map source-operation-summary operations))
  (define path (compiled-document-path document))
  (hasheq 'executionID execution-id
          'summary (take summaries (min 12 (length summaries)))
          'operationCount (length operations)
          'destructive destructive?
          'capability
          (hasheq 'id (sha1 (open-input-string
                             (format "~s" (list (compiled-document-id document)
                                                 producer-id operations))))
                  'kind "outline.write"
                  'resource path
                  'summary (format "Apply ~a outline change~a to ~a"
                                   (length operations)
                                   (if (= (length operations) 1) "" "s") path))
          'expectedSource (compiled-document-source document)
          'document (hasheq 'id (compiled-document-id document)
                            'path path
                            'revision (add1 (compiled-document-revision document))
                            'source candidate-source)))

(define (parse-mutation-operations state document producer-id body defaults supplied)
  (define datum (read-effect-datum (string-trim (substring body 1))))
  (define handler (and (list? datum) (pair? datum) (symbol? (car datum)) (car datum)))
  (unless handler (raise-user-error 'arbor-kernel "An outline transaction must be a handler call."))
  (define forms
    (if (eq? handler 'outline/transact)
        (cdr datum)
        (list (cons (string->symbol
                     (substring (symbol->string handler) (string-length "outline/")))
                    (cdr datum)))))
  (when (> (length forms) 100)
    (raise-user-error 'arbor-kernel "An outline transaction may contain at most 100 operations."))
  (define operations
    (append*
     (for/list ([form (in-list forms)] [index (in-naturals)])
       (parse-mutation-operation state document producer-id form index defaults supplied))))
  (when (> (length operations) 100)
    (raise-user-error 'arbor-kernel "Query expansion produced more than 100 outline operations."))
  operations)

(define (parse-mutation-operation state document producer-id form index defaults supplied)
  (unless (and (list? form) (pair? form) (symbol? (car form)))
    (raise-user-error 'arbor-kernel "Each outline transaction operation must be a list."))
  (define kind (car form))
  (define arguments (cdr form))
  (define (targets value)
    (resolve-mutation-targets state document producer-id value supplied))
  (define (text value)
    (define resolved (resolve-effect-datum value defaults supplied))
    (unless (string? resolved)
      (raise-user-error 'arbor-kernel "Outline transaction text must resolve to a string."))
    resolved)
  (define (result-key target-id)
    (format "m:~a:~a" index
            (substring (sha1 (open-input-string target-id)) 0 10)))
  (case kind
    [(insert-child insert-after)
     (unless (= (length arguments) 2)
       (raise-user-error 'arbor-kernel (format "~a needs a target and text." kind)))
     (for/list ([target-id (in-list (targets (car arguments)))])
       (source-operation kind target-id (text (cadr arguments)) #f (result-key target-id)))]
    [(set-text)
     (unless (= (length arguments) 2)
       (raise-user-error 'arbor-kernel "set-text needs a target and text."))
     (for/list ([target-id (in-list (targets (car arguments)))])
       (source-operation 'set-text target-id (text (cadr arguments)) #f #f))]
    [(add-tag)
     (unless (= (length arguments) 2)
       (raise-user-error 'arbor-kernel "add-tag needs a target and tag."))
     (define tag (text (cadr arguments)))
     (unless (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9_/-]*$" tag)
       (raise-user-error 'arbor-kernel "add-tag needs a tag without #."))
     (for/list ([target-id (in-list (targets (car arguments)))])
       (source-operation 'add-tag target-id tag #f #f))]
    [(delete)
     (unless (= (length arguments) 1)
       (raise-user-error 'arbor-kernel "delete needs one target."))
     (for/list ([target-id (in-list (targets (car arguments)))])
       (source-operation 'delete target-id #f #f #f))]
    [(move)
     (unless (= (length arguments) 2)
       (raise-user-error 'arbor-kernel "move needs a target and destination."))
     (define destinations (targets (cadr arguments)))
     (unless (= (length destinations) 1)
       (raise-user-error 'arbor-kernel "move needs exactly one destination block."))
     (for/list ([target-id (in-list (targets (car arguments)))])
       (source-operation 'move target-id #f (car destinations) #f))]
    [else
     (raise-user-error 'arbor-kernel
                       (format "Outline transaction operation is not available: ~a" kind))]))

(define (resolve-mutation-targets state document producer-id target supplied)
  (define ids
    (match target
      [(list 'self) (list producer-id)]
      [(list 'block (? string? uid)) (list uid)]
      [(list 'query (? string? query-id))
       (define definition
         (findf (lambda (candidate) (equal? query-id (query-definition-id candidate)))
                (compiled-document-queries document)))
       (unless definition
         (raise-user-error 'arbor-kernel (format "Outline transaction query does not exist: ~a" query-id)))
       (unless (query-block-column? definition (car (query-definition-columns definition)))
         (raise-user-error 'arbor-kernel "An outline transaction query must return a block in its first column."))
       (define query-arguments
         (for/fold ([filtered (hasheq)]) ([name (in-list (query-definition-inputs definition))])
           (cond
             [(hash-has-key? supplied name)
              (hash-set filtered name (hash-ref supplied name))]
             [(hash-has-key? supplied (symbol->string name))
              (hash-set filtered name (hash-ref supplied (symbol->string name)))]
             [else filtered])))
       (map car (run-query (kernel-state-theory state) definition
                           (checked-arguments definition query-arguments)))]
      [(? string? uid) (list uid)]
      [_ (raise-user-error 'arbor-kernel
                           "Outline targets use (self), (block \"uid\"), or (query \"uid\").")]))
  (define unique (remove-duplicates ids equal?))
  (for ([uid (in-list unique)])
    (unless (string? uid)
      (raise-user-error 'arbor-kernel "An outline transaction query returned a non-block value."))
    (define source (find-source-block state uid))
    (unless (and source
                 (equal? (compiled-document-id (car source)) (compiled-document-id document)))
      (raise-user-error 'arbor-kernel
                        (format "Outline transaction target is outside this document: ~a" uid))))
  unique)

(define (handle-effect-complete state request)
  (define execution-id (object-ref request 'executionID))
  (unless (string? execution-id)
    (raise-user-error 'arbor-kernel "effect/complete needs an executionID."))
  (define completed (hash-ref (kernel-state-completed-effects state) execution-id #f))
  (if completed
      (hash-set completed 'id (request-id request))
      (let ([pending (hash-ref (kernel-state-pending-effects state) execution-id #f)])
        (unless pending
          (raise-user-error 'arbor-kernel "Effect execution is not pending."))
        (define outcome (object-ref request 'outcome))
        (unless (hash? outcome)
          (raise-user-error 'arbor-kernel "effect/complete needs an outcome."))
        (if (object-ref outcome 'ok #f)
            (with-handlers ([exn:fail?
                             (lambda (error)
                               (hash-remove! (kernel-state-pending-effects state) execution-id)
                               (raise error))])
              (complete-effect state request execution-id pending outcome))
            (begin
              (hash-remove! (kernel-state-pending-effects state) execution-id)
              (operation-failure state request "effect/complete"
                                 (pending-effect-revision pending) "ARBOR3504"
                                 (object-ref outcome 'message
                                             "Effect execution failed.")))))))

(define (complete-effect state request execution-id pending outcome)
  (define value (object-ref outcome 'value missing-value))
  (unless (and (not (eq? value missing-value)) (effect-value? value))
    (raise-user-error 'arbor-kernel "A successful effect needs a typed value."))
  (when (> (bytes-length (jsexpr->bytes value)) maximum-derived-string-bytes)
    (raise-user-error 'arbor-kernel "Effect output exceeds the kernel value limit."))
  (define document
    (hash-ref (kernel-state-documents state) (pending-effect-document-id pending) #f))
  (unless (and document
               (= (compiled-document-revision document)
                  (pending-effect-revision pending)))
    (raise-user-error 'arbor-kernel "The producer changed while its effect was running."))
  (define response
    (hash-set
     (hash-set
      (producer-response
       state request
       (pending-effect-document-id pending)
       (pending-effect-revision pending)
       (pending-effect-producer-id pending)
       "effect"
       (pending-effect-mode pending)
       (pending-effect-generation pending)
       (pending-effect-input-hash pending)
       (effect-results value))
      'effect
      (pending-effect-descriptor pending))
     'op "effect/complete"))
  (hash-remove! (kernel-state-pending-effects state) execution-id)
  (remember-completed-effect! state execution-id response)
  response)

(define (handle-effect-cancel state request)
  (define execution-id (object-ref request 'executionID))
  (unless (string? execution-id)
    (raise-user-error 'arbor-kernel "effect/cancel needs an executionID."))
  (define pending (hash-ref (kernel-state-pending-effects state) execution-id #f))
  (when pending (hash-remove! (kernel-state-pending-effects state) execution-id))
  (define mutation (hash-ref (kernel-state-pending-mutations state) execution-id #f))
  (when mutation (hash-remove! (kernel-state-pending-mutations state) execution-id))
  (hasheq 'protocol protocol-version
          'id (request-id request)
          'op "effect/cancel"
          'ok #t
          'outcome (if (or pending mutation) "cancelled" "idempotent")
          'revision (cond [pending (pending-effect-revision pending)]
                          [mutation (pending-mutation-revision mutation)]
                          [else 0])
          'worldRevision (kernel-state-world-revision state)
          'diagnostics '()))

(define (handle-mutation-complete state request)
  (define execution-id (object-ref request 'executionID))
  (unless (string? execution-id)
    (raise-user-error 'arbor-kernel "mutation/complete needs an executionID."))
  (define completed (hash-ref (kernel-state-completed-effects state) execution-id #f))
  (if completed
      (hash-set completed 'id (request-id request))
      (let ([pending (hash-ref (kernel-state-pending-mutations state) execution-id #f)])
        (unless pending
          (raise-user-error 'arbor-kernel "Outline transaction is not pending."))
        (define outcome (object-ref request 'outcome))
        (unless (hash? outcome)
          (raise-user-error 'arbor-kernel "mutation/complete needs an outcome."))
        (if (object-ref outcome 'ok #f)
            (with-handlers ([exn:fail?
                             (lambda (error)
                               (hash-remove! (kernel-state-pending-mutations state) execution-id)
                               (raise error))])
              (complete-mutation state request execution-id pending))
            (begin
              (hash-remove! (kernel-state-pending-mutations state) execution-id)
              (operation-failure state request "mutation/complete"
                                 (pending-mutation-revision pending) "ARBOR3604"
                                 (object-ref outcome 'message
                                             "Outline transaction was not applied.")))))))

(define (complete-mutation state request execution-id pending)
  (define document
    (hash-ref (kernel-state-documents state) (pending-mutation-document-id pending) #f))
  (unless (and document
               (= (compiled-document-revision document)
                  (add1 (pending-mutation-revision pending)))
               (equal? (compiled-document-source document)
                       (pending-mutation-candidate-source pending)))
    (raise-user-error 'arbor-kernel
                      "The accepted document does not match the planned outline transaction."))
  (define response
    (hash-set
     (hash-set
      (producer-response state request
                         (compiled-document-id document)
                         (compiled-document-revision document)
                         (pending-mutation-producer-id pending)
                         "mutation"
                         (pending-mutation-mode pending)
                         (pending-mutation-generation pending)
                         (pending-mutation-input-hash pending)
                         '())
      'op "mutation/complete")
     'document
     (hasheq 'id (compiled-document-id document)
             'path (compiled-document-path document)
             'revision (compiled-document-revision document)
             'source (compiled-document-source document))))
  (hash-remove! (kernel-state-pending-mutations state) execution-id)
  (remember-completed-effect! state execution-id response)
  response)

(define (remember-completed-effect! state execution-id response)
  (define order (kernel-state-completed-effect-order state))
  (when (>= (length order) maximum-completed-effects)
    (hash-remove! (kernel-state-completed-effects state) (car order))
    (set! order (cdr order)))
  (hash-set! (kernel-state-completed-effects state) execution-id response)
  (set-kernel-state-completed-effect-order! state (append order (list execution-id))))

(define (next-generation document producer-id)
  (add1
   (for/fold ([generation 0]) ([block (in-list (compiled-document-blocks document))])
     (define computation (arbor-block-computation block))
     (if (and computation
              (equal? producer-id (arbor-computation-producer-id computation)))
         (max generation (arbor-computation-generation computation))
         generation))))

(define (handle-intent-apply state request)
  (define document-id (object-ref request 'documentID))
  (define revision (object-ref request 'revision))
  (define result-id (object-ref request 'resultID))
  (define intent (object-ref request 'intent))
  (unless (and (string? document-id) (exact-nonnegative-integer? revision)
               (string? result-id) (hash? intent))
    (raise-user-error 'arbor-kernel "intent/apply needs a document, revision, result, and intent."))
  (unless (equal? (object-ref intent 'op #f) "set-text")
    (raise-user-error 'arbor-kernel "Only the set-text intent is available."))
  (define text (object-ref intent 'text #f))
  (unless (string? text)
    (raise-user-error 'arbor-kernel "set-text needs string text."))
  (when (> (bytes-length (string->bytes/utf-8 text)) maximum-derived-string-bytes)
    (raise-user-error 'arbor-kernel "set-text exceeds the kernel string limit."))
  (define result-document (hash-ref (kernel-state-documents state) document-id #f))
  (cond
    [(not result-document)
     (operation-failure state request "intent/apply" revision "ARBOR3401"
                        "Document has not been accepted.")]
    [(not (= revision (compiled-document-revision result-document)))
     (revision-failure state request "intent/apply" revision
                       (compiled-document-revision result-document) "ARBOR3402"
                       "Intent revision does not match the accepted document revision.")]
    [else
     (define result
       (findf (lambda (block) (equal? result-id (arbor-block-uid block)))
              (compiled-document-blocks result-document)))
     (define computation (and result (arbor-block-computation result)))
     (unless (and computation
                  (eq? (arbor-computation-state computation) 'live)
                  (eq? (arbor-computation-update-policy computation) 'source-text)
                  (arbor-computation-origin-block-id computation))
       (raise-user-error 'arbor-kernel "Result is not a live source-backed block."))
     (define source-pair
       (find-source-block state (arbor-computation-origin-block-id computation)))
     (unless source-pair
       (raise-user-error 'arbor-kernel "The source block no longer exists."))
     (define source-document (car source-pair))
     (define source-block (cdr source-pair))
     (when (arbor-block-computation source-block)
       (raise-user-error 'arbor-kernel "A managed result cannot be used as a writable source."))
     (define expected-source (compiled-document-source source-document))
     (define response
       (hasheq 'protocol protocol-version
               'id (request-id request)
               'op "intent/apply"
               'ok #t
               'revision revision
               'worldRevision (kernel-state-world-revision state)
               'origin (hasheq 'blockID (arbor-block-uid source-block)
                               'documentID (compiled-document-id source-document)
                               'path (compiled-document-path source-document))
               'text text
               'diagnostics '()))
     (if (equal? (arbor-block-body source-block) text)
         (hash-set response 'outcome "idempotent")
         (let ([candidate-source (replace-block-text expected-source source-block text)])
           (hash-set
            (hash-set response 'expectedSource expected-source)
            'document
            (hasheq 'id (compiled-document-id source-document)
                    'path (compiled-document-path source-document)
                    'revision (add1 (compiled-document-revision source-document))
                    'source candidate-source))))]))

(define (replace-block-text source block text)
  (define lines (regexp-split #px"\r?\n" source))
  (define depth (arbor-block-depth block))
  (define indentation (make-string (* 2 depth) #\space))
  (define text-lines (regexp-split #px"\r?\n" text))
  (define replacement
    (cons (format "~a- ~a~a^~a"
                  indentation
                  (car text-lines)
                  (if (string=? (car text-lines) "") "" " ")
                  (arbor-block-uid block))
          (for/list ([line (in-list (cdr text-lines))])
            (format "~a  |~a" indentation (if (string=? line "") "" (string-append " " line))))))
  (string-join
   (append (take lines (sub1 (arbor-block-line block)))
           replacement
           (drop lines (arbor-block-end-line block)))
   "\n"))

(define (expression-materialization document producer)
  (define-values (patches _queries diagnostics)
    (evaluate-outline (compiled-document-blocks document)
                      (compiled-document-revision document)
                      '()))
  (define patch
    (findf (lambda (candidate)
             (and (equal? (hash-ref candidate 'op) "set-derived")
                  (equal? (hash-ref candidate 'uid) (arbor-block-uid producer))))
           patches))
  (unless patch
    (define producer-diagnostic
      (findf (lambda (item)
               (= (hash-ref item 'line -1) (arbor-block-line producer)))
             diagnostics))
    (raise-user-error 'arbor-kernel
                      (if producer-diagnostic
                          (hash-ref producer-diagnostic 'message)
                          "Expression did not produce a value.")))
  (list (hasheq 'key "scalar" 'markdown (hash-ref patch 'display))))

(define (query-materialization state definition arguments)
  (define rows (run-query (kernel-state-theory state) definition arguments))
  (define block-columns
    (map (lambda (name) (query-block-column? definition name))
         (query-definition-columns definition)))
  (for/list ([row (in-list rows)])
    (define cells
      (for/list ([value (in-list row)]
                 [block-column? (in-list block-columns)])
        (query-cell state value block-column?)))
    (define origins
      (remove-duplicates
       (for/list ([cell (in-list cells)]
                  #:when (and (equal? (hash-ref cell 'kind) "block")
                              (string? (hash-ref cell 'documentID #f))))
         (hasheq 'blockID (hash-ref cell 'blockID)
                 'documentID (hash-ref cell 'documentID)
                 'path (hash-ref cell 'path)))
       equal?))
    (define result
      (hasheq 'key
              (sha1
               (open-input-string
                (jsexpr->string
                 (if (= (length origins) 1)
                     (list (hash-ref (car origins) 'blockID))
                     row))))
              'markdown (render-query-row definition cells)))
    (if (and (= (length origins) 1)
             (source-text-projection? definition))
        (hash-set (hash-set result 'origin (car origins))
                  'updatePolicy "source-text")
        result)))

(define (source-text-projection? definition)
  (match (and (query-definition-projection definition)
              (regexp-match #px"^\\{([A-Za-z][A-Za-z0-9_-]*)\\}$"
                            (query-definition-projection definition)))
    [(list _ name)
     (define text-name (string->symbol name))
     (for/or ([clause (in-list (query-definition-clauses definition))])
       (match clause
         [(list 'block-text (? query-variable? block) (? query-variable? text))
          (and (memq (query-variable-name block) (query-definition-columns definition))
               (eq? text-name (query-variable-name text)))]
         [_ #f]))]
    [_ #f]))

(define (render-query-row definition cells)
  (define projection (query-definition-projection definition))
  (if (not projection)
      (string-join (map (lambda (cell) (hash-ref cell 'display)) cells) " · ")
      (let ([bindings
             (for/hash ([name (in-list (query-definition-columns definition))]
                        [cell (in-list cells)])
               (values name (hash-ref cell 'display)))])
        (regexp-replace*
         #px"\\{([A-Za-z][A-Za-z0-9_-]*)\\}"
         projection
         (lambda (_ name) (hash-ref bindings (string->symbol name)))))))

(define (selected-query-view state document query-id raw-arguments)
  (define definition
    (findf (lambda (candidate)
             (equal? query-id (query-definition-id candidate)))
           (compiled-document-queries document)))
  (unless definition
    (raise-user-error 'arbor-kernel "Query block does not exist at this revision."))
  (query-view state definition (checked-arguments definition raw-arguments)))

(define (document-query-views state document)
  (for/list ([definition (in-list (compiled-document-queries document))])
    (if (query-inputs-complete? definition)
        (with-handlers ([exn:fail?
                         (lambda (error)
                           (query-error-view definition (exn-message error)))])
          (query-view state definition (checked-arguments definition (hasheq))))
        (hasheq 'id (format "query:~a" (query-definition-id definition))
                'producerID (query-definition-id definition)
                'kind "query"
                'presentation "table"
                'status "needs-arguments"
                'inputs (map symbol->string (query-definition-inputs definition))
                'columns (map symbol->string (query-definition-columns definition))
                'rows '()
                'diagnostics '()))))

(define (expression-views document)
  (define blocks (compiled-document-blocks document))
  (define revision (compiled-document-revision document))
  (define-values (patches _queries diagnostics)
    (evaluate-outline blocks revision '()))
  (define patches-by-uid
    (for/hash ([patch (in-list patches)]
               #:when (equal? (hash-ref patch 'op) "set-derived"))
      (values (hash-ref patch 'uid) patch)))
  (for/list ([block (in-list blocks)]
             #:when (and (arbor-block-stable-uid? block)
                         (string-prefix? (arbor-block-body block) "=")))
    (define uid (arbor-block-uid block))
    (define patch (hash-ref patches-by-uid uid #f))
    (if patch
        (hasheq 'id (format "expression:~a" uid)
                'producerID uid
                'kind "expression"
                'presentation "scalar"
                'status "ok"
                'value (hash-ref patch 'value)
                'display (hash-ref patch 'display)
                'diagnostics '())
        (let ([block-diagnostics
               (filter (lambda (item)
                         (= (hash-ref item 'line -1) (arbor-block-line block)))
                       diagnostics)])
          (hasheq 'id (format "expression:~a" uid)
                  'producerID uid
                  'kind "expression"
                  'presentation "scalar"
                  'status "error"
                  'display ""
                  'diagnostics block-diagnostics)))))

(define block-term-positions
  (hasheq 'block-page '(0)
          'block-parent '(0 1)
          'block-order '(0)
          'block-text '(0)
          'block-tag '(0)
          'block-attribute '(0)
          'block-link-page '(0)
          'block-ref-block '(0 1)
          'block-ancestor '(0 1)))

(define (query-block-column? definition name)
  (for/or ([clause (in-list (query-definition-clauses definition))])
    (define positions (hash-ref block-term-positions (car clause) '()))
    (for/or ([term (in-list (cdr clause))]
             [position (in-naturals)])
      (and (member position positions)
           (query-variable? term)
           (eq? name (query-variable-name term))))))

(define (query-view state definition arguments)
  (define rows (run-query (kernel-state-theory state) definition arguments))
  (define block-columns
    (map (lambda (name) (query-block-column? definition name))
         (query-definition-columns definition)))
  (define view-rows
    (for/list ([row (in-list rows)])
      (hasheq 'id (format "query:~a:~a"
                          (query-definition-id definition)
                          (sha1 (open-input-string (jsexpr->string row))))
              'cells
              (for/list ([value (in-list row)]
                         [block-column? (in-list block-columns)])
                (query-cell state value block-column?)))))
  (hasheq 'id (format "query:~a" (query-definition-id definition))
          'producerID (query-definition-id definition)
          'kind "query"
          'presentation (if (and (= (length block-columns) 1)
                                 (car block-columns))
                            "outline"
                            "table")
          'status "ok"
          'inputs (map symbol->string (query-definition-inputs definition))
          'columns (map symbol->string (query-definition-columns definition))
          'rows view-rows
          'diagnostics '()))

(define (query-error-view definition message)
  (hasheq 'id (format "query:~a" (query-definition-id definition))
          'producerID (query-definition-id definition)
          'kind "query"
          'presentation "table"
          'status "error"
          'inputs (map symbol->string (query-definition-inputs definition))
          'columns (map symbol->string (query-definition-columns definition))
          'rows '()
          'diagnostics
          (list (diagnostic "error" "ARBOR3205" message
                            #:line (query-definition-line definition)
                            #:column 3))))

(define (query-cell state value block-column?)
  (cond
    [(and block-column? (string? value))
     (define source (find-source-block state value))
     (if source
         (let ([document (car source)]
               [block (cdr source)])
           (hasheq 'kind "block"
                   'value value
                   'display (arbor-block-body block)
                   'blockID value
                   'documentID (compiled-document-id document)
                   'path (compiled-document-path document)
                   'markdown (arbor-block-body block)))
         (hasheq 'kind "block"
                 'value value
                 'display value
                 'blockID value
                 'documentID 'null
                 'path 'null
                 'markdown 'null))]
    [else
     (hasheq 'kind "scalar"
             'value value
             'display (display-value value))]))

(define (find-source-block state uid)
  (for*/first ([document (in-list (documents-in-order
                                    (kernel-state-documents state)))]
               [block (in-list (compiled-document-blocks document))]
               #:when (and (arbor-block-stable-uid? block)
                           (equal? uid (arbor-block-uid block))))
    (cons document block)))

(define (checked-arguments definition raw)
  (unless (hash? raw)
    (raise-user-error 'arbor-kernel "arguments must be a JSON object"))
  (define expected (query-definition-inputs definition))
  (define supplied (hash-keys raw))
  (unless (andmap symbol? supplied)
    (raise-user-error 'arbor-kernel "argument names must be strings"))
  (for ([name (in-list supplied)])
    (unless (memq name expected)
      (raise-user-error 'arbor-kernel (format "unexpected query argument: ~a" name)))
    (unless (json-scalar? (hash-ref raw name))
      (raise-user-error 'arbor-kernel (format "query argument must be scalar: ~a" name))))
  (define merged (hash-copy (query-definition-defaults definition)))
  (for ([(name value) (in-hash raw)])
    (hash-set! merged name value))
  (for ([name (in-list expected)])
    (unless (hash-has-key? merged name)
      (raise-user-error 'arbor-kernel (format "missing query argument: ~a" name))))
  (for/hash ([name (in-list expected)])
    (values name (hash-ref merged name))))

(define (query-inputs-complete? definition)
  (for/and ([name (in-list (query-definition-inputs definition))])
    (hash-has-key? (query-definition-defaults definition) name)))

(define (json-scalar? value)
  (or (string? value) (exact-integer? value) (boolean? value)))

(define (has-errors? diagnostics)
  (ormap (lambda (item) (equal? (hash-ref item 'severity) "error")) diagnostics))

(define (find-block-collision documents)
  (define owners (make-hash))
  (define collision #f)
  (for* ([document (in-list (documents-in-order documents))]
         [block (in-list (compiled-document-blocks document))]
         #:break collision
         #:when (arbor-block-stable-uid? block))
    (define uid (arbor-block-uid block))
    (define owner (hash-ref owners uid #f))
    (if (and owner (not (equal? owner (compiled-document-id document))))
        (set! collision uid)
        (hash-set! owners uid (compiled-document-id document))))
  collision)

(define (documents-in-order documents)
  (sort (hash-values documents)
        string<?
        #:key compiled-document-id))

(define (operation-failure state request op revision code message)
  (hasheq 'protocol protocol-version
          'id (request-id request)
          'op op
          'ok #f
          'revision revision
          'worldRevision (kernel-state-world-revision state)
          'diagnostics (list (diagnostic "error" code message))))

(define (revision-failure state request op revision accepted-revision code message)
  (hash-set (operation-failure state request op revision code message)
            'acceptedRevision accepted-revision))

(define (elapsed-ms started)
  (inexact->exact (round (- (current-inexact-milliseconds) started))))

(define (write-log fields)
  (write-json fields (current-error-port))
  (newline (current-error-port)))

(define (log-replace request document-id revision started fact-count outcome)
  (write-log
   (hasheq 'event "document/replace"
           'requestID (request-id request)
           'documentID document-id
           'revision revision
           'durationMs (elapsed-ms started)
           'factCount fact-count
           'outcome outcome)))

(define (log-query request document-id revision query-id started row-count outcome)
  (write-log
   (hasheq 'event "query/run"
           'requestID (request-id request)
           'documentID document-id
           'revision revision
           'queryID query-id
           'durationMs (elapsed-ms started)
           'rowCount row-count
           'outcome outcome)))

(define (log-view request document-id revision query-id started view-count row-count outcome)
  (write-log
   (hasheq 'event "view/get"
           'requestID (request-id request)
           'documentID document-id
           'revision revision
           'queryID (or query-id 'null)
           'durationMs (elapsed-ms started)
           'viewCount view-count
           'rowCount row-count
           'outcome outcome)))

(define (log-producer request document-id revision producer-id mode started result-count outcome)
  (write-log
   (hasheq 'event "producer/run"
           'requestID (request-id request)
           'documentID document-id
           'revision revision
           'producerID producer-id
           'mode mode
           'durationMs (elapsed-ms started)
           'resultCount result-count
           'outcome outcome)))

(define (evaluate-outline blocks revision previous-derived-uids)
  (define environment (make-hash))
  (define patches '())
  (define queries '())
  (define diagnostics '())
  (define current-derived-uids (mutable-set))

  (for ([block (in-list blocks)])
    (define body (arbor-block-body block))
    (define uid (arbor-block-uid block))
    (define computation (arbor-block-computation block))
    (cond
      [(and computation
            (memq (arbor-computation-state computation) '(live snapshot)))
       (void)]
      [(string-prefix? body "=")
       (when (arbor-block-stable-uid? block)
         (with-handlers ([exn:fail?
                          (lambda (error)
                            (set! diagnostics
                                  (cons (diagnostic "error" "ARBOR2001"
                                                    (exn-message error)
                                                    #:line (arbor-block-line block)
                                                    #:column 3)
                                        diagnostics)))])
           (define expression-text (string-trim (substring body 1)))
           (define expression (read-single-expression expression-text))
           (define value (evaluate-expression expression environment))
           (define json-value (json-safe-value value))
           (hash-set! environment uid value)
           (set-add! current-derived-uids uid)
           (set! patches
                 (cons (hasheq 'op "set-derived"
                               'uid uid
                               'revision revision
                               'value json-value
                               'display (display-value value))
                       patches))))]
      [else
       (define query-match (regexp-match #px"^\\{\\{query:\\s*(.*?)\\}\\}$" body))
       (when (and query-match (arbor-block-stable-uid? block))
         (set! queries
               (cons (hasheq 'uid uid
                             'revision revision
                             'source (string-trim (list-ref query-match 1)))
                     queries)))]))

  (for ([uid (in-list previous-derived-uids)]
        #:unless (set-member? current-derived-uids uid))
    (set! patches
          (cons (hasheq 'op "clear-derived"
                        'uid uid
                        'revision revision)
                patches)))
  (values (reverse patches) (reverse queries) (reverse diagnostics)))

(define (read-single-expression source)
  (when (string=? "" (string-trim source))
    (raise-user-error 'arbor "A computed block needs an expression after =."))
  (define input (open-input-string source))
  (define expression
    (parameterize ([read-accept-reader #f]
                   [read-accept-lang #f]
                   [read-accept-compiled #f]
                   [read-accept-graph #f])
      (read input)))
  (define trailing
    (parameterize ([read-accept-reader #f]
                   [read-accept-lang #f]
                   [read-accept-compiled #f]
                   [read-accept-graph #f])
      (read input)))
  (unless (eof-object? trailing)
    (raise-user-error 'arbor "A computed block must contain one expression."))
  expression)

(define (evaluate-expression expression environment)
  (define visited-nodes 0)

  (define (visit value depth)
    (set! visited-nodes (add1 visited-nodes))
    (when (> visited-nodes maximum-expression-nodes)
      (raise-user-error 'arbor "Expression is too large."))
    (when (> depth maximum-expression-depth)
      (raise-user-error 'arbor "Expression is nested too deeply."))
    (cond
      [(or (number? value) (string? value) (boolean? value)) value]
      [(symbol? value)
       (raise-user-error 'arbor (format "Bare symbol is not allowed: ~a" value))]
      [(list? value)
       (when (null? value)
         (raise-user-error 'arbor "An empty application is not allowed."))
       (define operator (car value))
       (define arguments (cdr value))
       (unless (symbol? operator)
         (raise-user-error 'arbor "The expression operator must be a symbol."))
       (case operator
         [(if)
          (unless (= (length arguments) 3)
            (raise-user-error 'arbor "if expects three arguments."))
          (if (truthy? (visit (car arguments) (add1 depth)))
              (visit (cadr arguments) (add1 depth))
              (visit (caddr arguments) (add1 depth)))]
         [(and)
          (for/fold ([result #t]) ([argument (in-list arguments)] #:break (not result))
            (truthy? (visit argument (add1 depth))))]
         [(or)
          (for/fold ([result #f]) ([argument (in-list arguments)] #:break result)
            (truthy? (visit argument (add1 depth))))]
         [(ref)
          (unless (and (= (length arguments) 1) (string? (car arguments)))
            (raise-user-error 'arbor "ref expects one string UID."))
          (hash-ref environment (car arguments)
                    (lambda ()
                      (raise-user-error 'arbor
                                        (format "Unknown or not-yet-computed UID: ~a" (car arguments)))))]
         [else
          (apply-primitive operator
                           (map (lambda (argument) (visit argument (add1 depth))) arguments))])]
      [else
       (raise-user-error 'arbor "Only numbers, strings, booleans, and allowlisted calls are supported.")]))

  (visit expression 0))

(define (truthy? value) (not (eq? value #f)))

(define (require-arity operator arguments expected)
  (unless (= (length arguments) expected)
    (raise-user-error 'arbor (format "~a expects ~a argument(s)." operator expected))))

(define (require-numbers operator arguments #:minimum [minimum 0])
  (when (< (length arguments) minimum)
    (raise-user-error 'arbor (format "~a expects at least ~a argument(s)." operator minimum)))
  (unless (andmap number? arguments)
    (raise-user-error 'arbor (format "~a only accepts numbers." operator))))

(define (apply-primitive operator arguments)
  (case operator
    [(+)
     (require-numbers operator arguments)
     (apply + arguments)]
    [(-)
     (require-numbers operator arguments #:minimum 1)
     (if (= (length arguments) 1)
         (- (car arguments))
         (for/fold ([result (car arguments)]) ([value (in-list (cdr arguments))]) (- result value)))]
    [(*)
     (require-numbers operator arguments)
     (apply * arguments)]
    [(/)
     (require-numbers operator arguments #:minimum 1)
     (if (= (length arguments) 1)
         (/ 1 (car arguments))
         (for/fold ([result (car arguments)]) ([value (in-list (cdr arguments))]) (/ result value)))]
    [(min max)
     (require-numbers operator arguments #:minimum 1)
     (apply (if (eq? operator 'min) min max) arguments)]
    [(abs round floor ceiling)
     (require-arity operator arguments 1)
     (require-numbers operator arguments)
     ((case operator [(abs) abs] [(round) round] [(floor) floor] [else ceiling]) (car arguments))]
    [(= < <= > >=)
     (require-numbers operator arguments #:minimum 2)
     (apply (case operator [(=) =] [(<) <] [(<=) <=] [(>) >] [else >=]) arguments)]
    [(not)
     (require-arity operator arguments 1)
     (not (truthy? (car arguments)))]
    [(string-append)
     (unless (andmap string? arguments)
       (raise-user-error 'arbor "string-append only accepts strings."))
     (apply string-append arguments)]
    [(string-length)
     (require-arity operator arguments 1)
     (unless (string? (car arguments))
       (raise-user-error 'arbor "string-length expects a string."))
     (string-length (car arguments))]
    [else
     (raise-user-error 'arbor (format "Operator is not allowed: ~a" operator))]))

(define (json-safe-value value)
  (cond
    [(and (exact-integer? value)
          (> (integer-length (abs value)) maximum-derived-integer-bits))
     (raise-user-error 'arbor "Computed integer exceeds the kernel size limit.")]
    [(and (rational? value) (exact? value) (not (integer? value)))
     (when (or (> (integer-length (abs (numerator value))) maximum-derived-integer-bits)
               (> (integer-length (abs (denominator value))) maximum-derived-integer-bits))
       (raise-user-error 'arbor "Computed rational exceeds the kernel size limit."))
     (exact->inexact value)]
    [(string? value)
     (when (> (bytes-length (string->bytes/utf-8 value)) maximum-derived-string-bytes)
       (raise-user-error 'arbor "Computed string exceeds the kernel size limit."))
     value]
    [(or (rational? value) (boolean? value)) value]
    [else (raise-user-error 'arbor "Expression result cannot be represented as JSON.")]))

(define (display-value value)
  (cond
    [(boolean? value) (if value "true" "false")]
    [else (format "~a" value)]))
