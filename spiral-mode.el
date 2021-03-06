;;; spiral-mode.el --- SPIRAL minor mode for interactions with Socket Server -*- lexical-binding: t; -*-
;;
;; Filename: spiral-mode.el
;; Description:
;; Author: Daniel Barreto <daniel@barreto.tech>
;; Maintainer: Daniel Barreto <daniel@barreto.tech>
;; Copyright (C) 2017 Daniel Barreto
;; Created: Sun Nov 12 12:25:44 2017 (+0100)
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;; SPIRAL minor mode for interactions with Socket Server
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'spiral-ast)
(require 'spiral-project)
(require 'spiral-overlay)
(require 'spiral-util)

(defcustom spiral-ask-for-connection t
  "Automatically ask for host:port when trying to interact with UNREPL in an unconnected buffer."
  :type 'boolean
  :group 'spiral)

(defcustom spiral-display-repl-in-current-window nil
  "Whether to display the REPL in the current window."
  :type 'boolean
  :group 'spiral-repl)

(defcustom spiral-mode-line-show-connection t
  "Whether to have mode-line show the connection id or not."
  :type 'boolean
  :group 'spiral)

(defcustom spiral-mode-line
  '(:eval (format " 🌀[%s]" (or spiral-conn-id "-")))
  "Mode line lighter for `spiral-mode'."
  :type 'sexp
  :risky t
  :group 'spiral)

(defcustom spiral-eval-result-display 'both
  "Whether to display evaluation results with overlays, in the echo area, or both."
  :type '(choice (const :tag "End of line" overlay)
                 (const :tag "Echo area" echo)
                 (const :tag "Both" both))
  :group 'spiral)

(defcustom spiral-auto-mode t
  "Whether or not to automatically enable `spiral-mode' for all Clojure buffer."
  :type 'boolean
  :group 'spiral)

(defvar spiral-completion-last-context nil
  "Last compliment context used.")

(defvar-local spiral-conn-id nil
  "Port number used when creating a new Socket REPL.")

(defvar-local spiral-latest-eval nil
  "Latest evaluation for the current buffer.")



;; Helpers
;; -------------------------------------------------------------------

(defun spiral-mode--find-project-by-file-name (&optional allow-nil)
  "Check the current buffer file name and try to find a matching SPIRAL project.
If ALLOW-NIL is non-nil, allows returning projects with nil directory.
If there is more than one project for this buffers file name, return the
most recently created."
  (let ((project-dir (spiral-clojure-dir)))
    (when (or project-dir allow-nil)
      (spiral-projects-get-by-dir project-dir))))


(defun spiral-mode-enable-auto ()
  "Automatically enable SPIRAL's minor mode in every new Clojure buffer.
Setup a `clojure-mode-hook' that checks for a possible project connection
each time a new Clojure buffer gets opened."
  (add-hook 'clojure-mode-hook #'spiral-mode-conditionally-turn-on))


(defun spiral-mode--turn-on (project)
  "Turn on `spiral-mode' in current buffer and associate PROJECT to it."
  (setq-local spiral-conn-id (spiral-project-id project))
  (spiral-mode t)
  project)


(defun spiral-mode-turn-on (conn-id-or-project &optional buffer)
  "Turn on `spiral-mode' in BUFFER and associate CONN-ID-OR-PROJECT to it.
If BUFFER is nil, use current buffer.
Return the connected project."
  (with-current-buffer (or buffer (current-buffer))
    (let ((project (if (symbolp conn-id-or-project)
                       (spiral-projects-get conn-id-or-project))))
      (spiral-mode--turn-on project))))


(defun spiral-mode-conditionally-turn-on ()
  "Turn on `spiral-mode' only if variable `buffer-file-name' belongs to an existing project."
  (when-let (project (spiral-mode--find-project-by-file-name))
    (spiral-mode--turn-on project)))


(declare-function spiral--connection-prompt "spiral")
(defun spiral-ensure-connected! ()
  "Make sure a `spiral-conn-id' exists for current buffer.
If this local variable is not already set, tries to find a good candidate
by looking at the buffer's file path and comparing to existing
`spiral-projects'.
If that fails and `spiral-ask-for-connection' is non-nil, asks the user for
an *existing* host:port connection to connect to.  If everything else
fails, raise an error.

Return a SPIRAL project"
  (if-let (project (and spiral-conn-id
                        (spiral-projects-get spiral-conn-id)))
      project
    (if-let (project (spiral-mode-conditionally-turn-on))
        project
      (if spiral-ask-for-connection
          (seq-let [project _] (spiral--connection-prompt (spiral-clojure-dir))
            (spiral-mode--turn-on project))
        (error "Could not find a SPIRAL connection for this buffer")))))


(defmacro with-current-project (&rest body)
  "Ensure the current buffer is connected and put its project in BODY's local scope."
  `(let ((project (spiral-ensure-connected!)))
     ,@body))


(declare-function spiral-aux-send "spiral-loop")
(defun spiral-update-print-settings (project context coll-length nesting-depth string-length
                                             &optional eval-callback)
  "Adjust UNREPL print settings for PROJECT's CONTEXT.
COLL-LENGTH, NESTING-DEPTH, and STRING-LENGTH are UNREPL's update-able
settings.
If any of them is the symbol `max', the symbol `Long/MAX_VALUE' will be
sent instead.
If any of them is the symbol `same', the value will be unaltered in
UNREPL.
EVAL-CALLBACK is an optional function to execute after receiving evaluation
for the updated print settings."
  (let* ((actions (spiral-project-actions project))
         (print-settings-action (spiral-ast-map-elt actions :print-settings))
         (print-settings (spiral-project-print-settings project))
         (context-print-settings (map-elt print-settings context))
         (parse-value (lambda (key val)
                        (cl-case val
                          ('max 'Long/MAX_VALUE)
                          ('same (map-elt context-print-settings key))
                          (t val)))))
    (spiral-aux-send
     (spiral-command-template
      print-settings-action
      `((:unrepl.print/context . ,context)
        (:unrepl.print/coll-length . ,(funcall parse-value :coll-length coll-length))
        (:unrepl.print/nesting-depth . ,(funcall parse-value :nesting-depth nesting-depth))
        (:unrepl.print/string-length . ,(funcall parse-value :string-length string-length))))
     eval-callback)))


(defmacro spiral-binding-print-limits (coll-length nesting-depth string-length &rest body)
  "Edit UNREPL `:eval' print settings, exec BODY and revert limits back.
COLL-LENGTH, NESTING-DEPTH, and STRING-LENGTH are UNREPL's update-able
settings.
This macro adds a `revert-bindings-back' function into BODY's lexical
context.  BODY is in charge of calling this function whenever it seems
appropriate."
  (declare (indent 3))
  `(with-current-project
    (let ((ast-limits (lambda (bindings-node)
                        (mapcar
                         (lambda (key)
                           (parseclj-ast-value (spiral-ast-map-elt bindings-node key)))
                         '(:unrepl.print/coll-length
                           :unrepl.print/nesting-depth
                           :unrepl.print/string-length)))))
      (spiral-update-print-settings
       project :eval
       ,coll-length ,nesting-depth ,string-length
       (lambda (previous-limits)
         (let ((revert-bindings-back (lambda (&rest _args)
                                       (apply #'spiral-update-print-settings project :eval
                                              (funcall ast-limits previous-limits)))))
           ,@body))))))



;; Evaluation
;; -------------------------------------------------------------------

(declare-function spiral-client-send "spiral-loop")
(defun spiral-eval (form eval-callback &optional stdout-callback)
  "Send FORM to UNREPL Socket Server for evaluation.
FORM can either be a string or a list tuple of buffer start, end positions.
This function sends everything through the `:client' connection, and
dispatches the evaluation payload (as an AST node) to EVAL-CALLBACK, which
can expect it as its only argument.  STDOUT-CALLBACK is also a function
that expects just one argument, any STDOUT belonging to this evaluation."
  (when (listp form)
    (remove-overlays (car form) (cadr form) 'temporary t))
  (let ((form (if (consp form)
                  (apply #'buffer-substring-no-properties form)
                form)))
    (spiral-client-send form eval-callback stdout-callback (current-buffer))))


(defun spiral-mode--interactive-eval-display-callback (eval-payload &optional bounds)
  "Display evaluation result EVAL-PAYLOAD as a string.
This function will put a string version of EVAL-PAYLOAD in the echo area,
font-locked as Clojure.
If BOUNDS is non-nil and `spiral-eval-result-display' is something else
than 'echo, VALUE will also be displayed in an overlay starting at the end
bound."
  (let ((value (spiral-ast-unparse-to-string eval-payload))
        (point (cadr bounds)))
    (when (and point (not (eql spiral-eval-result-display 'echo)))
      (spiral--make-result-overlay value point))
    (message "%s%s" spiral-eval-result-prefix value)))


(defun spiral-mode--interactive-eval-replace-callback (eval-payload bounds)
  "Replace whatever it is in BOUNDS with the evaluation result EVAL-PAYLOAD.
This function will delete whatever it is between BOUNDS in BUFFER, and
replace it with a string version of EVAL-PAYLOAD."
  (with-current-buffer (marker-buffer (car bounds))
    (apply #'delete-region bounds)
    (goto-char (car bounds))
    (spiral-ast-unparse eval-payload)))


(defun spiral-eval-last-sexp (&optional prefix)
  "Evaluate the expression preceding point.
If invoked with PREFIX, replace the evaluated for with its result in
current buffer."
  (interactive "P")
  (spiral-ensure-connected!)
  (let ((bounds (spiral-last-sexp 'marker-bounds))
        (callback (if prefix
                      #'spiral-mode--interactive-eval-replace-callback
                    #'spiral-mode--interactive-eval-display-callback)))
    (spiral-eval bounds
                 (lambda (eval-payload)
                   (funcall callback eval-payload bounds)))))


(defun spiral-eval-top-level-form ()
  "Evaluate the \"top-level\" form containing point."
  (interactive)
  (spiral-ensure-connected!)
  (let ((bounds (spiral-top-level-form-at-point 'marker-bounds)))
    (spiral-eval bounds
                 (lambda (eval-payload)
                   (spiral-mode--interactive-eval-display-callback eval-payload bounds)))))



;; Interactive Commands
;; -------------------------------------------------------------------

(defun spiral-switch-to-repl-buffer ()
  "Switch to the REPL buffer for `spiral-conn-id'."
  (interactive)
  (with-current-project
   (let ((repl-buffer (spiral-project-repl-buffer project)))
     (if spiral-display-repl-in-current-window
         (pop-to-buffer-same-window repl-buffer t)
       (pop-to-buffer repl-buffer nil t)))))


(declare-function spiral-repl-insert-phantom-input "spiral-repl")
(defun spiral-inspect-last-eval ()
  "Replicate last evaluation in REPL buffer for further inspection."
  (interactive)
  (spiral-repl-insert-phantom-input spiral-latest-eval nil 'switch))


(defun spiral-eval-interrupt ()
  "Interrupt pending evaluation."
  (interactive)
  (with-current-project
   (let ((conn-id (spiral-project-id project))
         (interrupt (lambda (pe)
                      (let* ((actions (spiral-pending-eval-entry-actions pe))
                             (interrupt-templ (spiral-ast-map-elt actions :interrupt)))
                        (spiral-aux-send (spiral-command-template interrupt-templ)
                                         (lambda (_) (message "Evaluation interrupted!")))))))
     (if-let (pending-eval (or (spiral-pending-eval :client conn-id)
                               (spiral-pending-eval :aux conn-id)))
         (funcall interrupt pending-eval)
       (message "No evaluations pending...")))))


(defun spiral-eval-buffer (&optional buffer)
  "Eval BUFFER's file in UNREPL.
If no buffer is provided the command acts on the current buffer."
  (interactive)
  (check-parens)
  (with-current-project
   (with-current-buffer (or buffer (current-buffer))
     (unless buffer-file-name
       (user-error "Buffer `%s' is not associated with a file" (current-buffer)))
     (when (and (buffer-modified-p)
                (y-or-n-p (format "Save file %s? " buffer-file-name)))
       (save-buffer))
     (remove-overlays nil nil 'temporary t)
     (let ((filename (buffer-file-name buffer))
           ;; (ns-form  (cider-ns-form))
           (load-file-templ (spiral-project-actions-get project :spiral/load-file)))
       (spiral-aux-send (spiral-command-template
                         load-file-templ
                         `((:spiral/file . ,(spiral-file-string filename))
                           (:spiral/file-name . ,(funcall spiral-filename-function filename))
                           (:spiral/file-path . ,(file-name-nondirectory filename))))
                        (lambda (payload)
                          (message "%s" (spiral-ast-unparse-to-string payload 'mute-ui))))
       (message "Loading %s..." filename)))))



(defun spiral-quit (&optional just-do-it conn-id)
  "Quit connection to CONN-ID or current `spiral-conn-id'.
If JUST-DO-IT is non-nil, don't ask for confirmation."
  (interactive "P")
  (let ((conn-id (or conn-id
                     spiral-conn-id)))
    (if-let (project (spiral-projects-get conn-id))
        (when (or just-do-it
                  (y-or-n-p (format "Are you sure you want to quit connection to %s? " conn-id)))
          (spiral-project-quit conn-id)
          (message "UNREPL connection to %s terminated" conn-id))
      (error "Connection %s could not be found" conn-id))))



;; Completion
;; -------------------------------------------------------------------

(defun spiral-complete--symbol-start-pos ()
  "Find the starting position of the symbol at point, unless inside a string.
BORROWED FROM CIDER."
  (let ((sap (symbol-at-point)))
    (when (and sap (not (nth 3 (syntax-ppss))))
      (car (bounds-of-thing-at-point 'symbol)))))


(defun spiral-complete--get-context-at-point ()
  "Extract the context at point.
If point is not inside the list, returns nil; otherwise return \"top-level\"
form, with symbol at point replaced by __prefix__.
BORROWED FROM CIDER."
  (when (save-excursion
          (condition-case _
              (progn
                (up-list)
                (check-parens)
                t)
            (scan-error nil)
            (user-error nil)))
    (save-excursion
      (let* ((pref-end (point))
             (pref-start (spiral-complete--symbol-start-pos))
             (context (spiral-top-level-form-at-point))
             (expr-start (progn
                           (beginning-of-defun)
                           (point))))
        (concat (when pref-start (substring context 0 (- pref-start expr-start)))
                "__prefix__"
                (substring context (- pref-end expr-start)))))))


(defun spiral-complete--get-context ()
  "Extract compliment's context."
  (let ((context (when (derived-mode-p 'clojure-mode)
                   ;; Important because `beginning-of-defun' and
                   ;; `ending-of-defun' work incorrectly in the REPL
                   ;; buffer, so context extraction fails there.
                   (spiral-complete--get-context-at-point))))
    (if (string= spiral-completion-last-context context)
        :same
      (setq spiral-completion-last-context context)
      context)))


(declare-function spiral-aux-sync-request "spiral-loop")
(defun spiral-complete--candidates (str &optional ns)
  "Find completion candidates for STR.
NS is an optional namespace symbol."
  (with-current-project
   (let* ((context (spiral-complete--get-context))
          (complete-tmpl (thread-first project
                           (spiral-project-actions)
                           (spiral-ast-map-elt :spiral/complete)))
          (candidates (spiral-aux-sync-request
                       (spiral-command-template complete-tmpl
                                                `((:spiral/prefix . ,str)
                                                  (:spiral/context . ,context)
                                                  (:spiral/ns . ,ns))))))
     (mapcar
      (lambda (candidate-node)
        (let* ((node-get (lambda (key) (thread-first candidate-node
                                    (spiral-ast-map-elt key)
                                    (parseclj-ast-value))))
               (candidate (funcall node-get :candidate))
               (type (funcall node-get :type))
               (ns (funcall node-get :ns)))
          (when candidate
            (put-text-property 0 1 'type type candidate)
            (put-text-property 0 1 'ns ns candidate))
          candidate))
      (parseclj-ast-children candidates)))))


(defun spiral-complete--annotate-symbol (symbol)
  "Return a string suitable for annotating SYMBOL.
Takes properties `type' and `ns' from SYMBOL, if any, and concat them into
a single annotation.  `ns' is only used when the symbol to be completed is
not fully qualified."
  (let ((type (get-text-property 0 'type symbol))
        (ns (unless (spiral-namespace-qualified-p symbol)
              (get-text-property 0 'ns symbol))))
    (concat (when ns (format " (%s) " ns))
            (when type (format " <%s> " (spiral-keyword-name type))))))


(defun spiral-complete-at-point ()
  "Complete the symbol at point.
Used as a `completion-at-point-functions' function.
BORROWED FROM CIDER."
  (when (not (or (spiral-in-string-p) (spiral-in-comment-p)))
    (when-let (bounds (bounds-of-thing-at-point 'symbol))
      (list (car bounds) (cdr bounds)
            (completion-table-dynamic #'spiral-complete--candidates)
            :annotation-function #'spiral-complete--annotate-symbol))))



;; Setup
;; -------------------------------------------------------------------

(defconst spiral-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-TAB") #'complete-symbol)
    (define-key map (kbd "C-c C-z") #'spiral-switch-to-repl-buffer)
    (define-key map (kbd "C-x C-e") #'spiral-eval-last-sexp)
    (define-key map (kbd "C-c C-c") #'spiral-eval-top-level-form)
    (define-key map (kbd "C-c C-r") #'spiral-inspect-last-eval)
    (define-key map (kbd "C-c C-b") #'spiral-eval-buffer)
    (define-key map (kbd "C-c C-g") #'spiral-eval-interrupt)
    (define-key map (kbd "C-c q") #'spiral-quit)
    (define-key map (kbd "C-c C-q") #'spiral-quit)
    map))


(define-minor-mode spiral-mode
  "Minor mode for SPIRAL.

\\{spiral-mode-map\}"
  nil
  spiral-mode-line
  spiral-mode-map
  (if spiral-mode
      (progn
        (make-local-variable 'completion-at-point-functions)
        (add-to-list 'completion-at-point-functions
                     #'spiral-complete-at-point))
    (mapc #'kill-local-variable '(spiral-conn-id
                                  completion-at-point-functions))))


(provide 'spiral-mode)

;;; spiral-mode.el ends here
