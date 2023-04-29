;;; ai-completions.el --- Code autocompletion via AI -*- lexical-binding: t -*-

;; Copyright (C) 2023 Alex (https://github.com/lispython)

;; URL: https://github.com/ai-mode/ai-mode
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords: ai, chatgpt, gpt


;; This file is part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;


;;; Code:
(require 'ai-openai-completions)

(defgroup ai-completion nil
  "AI code completion tool for Emacs."
  :group 'ai-mode
  )

(defcustom ai--completion-backends '()
  "A list of async completion backends."
  :group 'ai-completion
  )

(defcustom ai--completion-current-backend 'ai--openai--completion-backend
  "Active completion backend."
  :group 'ai-completion
  )


(defcustom ai--completion-continue-commands '(not save-buffer save-some-buffers
                                                  save-buffers-kill-terminal
                                                  save-buffers-kill-emacs
                                                  )
  "A list of commands that are allowed during completion."

  :type '(choice (const :tag "Any command" t)
                 (cons  :tag "Any except"
                        (const not)
                        (repeat :tag "Commands" function))
                 (repeat :tag "Commands" function)
                 )
  :group 'ai-completion
  )


(defcustom ai--completion-abort-commands '(not ai--completion-select-next-or-abort
                                               ai--completion-select-prev-or-abort
                                               ai--completion-select-current
                                               ignore
                                               switch-to-buffer
                                               other-window
                                               other-buffer
                                               )
  ""

  :type '(choice (const :tag "Any command" t)
                 (cons  :tag "Any except"
                        (const not)
                        (repeat :tag "Commands" function))
                 (repeat :tag "Commands" function)
                 )
  :group 'ai-completion
  )


