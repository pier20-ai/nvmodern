#lang racket/base

(require json
         "../arbor/datalog-adapter.rkt"
         "../arbor/facts.rkt")

(define (fixture block-count)
  (define output (open-output-string))
  (display "#lang arbor/0\n" output)
  (for ([index (in-range block-count)])
    (fprintf output "- Block ~a ^b~a\n" index index))
  (get-output-string output))

(define (elapsed start)
  (inexact->exact (round (- (current-inexact-milliseconds) start))))

(module+ main
  (define arguments (current-command-line-arguments))
  (define block-count
    (if (zero? (vector-length arguments))
        10000
        (string->number (vector-ref arguments 0))))
  (unless (and (exact-positive-integer? block-count) (<= block-count 100000))
    (raise-user-error 'fact-compiler "block count must be between 1 and 100000"))
  (define source (fixture block-count))
  (collect-garbage)
  (define compile-start (current-inexact-milliseconds))
  (define document (compile-document "benchmark" "Benchmark" 1 source))
  (define compile-ms (elapsed compile-start))
  (when (pair? (compiled-document-diagnostics document))
    (raise-user-error 'fact-compiler "fixture did not compile cleanly"))
  (collect-garbage)
  (define theory-start (current-inexact-milliseconds))
  (define _theory (make-arbor-theory (compiled-document-facts document)))
  (define theory-ms (elapsed theory-start))
  (write-json
   (hasheq 'blocks block-count
           'sourceBytes (bytes-length (string->bytes/utf-8 source))
           'facts (length (compiled-document-facts document))
           'compileMs compile-ms
           'theoryMs theory-ms))
  (newline))
