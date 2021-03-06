#lang racket/base
(require racket/match
         racket/trace
         (only-in "alloc-rules.rkt" solidify-τ normalize-taddr)
         "common.rkt"
         "language.rkt"
         "tast.rkt"
         "type-formers.rkt" "types.rkt")
(provide coerce-language)

(define (deheapify-ct ct)
  (ct-replace-τ ct (solidify-τ (πct ct))))

(define (coerce-pattern pat)
  (define ct (Typed-ct pat))
;  (printf "pattern~%")
  (define ct* (deheapify-ct ct))
  (match ct
    [(Deref taddr ct)
     (PDeref (with-stx-stx pat) ct
             (coerce-pattern (pattern-replace-ct ct pat))
             taddr
             #f)]
    [_
     ;; Not immediately dereferencing, so continue structurally
     (match pat
       ;; All implicit dereferences become explicit.
       [(PDeref sy _ p taddr imp) (PDeref sy ct* (coerce-pattern p) taddr #f)]
       [(PName sy _ x p) (PName sy ct* x (coerce-pattern p))]
       [(PVariant sy _ n ps) (PVariant sy ct* n (map coerce-pattern ps))]
        
       [(or (and (PMap-with sy _ k v p) (app (λ _ PMap-with) ctor))
            (and (PMap-with* sy _ k v p) (app (λ _ PMap-with*) ctor)))
        (ctor sy ct* (coerce-pattern k) (coerce-pattern v) (coerce-pattern p))]
        
       [(or (and (PSet-with sy _ v p) (app (λ _ PSet-with) ctor))
            (and (PSet-with* sy _ v p) (app (λ _ PSet-with*) ctor)))
        (ctor sy ct* (coerce-pattern v) (coerce-pattern p))]

       [(PIsType sy _ p) (PIsType sy ct* (coerce-pattern p))]
       [(or (? PTerm?) (? PWild?))
        pat]
       [_ (error 'coerce-pattern "Unsupported pattern: ~a" pat)])]))

(define (do-deref e [lm #f])
  (define ct (Typed-ct e))
  (match ct
    ;; Unanticipated lookup (from unannotated semantics)
    [(Deref taddr ct)
     (EStore-lookup (with-stx-stx e)
                    (to-cast ct)
                    (expr-replace-ct (Check (normalize-taddr taddr)) e)
                    (or lm (get-option 'lm))
                    #f)]
    [_
     (match e
       ;; The expression anticipated a lookup
       [(EStore-lookup sy ct k lm (? TAddr? imp))
        (define kct (Typed-ct k))
        (define taddr* (normalize-taddr imp))
        (EStore-lookup sy
                       (Check taddr*)
                       (coerce-expr (replace-ct (ct-replace-τ kct taddr*) k))
                       lm #f)]
       [_ #f])]))

(define (do-store e)
  (match e
    [(EHeapify sy ct e* taddr tag)
;     (printf "heapify~%")
     (define cτ (deheapify-ct ct))
     (define ctaddr (Check (normalize-taddr taddr)))
     (define x (gensym 'temp))
     (define a (gensym 'tempa))
     (define e-coerced (coerce-expr (expr-replace-ct cτ e*)))
     ;; Make a tidier translation if we would just rebind a name.
     ;; There is no shadowing, so this is safe.
     (define-values (bind ref)
       (if (ERef? e-coerced)
           (values '() e-coerced)
           (values (list (Where sy (PName sy cτ x (PWild sy cτ)) e-coerced))
                   (ERef sy cτ x))))
     (ELet sy
           ctaddr
           (append bind
                   (list (Where sy
                         (PName sy ctaddr a (PWild sy ctaddr))
                         (EAlloc sy ctaddr tag))
                  (Update sy (ERef sy ctaddr a) ref)))
           (ERef sy ctaddr a))]
    [_
     ;; Even if e is THeap, if the typechecker is correct, the coercion is deeper in the expression.
     #f]))

(define (coerce-expr e)
  (define e* (do-deref e))
  (if e*
      (coerce-expr e*)
      (or (do-store e)
          (let* ([ct (Typed-ct e)]
                 [ct* (begin (displayln "Expr") (deheapify-ct ct))])
            (match e
              ;; 
              [(EStore-lookup sy _ k lm imp)
               (when imp (error 'coerce-expr "Must be done with do-deref ~a" e))
               (EStore-lookup sy ct* (coerce-expr k) lm #f)]
              [(? EHeapify?)
               (error 'coerce-expr "Should be removed: ~a" e)]
              ;; Structurally coerce
              [(EVariant sy _ n tag τs es)
               (EVariant sy ct* n tag τs (map coerce-expr es))]
              [(EExtend sy _ m tag k v)
               (EExtend sy ct* (coerce-expr m) tag
                        (coerce-expr k)
                        (coerce-expr v))]
              [(ESet-add sy _ e tag es)
               (ESet-add sy ct* (coerce-expr e) tag
                         (map coerce-expr es))]

              [(ECall sy _ mf τs es)
               (ECall sy ct* mf τs (map coerce-expr es))]
              [(ELet sy _ bus body)
               (ELet sy ct* (map coerce-bu bus) (coerce-expr body))]
              [(EMatch sy _ de rules)
               (EMatch sy ct* (coerce-expr de) (map coerce-rule rules))]
              [(EIf sy _ g th el)
               (EIf sy ct* (coerce-rule g) (coerce-rule th) (coerce-rule el))]
              [(ESet-union sy _ es)
               (ESet-union sy ct* (map coerce-rule es))]
              [(ESet-intersection sy _ e es)
               (ESet-intersection sy ct* (coerce-expr e) (map coerce-expr es))]
              [(ESet-subtract sy _ e es)
               (ESet-subtract sy ct* (coerce-expr e) (map coerce-expr es))]
              [(ESet-member sy _ e v)
               (ESet-member sy ct* (coerce-expr e) (coerce-expr v))]
              [(EMap-lookup sy _ m k)
               (EMap-lookup sy ct* (coerce-expr m) (coerce-expr k))]
              [(EMap-has-key sy _ m k)
               (EMap-has-key sy ct* (coerce-expr m) (coerce-expr k))]
              [(EMap-remove sy _ m k)
               (EMap-remove sy ct* (coerce-expr m) (coerce-expr k))]
              [(or (? ERef?) (? EEmpty-Map?) (? EEmpty-Set?) (? EAlloc?) (? EUnquote?) (? EExternal?))
               e]
              [_ (error 'coerce-expr "Unrecognized expression form: ~a" e)])))))

(define (coerce-bu bu)
  (match bu
    [(Where sy p e) (Where sy (coerce-pattern p) (coerce-expr e))]
    [(Update sy k e) (Update sy (coerce-expr k) (coerce-expr e))]
    [(When sy e) (When sy (coerce-expr e))]
    [(Unless sy e) (Unless sy (coerce-expr e))]))

(define (coerce-rule r)
  (match r
    [(Rule sy name lhs rhs bus)
     (Rule sy name (coerce-pattern lhs) (coerce-expr rhs) (map coerce-bu bus))]
    [_ (error 'coerce-rule "Bad rule ~a" r)]))

(define (coerce-metafunction mf)
  (match-define (Metafunction name τ rules) mf)
  (Metafunction name τ (map coerce-rule rules)))

(define (coerce-language R metafunctions)
  (values (map coerce-rule R) (map coerce-metafunction metafunctions)))
