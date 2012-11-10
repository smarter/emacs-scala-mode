;;; scala-mode.el - Major mode for editing scala, indenting
;;; Copyright (c) 2012 Heikki Vesalainen
;;; For information on the License, see the LICENSE file

(provide 'scala-mode-indent)

(require 'scala-mode-syntax)
(require 'scala-mode-lib)

(defcustom scala-indent:step 2
  "The number of spaces an indentation step should be. The actual
indentation will be one or two steps depending on context."
  :type 'integer
  :group 'scala)

(defcustom scala-indent:align-forms t
  "Whether or not to align 'else', 'yield', 'catch', 'finally'
below their respective expression start. When non-nil, identing
will be

val x = if (foo)
          bar
        else
          zot

when nil, the same will indent as

val x = if (foo)
    bar
  else
    zot
"
  :type 'boolean
  :group 'scala)

(defcustom scala-indent:indent-value-expression t
  "Whether or not to indent multi-line value expressions, with
one extra step. When true, indenting will be

val x = try {
    some()
  } catch {
    case e => other
  } finally {
    clean-up()
  }

When nil, the same will indent as

val x = try {
  some()
} catch {
  case e => other
} finally {
  clean-up()
}
"
  :type 'boolean
  :group 'scala)

(defcustom scala-indent:align-parameters t
  "Whether or not to indent parameter lists so that next
  parameter lines always align under the first parameter. When
  non-nil, indentation will be

def foo(x: Int, y: List[Int]
        z: Int)

val x = foo(1, List(1, 2, 3) map (i => 
              i + 1
            ), 2)

When nil, the same will indent as

def foo(x: Int, y: List[Int]
        z: Int)

val x = foo(1, List(1, 2, 3) map (i => 
    i + 1
  ), 2)
"
  :type 'boolean
  :group 'scala)



(defconst scala-indent:eager-strategy 0
  "See 'scala-indent:run-on-strategy'")
(defconst scala-indent:operator-strategy 1
  "See 'scala-indent:run-on-strategy'")
(defconst scala-indent:reluctant-strategy 2
  "See 'scala-indent:run-on-strategy'")
(defconst scala-indent:keywords-only-strategy 3
  "A strategy used internally by indent engine")

(defcustom scala-indent:default-run-on-strategy 2
  "What strategy to use for detecting run-on lines, i.e. lines
that continue a statement from the previous line. Possible values
are: 

'reluctant', which marks only lines that begin with -- or
that follow a line that ends with -- a reserved word that cannot start
or end a line, such as 'with'.

'operators', which extends the previous strategy by marking also
lines that begin with -- or that follow a line that ends with --
an operator character. For example, '+', '-', etc.

'eager', which marks all rows which could be run-ons, i.e. which
are not ruled out by the language specification.
"
  :type `(choice (const :tag "eager" ,scala-indent:eager-strategy)
                 (const :tag "operators" ,scala-indent:operator-strategy)
                 (const :tag "reluctant" ,scala-indent:reluctant-strategy))
  :group 'scala)

(make-variable-buffer-local 'scala-indent:effective-run-on-strategy)

(defun scala-indent:run-on-strategy ()
  "Returns the currently effecti run-on strategy"
  (or scala-indent:effective-run-on-strategy
      scala-indent:default-run-on-strategy
      scala-indent:eager-strategy))

(defun scala-indent:toggle-effective-run-on-strategy ()
  "If effective run-on strategy is not set, it is set as follows:
- if default is eager or operators, then it is set to reluctant
- if default is reluctant, then it is set to eager. If it is set, 
it is nilled."
  (if scala-indent:effective-run-on-strategy
      (setq scala-indent:effective-run-on-strategy nil)
    (let ((new-strategy
           (cond ((= (scala-indent:run-on-strategy)
                     scala-indent:reluctant-strategy)
                  scala-indent:eager-strategy)
                 ((or (= (scala-indent:run-on-strategy)
                         scala-indent:operator-strategy)
                      (= (scala-indent:run-on-strategy)
                         scala-indent:eager-strategy))
                  scala-indent:reluctant-strategy))))
      (setq scala-indent:effective-run-on-strategy new-strategy))))

(defun scala-indent:reset-effective-run-on-strategy ()
  (setq scala-indent:effective-run-on-strategy nil))

(defun scala-indent:rotate-run-on-strategy ()
  (interactive)
  (let ((new-strategy
         (cond ((= scala-indent:default-run-on-strategy
                         scala-indent:reluctant-strategy)
                scala-indent:operator-strategy)
               ((= scala-indent:default-run-on-strategy
                         scala-indent:operator-strategy)
                scala-indent:eager-strategy)
               ((= scala-indent:default-run-on-strategy
                         scala-indent:eager-strategy)
                scala-indent:reluctant-strategy))))
    (setq scala-indent:default-run-on-strategy new-strategy)
;    (message "scala-indent:default-run-on-strategy set to %s" scala-indent:default-run-on-strategy)
    ))
          
(defun scala-indent:backward-sexp-to-beginning-of-line ()
  "Skip sexps backwards until reaches beginning of line (i.e. the
point is at the first non whitespace or comment character). It
does not move outside enclosin list. Returns the current point or
nil if the beginning of line could not be reached because of
enclosing list."
  (let ((code-beg (scala-lib:point-after 
                   (scala-syntax:beginning-of-code-line))))
    (ignore-errors 
      (while (> (point) code-beg)
        (scala-syntax:backward-sexp)
        (when (< (point) code-beg) 
          ;; moved to previous line, set new target
          (setq code-beg (scala-lib:point-after 
                          (scala-syntax:beginning-of-code-line))))))
    (unless (> (point) code-beg)
      (point))))

(defun scala-indent:align-anchor ()
  "Go to beginning of line, if a) scala-indent:align-parameters
is nil or backward-sexp-to-beginning-of-line is non-nil. This has
the effect of staying within lists if
scala-indent:align-parameters is non-nil."
  (when (or (scala-indent:backward-sexp-to-beginning-of-line)
            (not scala-indent:align-parameters))
    (back-to-indentation)))

(defun scala-indent:value-expression-lead (start anchor)
  ;; calculate an indent lead. The lead is one indent step if there is
  ;; a '=' between anchor and start, otherwise 0.
  (if (and scala-indent:indent-value-expression 
           (ignore-errors 
             (save-excursion
               (let ((block-beg (nth 1 (syntax-ppss start))))
                 (goto-char anchor)
                 (scala-syntax:has-char-before ?= block-beg)))))
      scala-indent:step 0))

;;;
;;; Run-on 
;;;

(defconst scala-indent:mustNotTerminate-keywords-re
  (regexp-opt '("extends" "forSome" "match" "with") 'words)
  "Some keywords which occure only in the middle of an
expression")

(defconst scala-indent:mustNotTerminate-line-beginning-re
  (concat "\\(" scala-indent:mustNotTerminate-keywords-re 
          "\\|:\\("  scala-syntax:after-reserved-symbol-re "\\)\\)")
  "All keywords and symbols that cannot terminate a expression
and must be handled by run-on. Reserved-symbols not included.")

(defconst scala-indent:mustTerminate-re
  (concat "\\([,;\u21D2]\\|=>?" scala-syntax:end-of-code-line-re 
          "\\|\\s(\\|" scala-syntax:empty-line-re "\\)")
  "Symbols that must terminate an expression or start a
sub-expression, i.e the following expression cannot be a
run-on. This includes only parenthesis, '=', '=>', ',' and ';'
and the empty line")

(defconst scala-indent:mustNotContinue-re
  (regexp-opt '("abstract" "catch" "case" "class" "def" "do" "else" "final" 
                "finally" "for" "if" "implicit" "import" "lazy" "new" "object"
                "override" "package" "private" "protected" "return" "sealed" 
                "throw" "trait" "try" "type" "val" "var" "while" "yield")
              'words)
  "Words that we don't want to continue the previous line")

(defconst scala-indent:mustBeContinued-line-end-re
  (concat "\\(" scala-syntax:other-keywords-unsafe-re
          "\\|:" scala-syntax:end-of-code-line-re "\\)")
  "All keywords and symbols that cannot terminate a expression
and are infact a sign of run-on. Reserved-symbols not included.")

(defun scala-indent:run-on-p (&optional point strategy)
  "Returns t if the current point is in the middle of an expression"
  ;; use default strategy if none given
  (when (not strategy) (setq strategy (scala-indent:run-on-strategy)))
  (save-excursion
    (when point (goto-char point))
    (unless (eobp)
      ;; Note: ofcourse this 'cond' could be written as one big boolean
      ;; expression, but I doubt that would be so readable and
      ;; maintainable
      (cond 
       ;; NO: this line starts with close parenthesis
       ((= (char-syntax (char-after)) ?\))
        nil)
       ;; NO: the previous line must terminate
       ((save-excursion
          (scala-syntax:skip-backward-ignorable)
          (or (bobp)
              (scala-syntax:looking-back-empty-line-p)
              (scala-syntax:looking-back-token scala-indent:mustTerminate-re)))
        nil)
       ;; YES: in a region where newlines are disabled
       ((and (scala-syntax:newlines-disabled-p) 
             (not (= strategy scala-indent:keywords-only-strategy)))
        t)
       ;; NO: this line starts with a keyword that starts a new
       ;; expression (e.g. 'def' or 'class')
       ((looking-at scala-indent:mustNotContinue-re)
        nil)
       ;; NO: this line is the start of value body
       ((scala-indent:body-p)
        nil)
       ;; YES: eager strategy can stop here, everything is a run-on if no
       ;; counter evidence
       ((= strategy scala-indent:eager-strategy)
        t)
       ;; YES: this line must not terminate because it starts with a
       ;; middle of expression keyword
       ((looking-at scala-indent:mustNotTerminate-line-beginning-re)
        t)
       ;; YES: end of prev line must not terminate
       ((scala-syntax:looking-back-token
         scala-indent:mustBeContinued-line-end-re)
        t)
       ;; YES: this line starts with type param
       ((= (char-after) ?[)
        t)
       ;; YES: this line starts with open paren and the expression
       ;; after all parens is a run-on
       ((and (= (char-after) ?\()
             (save-excursion (scala-syntax:forward-parameter-groups)
                             (scala-syntax:skip-forward-ignorable)
                             (or (= (char-after) ?=)
                                 (= (char-after) ?{)
                                 (scala-indent:run-on-p nil strategy))))
        t)
       ;; NO: that's all for keywords-only strategy
       ((= strategy scala-indent:keywords-only-strategy)
        nil)
       ;; YES: this line starts with punctuation
       ((= (char-after) ?\.)
        t)
       ;; YES: prev line ended with punctuation
       ((scala-syntax:looking-back-token ".*[.]")
        t)
       ;; NO: that's all for reluctant-strategy
       ((= strategy scala-indent:reluctant-strategy)
        nil)
       ;; YES: this line starts with opchars
       ((save-excursion 
          (< 0 (skip-chars-forward scala-syntax:opchar-group)))
        t)
       ;; YES: prev line ends with opchars
       ((save-excursion 
          (scala-syntax:skip-backward-ignorable)
          (> 0 (skip-chars-backward scala-syntax:opchar-group)))
        t)
       ;; NO: else nil (only operator strategy should reach here)
       (t nil)))))

(defun scala-indent:run-on-line-p (&optional point strategy)
  "Returns t if the current point (or point at 'point) is on a
line that is a run-on from a previous line." 
  (save-excursion
    (when point (goto-char point))
    (scala-syntax:beginning-of-code-line)
    (scala-indent:run-on-p nil strategy)))

(defun scala-indent:goto-run-on-anchor (&optional point strategy)
  "Moves back to the point whose column will be used as the
anchor relative to which indenting for current point (or point
'point') is calculated. Returns the new point or nil if the point
is not on a run-on line."
  (when (scala-indent:run-on-line-p point strategy)
    (when point (goto-char point))
    (scala-syntax:beginning-of-code-line)
    (while (and (scala-indent:run-on-line-p nil strategy)
                (scala-syntax:skip-backward-ignorable)
                (scala-indent:backward-sexp-to-beginning-of-line)))
    (scala-indent:align-anchor)
    (point)))

(defconst scala-indent:double-indent-re
  (concat (regexp-opt '("with" "extends" "forSome") 'words)
          "\\|:\\("  scala-syntax:after-reserved-symbol-re "\\)"))

(defun scala-indent:resolve-run-on-step (start &optional anchor)
  "Resolves the appropriate indent step for run-on line at position
'start'"
  (save-excursion
    (goto-char anchor)
    (if (scala-syntax:looking-at-case-p)
        ;; case run-on lines get double indent, except '|' which get
        ;; special indents
        (progn (goto-char start)
               (- (* 2 scala-indent:step)
                  (skip-chars-forward "|")))
      (goto-char start)
      (cond 
       ;; some keywords get double indent
       ((or (looking-at scala-indent:double-indent-re)
            (scala-syntax:looking-back-token scala-indent:double-indent-re))
        (* 2 scala-indent:step))
       ;; no indent if the previous line is just close parens
       ;; ((save-excursion
       ;;    (scala-syntax:skip-backward-ignorable)
       ;;    (let ((end (point)))
       ;;      (scala-syntax:beginning-of-code-line)
       ;;      (skip-syntax-forward ")")
       ;;      (= (point) end)))
       ;;  0)
       ;; else normal indent
       (t (+ (if scala-indent:align-parameters 0
               (scala-indent:value-expression-lead start anchor))
             scala-indent:step))))))

(defconst scala-indent:forms-align-re
  (regexp-opt '("yield" "else" "catch" "finally") 'words))

(defun scala-indent:forms-align-p (&optional point)
  "Returns scala-syntax:beginning-of-code-line for the line on
which current point (or point 'point') is, if the line starts
with one of 'yield', 'else', 'catch' and 'finally', otherwise
nil. Also, the previous line must not be with '}'"
  (save-excursion
    (when point (goto-char point))
    (scala-syntax:beginning-of-code-line)
    (when (looking-at scala-indent:forms-align-re)
      (goto-char (match-beginning 0))
      (point))))
    

(defun scala-indent:goto-forms-align-anchor (&optional point)
  "Moves back to the point whose column will be used as the
anchor relative to which indenting of special words on beginning
of the line on which point (or point 'point') is, or nul if not
special word found. Special words include 'yield', 'else',
'catch' and 'finally'"
  (let ((special-beg (scala-indent:forms-align-p point)))
    (when special-beg
      (goto-char special-beg)
      (if (and (scala-syntax:looking-back-token "}")
               (save-excursion
                 (goto-char (match-beginning 0))
                 (= (match-beginning 0) (scala-lib:point-after (scala-syntax:beginning-of-code-line)))))
          (goto-char (match-beginning 0))
        (let ((anchor 
               (cond ((looking-at "\\<yield\\>")
                      ;; align with 'for'
                      (if (scala-syntax:search-backward-sexp "\\<for\\>")
                          (point)
                        (message "matching 'for' not found")
                        nil))
                     ((looking-at "\\<else\\>")
                      ;; align with 'if' or 'else if'
                      (if (scala-syntax:search-backward-sexp "\\<if\\>")
                          (if (scala-syntax:looking-back-token "\\<else\\>")
                              (goto-char (match-beginning 0))
                            (point))
                        nil))
                     ((looking-at "\\<catch\\>")
                      ;; align with 'try'
                      (if (scala-syntax:search-backward-sexp "\\<try\\>")
                          (point)
                        (message "matching 'try' not found")
                        nil))
                     ((looking-at "\\<finally\\>")
                      ;; align with 'try'
                      (if (scala-syntax:search-backward-sexp "\\<try\\>")
                          (point)
                        (message "matching 'try' not found")
                        nil)))))
          (if scala-indent:align-forms
              anchor
            (when anchor
              ;; TODO: merge to use the new function for this
              (when (scala-indent:backward-sexp-to-beginning-of-line)
                (back-to-indentation))
              (point))))))))

(defun scala-indent:resolve-forms-align-step (start anchor)
  (if scala-indent:align-forms
      0
    ;; TODO: merge to use step calculation
    0)) 

;;;
;;; Lists and enumerators
;;;

(defun scala-indent:goto-list-anchor-impl (point)
  (goto-char point)
  ;; find the first element of the list
  (if (not scala-indent:align-parameters)
      (progn (back-to-indentation) (point))
    (forward-comment (buffer-size))
    (if (= (line-number-at-pos point) 
           (line-number-at-pos))
        (goto-char point)
      (beginning-of-line))
    
    ;; align list with first non-whitespace character
    (skip-syntax-forward " ")
    (point)))

(defun scala-indent:goto-list-anchor (&optional point)
  "Moves back to the point whose column will be used to indent
list rows at current point (or point 'point'). Returns the new
point or nil if the point is not in a list element > 1."
  (let ((list-beg (scala-syntax:list-p point)))
    (when list-beg
      (scala-indent:goto-list-anchor-impl list-beg))))

(defun scala-indent:resolve-list-step (start anchor)
  (if scala-indent:align-parameters 
      0
    (scala-indent:resolve-block-step start anchor)))

(defun scala-indent:for-enumerators-p (&optional point)
  "Returns the point after opening parentheses if the current
point (or point 'point') is in a block of enumerators. Return nil
if not in a list of enumerators or at the first enumerator."
  (unless point (setq point (point)))
  (save-excursion
    (goto-char point)
    (scala-syntax:beginning-of-code-line)
    (let ((state (syntax-ppss point)))
      (unless (or (eobp) (= (char-syntax (char-after)) ?\)))
        (when (and state (nth 1 state))
          (goto-char (nth 1 state))
          (when (scala-syntax:looking-back-token scala-syntax:for-re)
            (forward-char)
            (forward-comment (buffer-size))
            (when (< (point) point)
              (1+ (nth 1 state)))))))))

(defun scala-indent:goto-for-enumerators-anchor (&optional point)
  "Moves back to the point whose column will be used to indent
for enumerator at current point (or point 'point'). Returns the new
point or nil if the point is not in a enumerator element > 1."
  (let ((enumerators-beg (scala-indent:for-enumerators-p point)))
    (when enumerators-beg
      (scala-indent:goto-list-anchor-impl enumerators-beg))))

;;;
;;; Body
;;;

(defconst scala-indent:value-keyword-re
  (regexp-opt '("if" "else" "yield" "for" "try" "finally" "catch") 'words))

(defun scala-indent:body-p (&optional point)
  "Returns the position of '=', 'if or 'else if' (TODO: or '=>')
symbol if current point (or point 'point) is on a line that
follows said symbol, or nil if not."
  (save-excursion
    (when point (goto-char point))
    (scala-syntax:beginning-of-code-line)
    (or (scala-syntax:looking-back-token scala-syntax:body-start-re 3)
        (progn
          ;; if, else if
          (when (scala-syntax:looking-back-token ")" 1)
            (goto-char (match-end 0))
            (backward-list))
          (when (scala-syntax:looking-back-token scala-indent:value-keyword-re)
            (goto-char (match-beginning 0))
            (when (and (looking-at "\\<if\\>")
                       (scala-syntax:looking-back-token "\\<else\\>"))
              (match-beginning 0))
            ;;TODO merge with teh function
            (when (and (not scala-indent:align-forms)
                       (scala-indent:backward-sexp-to-beginning-of-line))
              (back-to-indentation))
            (point))))))

(defun scala-indent:goto-body-anchor (&optional point)
  (let ((declaration-end (scala-indent:body-p point)))
    (when declaration-end
      (goto-char declaration-end)
      (if (looking-at scala-indent:value-keyword-re)
          (point)
        (when (scala-indent:backward-sexp-to-beginning-of-line)
          (scala-indent:goto-run-on-anchor 
           nil 
           scala-indent:keywords-only-strategy))
        (scala-indent:align-anchor)
        (point)))))

(defun scala-indent:resolve-body-step (start &optional anchor)
  (if (and (not (= start (point-max))) (= (char-after start) ?\{))
      0
    scala-indent:step))

;;;
;;; Block
;;;

(defun scala-indent:goto-block-anchor (&optional point)
  "Moves back to the point whose column will be used as the
anchor for calculating block indent for current point (or point
'point'). Returns point or (point-min) if not inside a block." 
  (let ((block-beg (nth 1 (syntax-ppss 
                           (scala-lib:point-after (beginning-of-line))))))
    (when block-beg
      ;; check if the opening paren is the first on the line,
      ;; if so, it is the anchor. If not, then go back to the
      ;; start of the line
      (goto-char block-beg)
      (if (= (point) (scala-lib:point-after
                      (scala-syntax:beginning-of-code-line)))
          (point)
        (goto-char (or (scala-syntax:looking-back-token 
                        scala-syntax:body-start-re 3) 
                       (point)))
        (scala-syntax:backward-parameter-groups)
        (when (scala-indent:backward-sexp-to-beginning-of-line)
          (scala-indent:goto-run-on-anchor nil 
                                           scala-indent:keywords-only-strategy))
        (scala-indent:align-anchor)
        (point)))))

(defun scala-indent:resolve-block-step (start anchor)
  "Resolves the appropriate indent step for block line at position
'start' relative to the block anchor 'anchor'."
  (let 
      ((lead (scala-indent:value-expression-lead start anchor)))
    (cond
     ;; at end of buffer
     ((= start (point-max)) (+ scala-indent:step lead))
     ;; block close parentheses line up with anchor in normal case
     ((= (char-syntax (char-after start)) ?\))
      (+ 0 lead)) 
     ;; case-lines indent normally, regardless of where they are
     ((scala-syntax:looking-at-case-p start)
      (+ scala-indent:step lead))
     ;; other than case-line in case-block get double indent
     ((save-excursion 
        (goto-char (1+ (nth 1 (syntax-ppss start))))
        (forward-comment (buffer-size))
        (and (scala-syntax:looking-at-case-p)
             (> start (match-beginning 0))))
      (+ (* 2 scala-indent:step) lead))
     ;; normal block line
     (t  (+ scala-indent:step lead)))))
  
;;;
;;; Open parentheses
;;;

(defun scala-indent:open-parentheses-line-p (&optional point)
  "Returns the position of the first character of the line,
if the current point (or point 'point') is on a line that starts
with an opening parentheses, or nil if not."
  (save-excursion
    (when point (goto-char point))    
    (scala-syntax:beginning-of-code-line)
    (if (looking-at "\\s(") (point) nil)))

(defun scala-indent:goto-open-parentheses-anchor (&optional point)
  "Moves back to the point whose column will be used as the
anchor for calculating opening parenthesis indent for the current
point (or point 'point'). Returns point or nil, if line does not
start with opening parenthesis."
  ;; There are four cases we need to consider:
  ;; 1. curry parentheses, i.e. 2..n parentheses groups.
  ;; 2. value body parentheses (follows '=').
  ;; 3. parameters, etc on separate line (who would be so mad?)
  ;; 4. non-value body parentheses (follows class, trait, new, def, etc).
  (let ((parentheses-beg (scala-indent:open-parentheses-line-p point)))
    (when parentheses-beg
      (goto-char parentheses-beg)
      (cond
       ;; case 1
       ((and scala-indent:align-parameters
             (= (char-after) ?\()
             (scala-indent:run-on-p)
             (scala-syntax:looking-back-token ")" 1))
        (scala-syntax:backward-parameter-groups)
        (let ((curry-beg (point)))
          (forward-char)
          (forward-comment (buffer-size))
          (if (= (line-number-at-pos curry-beg) 
                 (line-number-at-pos))
              (goto-char curry-beg)
            nil)))
       ;; case 2
       ((scala-syntax:looking-back-token "=" 1)
        nil) ; let body rule handle it
       ;; case 4
       ((and (= (char-after) ?\{)
             (scala-indent:goto-run-on-anchor 
              nil scala-indent:keywords-only-strategy)) ; use customized strategy
        (point))
       ;; case 3
       ;;((scala-indent:run-on-p)
       ;; (scala-syntax:skip-backward-ignorable)
       ;; (back-to-indentation)
       ;; (point))
       (t 
        nil)
       ))))

(defun scala-indent:resolve-open-parentheses-step (start anchor)
  "Resolves the appropriate indent step for an open paren
anchored at 'anchor'."
  (cond ((scala-syntax:looking-back-token ")")
;         (message "curry")
         0)
        ((save-excursion
           (goto-char anchor)
           ;; find =
           (scala-syntax:has-char-before ?= start))
         (message "=")
         scala-indent:step)
        (t
;         (message "normal at %d" (current-column))
         0)))

;;;
;;; Indentation engine
;;;

(defun scala-indent:apply-indent-rules (rule-indents &optional point)
  "Evaluates each rule, until one returns non-nil value. Returns
the sum of the value and the respective indent step, or nil if
nothing was applied."
  (when rule-indents
    (save-excursion
      (let* ((pos (scala-syntax:beginning-of-code-line))
             (rule-indent (car rule-indents))
             (rule-statement (car rule-indent))
             (indent-statement (cadr rule-indent))
             (anchor (funcall rule-statement point)))
        (if anchor
            (progn 
              (message "indenting acording to %s at %d" rule-statement anchor)
              (when (/= anchor (point))
                (error (format "Assertion error: anchor=%d, point=%d" anchor (point))))
              (+ (current-column)
                 (save-excursion
                   (if (functionp indent-statement)
                       (funcall indent-statement pos anchor) 
                     (eval indent-statement)))))
          (scala-indent:apply-indent-rules (cdr rule-indents)))))))

(defun scala-indent:calculate-indent-for-line (&optional point)
  "Calculate the appropriate indent for the current point or the
point 'point'. Returns the new column, or nil if the indent
cannot be determined."
  (or (scala-indent:apply-indent-rules
       `((scala-indent:goto-open-parentheses-anchor scala-indent:resolve-open-parentheses-step)
         (scala-indent:goto-for-enumerators-anchor scala-indent:resolve-list-step)
         (scala-indent:goto-forms-align-anchor scala-indent:resolve-forms-align-step)
         (scala-indent:goto-list-anchor scala-indent:resolve-list-step)
         (scala-indent:goto-body-anchor scala-indent:resolve-body-step)
         (scala-indent:goto-run-on-anchor scala-indent:resolve-run-on-step)
         (scala-indent:goto-block-anchor scala-indent:resolve-block-step)
     )
       point)
      0))

(defun scala-indent:indent-line-to (column)
  "Indent the line to column and move cursor to the indent
column, if it was at the left margin."
  (when column
    (if (<= (current-column) (current-indentation))
        (indent-line-to column)
      (save-excursion (indent-line-to column)))))

(defun scala-indent:indent-code-line (&optional strategy)
  "Indent a line of code. Expect to be outside of any comments or
strings"
  (if strategy
      (setq scala-indent:effective-run-on-strategy strategy)
    (if (eq last-command this-command)
        (scala-indent:toggle-effective-run-on-strategy)
      (scala-indent:reset-effective-run-on-strategy)))
;  (message "run-on-strategy is %s" (scala-indent:run-on-strategy))
  (scala-indent:indent-line-to (scala-indent:calculate-indent-for-line))
  (scala-lib:delete-trailing-whitespace)
  )

(defun scala-indent:indent-line (&optional strategy)
  "Indents the current line."
  (interactive)
  (let ((state (save-excursion (syntax-ppss (line-beginning-position)))))
    (if (not (nth 8 state)) ;; 8 = start pos of comment or string, nil if none
        (scala-indent:indent-code-line strategy)
      (scala-indent:indent-line-to (current-indentation))
      nil)))

(defun scala-indent:indent-with-reluctant-strategy ()
  (interactive)
  (scala-indent:indent-line scala-indent:reluctant-strategy))
        
