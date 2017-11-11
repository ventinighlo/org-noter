;;; interleave.el --- Interleave PDFs                     -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Gonçalo Santos

;; Author: Gonçalo Santos (aka. weirdNox@GitHub)
;; Homepage: https://github.com/weirdNox/interleave
;; Keywords: lisp pdf interleave annotate
;; Package-Requires: (cl-lib)
;; Version: 0.0.1

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; TODO
;; THE NAME IS TEMPORARY
;; This is a rewrite from scratch of Interleave mode, by rudolfochrist, using many of his
;; great ideas, and trying to achieve better user experience by providing extra features.

;;; Code:
(require 'cl-lib)

(defconst interleave--property-pdf-file "INTERLEAVE_PDF"
  "Name of the property which specifies the PDF file.")

;; TODO(nox): Change this string, this is for compatibility with previous interleave mode
(defconst interleave--property-note-page "INTERLEAVE_PAGE_NOTE"
  "Name of the property which specifies the page of the current note.")

(cl-defstruct interleave--session frame pdf-mode property-text
              org-file-path pdf-file-path notes-buffer
              pdf-buffer)

(defvar interleave--sessions nil
  "List of Interleave sessions")

(defvar-local interleave--session nil
  "Session associated with the current buffer.")

(defvar interleave--inhibit-next-page-change nil
  "Whether or not it should keep the point on the same place even
  if the page changes to another page that has a note.
After a page change, it will always reset to `nil'")

;; --------------------------------------------------------------------------------
;; NOTE(nox): Utility functions
(defun interleave--valid-session (session)
  (if (and session
           (frame-live-p (interleave--session-frame session))
           (buffer-live-p (interleave--session-pdf-buffer session))
           (buffer-live-p (interleave--session-notes-buffer session)))
      t
    (interleave-kill-session session)
    nil))

(defmacro interleave--with-valid-session (&rest body)
  `(let ((session interleave--session))
     (when (interleave--valid-session session)
       (progn ,@body))))

(defun interleave--handle-kill-buffer ()
  (interleave--with-valid-session
   (let ((buffer (current-buffer))
         (notes-buffer (interleave--session-notes-buffer session))
         (pdf-buffer (interleave--session-pdf-buffer session)))
     ;; NOTE(nox): This needs to be checked in order to prevent session killing because of
     ;; temporary buffers with the same local variables
     (when (or (eq buffer notes-buffer)
               (eq buffer pdf-buffer))
       (interleave-kill-session session)))))

(defun interleave--handle-delete-frame (frame)
  (dolist (session interleave--sessions)
    (when (eq (interleave--session-frame session) frame)
      (interleave-kill-session session))))

(defun interleave--parse-root ()
  (let* ((session interleave--session)
         (notes-buffer (when session (interleave--session-notes-buffer session))))
    (when (buffer-live-p notes-buffer)
      (with-current-buffer notes-buffer
        (org-with-wide-buffer
         (let ((wanted-value (interleave--session-property-text session))
               element)
           (unless (org-before-first-heading-p)
             ;; NOTE(nox): Start by trying to find a parent heading with the specified
             ;; property
             (let ((try-next t) property-value)
               (while try-next
                 (setq property-value (org-entry-get nil interleave--property-pdf-file))
                 (when (and property-value (string= property-value wanted-value))
                   (org-narrow-to-subtree)
                   (setq element (org-element-parse-buffer 'greater-element)))
                 (setq try-next (and (not element) (org-up-heading-safe))))))
           (unless element
             ;; NOTE(nox): Could not find parent with property, do a global search
             (let ((pos (org-find-property interleave--property-pdf-file wanted-value)))
               (when pos
                 (goto-char pos)
                 (org-narrow-to-subtree)
                 (setq element (org-element-parse-buffer 'greater-element)))))
           (car (org-element-contents element))))))))

(defun interleave--get-properties-end (ast &optional force-trim)
  (when ast
    (let* ((properties (org-element-map ast 'property-drawer 'identity nil t))
           (last-element (car (last (car (org-element-contents ast)))))
           properties-end)
      (if (not properties)
          (org-element-property :contents-begin ast)
        (setq properties-end (org-element-property :end properties))
        (while (and (or force-trim (eq (org-element-type last-element) 'property-drawer))
                    (not (eq (char-before properties-end) ?:)))
          (setq properties-end (1- properties-end)))
        properties-end))))

(defun interleave--set-read-only (ast)
  (when ast
    (let ((begin (org-element-property :begin ast))
          (properties-end (interleave--get-properties-end ast t))
          (modified (buffer-modified-p)))
      (add-text-properties begin (1+ begin) '(read-only t front-sticky t))
      (add-text-properties (1+ begin) (1- properties-end) '(read-only t))
      (add-text-properties (1- properties-end) properties-end '(read-only t rear-nonsticky t))
      (set-buffer-modified-p modified))))

(defun interleave--unset-read-only (ast)
  (when ast
    (let ((begin (org-element-property :begin ast))
          (end (interleave--get-properties-end ast t))
          (inhibit-read-only t)
          (modified (buffer-modified-p)))
      (remove-list-of-text-properties begin end '(read-only front-sticky rear-nonsticky))
      (set-buffer-modified-p modified))))

(defun interleave--narrow-to-root (ast)
  (when ast
    (let ((old-point (point))
          (begin (org-element-property :begin ast))
          (end (org-element-property :end ast))
          (contents-pos (interleave--get-properties-end ast)))
      (goto-char begin)
      (org-show-entry)
      (org-narrow-to-subtree)
      (org-show-children)
      (if (or (< old-point begin) (>= old-point end))
          (goto-char contents-pos)
        (goto-char old-point)))))

(defun interleave--get-notes-window ()
  (interleave--with-valid-session
   (display-buffer (interleave--session-notes-buffer session) nil
                   (interleave--session-frame session))))

(defun interleave--get-pdf-window ()
  (interleave--with-valid-session
   (get-buffer-window (interleave--session-pdf-buffer session)
                      (interleave--session-frame session))))

(defun interleave--goto-page (page-str &optional inhibit-point-change)
  (interleave--with-valid-session
   (setq interleave--inhibit-next-page-change inhibit-point-change)
   (with-selected-window (get-buffer-window (interleave--session-pdf-buffer session)
                                            (interleave--session-frame session))
     (cond ((eq major-mode 'pdf-view-mode)
            (pdf-view-goto-page (string-to-number page-str)))
           ((eq major-mode 'doc-view-mode)
            (doc-view-goto-page (string-to-number page-str)))))))

(defun interleave--current-page ()
  (interleave--with-valid-session
   (with-current-buffer (interleave--session-pdf-buffer session)
     (image-mode-window-get 'page))))

(defun interleave--doc-view-advice (page)
  (when (interleave--valid-session interleave--session)
    (interleave--page-change-handler page)))

(defun interleave--page-change-handler (&optional page-arg)
  (interleave--with-valid-session
   (let* ((page-string (number-to-string
                        (or page-arg (interleave--current-page))))
          (ast (interleave--parse-root))
          (notes (when ast (org-element-contents ast)))
          note)
     (when (and notes (not interleave--inhibit-next-page-change))
       (setq
        note
        (org-element-map notes 'headline
          (lambda (headline)
            (when (string= page-string
                           (org-element-property
                            (intern (concat ":" interleave--property-note-page))
                            headline))
              headline))
          nil t 'headline))
       (when note
         (with-selected-window (interleave--get-notes-window)
           (when (or (< (point) (interleave--get-properties-end note))
                     (and (not (eobp))
                          (>= (point) (org-element-property :end note))))
             (goto-char (interleave--get-properties-end note)))
           (org-show-context)
           (org-show-siblings)
           (org-show-subtree)
           (org-cycle-hide-drawers 'all)
           (recenter))))
     (setq interleave--inhibit-next-page-change nil))))

;; --------------------------------------------------------------------------------
;; NOTE(nox): User commands
(defun interleave-kill-session (&optional session)
  (interactive "P")
  (when (and (interactive-p) (> (length interleave--sessions) 0))
    ;; NOTE(nox): `session' is representing a prefix argument
    (if (and interleave--session (not (equal session '(4))))
        (setq session interleave--session)
      (setq session nil)
      (let (collection default pdf-file-name org-file-name display)
        (dolist (session interleave--sessions)
          (setq pdf-file-name (file-name-nondirectory
                               (interleave--session-pdf-file-path session))
                org-file-name (file-name-nondirectory
                               (interleave--session-org-file-path session))
                display (concat pdf-file-name " with notes from " org-file-name))
          (when (eq session interleave--session) (setq default display))
          (push (cons display session) collection))
        (setq session (cdr (assoc (completing-read "Which session? " collection nil t
                                                   nil nil default)
                                  collection))))))
  (when (and session (memq session interleave--sessions))
    (let ((frame (interleave--session-frame session))
          (notes-buffer (interleave--session-notes-buffer session))
          (pdf-buffer (interleave--session-pdf-buffer session)))
      (with-current-buffer notes-buffer
        (interleave--unset-read-only (interleave--parse-root)))
      (setq interleave--sessions (delq session interleave--sessions))
      (when (eq (length interleave--sessions) 0)
        (setq delete-frame-functions (delq 'interleave--handle-delete-frame
                                           delete-frame-functions))
        (when (featurep 'doc-view)
          (advice-remove  'interleave--doc-view-advice 'doc-view-goto-page)))
      (when (frame-live-p frame)
        (delete-frame frame))
      (when (buffer-live-p pdf-buffer)
        (kill-buffer pdf-buffer))
      (when (buffer-live-p notes-buffer)
        (kill-buffer notes-buffer)))))

(defun interleave-insert-note ()
  (interactive)
  (interleave--with-valid-session
   (let* ((ast (interleave--parse-root))
          (page (interleave--current-page))
          (page-string (number-to-string page))
          note-element closest-previous-element)
     (when ast
       (setq
        note-element
        (org-element-map (org-element-contents ast) org-element-all-elements
          (lambda (element)
            (let ((property-value (org-element-property
                                   (intern (concat ":" interleave--property-note-page)) element)))
              (cond ((string= property-value page-string) element)
                    ((or (not property-value) (< (string-to-number property-value) page))
                     (setq closest-previous-element element)
                     nil))))
          nil t 'headline))
       (with-selected-frame (interleave--session-frame session)
         (select-window (interleave--get-notes-window))
         (if note-element
             (let ((last (car (last (car (org-element-contents note-element)))))
                   (num-blank (org-element-property :post-blank note-element))
                   (prev-char (char-before)))
               (goto-char (org-element-property :end note-element))
               (cond ((eq (org-element-type last) 'property-drawer)
                      (when (eq num-blank 0) (insert "\n")))
                     (t (while (< num-blank 2)
                          (insert "\n")
                          (setq num-blank (1+ num-blank)))))
               (when (eq prev-char ?\n)
                 (forward-line -1))
               (org-show-context)
               (org-show-siblings)
               (org-show-subtree))
           (if closest-previous-element
               (progn
                 (goto-char (org-element-property :end closest-previous-element))
                 (if (eq (org-element-type closest-previous-element) 'headline)
                     (org-insert-heading)
                   (org-insert-subheading nil)))
             (goto-char (interleave--get-properties-end ast t))
             (outline-show-entry)
             (org-insert-subheading nil))
           (insert (format "Notes for page %d\n" page))
           (org-entry-put nil interleave--property-note-page page-string))
         (org-cycle-hide-drawers 'all))))))

(defun interleave-sync-previous-page-note ()
  (interactive)
  (interleave--with-valid-session
   (let ((ast (interleave--parse-root))
         (point (with-selected-window (interleave--get-notes-window) (point)))
         (max (with-selected-window (interleave--get-notes-window) (point-max)))
         (property-name (intern (concat ":" interleave--property-note-page)))
         (current-page (interleave--current-page))
         contents previous-page-string should-goto)
     (setq contents (org-element-contents ast))
     (setq
      should-goto
      (org-element-map contents 'headline
        (lambda (headline)
          (if (and (>= point (org-element-property :begin headline))
                   (or (< point (org-element-property :end headline))
                       (eq (org-element-property :end headline) max)))
              t
            (setq previous-page-string (or (org-element-property property-name headline)
                                           previous-page-string))
            nil))
        nil t 'headline))
     (when (and should-goto previous-page-string)
       (if (eq current-page (string-to-number previous-page-string))
           (interleave--page-change-handler current-page)
         (interleave--goto-page previous-page-string))))
   (select-window (interleave--get-pdf-window))))

(defun interleave-sync-page-note ()
  (interactive)
  (interleave--with-valid-session
   (with-selected-window (interleave--get-notes-window)
     (let ((page-string (org-entry-get nil interleave--property-note-page t)))
       (interleave--goto-page page-string t)))
   (select-window (interleave--get-pdf-window))))

(defun interleave-sync-next-page-note ()
  (interactive)
  (interleave--with-valid-session
   (let ((ast (interleave--parse-root))
         (point (with-selected-window (interleave--get-notes-window) (point)))
         (property-name (intern (concat ":" interleave--property-note-page)))
         (current-page (interleave--current-page))
         contents start-searching page-string)
     (setq contents (org-element-contents ast))
     (org-element-map contents 'headline
       (lambda (headline)
         (when (< point (org-element-property :begin headline))
           (setq start-searching t))
         t)
       nil t)
     (org-element-map contents 'headline
       (lambda (headline)
         (if start-searching
             (setq page-string (org-element-property property-name headline))
           (when (and (>= point (org-element-property :begin headline))
                      (< point (org-element-property :end headline)))
             (setq start-searching t)
             nil)))
       nil t 'headline)
     (when page-string
       (if (eq current-page (string-to-number page-string))
           (interleave--page-change-handler current-page)
         (interleave--goto-page page-string))))
   (select-window (interleave--get-pdf-window))))

;;;###autoload
(defun interleave (arg)
  "Start Interleave.
When with an argument, only check for the property in the current
heading"
  (interactive "P")
  (when (eq major-mode 'org-mode)
    (when (org-before-first-heading-p)
      (error "Interleave must be issued inside a heading."))
    (let ((org-file-path (buffer-file-name))
          (pdf-property (org-entry-get nil interleave--property-pdf-file (not arg)))
          pdf-file-path session)
      (when (stringp pdf-property) (setq pdf-file-path (expand-file-name pdf-property)))
      (unless (and pdf-file-path (not (file-directory-p pdf-file-path)) (file-readable-p pdf-file-path))
        (setq pdf-file-path (expand-file-name
                             (read-file-name
                              "No INTERLEAVE_PDF property found. Please specify a PDF path: "
                              nil nil t)))
        (when (or (file-directory-p pdf-file-path) (not (file-readable-p pdf-file-path)))
          (error "Invalid file path."))
        (setq pdf-property (if (y-or-n-p "Do you want a relative file name? ")
                               (file-relative-name pdf-file-path)
                             pdf-file-path))
        (org-entry-put nil interleave--property-pdf-file pdf-property))
      (when (catch 'should-continue
              (dolist (session interleave--sessions)
                (when (string= (interleave--session-pdf-file-path session)
                               pdf-file-path)
                  (if (string= (interleave--session-org-file-path session)
                               org-file-path)
                      (if (interleave--valid-session session)
                          (progn
                            (raise-frame (interleave--session-frame session))
                            (throw 'should-continue nil))
                        ;; NOTE(nox): This should not happen, but we may as well account
                        ;; for it
                        (interleave-kill-session session)
                        (throw 'should-continue t))
                    (if (y-or-n-p (format "%s is already being Interleaved in another notes file. \
Should I end the session? "))
                        (progn
                          (interleave-kill-session session)
                          (throw 'should-continue t))
                      (throw 'should-continue nil)))))
              t)
        (setq
         session
         (let* ((display-name (file-name-nondirectory (file-name-sans-extension pdf-file-path)))
                (notes-buffer-name
                 (generate-new-buffer-name (format "Interleave - Notes of %s" display-name)))
                (pdf-buffer-name
                 (generate-new-buffer-name (format "Interleave - %s" display-name)))
                (orig-pdf-buffer (find-file-noselect pdf-file-path))
                (frame (make-frame `((name . ,(format "Emacs - Interleave %s" display-name))
                                     (fullscreen . maximized))))
                (notes-buffer (make-indirect-buffer (current-buffer) notes-buffer-name t))
                (pdf-buffer (make-indirect-buffer orig-pdf-buffer pdf-buffer-name))
                (pdf-mode (with-current-buffer orig-pdf-buffer major-mode)))
           (make-interleave--session :frame frame :pdf-mode pdf-mode :property-text pdf-property
                                     :org-file-path org-file-path :pdf-file-path pdf-file-path
                                     :notes-buffer notes-buffer :pdf-buffer pdf-buffer)))
        (with-current-buffer (interleave--session-pdf-buffer session)
          (setq buffer-file-name pdf-file-path)
          (cond ((eq (interleave--session-pdf-mode session) 'pdf-view-mode)
                 (pdf-view-mode)
                 (add-hook 'pdf-view-after-change-page-hook
                           'interleave--page-change-handler nil t))
                ((eq (interleave--session-pdf-mode session) 'doc-view-mode)
                 (doc-view-mode)
                 (advice-add 'doc-view-goto-page :after 'interleave--doc-view-advice))
                (t (error "This PDF handler is not supported :/")))
          (kill-local-variable 'kill-buffer-hook)
          (setq interleave--session session)
          (add-hook 'kill-buffer-hook 'interleave--handle-kill-buffer nil t)
          (local-set-key (kbd "i") 'interleave-insert-note)
          (local-set-key (kbd "q") 'interleave-kill-session)
          (local-set-key (kbd "M-p") 'interleave-sync-previous-page-note)
          (local-set-key (kbd "M-.") 'interleave-sync-page-note)
          (local-set-key (kbd "M-n") 'interleave-sync-next-page-note))
        (with-current-buffer (interleave--session-notes-buffer session)
          (setq interleave--session session)
          (add-hook 'kill-buffer-hook 'interleave--handle-kill-buffer nil t)
          (let ((ast (interleave--parse-root)))
            (interleave--set-read-only ast)
            (interleave--narrow-to-root ast))
          (local-set-key (kbd "M-p") 'interleave-sync-previous-page-note)
          (local-set-key (kbd "M-.") 'interleave-sync-page-note)
          (local-set-key (kbd "M-n") 'interleave-sync-next-page-note))
        (with-selected-frame (interleave--session-frame session)
          (let ((pdf-window (selected-window))
                (notes-window (split-window-right)))
            ;; TODO(nox): Option to customize this
            (set-window-buffer pdf-window (interleave--session-pdf-buffer session))
            (set-window-dedicated-p pdf-window t)
            (set-window-buffer notes-window (interleave--session-notes-buffer session))))
        (add-hook 'delete-frame-functions 'interleave--handle-delete-frame)
        (push session interleave--sessions)
        ;; TODO(nox): Load page of current note?
        (with-current-buffer (interleave--session-pdf-buffer session)
          (interleave--page-change-handler 1))))))

(provide 'interleave)

;;; interleave.el ends here
