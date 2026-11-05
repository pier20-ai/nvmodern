#lang racket/base

(require file/sha1
         racket/list
         racket/string
         "facts.rkt"
         "outline.rkt")

(provide (struct-out source-operation)
         apply-source-operations
         mutation-error-diagnostics
         source-operation-destructive?
         source-operation-summary)

(struct source-operation (kind block-id value destination-id result-key) #:transparent)

(define (apply-source-operations document operations producer-id mode generation input-hash world-revision)
  (define prepared
    (if (equal? mode "append")
        (freeze-live-results document producer-id)
        document))
  (define desired-keys
    (for/list ([operation (in-list operations)]
               #:when (source-operation-result-key operation))
      (source-operation-result-key operation)))
  (define reconciled
    (if (equal? mode "refresh")
        (remove-stale-live-results prepared producer-id desired-keys)
        prepared))
  (for/fold ([candidate reconciled]) ([operation (in-list operations)])
    (apply-operation candidate operation producer-id generation input-hash world-revision)))

(define (apply-operation document operation producer-id generation input-hash world-revision)
  (case (source-operation-kind operation)
    [(insert-child insert-after)
     (apply-insert document operation producer-id generation input-hash world-revision)]
    [(set-text)
     (define block (authored-block document (source-operation-block-id operation)))
     (recompile document (replace-block-body (compiled-document-source document) block
                                             (source-operation-value operation)
                                             (arbor-block-uid block)))]
    [(add-tag)
     (define block (authored-block document (source-operation-block-id operation)))
     (define tag (source-operation-value operation))
     (define body (arbor-block-body block))
     (if (member tag (block-tags body))
         document
         (recompile document (replace-block-body (compiled-document-source document) block
                                                 (string-append body " #" tag)
                                                 (arbor-block-uid block))))]
    [(delete)
     (define block (authored-block document (source-operation-block-id operation)))
     (recompile document (delete-subtree (compiled-document-source document)
                                         (compiled-document-blocks document) block))]
    [(move)
     (define block (authored-block document (source-operation-block-id operation)))
     (define destination (authored-block document (source-operation-destination-id operation)))
     (when (or (equal? (arbor-block-uid block) (arbor-block-uid destination))
               (descendant? document destination block))
       (mutation-error "An outline transaction cannot move a block into its own subtree."))
     (recompile document (move-subtree (compiled-document-source document)
                                       (compiled-document-blocks document)
                                       block destination))]
    [else (mutation-error "Unsupported outline transaction operation.")]))

(define (apply-insert document operation producer-id generation input-hash world-revision)
  (define target (authored-block document (source-operation-block-id operation)))
  (define result-key (source-operation-result-key operation))
  (define live (find-live-result document producer-id result-key))
  (when (and live (block-has-children? (compiled-document-blocks document) live))
    (mutation-error "A managed transaction result with children must be detached before refresh."))
  (define uid
    (if live
        (arbor-block-uid live)
        (fresh-managed-id document producer-id result-key generation)))
  (define without-live
    (if live
        (recompile document (delete-subtree (compiled-document-source document)
                                            (compiled-document-blocks document) live))
        document))
  (define current-target (required-block without-live (arbor-block-uid target)))
  (define depth
    (if (eq? (source-operation-kind operation) 'insert-child)
        (add1 (arbor-block-depth current-target))
        (arbor-block-depth current-target)))
  (define anchor
    (managed-anchor uid 'live producer-id result-key generation input-hash world-revision))
  (define lines (block-lines depth (source-operation-value operation) anchor))
  (define insertion-line
    (subtree-end-line (compiled-document-blocks without-live) current-target))
  (recompile without-live
             (insert-source-lines (compiled-document-source without-live) insertion-line lines)))

(define (freeze-live-results document producer-id)
  (for/fold ([candidate document])
            ([uid (in-list
                   (for/list ([block (in-list (compiled-document-blocks document))]
                              #:when (live-result? block producer-id))
                     (arbor-block-uid block)))])
    (define block (required-block candidate uid))
    (define computation (arbor-block-computation block))
    (recompile candidate
               (replace-block-body
                (compiled-document-source candidate) block (arbor-block-body block)
                (managed-anchor uid 'snapshot producer-id
                                (arbor-computation-result-key computation)
                                (arbor-computation-generation computation)
                                (arbor-computation-input-hash computation)
                                (arbor-computation-world-revision computation))))))

(define (remove-stale-live-results document producer-id desired-keys)
  (define stale-uids
    (for/list ([block (in-list (compiled-document-blocks document))]
               #:when (and (live-result? block producer-id)
                           (not (member (arbor-computation-result-key
                                         (arbor-block-computation block))
                                        desired-keys))))
      (arbor-block-uid block)))
  (for/fold ([candidate document]) ([uid (in-list stale-uids)])
    (define block (required-block candidate uid))
    (when (block-has-children? (compiled-document-blocks candidate) block)
      (mutation-error "A stale managed transaction result with children must be detached before refresh."))
    (recompile candidate (delete-subtree (compiled-document-source candidate)
                                         (compiled-document-blocks candidate) block))))

(define (find-live-result document producer-id result-key)
  (findf (lambda (block)
           (define computation (arbor-block-computation block))
           (and computation
                (eq? (arbor-computation-state computation) 'live)
                (equal? producer-id (arbor-computation-producer-id computation))
                (equal? result-key (arbor-computation-result-key computation))))
         (compiled-document-blocks document)))

(define (live-result? block producer-id)
  (define computation (arbor-block-computation block))
  (and computation
       (eq? (arbor-computation-state computation) 'live)
       (equal? producer-id (arbor-computation-producer-id computation))))

(define (fresh-managed-id document producer-id result-key generation)
  (define base
    (string-append
     "m_"
     (substring
      (sha1 (open-input-string
             (format "~s" (list (compiled-document-id document) producer-id result-key generation))))
      0 16)))
  (if (required-block document base #f)
      (mutation-error "A generated transaction block ID collided with existing source.")
      base))

(define (authored-block document uid)
  (define block (required-block document uid))
  (define computation (arbor-block-computation block))
  (when (and computation (memq (arbor-computation-state computation) '(live snapshot)))
    (mutation-error "A managed result must be detached before an outline transaction changes it."))
  block)

(define (required-block document uid [fail? #t])
  (define block
    (findf (lambda (candidate) (equal? uid (arbor-block-uid candidate)))
           (compiled-document-blocks document)))
  (cond
    [block block]
    [fail? (mutation-error (format "Outline transaction block does not exist: ~a" uid))]
    [else #f]))

(define (descendant? document candidate ancestor)
  (let loop ([parent-id (arbor-block-parent-uid candidate)])
    (cond
      [(not parent-id) #f]
      [(equal? parent-id (arbor-block-uid ancestor)) #t]
      [else (loop (arbor-block-parent-uid (required-block document parent-id)))])))

(define (block-has-children? blocks block)
  (define tail (cdr (member block blocks eq?)))
  (and (pair? tail) (> (arbor-block-depth (car tail)) (arbor-block-depth block))))

(define (subtree-end-line blocks block)
  (let loop ([remaining (cdr (member block blocks eq?))]
             [end-line (arbor-block-end-line block)])
    (cond
      [(null? remaining) end-line]
      [(<= (arbor-block-depth (car remaining)) (arbor-block-depth block)) end-line]
      [else (loop (cdr remaining) (arbor-block-end-line (car remaining)))])))

(define (replace-block-body source block body anchor)
  (replace-source-lines source
                        (arbor-block-line block)
                        (arbor-block-end-line block)
                        (block-lines (arbor-block-depth block) body anchor)))

(define (block-lines depth body anchor)
  (define indentation (make-string (* 2 depth) #\space))
  (define text-lines (regexp-split #px"\r?\n" body))
  (cons (format "~a- ~a~a^~a"
                indentation (car text-lines)
                (if (string=? (car text-lines) "") "" " ") anchor)
        (for/list ([line (in-list (cdr text-lines))])
          (format "~a  |~a" indentation (if (string=? line "") "" (string-append " " line))))))

(define (managed-anchor uid state producer-id result-key generation input-hash world-revision)
  (string-join
   (list uid "c1"
         (case state [(live) "l"] [(snapshot) "s"] [else "d"])
         producer-id result-key (number->string generation) input-hash
         (number->string world-revision))
   "~"))

(define (delete-subtree source blocks block)
  (replace-source-lines source (arbor-block-line block) (subtree-end-line blocks block) '()))

(define (move-subtree source blocks block destination)
  (define start (arbor-block-line block))
  (define end (subtree-end-line blocks block))
  (define lines (source-lines source))
  (define extracted (take (drop lines (sub1 start)) (add1 (- end start))))
  (define removed (replace-source-lines source start end '()))
  (define interim (recompile-like removed))
  (define current-destination (required-block interim (arbor-block-uid destination)))
  (define depth-delta (- (add1 (arbor-block-depth current-destination))
                         (arbor-block-depth block)))
  (define reindented (map (lambda (line) (reindent-line line depth-delta)) extracted))
  (insert-source-lines removed
                       (subtree-end-line (compiled-document-blocks interim) current-destination)
                       reindented))

(define (reindent-line line depth-delta)
  (define match (regexp-match #px"^([ ]*)(.*)$" line))
  (define width (string-length (cadr match)))
  (string-append (make-string (max 0 (+ width (* 2 depth-delta))) #\space)
                 (caddr match)))

(define (source-lines source) (regexp-split #px"\r?\n" source))

(define (replace-source-lines source start end replacement)
  (define lines (source-lines source))
  (string-join (append (take lines (sub1 start)) replacement (drop lines end)) "\n"))

(define (insert-source-lines source after-line insertion)
  (define lines (source-lines source))
  (string-join (append (take lines after-line) insertion (drop lines after-line)) "\n"))

(define (recompile document source)
  (define candidate
    (compile-document (compiled-document-id document)
                      (compiled-document-path document)
                      (compiled-document-revision document)
                      source))
  (define errors (mutation-error-diagnostics candidate))
  (unless (null? errors) (mutation-error (hash-ref (car errors) 'message)))
  candidate)

(define (recompile-like source)
  (define candidate (compile-document "candidate" "candidate.outline" 0 source))
  (define errors (mutation-error-diagnostics candidate))
  (unless (null? errors) (mutation-error (hash-ref (car errors) 'message)))
  candidate)

(define (mutation-error-diagnostics document)
  (filter (lambda (item) (equal? (hash-ref item 'severity #f) "error"))
          (compiled-document-diagnostics document)))

(define (block-tags body)
  (regexp-match* #px"(?:^|[[:space:]([])#([A-Za-z0-9][A-Za-z0-9_/-]*)"
                 body #:match-select cadr))

(define (source-operation-destructive? operation)
  (memq (source-operation-kind operation) '(set-text move delete)))

(define (source-operation-summary operation)
  (case (source-operation-kind operation)
    [(insert-child) (format "Insert a child under ^~a" (source-operation-block-id operation))]
    [(insert-after) (format "Insert a sibling after ^~a" (source-operation-block-id operation))]
    [(set-text) (format "Replace the text of ^~a" (source-operation-block-id operation))]
    [(add-tag) (format "Add #~a to ^~a" (source-operation-value operation)
                       (source-operation-block-id operation))]
    [(move) (format "Move ^~a under ^~a" (source-operation-block-id operation)
                    (source-operation-destination-id operation))]
    [(delete) (format "Delete ^~a and its subtree" (source-operation-block-id operation))]
    [else "Change the outline"]))

(define (mutation-error message)
  (raise-user-error 'arbor-kernel message))
