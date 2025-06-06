;;; syntax.el --- helper functions to find syntactic context  -*- lexical-binding: t -*-

;; Copyright (C) 2000-2025 Free Software Foundation, Inc.

;; Maintainer: emacs-devel@gnu.org
;; Keywords: internal

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The main exported function is `syntax-ppss'.  You might also need
;; to call `syntax-ppss-flush-cache' or to add it to
;; before-change-functions'(although this is automatically done by
;; syntax-ppss when needed, but that might fail if syntax-ppss is
;; called in a context where before-change-functions is temporarily
;; let-bound to nil).

;;; Todo:

;; - do something about the case where the syntax-table is changed.
;;   This typically happens with tex-mode and its `$' operator.
;; - new functions `syntax-state', ... to replace uses of parse-partial-state
;;   with something higher-level (similar to syntax-ppss-context).
;; - interaction with mmm-mode.

;;; Code:

;; Note: PPSS stands for `parse-partial-sexp state'

(eval-when-compile (require 'cl-lib))

;;; Applying syntax-table properties where needed.

(defvar syntax-propertize-function nil
  ;; Rather than a -functions hook, this is a -function because it's easier
  ;; to do a single scan than several scans: with multiple scans, one cannot
  ;; assume that the text before point has been propertized, so syntax-ppss
  ;; gives unreliable results (and stores them in its cache to boot, so we'd
  ;; have to flush that cache between each function, and we couldn't use
  ;; syntax-ppss-flush-cache since that would not only flush the cache but also
  ;; reset syntax-propertize--done which should not be done in this case).
  "Mode-specific function to apply `syntax-table' text properties.
It is the work horse of `syntax-propertize', which is called by things like
Font-Lock and indentation.

It is given two arguments, START and END: the start and end of the text to
which `syntax-table' might need to be applied.  Major modes can use this to
override the buffer's syntax table for special syntactic constructs that
cannot be handled just by the buffer's syntax-table.

The specified function may call `syntax-ppss' on any position
before END, but if it calls `syntax-ppss' on some
position and later modifies the buffer on some earlier position,
then it is its responsibility to call `syntax-ppss-flush-cache' to flush
the now obsolete ppss info from the cache.

Note: When this variable is a function, it must apply _all_ the
`syntax-table' properties needed in the given text interval.
Using both this function and other means to apply these
properties won't work properly.")

(defvar syntax-propertize-chunk-size 500)

(defvar-local syntax-propertize-extend-region-functions
  '(syntax-propertize-wholelines)
  "Special hook run just before proceeding to propertize a region.
This is used to allow major modes to help `syntax-propertize' find safe buffer
positions as beginning and end of the propertized region.  Its most common use
is to solve the problem of /identification/ of multiline elements by providing
a function that tries to find such elements and move the boundaries such that
they do not fall in the middle of one.
Each function is called with two arguments (START and END) and it should return
either a cons (NEW-START . NEW-END) or nil if no adjustment should be made.
These functions are run in turn repeatedly until they all return nil.
Put first the functions more likely to cause a change and cheaper to compute.")
;; Mark it as a special hook which doesn't use any global setting
;; (i.e. doesn't obey the element t in the buffer-local value).

(cl-defstruct (ppss
               (:constructor make-ppss)
               (:copier nil)
               (:type list))
  (depth nil :documentation "Depth in parens.")
  (innermost-start
   nil :documentation
   "Character address of start of innermost containing list; nil if none.")
  (last-complete-sexp-start
   nil :documentation
   "Character address of start of last complete sexp terminated.")
  (string-terminator nil :documentation "\
Non-nil if inside a string.
\(it is the character that will terminate the string, or t if the
string should be terminated by a generic string delimiter.)")
  (comment-depth nil :documentation "\
nil if outside a comment, t if inside a non-nestable comment,
else an integer (the current comment nesting).")
  (quoted-p nil :documentation "t if following a quote character.")
  (min-depth
   nil :documentation "The minimum depth in parens encountered during this scan.")
  (comment-style nil :documentation "Style of comment, if any.")
  (comment-or-string-start
   nil :documentation
   "Character address of start of comment or string; nil if not in one.")
  (open-parens
   nil :documentation
   "List of positions of currently open parens, outermost first.")
  (two-character-syntax nil :documentation "\
When the last position scanned holds the first character of a
\(potential) two character construct, the syntax of that position,
otherwise nil.  That construct can be a two character comment
delimiter or an Escaped or Char-quoted character."))

(defvar syntax-wholeline-max 10000
  "Maximum line length for syntax operations.
If lines are longer than that, syntax operations will treat them as chunks
of this size.  Misfontification may then occur.
This is a tradeoff between correctly applying the syntax rules,
and avoiding major slowdown on pathologically long lines.")

(defun syntax--lbp (&optional arg)
  "Like `line-beginning-position' but obeying `syntax-wholeline-max'."
  (let ((pos (point))
        (res (line-beginning-position arg)))
    (cond
     ((< (abs (- pos res)) syntax-wholeline-max) res)
     ;; For lines that are too long, round to the nearest multiple of
     ;; `syntax-wholeline-max'.  We use rounding rather than just
     ;; (min res (+ pos syntax-wholeline-max)) so that repeated calls
     ;; to `syntax-propertize-wholelines' don't keep growing the bounds,
     ;; i.e. it really behaves like additional line-breaks.
     ((< res pos)
      (let ((max syntax-wholeline-max))
        (max (point-min) (* max (truncate pos max)))))
     (t
      (let ((max syntax-wholeline-max))
        (min (point-max) (* max (ceiling pos max))))))))

