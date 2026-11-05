#lang racket/base

(require file/sha1
         json
         racket/list
         racket/match
         racket/string)

(provide (struct-out effect-plan)
         effect-plan->jsexpr
         effect-results
         effect-value?
         read-effect-datum
         resolve-effect-datum
         parse-effect-call)

(struct effect-plan (handler arguments capability timeout-ms max-output-bytes) #:transparent)

(define maximum-value-depth 16)
(define maximum-value-nodes 256)
(define maximum-value-bytes (* 1024 1024))

(define (parse-effect-call document-id producer-id body defaults supplied execution-id)
  (define datum (read-effect-datum (string-trim (substring body 1))))
  (unless (and (list? datum) (pair? datum) (symbol? (car datum)))
    (effect-error "An effect must be a handler call."))
  (define handler (symbol->string (car datum)))
  (define arguments
    (for/list ([argument (in-list (cdr datum))])
      (resolve-effect-datum argument defaults supplied)))
  (define-values (capability timeout-ms output-bytes)
    (handler-contract document-id producer-id handler arguments))
  (effect-plan handler arguments capability timeout-ms output-bytes))

(define (read-effect-datum source)
  (when (string=? source "") (effect-error "An effect declaration cannot be empty."))
  (define input (open-input-string source))
  (define (safe-read)
    (parameterize ([read-accept-reader #f]
                   [read-accept-lang #f]
                   [read-accept-compiled #f]
                   [read-accept-graph #f])
      (read input)))
  (define datum (safe-read))
  (unless (eof-object? (safe-read))
    (effect-error "An effect declaration must contain one expression."))
  datum)

(define (resolve-effect-datum datum defaults supplied)
  (define nodes 0)
  (define (count! depth)
    (set! nodes (add1 nodes))
    (when (> nodes maximum-value-nodes)
      (effect-error "An effect value contains too many items."))
    (when (> depth maximum-value-depth)
      (effect-error "An effect value is nested too deeply.")))
  (define (visit-json value depth)
    (count! depth)
    (cond
      [(or (eq? value 'null) (string? value) (boolean? value) (exact-integer? value)) value]
      [(list? value) (map (lambda (item) (visit-json item (add1 depth))) value)]
      [(hash? value)
       (for/hasheq ([(key item) (in-hash value)])
         (unless (or (symbol? key) (string? key))
           (effect-error "Effect record keys must be strings."))
         (values (if (symbol? key) key (string->symbol key))
                 (visit-json item (add1 depth))))]
      [else (effect-error "Effect inputs must be JSON values.")]))
  (define (visit value depth)
    (count! depth)
    (define resolved
      (cond
        [(or (string? value) (boolean? value) (exact-integer? value)) value]
        [(effect-input-name value)
         => (lambda (name)
              (define found (input-ref supplied defaults name))
              (when (eq? found missing-input)
                (effect-error (format "Effect input is missing: $~a" name)))
              (visit-json found (add1 depth)))]
        [(and (list? value) (pair? value) (eq? (car value) 'list))
         (for/list ([item (in-list (cdr value))]) (visit item (add1 depth)))]
        [(and (list? value) (pair? value) (eq? (car value) 'record))
         (for/hasheq ([entry (in-list (cdr value))])
           (unless (and (list? entry) (= (length entry) 2) (string? (car entry)))
             (effect-error "Record entries must use (\"key\" value)."))
           (values (string->symbol (car entry)) (visit (cadr entry) (add1 depth))))]
        [else
         (effect-error "Effect values must be literals, $inputs, lists, or records.")]))
    (when (> (bytes-length (jsexpr->bytes resolved)) maximum-value-bytes)
      (effect-error "An effect value exceeds 1 MB."))
    resolved)
  (visit datum 0))

(define missing-input (gensym 'missing-input))

(define (effect-input-name value)
  (and (symbol? value)
       (regexp-match #px"^\\$([A-Za-z][A-Za-z0-9_-]*)$" (symbol->string value))
       (string->symbol (substring (symbol->string value) 1))))

(define (input-ref supplied defaults name)
  (cond
    [(hash-has-key? supplied name) (hash-ref supplied name)]
    [(hash-has-key? supplied (symbol->string name)) (hash-ref supplied (symbol->string name))]
    [(hash-has-key? defaults name) (hash-ref defaults name)]
    [(hash-has-key? defaults (symbol->string name)) (hash-ref defaults (symbol->string name))]
    [else missing-input]))

(define (handler-contract document-id producer-id handler arguments)
  (define (capability kind resource summary)
    (make-capability document-id producer-id handler arguments kind resource summary))
  (case (string->symbol handler)
    [(clock/now clock/today)
     (expect-count handler arguments 0)
     (values 'null 1000 65536)]
    [(fs/read fs/stat)
     (expect-count handler arguments 1)
     (define path (relative-path-argument handler (car arguments)))
     (values (capability "filesystem.read" path (format "Read ~a" path)) 3000 maximum-value-bytes)]
    [(fs/list)
     (unless (<= 0 (length arguments) 1) (arity-error handler "zero or one path"))
     (define path (relative-path-argument handler (if (null? arguments) "." (car arguments))))
     (values (capability "filesystem.read" path (format "List ~a" path)) 3000 maximum-value-bytes)]
    [(fs/glob)
     (expect-count handler arguments 2)
     (define path (relative-path-argument handler (car arguments)))
     (define pattern (string-argument handler (cadr arguments)))
     (when (or (string=? pattern "") (regexp-match? #px"[/\\\\]" pattern))
       (effect-error "fs/glob needs a filename pattern without path separators."))
     (values (capability "filesystem.read" path (format "Match ~a in ~a" pattern path))
             3000 maximum-value-bytes)]
    [(fs/write fs/append)
     (expect-count handler arguments 2)
     (define path (relative-path-argument handler (car arguments)))
     (string-argument handler (cadr arguments))
     (values (capability "filesystem.write" path
                         (format "~a ~a" (if (equal? handler "fs/write") "Write" "Append to") path))
             3000 maximum-value-bytes)]
    [(fs/mkdir)
     (expect-count handler arguments 1)
     (define path (relative-path-argument handler (car arguments)))
     (values (capability "filesystem.write" path (format "Create folder ~a" path))
             3000 65536)]
    [(process/run)
     (unless (<= 1 (length arguments) 32) (arity-error handler "a command and at most 31 arguments"))
     (for-each (lambda (value) (string-argument handler value)) arguments)
     (when (ormap string=? arguments (make-list (length arguments) ""))
       (effect-error "process/run arguments cannot be empty."))
     (values (capability "process.run" (car arguments)
                         (format "Run ~a" (string-join arguments " ")))
             5000 maximum-value-bytes)]
    [(http/request)
     (unless (<= 2 (length arguments) 4)
       (arity-error handler "method, URL, optional body, and optional headers record"))
     (define method (string-upcase (string-argument handler (car arguments))))
     (unless (member method '("GET" "POST" "PUT" "PATCH" "DELETE"))
       (effect-error "http/request method must be GET, POST, PUT, PATCH, or DELETE."))
     (define url (string-argument handler (cadr arguments)))
     (define origin (http-origin url))
     (when (>= (length arguments) 3) (string-argument handler (list-ref arguments 2)))
     (when (>= (length arguments) 4) (headers-argument handler (list-ref arguments 3)))
     (values (capability "network.request" (format "~a ~a" method origin)
                         (format "Send ~a to ~a" method origin))
             15000 maximum-value-bytes)]
    [(clipboard/read)
     (expect-count handler arguments 0)
     (values (capability "clipboard.read" "system clipboard" "Read the system clipboard")
             3000 maximum-value-bytes)]
    [(clipboard/write)
     (expect-count handler arguments 1)
     (string-argument handler (car arguments))
     (values (capability "clipboard.write" "system clipboard" "Write the system clipboard")
             3000 65536)]
    [(notification/show)
     (unless (<= 1 (length arguments) 2) (arity-error handler "a title and optional body"))
     (for-each (lambda (value) (string-argument handler value)) arguments)
     (values (capability "notification.show" "desktop notification" "Show a desktop notification")
             3000 65536)]
    [(action/run)
     (unless (<= 1 (length arguments) 2) (arity-error handler "a method and optional arguments record"))
     (define method (string-argument handler (car arguments)))
     (unless (regexp-match? #px"^[a-z][A-Za-z0-9._-]{1,127}$" method)
       (effect-error "action/run method is invalid."))
     (when (and (= (length arguments) 2) (not (hash? (cadr arguments))))
       (effect-error "action/run arguments must be a record."))
     (values (capability "action.execute" method (format "Run nvModern action ~a" method))
             15000 maximum-value-bytes)]
    [(model/complete)
     (unless (<= 1 (length arguments) 2) (arity-error handler "a prompt and optional model name"))
     (for-each (lambda (value) (string-argument handler value)) arguments)
     (define model (if (= (length arguments) 2) (cadr arguments) "configured model"))
     (values (capability "model.complete" model (format "Send a prompt to ~a" model))
             60000 maximum-value-bytes)]
    [else (effect-error (format "Effect handler is not available: ~a" handler))]))

(define (expect-count handler arguments count)
  (unless (= (length arguments) count)
    (arity-error handler (format "~a argument~a" count (if (= count 1) "" "s")))))

(define (arity-error handler expected)
  (effect-error (format "~a needs ~a." handler expected)))

(define (string-argument handler value)
  (unless (string? value) (effect-error (format "~a arguments must be strings." handler)))
  value)

(define (relative-path-argument handler value)
  (define path (string-argument handler value))
  (unless (and (not (string=? path ""))
               (not (regexp-match? #px"^(?:/|[A-Za-z]:)" path))
               (not (member ".." (regexp-split #px"[/\\\\]+" path))))
    (effect-error (format "~a needs a workspace-relative path." handler)))
  path)

(define (headers-argument handler value)
  (unless (and (hash? value)
               (for/and ([(key item) (in-hash value)])
                 (and (symbol? key) (string? item))))
    (effect-error (format "~a headers must be a record of strings." handler)))
  value)

(define (http-origin value)
  (match (regexp-match #px"^(https?)://([^/?#@]+)(?:[/?#]|$)" value)
    [(list _ scheme authority) (format "~a://~a" scheme authority)]
    [_ (effect-error "http/request needs an http or https URL without embedded credentials.")]))

(define (make-capability document-id producer-id handler arguments kind resource summary)
  (hasheq 'id (sha1 (open-input-string
                     (format "~s" (list document-id producer-id handler
                                         (canonical-value arguments)))))
          'kind kind
          'resource resource
          'summary summary))

(define (canonical-value value)
  (cond
    [(hash? value)
     (for/list ([key (in-list (sort (hash-keys value) string<? #:key symbol->string))])
       (list key (canonical-value (hash-ref value key))))]
    [(list? value) (map canonical-value value)]
    [else value]))

(define (effect-plan->jsexpr plan execution-id)
  (hasheq 'executionID execution-id
          'handler (effect-plan-handler plan)
          'arguments (effect-plan-arguments plan)
          'capability (effect-plan-capability plan)
          'limits (hasheq 'timeoutMs (effect-plan-timeout-ms plan)
                          'maxOutputBytes (effect-plan-max-output-bytes plan))))

(define (effect-value? value [depth 0])
  (and (<= depth maximum-value-depth)
       (cond
         [(or (eq? value 'null) (string? value) (boolean? value) (exact-integer? value)) #t]
         [(list? value) (andmap (lambda (item) (effect-value? item (add1 depth))) value)]
         [(hash? value)
          (for/and ([(key item) (in-hash value)])
            (and (symbol? key) (effect-value? item (add1 depth))))]
         [else #f])))

(define (effect-results value)
  (define values (if (list? value) value (list value)))
  (for/list ([item (in-list values)] [index (in-naturals)])
    (hasheq 'key (if (list? value) (format "item:~a" index) "effect")
            'markdown (render-value item))))

(define (render-value value)
  (cond
    [(eq? value 'null) "null"]
    [(boolean? value) (if value "true" "false")]
    [(number? value) (number->string value)]
    [(string? value) value]
    [(hash? value)
     (string-join
      (for/list ([key (in-list (sort (hash-keys value) string<? #:key symbol->string))])
        (format "~a:: ~a" (symbol->string key) (render-inline (hash-ref value key))))
      "\n")]
    [else (jsexpr->string value)]))

(define (render-inline value)
  (if (or (string? value) (number? value) (boolean? value) (eq? value 'null))
      (render-value value)
      (jsexpr->string value)))

(define (effect-error message)
  (raise-user-error 'arbor-kernel message))
