#lang racket/base

(require racket/list
         racket/match
         racket/set
         racket/string
         "outline.rkt")

(provide (struct-out arbor-fact)
         (struct-out compiled-document)
         (struct-out query-definition)
         (struct-out query-variable)
         block-attribute-defaults
         compile-document
         fact->jsexpr)

(struct arbor-fact
  (predicate terms document-id block-id line column end-line end-column)
  #:transparent)

(struct query-variable (name) #:transparent)
(struct query-definition (id columns inputs clauses defaults projection line) #:transparent)
(struct compiled-document (id path revision source blocks facts queries diagnostics) #:transparent)

(define query-arities
  (hasheq 'block-page 2
          'block-parent 2
          'block-order 2
          'block-text 2
          'block-tag 2
          'block-attribute 3
          'block-link-page 2
          'block-ref-block 2
          'block-ancestor 2))

(define (compile-document document-id path revision source)
  (define-values (blocks parse-diagnostics) (parse-outline source))
  (define-values (facts queries fact-diagnostics)
    (compile-blocks document-id path blocks))
  (compiled-document document-id
                     path
                     revision
                     source
                     blocks
                     facts
                     queries
                     (append parse-diagnostics fact-diagnostics)))

(define (compile-blocks document-id page blocks)
  (define sibling-orders (make-hash))
  (define all-facts '())
  (define queries '())
  (define diagnostics '())
  (define excluded-uids (mutable-set))

  (define (add-fact! block predicate . terms)
    (set! all-facts
          (cons (arbor-fact predicate
                            terms
                            document-id
                            (arbor-block-uid block)
                            (arbor-block-line block)
                            (arbor-block-column block)
                            (arbor-block-end-line block)
                            (arbor-block-end-column block))
                all-facts)))

  (for ([block (in-list blocks)])
    (define uid (arbor-block-uid block))
    (define body (arbor-block-body block))
    (define parent (arbor-block-parent-uid block))
    (define computation (arbor-block-computation block))
    (define excluded?
      (or (and computation
               (memq (arbor-computation-state computation) '(live snapshot)))
          (and parent (set-member? excluded-uids parent))))
    (when excluded? (set-add! excluded-uids uid))
    (define sibling-key (or parent 'root))
    (define order (hash-ref sibling-orders sibling-key 0))
    (hash-set! sibling-orders sibling-key (add1 order))

    (when (and (arbor-block-stable-uid? block) (not excluded?))
      (add-fact! block 'block-page uid page)
      (when parent (add-fact! block 'block-parent uid parent))
      (add-fact! block 'block-order uid order)
      (add-fact! block 'block-text uid body)

      (for ([tag (in-list (extract-tags body))])
        (add-fact! block 'block-tag uid tag))
      (for ([link (in-list (extract-page-links body))])
        (add-fact! block 'block-link-page uid link))
      (for ([target (in-list (extract-block-references body))])
        (add-fact! block 'block-ref-block uid target))
      (match (extract-attribute body)
        [(list key value) (add-fact! block 'block-attribute uid key value)]
        [_ (void)])

      (define query-source (extract-query-source body))
      (when query-source
        (with-handlers ([exn:fail?
                         (lambda (error)
                           (set! diagnostics
                                 (cons (diagnostic "error"
                                                   "ARBOR3001"
                                                   (exn-message error)
                                                   #:line (arbor-block-line block)
                                                   #:column 3)
                                       diagnostics)))])
          (set! queries
                (cons (parse-query uid
                                   query-source
                                   (block-attribute-defaults blocks uid)
                                   (arbor-block-line block))
                      queries))))))

  (values (reverse all-facts) (reverse queries) (reverse diagnostics)))

(define (extract-tags body)
  (sort
   (remove-duplicates
    (regexp-match* #px"(?:^|[[:space:]([])#([A-Za-z0-9][A-Za-z0-9_/-]*)"
                   body
                   #:match-select cadr))
   string<?))

(define (extract-page-links body)
  (sort
   (remove-duplicates
    (filter (lambda (value) (not (string=? value "")))
            (map string-trim
                 (regexp-match* #px"\\[\\[([^][\n]+)\\]\\]"
                                body
                                #:match-select cadr))))
   string<?))

(define (extract-block-references body)
  (sort
   (remove-duplicates
    (regexp-match* #px"\\(\\(([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\\)\\)"
                   body
                   #:match-select cadr))
   string<?))

(define (extract-attribute body)
  (match (regexp-match #px"^([A-Za-z][A-Za-z0-9_-]*)::[[:space:]]*(.*)$" body)
    [(list _ key value) (list key value)]
    [_ #f]))

(define (extract-query-source body)
  (match (regexp-match #px"(?s:^\\{\\{query:[[:space:]]*(.*?)\\}\\}$)" body)
    [(list _ source) (string-trim source)]
    [_ #f]))

(define (block-attribute-defaults blocks parent-id)
  (for/hash ([block (in-list blocks)]
             #:when (equal? parent-id (arbor-block-parent-uid block))
             #:unless (let ([computation (arbor-block-computation block)])
                        (and computation
                             (memq (arbor-computation-state computation) '(live snapshot))))
             [attribute (in-value (extract-attribute (arbor-block-body block)))]
             #:when attribute)
    (values (string->symbol (car attribute)) (cadr attribute))))

(define (parse-query id source defaults line)
  (define datum (read-one source))
  (unless (and (list? datum) (pair? datum) (eq? (car datum) 'find))
    (query-error "A query must use (find (...) ...)."))
  (unless (<= 3 (length datum) 5)
    (query-error "A query must contain columns, where clauses, and optional inputs or projection."))

  (define output-form (list-ref datum 1))
  (define forms (cddr datum))
  (for ([form (in-list forms)])
    (unless (and (list? form)
                 (pair? form)
                 (memq (car form) '(in where project)))
      (query-error "Query forms must use in, where, or project.")))
  (define (single-form name)
    (define matches (filter (lambda (form) (eq? (car form) name)) forms))
    (when (> (length matches) 1)
      (query-error (format "A query may contain one ~a form." name)))
    (and (pair? matches) (car matches)))
  (define input-form (single-form 'in))
  (define where-form (single-form 'where))
  (define project-form (single-form 'project))
  (unless (list? output-form)
    (query-error "Query columns must be a list of ?variables."))
  (unless where-form
    (query-error "A query needs a (where ...) form."))
  (when (and project-form
             (not (and (= (length project-form) 2)
                       (string? (cadr project-form)))))
    (query-error "Query projection must use (project \"template\")."))

  (define columns (map checked-variable output-form))
  (define inputs (map checked-variable (if input-form (cdr input-form) '())))
  (when (null? columns)
    (query-error "A query needs at least one result column."))
  (define declared (append columns inputs))
  (unless (= (length declared) (length (remove-duplicates declared eq?)))
    (query-error "Query variables must be declared once."))

  (define clauses
    (for/list ([clause (in-list (cdr where-form))])
      (parse-clause clause declared)))
  (when (null? clauses)
    (query-error "A query needs at least one where clause."))
  (for ([column (in-list columns)])
    (unless (variable-used? column clauses)
      (query-error (format "Query column ?~a does not appear in a where clause." column))))
  (for ([input (in-list inputs)])
    (unless (variable-used? input clauses)
      (query-error (format "Query input ?~a does not appear in a where clause." input))))

  (define projection (and project-form (cadr project-form)))
  (when projection
    (define placeholders
      (map string->symbol
           (regexp-match* #px"\\{([A-Za-z][A-Za-z0-9_-]*)\\}"
                          projection
                          #:match-select cadr)))
    (define residue
      (regexp-replace* #px"\\{[A-Za-z][A-Za-z0-9_-]*\\}" projection ""))
    (when (regexp-match? #px"[{}]" residue)
      (query-error "Projection braces must contain one result variable name."))
    (for ([name (in-list placeholders)])
      (unless (memq name columns)
        (query-error (format "Projection variable is not a result column: ~a" name)))))

  (query-definition id columns inputs clauses defaults projection line))

(define (read-one source)
  (when (string=? source "")
    (query-error "A query declaration cannot be empty."))
  (define input (open-input-string source))
  (define datum
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
    (query-error "A query declaration must contain one expression."))
  datum)

(define (checked-variable value)
  (unless (and (symbol? value)
               (string-prefix? (symbol->string value) "?")
               (> (string-length (symbol->string value)) 1))
    (query-error "Query variables must begin with ?."))
  (string->symbol (substring (symbol->string value) 1)))

(define (parse-clause value declared)
  (unless (and (list? value) (pair? value) (symbol? (car value)))
    (query-error "Each where clause must be a predicate call."))
  (define predicate (car value))
  (define expected-arity (hash-ref query-arities predicate #f))
  (unless expected-arity
    (query-error (format "Query predicate is not available: ~a" predicate)))
  (unless (= (length (cdr value)) expected-arity)
    (query-error (format "~a expects ~a arguments." predicate expected-arity)))
  (cons predicate
        (for/list ([term (in-list (cdr value))])
          (cond
            [(and (symbol? term) (string-prefix? (symbol->string term) "?"))
             (define variable-name (checked-variable term))
             (unless (memq variable-name declared)
               (query-error (format "Query variable is not declared: ?~a" variable-name)))
             (query-variable variable-name)]
            [(or (string? term) (exact-integer? term) (boolean? term)) term]
            [else (query-error "Query constants must be strings, integers, or booleans.")]))))

(define (variable-used? name clauses)
  (for/or ([clause (in-list clauses)])
    (for/or ([term (in-list (cdr clause))])
      (and (query-variable? term) (eq? name (query-variable-name term))))))

(define (query-error message)
  (raise-user-error 'arbor-query message))

(define (fact->jsexpr fact)
  (hasheq 'predicate (symbol->string (arbor-fact-predicate fact))
          'terms (arbor-fact-terms fact)
          'source
          (hasheq 'documentID (arbor-fact-document-id fact)
                  'blockID (arbor-fact-block-id fact)
                  'line (arbor-fact-line fact)
                  'column (arbor-fact-column fact)
                  'endLine (arbor-fact-end-line fact)
                  'endColumn (arbor-fact-end-column fact))))