(defun syntax-propertize-wholelines (beg end)
  "Extend the region delimited by BEG and END to whole lines.
This function is useful for
`syntax-propertize-extend-region-functions';
see Info node `(elisp) Syntax Properties'."
  ;; This let-binding was taken from
  ;; `font-lock-extend-region-wholelines' where it was used to avoid
  ;; inf-looping (Bug#21615) but for some reason it was not applied
  ;; here in syntax.el and was used only for the "beg" side.
  (let ((inhibit-field-text-motion t))
    (let ((new-beg (progn (goto-char beg)
                          (if (bolp) beg
                            (syntax--lbp))))
          (new-end (progn (goto-char end)
                          (if (bolp) end
                            (syntax--lbp 2)))))
      (unless (and (eql beg new-beg) (eql end new-end))
        (cons new-beg new-end)))))

(defun syntax-propertize-multiline (beg end)
  "Let `syntax-propertize' pay attention to the syntax-multiline property."
  (when (and (> beg (point-min))
	     (get-text-property (1- beg) 'syntax-multiline))
    (setq beg (or (previous-single-property-change beg 'syntax-multiline)
		  (point-min))))
  ;;
  (when (get-text-property end 'syntax-multiline)
    (setq end (or (text-property-any end (point-max)
				     'syntax-multiline nil)
		  (point-max))))
  (cons beg end))

(defun syntax-propertize--shift-groups-and-backrefs (re n)
  (let ((new-re (replace-regexp-in-string
                 "\\\\(\\?\\([0-9]+\\):"
                 (lambda (s)
                   (replace-match
                    (number-to-string
                     (+ n (string-to-number (match-string 1 s))))
                    t t s 1))
                 re t t))
        (pos 0))
    (while (string-match "\\\\\\([0-9]+\\)" new-re pos)
      (setq pos (+ 1 (match-beginning 1)))
      (when (save-match-data
              ;; With \N, the \ must be in a subregexp context, i.e.,
              ;; not in a character class or in a \{\} repetition.
              (subregexp-context-p new-re (match-beginning 0)))
        (let ((shifted (+ n (string-to-number (match-string 1 new-re)))))
          (when (> shifted 9)
            (error "There may be at most nine back-references"))
          (setq new-re (replace-match (number-to-string shifted)
                                      t t new-re 1)))))
    new-re))

(defmacro syntax-propertize-precompile-rules (&rest rules)
  "Return a precompiled form of RULES to pass to `syntax-propertize-rules'.
The arg RULES can be of the same form as in `syntax-propertize-rules'.
The return value is an object that can be passed as a rule to
`syntax-propertize-rules'.
I.e. this is useful only when you want to share rules among several
`syntax-propertize-function's."
  (declare (debug syntax-propertize-rules))
  ;; Precompile?  Yeah, right!
  ;; Seriously, tho, this is a macro for 2 reasons:
  ;; - we could indeed do some pre-compilation at some point in the future,
  ;;   e.g. fi/when we switch to a DFA-based implementation of
  ;;   syntax-propertize-rules.
  ;; - this lets Edebug properly annotate the expressions inside RULES.
  `',rules)

(defmacro syntax-propertize-rules (&rest rules)
  "Make a function that applies RULES for use in `syntax-propertize-function'.
The function will scan the buffer, applying the rules where they match.
The buffer is scanned a single time, like \"lex\" would, rather than once
per rule.

Each RULE can be a symbol, in which case that symbol's value should be,
at macro-expansion time, a precompiled set of rules, as returned
by `syntax-propertize-precompile-rules'.

Otherwise, RULE should have the form (REGEXP HIGHLIGHT1 ... HIGHLIGHTn), where
REGEXP is an expression (evaluated at time of macro-expansion) that returns
a regexp, and where HIGHLIGHTs have the form (NUMBER SYNTAX) which means to
apply the property SYNTAX to the chars matched by the subgroup NUMBER
of the regular expression, if NUMBER did match.
SYNTAX is an expression that returns a value to apply as `syntax-table'
property.  Some expressions are handled specially:
- if SYNTAX is a string, then it is converted with `string-to-syntax';
- if SYNTAX has the form (prog1 EXP . EXPS) then the value returned by EXP
  will be applied to the buffer before running EXPS and if EXP is a string it
  is also converted with `string-to-syntax'.
The SYNTAX expression is responsible to save the `match-data' if needed
for subsequent HIGHLIGHTs.
Also SYNTAX is free to move point, in which case RULES may not be applied to
some parts of the text or may be applied several times to other parts.

Note: There may be at most nine back-references in the REGEXPs of
all RULES in total."
  (declare
   (debug (&rest &or symbolp            ;FIXME: edebug this eval step.
                 (def-form ;; `def-' needed to debug during macroexpansion.
                  &rest (numberp
                         [&or stringp   ;FIXME: Use &wrap
                              ;; `def-' because this is the body of a function.
                              ("prog1" [&or stringp def-form] def-body)
                              def-form])))))
  (let ((newrules nil))
    (while rules
      (if (symbolp (car rules))
          (setq rules (append (symbol-value (pop rules)) rules))
        (push (pop rules) newrules)))
    (setq rules (nreverse newrules)))
  (let* ((offset 0)
         (branches '())
         ;; We'd like to use a real DFA-based lexer, usually, but since Emacs
         ;; doesn't have one yet, we fallback on building one large regexp
         ;; and use groups to determine which branch of the regexp matched.
         (re
          (mapconcat
           (lambda (rule)
             (let* ((orig-re (eval (car rule) t))
                    (re orig-re))
               (when (and (assq 0 rule) (cdr rules))
                 ;; If there's more than 1 rule, and the rule want to apply
                 ;; highlight to match 0, create an extra group to be able to
                 ;; tell when *this* match 0 has succeeded.
                 (incf offset)
                 (setq re (concat "\\(" re "\\)")))
               (setq re (syntax-propertize--shift-groups-and-backrefs re offset))
               (let ((code '())
                     (condition
                      (cond
                       ((assq 0 rule) (if (zerop offset) t
                                        `(match-beginning ,offset)))
                       ((and (cdr rule) (null (cddr rule)))
                        `(match-beginning ,(+ offset (car (cadr rule)))))
                       (t
                        `(or ,@(mapcar
                                (lambda (case)
                                  `(match-beginning ,(+ offset (car case))))
                                (cdr rule))))))
                     (nocode t)
                     (offset offset))
                 ;; If some of the subgroup rules include Elisp code, then we
                 ;; need to set the match-data so it's consistent with what the
                 ;; code expects.  If not, then we can simply use shifted
                 ;; offset in our own code.
                 (unless (zerop offset)
                   (dolist (case (cdr rule))
                     (unless (stringp (cadr case))
                       (setq nocode nil)))
                   (unless nocode
                     (push `(let ((md (match-data 'ints)))
                              ;; Keep match 0 as is, but shift everything else.
                              (setcdr (cdr md) (nthcdr ,(* (1+ offset) 2) md))
                              (set-match-data md))
                           code)
                     (setq offset 0)))
                 ;; Now construct the code for each subgroup rules.
                 (dolist (case (cdr rule))
                   (cl-assert (null (cddr case)))
                   (let* ((gn (+ offset (car case)))
                          (action (nth 1 case))
                          (thiscode
                           (cond
                            ((stringp action)
                             `((put-text-property
                                (match-beginning ,gn) (match-end ,gn)
                                'syntax-table
                                ',(string-to-syntax action))))
                            ((eq (car-safe action) 'ignore)
                             (cdr action))
                            ((eq (car-safe action) 'prog1)
                             (if (stringp (nth 1 action))
                                 `((put-text-property
                                    (match-beginning ,gn) (match-end ,gn)
                                    'syntax-table
                                    ',(string-to-syntax (nth 1 action)))
                                   ,@(nthcdr 2 action))
                               `((let ((mb (match-beginning ,gn))
                                       (me (match-end ,gn)))
                                   ,(macroexp-let2 nil syntax (nth 1 action)
                                      `(progn
                                         (if ,syntax
                                             (put-text-property
                                              mb me 'syntax-table ,syntax))
                                         ,@(nthcdr 2 action)))))))
                            (t
                             `((let ((mb (match-beginning ,gn))
                                     (me (match-end ,gn))
                                     (syntax ,action))
                                 (if syntax
                                     (put-text-property
                                      mb me 'syntax-table syntax))))))))

                     (if (or (not (cddr rule)) (zerop gn))
                         (setq code (nconc (nreverse thiscode) code))
                       (push `(if (match-beginning ,gn)
                                  ;; Try and generate clean code with no
                                  ;; extraneous progn.
                                  ,(if (null (cdr thiscode))
                                       (car thiscode)
                                     `(progn ,@thiscode)))
                             code))))
                 (push (cons condition (nreverse code))
                       branches))
               (incf offset (regexp-opt-depth orig-re))
               re))
           rules
           "\\|")))
    `(lambda (start end)
       (goto-char start)
       (while (and (< (point) end)
                   (re-search-forward ,re end t))
         (cond ,@(nreverse branches))))))

(defun syntax-propertize-via-font-lock (keywords)
  "Propertize for syntax using font-lock syntax.
KEYWORDS obeys the format used in `font-lock-syntactic-keywords'.
The return value is a function (with two parameters, START and
END) suitable for `syntax-propertize-function'."
  (lambda (start end)
    (with-no-warnings
      (let ((font-lock-syntactic-keywords keywords))
        (font-lock-fontify-syntactic-keywords-region start end)
        ;; In case it was eval'd/compiled.
        (setq keywords font-lock-syntactic-keywords)))))

(defvar-local syntax-ppss-table nil
  "Syntax-table to use during `syntax-ppss', if any.")

(defun syntax-propertize--in-process-p ()
  "Non-nil if we're inside `syntax-propertize'.
This is used to avoid infinite recursion as well as to handle cases where
`syntax-ppss' is called when the final `syntax-table' properties have not
yet been setup, in which case we may end up putting invalid info into the cache.
It's also used so that `syntax-ppss-flush-cache' can be used from within
`syntax-propertize' without ruining the `syntax-table' already set."
  (eq syntax-propertize--done most-positive-fixnum))

(defvar-local syntax-ppss--updated-cache nil)

(defun syntax-propertize (pos)
  "Ensure that syntax-table properties are set until POS (a buffer point)."
  (when (< syntax-propertize--done pos)
    (if (memq syntax-propertize-function '(nil ignore))
        (setq syntax-propertize--done (max (point-max) pos))
      ;; (message "Needs to syntax-propertize from %s to %s"
      ;;          syntax-propertize--done pos)
      (setq-local parse-sexp-lookup-properties t)
      (when (< syntax-propertize--done (point-min))
        ;; *Usually* syntax-propertize is called via syntax-ppss which
        ;; takes care of adding syntax-ppss-flush-cache to b-c-f, but this
        ;; is not *always* the case, so since we share a single "flush" function
        ;; between syntax-ppss and syntax-propertize, we also have to make
        ;; sure the flush function is installed here (bug#29767).
        (add-hook 'before-change-functions
	          #'syntax-ppss-flush-cache 99 t))
      (save-excursion
        (with-silent-modifications
          (with-syntax-table (or syntax-ppss-table (syntax-table))
            (make-local-variable 'syntax-propertize--done) ;Just in case!
            ;; Make sure we let-bind it only buffer-locally.
            (make-local-variable 'syntax-ppss--updated-cache)
            (let* ((start (max (min syntax-propertize--done (point-max))
                               (point-min)))
                   (end (max pos
                             (min (point-max)
                                  (+ start syntax-propertize-chunk-size))))
                   (first t)
                   (repeat t)
                   (syntax-ppss--updated-cache nil))
              (while repeat
                (setq repeat nil)
                (run-hook-wrapped
                 'syntax-propertize-extend-region-functions
                 (lambda (f)
                   ;; Bind `syntax-propertize--done' to avoid recursion!
                   (let* ((syntax-propertize--done most-positive-fixnum)
                          (new (funcall f start end)))
                     (if (or (null new)
                             (and (>= (car new) start) (<= (cdr new) end)))
                         nil
                       (setq start (car new))
                       (setq end (cdr new))
                       ;; If there's been a change, we should go through the
                       ;; list again since this new position may
                       ;; warrant a different answer from one of the funs we've
                       ;; already seen.
                       (unless first (setq repeat t))))
                   (setq first nil))))
              ;; Flush ppss cache between the original value of `start' and that
              ;; set above by syntax-propertize-extend-region-functions.
              (syntax-ppss-flush-cache start)
              ;; Move the limit before calling the function, so it's
              ;; done in case of errors.
              (setq syntax-propertize--done end)
              ;; (message "syntax-propertizing from %s to %s" start end)
              (remove-text-properties start end
                                      '(syntax-table nil syntax-multiline nil))
              ;; Bind `syntax-propertize--done' to avoid recursion!
              (let ((syntax-propertize--done most-positive-fixnum))
                (funcall syntax-propertize-function start end)
                (when syntax-ppss--updated-cache
                  ;; `syntax-ppss' was called and updated the cache while we
                  ;; were propertizing so we need to flush the part of the
                  ;; cache that may have been rendered out-of-date by the new
                  ;; properties.
                  ;; We used to require syntax-propertize-functions to do that
                  ;; manually when applicable, but nowadays the `syntax-ppss'
                  ;; cache can be updated by too many functions, so the author
                  ;; of the syntax-propertize-function may not be aware it
                  ;; can happen.
                  (syntax-ppss-flush-cache start))))))))))

;;; Link syntax-propertize with syntax.c.

(defvar syntax-propertize-chunks
  ;; We're not sure how far we'll go.  In my tests, using chunks of 2000
  ;; brings the overhead to something negligible.  Passing ‘charpos’ directly
  ;; also works (basically works line-by-line) but results in an overhead which
  ;; I thought was a bit too high (like around 50%).
  2000)

(defun internal--syntax-propertize (charpos)
  ;; FIXME: Called directly from C.
  (save-match-data
    (syntax-propertize (min (+ syntax-propertize-chunks charpos) (point-max)))))

;;; Incrementally compute and memoize parser state.

(defsubst syntax-ppss-depth (ppss)
  (nth 0 ppss))

(defun syntax-ppss-toplevel-pos (ppss)
  "Get the latest syntactically outermost position found in a syntactic scan.
PPSS is a scan state, as returned by `parse-partial-sexp' or `syntax-ppss'.
An \"outermost position\" means one that it is outside of any syntactic entity:
outside of any parentheses, comments, or strings encountered in the scan.
If no such position is recorded in PPSS (because the end of the scan was
itself at the outermost level), return nil."
  (or (car (nth 9 ppss))
      (nth 8 ppss)))

(defsubst syntax-ppss-context (ppss)
  "Say whether PPSS is a string, a comment, or something else.
If PPSS is a string, the symbol `string' is returned.  If it's a
comment, the symbol `comment' is returned.  If it's something
else, nil is returned."
  (cond
   ((nth 3 ppss) 'string)
   ((nth 4 ppss) 'comment)
   (t nil)))

(defvar syntax-ppss-max-span 20000
  "Threshold below which cache info is deemed unnecessary.
We try to make sure that cache entries are at least this far apart
from each other, to avoid keeping too much useless info.")

(defvar syntax-begin-function nil
  "Function to move back outside of any comment/string/paren.
This function should move the cursor back to some syntactically safe
point (where the PPSS is equivalent to nil).")
(make-obsolete-variable 'syntax-begin-function nil "25.1")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Several caches.
;;
;; Because `syntax-ppss' is equivalent to (parse-partial-sexp
;; (POINT-MIN) x), we need either to empty the cache when we narrow
;; the buffer, which is suboptimal, or we need to use several caches.
;; We use two of them, one for widened buffer, and one for narrowing.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar-local syntax-ppss-wide nil
  "Cons of two elements (LAST . CACHE).
Where LAST is a pair (LAST-POS . LAST-PPS) caching the last invocation
and CACHE is a list of (POS . PPSS) pairs, in decreasing POS order.
These are valid when the buffer has no restriction.")

(defvar-local syntax-ppss-narrow nil
  "Same as `syntax-ppss-wide' but for a narrowed buffer.")

(defvar-local syntax-ppss-narrow-start nil
  "Start position of the narrowing for `syntax-ppss-narrow'.")

(define-obsolete-function-alias 'syntax-ppss-after-change-function
  #'syntax-ppss-flush-cache "27.1")
(defun syntax-ppss-flush-cache (beg &rest _ignored)
  "Flush the cache of `syntax-ppss' starting at position BEG."
  ;; Set syntax-propertize to refontify anything past beg.
  (unless (syntax-propertize--in-process-p)
    (setq syntax-propertize--done (min beg syntax-propertize--done)))
  ;; Flush invalid cache entries.
  (dolist (cell (list syntax-ppss-wide syntax-ppss-narrow))
    (pcase cell
      (`(,last . ,cache)
       (while (and cache (> (caar cache) beg))
         (setq cache (cdr cache)))
       ;; Throw away `last' value if made invalid.
       (when (< beg (or (car last) 0))
         ;; If syntax-begin-function jumped to BEG, then the old state at BEG can
         ;; depend on the text after BEG (which is presumably changed).  So if
         ;; BEG=(car (nth 10 syntax-ppss-last)) don't reuse that data because the
         ;; assumed nil state at BEG may not be valid any more.
         (if (<= beg (or (syntax-ppss-toplevel-pos (cdr last))
                         (nth 3 last)
                         0))
	     (setq last nil)
           (setcar last nil)))
       ;; Unregister if there's no cache left.  Sadly this doesn't work
       ;; because `before-change-functions' is temporarily bound to nil here.
       ;; (unless cache
       ;;   (remove-hook 'before-change-functions #'syntax-ppss-flush-cache t))
       (setcar cell last)
       (setcdr cell cache)))
    ))

;; FIXME: Explain this variable.  Currently only its last (5th) slot is used.
;; Perhaps the other slots should be removed?
;; This variable is only used when `syntax-begin-function' is used and
;; will hence be removed together with `syntax-begin-function'.
(defvar syntax-ppss-stats
  [(0 . 0) (0 . 0) (0 . 0) (0 . 0) (0 . 0) (2 . 2500)]
  "Statistics about which case is more/less frequent in `syntax-ppss'.
The 5th slot drives the heuristic to use `syntax-begin-function'.
The rest is only useful if you're interested in tweaking the algorithm.")

(defun syntax-ppss-stats ()
  (mapcar (lambda (x)
	    (condition-case nil
		(cons (car x) (/ (cdr x) (car x)))
	      (error nil)))
	  syntax-ppss-stats))
(defun syntax-ppss--update-stats (i old new)
  (let ((pair (aref syntax-ppss-stats i)))
    (incf (car pair))
    (incf (cdr pair) (- new old))))

(defun syntax-ppss--data ()
  (if (eq (point-min) 1)
      (progn
        (unless syntax-ppss-wide
          (setq syntax-ppss-wide (cons nil nil)))
        syntax-ppss-wide)
    (unless (eq syntax-ppss-narrow-start (point-min))
      (setq syntax-ppss-narrow-start (point-min))
      (setq syntax-ppss-narrow (cons nil nil)))
    syntax-ppss-narrow))

(defun syntax-ppss (&optional pos)
  "Parse-Partial-Sexp State at POS, defaulting to point.
If POS is given, this function moves point to POS.

The returned value is the same as that of `parse-partial-sexp'
run from `point-min' to POS except that values at positions 2 and 6
in the returned list (counting from 0) cannot be relied upon.

It is necessary to call `syntax-ppss-flush-cache' explicitly if
this function is called while `before-change-functions' is
temporarily let-bound, or if the buffer is modified without
running the hook."
  ;; Default values.
  (unless pos (setq pos (point)))
  (syntax-propertize pos)
  ;;
  (with-syntax-table (or syntax-ppss-table (syntax-table))
    (let* ((cell (syntax-ppss--data))
           (ppss-last (car cell))
           (ppss-cache (cdr cell))
           (old-ppss (cdr ppss-last))
           (old-pos (car ppss-last))
           (ppss nil)
           (pt-min (point-min)))
      (if (and old-pos (> old-pos pos)) (setq old-pos nil))
      ;; Use the OLD-POS if usable and close.  Don't update the `last' cache.
      (condition-case nil
          (if (and old-pos (< (- pos old-pos)
                              ;; The time to use syntax-begin-function and
                              ;; find PPSS is assumed to be about 2 * distance.
                              (let ((pair (aref syntax-ppss-stats 5)))
                                (/ (* 2 (cdr pair)) (car pair)))))
              (progn
                (syntax-ppss--update-stats 0 old-pos pos)
                (parse-partial-sexp old-pos pos nil nil old-ppss))

            (cond
             ;; Use OLD-PPSS if possible and close enough.
             ((and (not old-pos) old-ppss
                   ;; If `pt-min' is too far from `pos', we could try to use
                   ;; other positions in (nth 9 old-ppss), but that doesn't
                   ;; seem to happen in practice and it would complicate this
                   ;; code (and the before-change-function code even more).
                   ;; But maybe it would be useful in "degenerate" cases such
                   ;; as when the whole file is wrapped in a set
                   ;; of parentheses.
                   (setq pt-min (or (syntax-ppss-toplevel-pos old-ppss)
                                    (nth 2 old-ppss)))
                   (<= pt-min pos) (< (- pos pt-min) syntax-ppss-max-span))
              (syntax-ppss--update-stats 1 pt-min pos)
              (setq ppss (parse-partial-sexp pt-min pos)))
             ;; The OLD-* data can't be used.  Consult the cache.
             (t
              (let ((cache-pred nil)
                    (cache ppss-cache)
                    (pt-min (point-min))
                    ;; I differentiate between PT-MIN and PT-BEST because
                    ;; I feel like it might be important to ensure that the
                    ;; cache is only filled with 100% sure data (whereas
                    ;; syntax-begin-function might return incorrect data).
                    ;; Maybe that's just stupid.
                    (pt-best (point-min))
                    (ppss-best nil))
                ;; look for a usable cache entry.
                (while (and cache (< pos (caar cache)))
                  (setq cache-pred cache)
                  (setq cache (cdr cache)))
                (if cache (setq pt-min (caar cache) ppss (cdar cache)))

                ;; Setup the before-change function if necessary.
                (unless (or ppss-cache ppss-last)
                  ;; Note: combine-change-calls-1 needs to be kept in sync
                  ;; with this!
                  (add-hook 'before-change-functions
                            #'syntax-ppss-flush-cache
                            ;; We should be either the very last function on
                            ;; before-change-functions or the very first on
                            ;; after-change-functions.
                            99 t))

                ;; Use the best of OLD-POS and CACHE.
                (if (or (not old-pos) (< old-pos pt-min))
                    (setq pt-best pt-min ppss-best ppss)
                  (syntax-ppss--update-stats 4 old-pos pos)
                  (setq pt-best old-pos ppss-best old-ppss))

                ;; Use the `syntax-begin-function' if available.
                ;; We could try using that function earlier, but:
                ;; - The result might not be 100% reliable, so it's better to use
                ;;   the cache if available.
                ;; - The function might be slow.
                ;; - If this function almost always finds a safe nearby spot,
                ;;   the cache won't be populated, so consulting it is cheap.
                (when (and syntax-begin-function
                           (progn (goto-char pos)
                                  (funcall syntax-begin-function)
                                  ;; Make sure it's better.
                                  (> (point) pt-best))
                           ;; Simple sanity checks.
                           (< (point) pos) ; backward-paragraph can fail here.
                           (not (memq (get-text-property (point) 'face)
                                      '(font-lock-string-face font-lock-doc-face
                                                              font-lock-comment-face))))
                  (syntax-ppss--update-stats 5 (point) pos)
                  (setq pt-best (point) ppss-best nil))

                (cond
                 ;; Quick case when we found a nearby pos.
                 ((< (- pos pt-best) syntax-ppss-max-span)
                  (syntax-ppss--update-stats 2 pt-best pos)
                  (setq ppss (parse-partial-sexp pt-best pos nil nil ppss-best)))
                 ;; Slow case: compute the state from some known position and
                 ;; populate the cache so we won't need to do it again soon.
                 (t
                  (syntax-ppss--update-stats 3 pt-min pos)
                  (setq syntax-ppss--updated-cache t)

                  ;; If `pt-min' is too far, add a few intermediate entries.
                  (while (> (- pos pt-min) (* 2 syntax-ppss-max-span))
                    (setq ppss (parse-partial-sexp
                                pt-min (setq pt-min (/ (+ pt-min pos) 2))
                                nil nil ppss))
                    (push (cons pt-min ppss)
                          (if cache-pred (cdr cache-pred) ppss-cache)))

                  ;; Compute the actual return value.
                  (setq ppss (parse-partial-sexp pt-min pos nil nil ppss))

                  ;; Debugging check.
                  ;; (let ((real-ppss (parse-partial-sexp (point-min) pos)))
                  ;;   (setcar (last ppss 4) 0)
                  ;;   (setcar (last real-ppss 4) 0)
                  ;;   (setcar (last ppss 8) nil)
                  ;;   (setcar (last real-ppss 8) nil)
                  ;;   (unless (equal ppss real-ppss)
                  ;;     (message "!!Syntax: %s != %s" ppss real-ppss)
                  ;;     (setq ppss real-ppss)))

                  ;; Store it in the cache.
                  (let ((pair (cons pos ppss)))
                    (if cache-pred
                        (if (> (- (caar cache-pred) pos) syntax-ppss-max-span)
                            (push pair (cdr cache-pred))
                          (setcar cache-pred pair))
                      (if (or (null ppss-cache)
                              (> (- (caar ppss-cache) pos)
                                 syntax-ppss-max-span))
                          (push pair ppss-cache)
                        (setcar ppss-cache pair)))))))))

            (setq syntax-ppss--updated-cache t)
            (setq ppss-last (cons pos ppss))
            (setcar cell ppss-last)
            (setcdr cell ppss-cache)
            ppss)
        (args-out-of-range
         ;; If the buffer is more narrowed than when we built the cache,
         ;; we may end up calling parse-partial-sexp with a position before
         ;; point-min.  In that case, just parse from point-min assuming
         ;; a nil state.
         (parse-partial-sexp (point-min) pos))))))

;; Debugging functions

(defun syntax-ppss-debug ()
  (let ((pt nil)
	(min-diffs nil))
    (dolist (x (append (cdr (syntax-ppss--data)) (list (cons (point-min) nil))))
      (when pt (push (- pt (car x)) min-diffs))
      (setq pt (car x)))
    min-diffs))

(provide 'syntax)

;;; syntax.el ends here
