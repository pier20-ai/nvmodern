#lang racket/base

(require json
         racket/string
         "arbor/protocol.rkt")

(define (request-id request)
  (if (and (hash? request)
           (hash-has-key? request 'id)
           (string? (hash-ref request 'id)))
      (hash-ref request 'id)
      ""))

(define (fatal-response request code message)
  (hasheq 'protocol protocol-version
          'id (request-id request)
          'ok #f
          'revision 0
          'blocks '()
          'patches '()
          'queries '()
          'diagnostics
          (list (hasheq 'severity "error"
                        'code code
                        'message message))))

(define (emit response)
  (write-json response)
  (newline)
  (flush-output))

(let loop ()
  (define line (read-line (current-input-port) 'any))
  (unless (eof-object? line)
    (unless (string=? "" (string-trim line))
      (define response
        (with-handlers ([exn:fail?
                         (lambda (error)
                           (fatal-response #f "ARBOR0002" (exn-message error)))])
          (define request (string->jsexpr line))
          (handle-request request)))
      (emit response))
    (loop)))