(defvar-local ai--completion--candidates '())
(defvar-local ai--completion-current-candidate 0)

(defvar-local ai--completion-active nil)

(defvar ai--emulation-alist '((t . nil)))


(defvar-local ai--completion-preview-overlay nil)
(defvar-local ai--completion-pseudo-tooltip-overlay nil)
(defvar-local ai--completion-last-point nil)
(defvar-local ai--completion-activated-keymap nil)


(defvar ai--completion-mode-keymap
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap "\e\e\e" 'ai--completion-abort)
    (define-key keymap "\C-g" 'ai--completion-abort)
    (define-key keymap (kbd "C-n") 'ai--completion-select-next-or-abort)
    (define-key keymap (kbd "C-p") 'ai--completion-select-prev-or-abort)
    (define-key keymap (kbd "<down>") 'ai--completion-select-next-or-abort)
    (define-key keymap (kbd "<up>") 'ai--completion-select-prev-or-abort)
    (define-key keymap [down-mouse-1] 'ignore)
    (define-key keymap [down-mouse-3] 'ignore)
    (define-key keymap [mouse-1] 'ignore)
    (define-key keymap [mouse-3] 'ignore)
    (define-key keymap [up-mouse-1] 'ignore)
    (define-key keymap [up-mouse-3] 'ignore)
    (define-key keymap [return] 'ai--completion-select-current)
    (define-key keymap (kbd "RET") 'ai--completion-select-current)
    (define-key keymap (kbd "C-<tab>") 'ai--completion-select-next-or-abort)
    keymap)

  "Keymap used for manage complete candidates")


(defun ai--completion-coordinator ()
  ""
  (condition-case-unless-debug err
      (progn
        (if (or (ai--completion-is-new-completion-required)
                (not (ai--completion-should-continue this-command)))
            (ai--completion-begin)
          (ai--completion-continue)
          ))
    (error (message (format "AI completion: An error occured in ai--completion-coordinator => %s" (error-message-string err)))
           (ai--completion-cancel))))


(defun ai--completion-begin ()
  ""
  (ai--completion-cancel)
  (setq ai--completion-last-point (point)
        ai--completion-active t)

  (condition-case-unless-debug err
      (progn (ai-completion-mode 1)
             (ai--completion-update-candidates (current-buffer))
             ;; (ai--completion-show-candidate)
             )
    (error (message (format "AI completion: An error occured in ai--completion-begin => %s" (error-message-string err)))
           (ai--completion-cancel))
    )
  )

(defun ai--completion-continue ()
  ""
  (condition-case-unless-debug err
      (progn )
    (error (message (format "AI completion : An error occured in ai--completion-continue => %s" (error-message-string err)))
           (ai--completion-cancel)
           )
    )
  )

(defun ai--completion-show-candidate ()
  ""
  (ai--completion-update-preview)
  (ai--completion-prepare-keymap)
  (ai--completion-activate-keymap)
  )

(defun ai--completion-should-continue (command)
  ""
  (or (eq t ai--completion-continue-commands)
      (if (eq 'not (car ai--completion-abort-commands))
          (consp (memq command (cdr ai--completion-abort-commands)))
        (or (memq command ai--completion-abort-commands)
            (and (symbolp command)
                 (string-match-p "\\`ai-" (symbol-name command)))))
      ))

(defun ai--completion-is-new-completion-required ()
  ""
  (or (not (equal (point) ai--completion-last-point))
      (not ai--completion-active)))


(defun ai--completion-before-buffer-changed ()
  ""
  )

(defun ai--completion-get-text-to-complete ()
  ""
  (if (region-active-p)
      (ai--get-region-content)
    (ai--get-buffer-content-before-point)
    )
  )

(defun ai--completion-update-candidates (buffer)
  ""
  (funcall ai--completion-current-backend
           (ai--completion-get-text-to-complete)
           (lambda (candidates)
             (progn
               (with-current-buffer buffer
                 (ai--completion-add-candidates candidates)
                 (ai--completion-show-candidate)
                 )
               )))
  )

(defun ai--completion-update-preview ()
  ""
  (ai--completion-preview-show-at-point ai--completion-last-point (nth ai--completion-current-candidate ai--completion--candidates))
  )

(defun ai--completion-add-candidates (candidates)
  ""
  (setq ai--completion--candidates (append ai--completion--candidates candidates)
        ai--completion-current-candidate (- (length ai--completion--candidates) (length candidates))
        ))

(defun ai--completion-preview-hide ()
  ""
  (when ai--completion-preview-overlay
    (delete-overlay ai--completion-preview-overlay)
    (setq ai--completion-preview-overlay nil)))


(defun ai--completion-abort ()
  ""
  (interactive)
  (ai--completion-cancel))


(defun ai--completion-finish (candidate)
  ""
  (ai--completion-preview-hide)
  (ai--completion-insert-candidate candidate)
  (ai--completion-cancel)
  )

(defun ai--completion-cancel (&optional result)
  ""
  (ai--completion-preview-hide)
  (setq ai--completion-current-candidate 0
        ai--completion--candidates '()
        ai--completion-last-point nil
        ai--completion-active nil
        )
  (ai--completion-destroy-keymap)
  (ai-completion-mode 0)
  ;; TODO: run hooks
  nil)


(defun ai--completion-insert-candidate (candidate)
  ""
  (when (> (length candidate) 0)
    (setq candidate (substring-no-properties candidate))
    (ai--insert-completion candidate)))


(defun ai--completion-select-current ()
  "Insert the selected candidate."
  (interactive)
  (let ((result (nth ai--completion-current-candidate ai--completion--candidates)))
    (ai--completion-finish result)
    ))


(defun ai--completion-select-next-or-abort ()
  ""
  (interactive)
  (let ((next-candidate-index (+ ai--completion-current-candidate 1)))
    (cond
     ((>= next-candidate-index (length ai--completion--candidates))
      (ai--completion-update-candidates (current-buffer)))
     (t (progn
          (setq ai--completion-current-candidate next-candidate-index)
          (ai--completion-show-candidate)
          )))))

(defun ai--completion-select-prev-or-abort ()
  ""
  (interactive)
  (let ((prev-candidate-index (- ai--completion-current-candidate 1)))
    (cond
     ((>= prev-candidate-index 0)
      (let ((result (nth prev-candidate-index ai--completion--candidates)))
        (setq ai--completion-current-candidate prev-candidate-index)
        (ai--completion-show-candidate)
        )
      )
     (t (message "completion candidate already selected"))
     )))


(define-minor-mode ai-completion-mode
  ""
  :lighter "ai complete mode lighter"
  (if ai-completion-mode
      (progn
        (message "AI completion mode enabled")
        (add-hook 'pre-command-hook 'ai-completion-mode-pre-command)
        (add-hook 'post-command-hook 'ai-completion-mode-post-command)
        (add-hook 'pre-command-hook 'ai--completion-before-buffer-changed)

        )
    (remove-hook 'pre-command-hook 'ai-completion-mode-pre-command)
    (remove-hook 'post-command-hook 'ai-completion-mode-post-command)
    (remove-hook 'pre-command-hook 'ai--completion-before-buffer-changed)
    (message "AI completion mode disabled")

    )
  )


(defun ai-completion-mode-pre-command ()
  ""
  (if (not (ai--completion-should-continue this-command))
      (progn
        (ai--completion-abort))
    (ai--completion-deactivate-keymap)))


(defun ai-completion-mode-post-command ()
  ""
  (when ai--completion-active
    (ai--completion-activate-keymap))
  )



(defun ai--completion-prepare-keymap ()
  ""
  (ai--completion-ensure-emulation-alist)
  (ai--completion-enable-overriding-keymap ai--completion-mode-keymap))

(defun ai--completion-destroy-keymap ()
  ""
  (ai--completion-deactivate-keymap)
  (ai--completion-enable-overriding-keymap nil))

(defun ai--completion-enable-overriding-keymap (keymap)
  ""
  (ai--completion-deactivate-keymap)

  (setf (cdar ai--emulation-alist) nil)
  (setq ai--completion-activated-keymap keymap))


(defun ai--completion-deactivate-keymap ()
  ""
  (setf (cdar ai--emulation-alist) nil))


(defun ai--completion-activate-keymap ()
  ""
  (unless (or (cdar ai--emulation-alist)
              (null ai--completion-activated-keymap))
    (setf (cdar ai--emulation-alist) ai--completion-activated-keymap)))


(defun ai--completion-ensure-emulation-alist ()
  ""
  (unless (eq 'ai--emulation-alist (car emulation-mode-map-alists))
    (setq emulation-mode-map-alists
          (cons 'ai--emulation-alist
                (delq 'ai--emulation-alist emulation-mode-map-alists)))))


(defface ai--completion-preview-face
  '((((class color) (min-colors 88) (background light))
     (:background "light blue"))
    (((class color) (min-colors 88) (background dark))
     (:background "gray31"))
    (t (:background "green"))
    (((class color) (min-colors 88) (background light))
     (:foreground "black" :background "cornsilk"))
    (((class color) (min-colors 88) (background dark))
     (:background "gray26"))
    (t (:foreground "black" :background "yellow"))
    )
  "Face used for the selection in the tooltip.")


(defun ai--completion-preview-show-at-point (pos completion)
  ""
  (ai--completion-preview-hide)

  (let* ((completion completion))

    (add-face-text-property 0 (length completion) 'ai--completion-preview-face nil completion)

    (and (equal pos (point))
         (not (equal completion ""))
         (add-text-properties 0 1 '(cursor 1) completion))

    (let* ((beg pos)
           (pto ai--completion-pseudo-tooltip-overlay)
           (ptf-workaround (and
                            pto
                            (char-before pos)
                            (eq pos (overlay-start pto)))))
      ;; Try to accommodate for the pseudo-tooltip overlay,
      ;; which may start at the same position if it's at eol.
      (when ptf-workaround
        (cl-decf beg)
        (setq completion (concat (buffer-substring beg pos) completion)))

      (setq ai--completion-preview-overlay (make-overlay beg pos))

      (let ((ov ai--completion-preview-overlay))
        (overlay-put ov (if ptf-workaround 'display 'after-string)
                     completion)
        (overlay-put ov 'window (selected-window))))))


(provide 'ai-completions)

;;; ai-completions.el ends here