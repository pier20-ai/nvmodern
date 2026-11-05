#lang racket/base

(require racket/list
         racket/set
         racket/string)

(provide (struct-out arbor-block)
         (struct-out arbor-computation)
         block->jsexpr
         diagnostic
         maximum-blocks
         maximum-source-bytes
         parse-outline)

(define maximum-source-bytes (* 4 1024 1024))
(define maximum-blocks 100000)

(struct arbor-computation
  (state producer-id result-key generation input-hash world-revision origin-block-id update-policy)
  #:transparent)

(struct arbor-block
  (uid depth body line column end-line end-column parent-uid computation stable-uid?)
  #:transparent)

(define c1-anchor-pattern
  #px"^([A-Za-z0-9][A-Za-z0-9._:-]{0,127})(?:~c1~([lsd])~([A-Za-z0-9][A-Za-z0-9._:-]{0,127})~([A-Za-z0-9._:-]+)~([1-9][0-9]*|true)~([a-f0-9]{40})(?:~([0-9]+|true|false))?)?$")

(define c2-anchor-pattern
  #px"^([A-Za-z0-9][A-Za-z0-9._:-]{0,127})~c2~([lsd])~([A-Za-z0-9][A-Za-z0-9._:-]{0,127})~([A-Za-z0-9._:-]+)~([1-9][0-9]*|true)~([a-f0-9]{40})~([0-9]+|true|false|x)~([A-Za-z0-9][A-Za-z0-9._:-]{0,127})~([td])$")

(define (anchor-number value)
  (cond
    [(equal? value "true") 1]
    [(equal? value "false") 0]
    [else (string->number value)]))

(define (parse-anchor value)
  (define c2-match (regexp-match c2-anchor-pattern value))
  (define match (or c2-match (regexp-match c1-anchor-pattern value)))
  (if (not match)
      (values #f #f)
      (let ([state-code (list-ref match 2)])
        (values
         (list-ref match 1)
         (and state-code
              (arbor-computation
               (case (string-ref state-code 0)
                 [(#\l) 'live]
                 [(#\s) 'snapshot]
                 [else 'detached])
               (list-ref match 3)
               (list-ref match 4)
               (anchor-number (list-ref match 5))
               (list-ref match 6)
               (and (list-ref match 7)
                    (not (equal? (list-ref match 7) "x"))
                    (anchor-number (list-ref match 7)))
               (and c2-match (list-ref match 8))
               (and c2-match
                    (if (equal? (list-ref match 9) "t") 'source-text 'detach))))))))

(define (diagnostic severity code message
                    #:line [line #f]
                    #:column [column #f])
  (for/hasheq ([entry (in-list
                       (filter values
                               (list (cons 'severity severity)
                                     (cons 'code code)
                                     (cons 'message message)
                                     (and line (cons 'line line))
                                     (and column (cons 'column column)))) )])
    (values (car entry) (cdr entry))))

(define (parse-outline source)
  (define lines (regexp-split #px"\r?\n" source))
  (define diagnostics '())
  (define blocks '())
  (define ancestors (make-hasheq))
  (define seen-uids (mutable-set))
  (define previous-depth -1)
  (define block-count 0)

  (define first-line (if (null? lines) "" (string-trim (car lines))))
  (define has-too-many-blocks?
    (> (count (lambda (line) (regexp-match? #px"^[ \t]*-" line))
              (if (null? lines) '() (cdr lines)))
       maximum-blocks))
  (unless (equal? first-line "#lang arbor/0")
    (set! diagnostics
          (cons (diagnostic "error" "ARBOR1001"
                            "An Arbor document must begin with #lang arbor/0."
                            #:line 1 #:column 1)
                diagnostics)))

  (for ([line-text (in-list (if (null? lines) '() (cdr lines)))]
        [line-number (in-naturals 2)]
        #:break (>= block-count maximum-blocks))
    (unless (string=? "" (string-trim line-text))
      (cond
        [(regexp-match? #px"\t" line-text)
         (set! diagnostics
               (cons (diagnostic "error" "ARBOR1002"
                                 "Indentation must use spaces, not tabs."
                                 #:line line-number #:column 1)
                     diagnostics))]
        [else
         (define continuation-match (regexp-match #px"^( *)\\|(?: (.*))?$" line-text))
         (cond
           [continuation-match
            (define indentation (string-length (list-ref continuation-match 1)))
            (define target-depth (sub1 (quotient indentation 2)))
            (define latest-block (and (pair? blocks) (car blocks)))
            (cond
              [(or (not (zero? (remainder indentation 2)))
                   (< target-depth 0)
                   (not latest-block)
                   (not (= (arbor-block-depth latest-block) target-depth)))
               (set! diagnostics
                     (cons (diagnostic "error" "ARBOR1009"
                                       "A continuation line must be indented beneath its block."
                                       #:line line-number #:column 1)
                           diagnostics))]
              [else
               (define continuation (or (list-ref continuation-match 2) ""))
               (set! blocks
                     (cons (struct-copy
                            arbor-block latest-block
                            [body (string-append (arbor-block-body latest-block)
                                                 "\n"
                                                 continuation)]
                            [end-line line-number]
                            [end-column (+ indentation 3 (string-length continuation))])
                           (cdr blocks)))])]
           [else
            (define match-result (regexp-match #px"^( *)- +(.*)$" line-text))
            (cond
              [(not match-result)
               (set! diagnostics
                     (cons (diagnostic "error" "ARBOR1003"
                                       "Outline lines must use the form: - content ^uid"
                                       #:line line-number #:column 1)
                           diagnostics))]
              [else
               (define indentation (string-length (list-ref match-result 1)))
               (define raw-body (list-ref match-result 2))
               (unless (zero? (remainder indentation 2))
                 (set! diagnostics
                       (cons (diagnostic "error" "ARBOR1004"
                                         "Indentation must be a multiple of two spaces."
                                         #:line line-number #:column 1)
                             diagnostics)))
               (define depth (quotient indentation 2))
               (when (> depth (add1 previous-depth))
                 (set! diagnostics
                       (cons (diagnostic "error" "ARBOR1006"
                                         "A block may only indent one level deeper than its predecessor."
                                         #:line line-number #:column 1)
                             diagnostics)))

               (define uid-match
                 (regexp-match
                  #px"^(?:(.*?)\\s+)?\\^([^[:space:]]+)\\s*$"
                  raw-body))
               (define anchor-values
                 (and uid-match
                      (call-with-values
                       (lambda () (parse-anchor (list-ref uid-match 2)))
                       list)))
               (define stable-uid? (and anchor-values (car anchor-values) #t))
               (define uid (if stable-uid?
                               (car anchor-values)
                               (format "missing-line-~a" line-number)))
               (define computation (and stable-uid? (cadr anchor-values)))
               (define body
                 (string-trim (if uid-match (or (list-ref uid-match 1) "") raw-body)))
               (define body-start (+ indentation 3))
               (define body-end (+ body-start (string-length body)))
               (unless stable-uid?
                 (set! diagnostics
                       (cons (diagnostic "error" (if uid-match "ARBOR1010" "ARBOR1005")
                                         (if uid-match
                                             "Invalid Arbor block anchor metadata."
                                             "Every block needs a stable ^uid suffix.")
                                         #:line line-number
                                         #:column (add1 (string-length line-text)))
                             diagnostics)))
               (when (and stable-uid? (set-member? seen-uids uid))
                 (set! diagnostics
                       (cons (diagnostic "error" "ARBOR1007"
                                         (format "Duplicate block UID: ^~a" uid)
                                         #:line line-number #:column 1)
                             diagnostics)))
               (when stable-uid? (set-add! seen-uids uid))

               (define parent-uid
                 (and (> depth 0) (hash-ref ancestors (sub1 depth) #f)))
               (hash-set! ancestors depth uid)
               (set! previous-depth depth)
               (set! block-count (add1 block-count))
               (set! blocks
                     (cons (arbor-block uid
                                       depth
                                       body
                                       line-number
                                       body-start
                                       line-number
                                       body-end
                                       parent-uid
                                       computation
                                       stable-uid?)
                           blocks))])])])))

  (when has-too-many-blocks?
    (set! diagnostics
          (cons (diagnostic "error" "ARBOR1008"
                            (format "Document exceeds the ~a block kernel limit." maximum-blocks))
                diagnostics)))
  (values (reverse blocks) (reverse diagnostics)))

(define (block->jsexpr block)
  (hasheq 'uid (arbor-block-uid block)
          'depth (arbor-block-depth block)
          'body (arbor-block-body block)
          'line (arbor-block-line block)
          'parentUID (or (arbor-block-parent-uid block) 'null)))
