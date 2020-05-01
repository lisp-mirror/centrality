;; Copyright (c) 2020 Andrey Dubovik <andrei@dubovik.eu>

;; Talking to trackers

(in-package :ansible)

(defparameter *tracker-timeout* 120)
(defparameter *tracker-interval* 600)
(defparameter *listen-port* 6881) ; not implemented, sent to trackers

(defun make-uri (host query)
  "An URI constructor that does not strive to be smart about type conversion"
  (concatenate 'string host "?"
   (string-join
    (mapcar
     (lambda (keyval)
       (destructuring-bind (key . val) keyval
       (concatenate 'string key "=" val)))
     query) "&")))

(defun split-peers (peers size)
  "Split peers array"
  (iter (for i from 0 below (length peers) by size)
        (collect (cons
                  (subseq peers i (- (+ i size) 2))
                  (unpack (subseq peers (- (+ i size) 2) (+ i size)))))))

;; TODO: add ip6 support (here and elsewhere)
(defun decode-peers (peers)
  "Decode compact tracker response (ip6 is currently ignored)"
  (let ((dict (decode-sequence peers)))
    (values (split-peers (getvalue "peers" dict) 6)
            (getvalue "interval" dict))))

(defun format-proxy (address)
  "Format proxy address for dexador"
  (if address
      (destructuring-bind (host . port) address
        (format nil "socks5://~{~d~^.~}:~d" (coerce host 'list) port))))

;; TODO: does dexador support username/password for SOCKS5?
;; TODO: do trackers actually need other fields mentioned in the specification?
(defun get-peers (torrent proxy)
  "Get a list of peers from tracker"
  (decode-peers
   (dex:get
    (make-uri
     (tr-announce torrent)
     `(("info_hash" . ,(quri:url-encode (tr-hash torrent)))
       ("peer_id" . ,(quri:url-encode (random-peerid)))
       ("port" . ,(write-to-string *listen-port*))
       ("compact" . "1")))
    :connect-timeout *tracker-timeout*
    :read-timeout *tracker-timeout*
    :force-binary t
    :proxy (format-proxy proxy))))

;; Tracker logic is basic: query tracker periodically, ignore errors but log them.

(defun tracker-loop (torrent queue alarm &key proxy &allow-other-keys)
  "Query tracker periodically"
  (loop
     (handler-case
         (let ((peers (get-peers torrent proxy)))
           (dolist (peer peers) (enqueue peer queue))
           (signal-semaphore alarm)
           (log-msg 2 :event :tracker :torrent (format-hash torrent) :proxy proxy :count (length peers)))
       (error (e)
         (log-msg 1 :event :notracker :torrent (format-hash torrent) :condition (type-of e))))
     (sleep *tracker-interval*)))

(defun open-tracker (torrent queue alarm &rest rest)
  "Start tracker loop"
  (make-thread (lambda () (apply #'tracker-loop torrent queue alarm rest)) :name "ansible-tracker"))
