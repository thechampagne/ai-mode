;;; ai-openai-completions.el --- Integration with completions OpenAI API -*- lexical-binding: t -*-

;; Copyright (C) 2023 Alex (https://github.com/lispython)

;; URL: https://github.com/ai-mode/ai-mode
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords: help, tools


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
;; The module includes functions for creating requests
;; to the OpenAI completions API and processing responses.

;;; Code:

(require 'ai-utils)
(require 'ai-openai)
(require 'map)

(defcustom ai-openai-completions--model-version "text-davinci-003"
  "The used OpenAI model.

The list of models supported by /v1/chat/completions endpoint is
documented at
https://platform.openai.com/docs/models/model-endpoint-compatibility."
  :type 'string
  :group 'ai-openai)


(defvar ai-openai-completions--url "https://api.openai.com/v1/completions")


(cl-defun ai-openai-completions--async-request (input callback &key (fail-callback nil) (extra-params nil))
  "Asynchronous INPUT execution of a request to the OpenAI completions API.

In case of a successful request execution, a CALLBACK function is called.
In case of failed request execution FAIL-CALLBACK is called.

EXTRA-PARAMS is a list of properties (plist) that can be used to store parameters."
  (when (null ai-openai--api-key)
    (error "OpenAI API key is not set"))

  (let* ((api-url (map-elt extra-params :api-url ai-openai-completions--url))
         (model (map-elt extra-params :model ai-openai-completions--model-version))
         (temperature (map-elt extra-params :temperature ai-openai--model-temperature))
         (max-tokens (map-elt extra-params :max-tokens ai-openai--default-max-tokens))
         (timeout (map-elt extra-params :timeout ai-openai-request-timeout))
         (n (map-elt extra-params :n ai-openai--completion-choices))

         (request-data `(("model" . ,model)
                         ("prompt" . ,input)
                         ("temperature" . ,temperature)
                         ("max_tokens" . ,max-tokens)))
         (encoded-request-data (encode-coding-string (json-encode request-data) 'utf-8))
         (headers  `(("Content-Type" . "application/json")
                     ("Authorization" . ,(format "Bearer %s" ai-openai--api-key)))))
    (ai-utils--async-request api-url "POST" encoded-request-data headers callback :timeout timeout)))


(cl-defun ai-openai-completions--sync-request (input &key (extra-params nil))
  "Synchronous INPUT execution of a request to the OpenAI completions API.

EXTRA-PARAMS is a list of properties (plist) that can be used to store parameters."
  (when (null ai-openai--api-key)
    (error "OpenAI API key is not set"))

  (let* ((api-url (map-elt extra-params :api-url ai-openai-completions--url))
         (model (map-elt extra-params :model ai-openai-completions--model-version))
         (temperature (map-elt extra-params :temperature ai-openai--model-temperature))
         (max-tokens (map-elt extra-params :max-tokens ai-openai--default-max-tokens))
         (timeout (map-elt extra-params :timeout ai-openai-request-timeout))
         (n (map-elt extra-params :n ai-openai--completion-choices))

         (request-data `(("model" . ,model)
                         ("prompt" . ,input)
                         ("temperature" . ,temperature)
                         ("max_tokens" . ,max-tokens)))
         (encoded-request-data (encode-coding-string (json-encode request-data)
                                                     'utf-8))

         (headers  `(("Content-Type" . "application/json")
                     ("Authorization" . ,(format "Bearer %s" ai-openai--api-key)))))
    (condition-case-unless-debug processing-error
        (let ((response (ai-utils--sync-request api-url "POST" encoded-request-data headers :timeout timeout)))
          (ai-openai--extract-response-or-error response))
      (error  (progn
                (ai-utils--log-and-error  (format "Process chat request error: %s" (error-message-string processing-error))))))))


(cl-defun ai-openai-completions--async-send-query (input callback &key (fail-callback nil) (extra-params nil))
  "Async execute INPUT, exract message from response.

In case of a successful request execution, a CALLBACK function is called.
In case of failed request execution FAIL-CALLBACK is called.

EXTRA-PARAMS is a list of properties (plist) that can be used to store parameters."
  (ai-openai-completions--async-request
   input
   (lambda (response)
     (let* ((success-response (ai-openai--extract-response-or-error response))
            (choice  (ai-openai-completions--get-choice success-response)))
       (funcall callback choice)))
   :fail-callback fail-callback
   :extra-params extra-params))


(cl-defun ai-openai-completions--sync-send-query (input &key (extra-params nil))
  "Sync execute INPUT, exract message from response and return.

EXTRA-PARAMS is a list of properties (plist) that can be used to store parameters."
  (let* ((message input)
         (success-response (ai-openai-completions--sync-request input :extra-params extra-params))
         (content (ai-openai-completions--get-choice success-response)))
    content))


(cl-defun ai-openai-completions--get-choice (response &optional (choice-id 0))
  "Extract CHOICE-ID element from RESPONSE."
  (if (> (length (ai-openai--get-response-choices response)) 0)
      (let* ((choice (elt (ai-openai--get-response-choices response) choice-id)))
        (cdr (assoc 'text choice)))))


(cl-defun ai-openai-completions--completion-backend (code callback &key (fail-callback nil) (extra-params nil))
  "Completion CODE with TYPE via AI and call CALLBACK with response.

If request failed call FAIL-CALLBACK.
EXTRA-PARAMS is a list of properties (plist) that can be used to store parameters."

  (message (format "ai-openai-completions--completion-backend: %s" extra-params))
  (ai-openai-completions--async-request
   code
   (lambda (response)
     (let* ((success-response (ai-openai--extract-response-or-error response))
            (choices  (ai-openai--get-response-choices success-response))
            (candidates (ai-openai-completions--choices-to-candidates choices)))
       (funcall callback candidates)))
   :fail-callback fail-callback
   :extra-params extra-params))


(defun ai-openai-completions--choices-to-candidates (choices)
  "Convert completion result CHOICES into internal candidates."
  (mapcar (lambda (item) (cdr (assoc 'text item))) choices))



(provide 'ai-openai-completions)

;;; ai-openai-completions.el ends here
