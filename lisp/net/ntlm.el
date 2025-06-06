;;; ntlm.el --- NTLM (NT LanManager) authentication support  -*- lexical-binding:t -*-

;; Copyright (C) 2001, 2007-2025 Free Software Foundation, Inc.

;; Author: Taro Kawagishi <tarok@transpulse.org>
;; Maintainer: Thomas Fitzsimmons <fitzsim@fitzsim.org>
;; Keywords: NTLM, SASL, comm
;; Version: 2.1.0
;; Created: February 2001

;; This is a GNU ELPA :core package.  Avoid functionality that is not
;; compatible with the version of Emacs recorded above.

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

;; This library is a direct translation of the Samba release 2.2.0
;; implementation of Windows NT and LanManager compatible password
;; encryption.
;;
;; Interface functions:
;;
;; ntlm-build-auth-request
;;   This will return a binary string, which should be used in the
;;   base64 encoded form and it is the caller's responsibility to encode
;;   the returned string with base64.
;;
;; ntlm-build-auth-response
;;   It is the caller's responsibility to pass a base64 decoded string
;;   (which will be a binary string) as the first argument and to
;;   encode the returned string with base64.  The second argument user
;;   should be given in user@domain format.
;;
;; ntlm-get-password-hashes
;;
;;
;; NTLM authentication procedure example:
;;
;;  1. Open a network connection to the Exchange server at the IMAP port (143)
;;  2. Receive an opening message such as:
;;     "* OK Microsoft Exchange IMAP4rev1 server
;;        version 5.5.2653.7 (XXXX) ready"
;;  3. Ask for IMAP server capability by sending "NNN capability"
;;  4. Receive a capability message such as:
;;     "* CAPABILITY IMAP4 IMAP4rev1 IDLE LITERAL+
;;        LOGIN-REFERRALS MAILBOX-REFERRALS NAMESPACE AUTH=NTLM"
;;  5. Ask for NTLM authentication by sending a string
;;     "NNN authenticate ntlm"
;;  6. Receive continuation acknowledgment "+"
;;  7. Send NTLM authentication request generated by 'ntlm-build-auth-request
;;  8. Receive NTLM challenge string following acknowledgment "+"
;;  9. Generate response to challenge by 'ntlm-build-auth-response
;;     (here two hash function values of the user password are encrypted)
;; 10. Receive authentication completion message such as
;;     "NNN OK AUTHENTICATE NTLM completed."

;;; Code:

(require 'md4)
(require 'hmac-md5)

(defgroup ntlm nil
  "NTLM (NT LanManager) authentication."
  :version "25.1"
  :group 'comm)

(defcustom ntlm-compatibility-level 5
  "The NTLM compatibility level.
Ordered from 0, the oldest, least-secure level through 5, the
newest, most-secure level.  Newer servers may reject lower
levels.  At levels 3 through 5, send LMv2 and NTLMv2 responses.
At levels 0, 1 and 2, send LM and NTLM responses.

In this implementation, levels 0, 1 and 2 are the same (old,
insecure), and levels 3, 4 and 5 are the same (new, secure).  If
NTLM authentication isn't working at level 5, try level 0.  The
other levels are only present because other clients have six
levels."
  :type '(choice (const 0) (const 1) (const 2) (const 3) (const 4) (const 5)))

;;;
;;; NTLM authentication interface functions

(defun ntlm-build-auth-request (user &optional domain)
  "Return the NTLM authentication request string for USER and DOMAIN.
USER is a string representing a user name to be authenticated and
DOMAIN is a NT domain.  USER can include a NT domain part as in
user@domain where the string after @ is used as the domain if DOMAIN
is not given."
  (let ((request-ident (concat "NTLMSSP" (make-string 1 0)))
	(request-msgType (concat (make-string 1 1) (make-string 3 0)))
					;0x01 0x00 0x00 0x00
	(request-flags (unibyte-string #x07 #x82 #x08 #x00))
	)
    (when (and user (string-match "@" user))
      (unless domain
	(setq domain (substring user (1+ (match-beginning 0)))))
      (setq user (substring user 0 (match-beginning 0))))
    (when (and (stringp domain) (> (length domain) 0))
      ;; set "negotiate domain supplied" bit
      (aset request-flags 1 (logior (aref request-flags 1) ?\x10)))
    ;; set fields offsets within the request struct
    (let* ((lu (length user))
           (ld (length domain))
           (off-u 32)           ;offset to the string 'user
           (off-d (+ 32 lu)))   ;offset to the string 'domain
    ;; pack the request struct in a string
    (concat request-ident			;8 bytes
	    request-msgType			;4 bytes
	    request-flags			;4 bytes
	    (md4-pack-int16 lu)			;user field, count field
	    (md4-pack-int16 lu)			;user field, max count field
	    (md4-pack-int32 (cons 0 off-u))	;user field, offset field
	    (md4-pack-int16 ld)			;domain field, count field
	    (md4-pack-int16 ld)			;domain field, max count field
	    (md4-pack-int32 (cons 0 off-d))	;domain field, offset field
	    user				;buffer field
	    domain				;buffer field
	    ))))

;; Poor man's bignums: natural numbers represented as lists of bytes
;; in little-endian order.
;; When this code no longer needs to run on Emacs 26 or older, all this
;; silliness should be simplified to use ordinary Lisp integers.

(eval-and-compile                       ; for compile-time simplification
  (defun ntlm--bignat-of-int (x)
    "Convert the natural number X into a bignat."
    (declare (pure t))
    (and (not (zerop x))
         (cons (logand x #xff) (ntlm--bignat-of-int (ash x -8)))))

  (defun ntlm--bignat-add (a b &optional carry)
    "Add the bignats A and B and the natural number CARRY."
    (declare (pure t))
    (and (or a b (and carry (not (zerop carry))))
         (let ((s (+ (if a (car a) 0)
                     (if b (car b) 0)
                     (or carry 0))))
           (cons (logand s #xff)
                 (ntlm--bignat-add (cdr a) (cdr b) (ash s -8))))))

  (defun ntlm--bignat-shift-left (x n)
    "Multiply the bignat X by 2^{8N}."
    (declare (pure t))
    (if (zerop n) x (ntlm--bignat-shift-left (cons 0 x) (1- n))))

  (defun ntlm--bignat-mul-byte (a b)
    "Multiply the bignat A with the byte B."
    (declare (pure t))
    (let ((p (mapcar (lambda (x) (* x b)) a)))
      (ntlm--bignat-add
       (mapcar (lambda (x) (logand x #xff)) p)
       (cons 0 (mapcar (lambda (x) (ash x -8)) p)))))

  (defun ntlm--bignat-mul (a b)
    "Multiply the bignats A and B."
    (declare (pure t))
    (and a b (ntlm--bignat-add (ntlm--bignat-mul-byte a (car b))
                               (cons 0 (ntlm--bignat-mul a (cdr b))))))

  (defun ntlm--bignat-of-string (s)
    "Convert the string S (in decimal) to a bignat."
    (declare (pure t))
    (ntlm--bignat-of-digits (reverse (string-to-list s))))

  (defun ntlm--bignat-of-digits (digits)
    "Convert the little-endian list DIGITS of decimal digits to a bignat."
    (declare (pure t))
    (and digits
         (ntlm--bignat-add
          nil
          (ntlm--bignat-mul-byte (ntlm--bignat-of-digits (cdr digits)) 10)
          (- (car digits) ?0))))

  (defun ntlm--bignat-to-int64 (x)
    "Convert the bignat X to a 64-bit little-endian number as a string."
    (declare (pure t))
    (apply #'unibyte-string (mapcar (lambda (n) (or (nth n x) 0))
                                    (number-sequence 0 7))))
  )

(defun ntlm--time-to-timestamp (time)
  "Convert TIME to an NTLMv2 timestamp.
Return a unibyte string representing the number of tenths of a
microsecond since January 1, 1601 as a 64-bit little-endian
signed integer.  TIME must be on the form (HIGH LOW USEC PSEC)."
  (let* ((s-hi (ntlm--bignat-of-int (nth 0 time)))
         (s-lo (ntlm--bignat-of-int (nth 1 time)))
         (s (ntlm--bignat-add (ntlm--bignat-shift-left s-hi 2) s-lo))
         (us*10 (ntlm--bignat-of-int (* (nth 2 time) 10)))
         (ps/1e5 (ntlm--bignat-of-int (/ (nth 3 time) 100000)))
	 ;; tenths of microseconds between 1601-01-01 and 1970-01-01
         (to-unix-epoch (ntlm--bignat-of-string "116444736000000000"))
         (tenths-of-us-since-jan-1-1601
          (ntlm--bignat-add
           (ntlm--bignat-add
            (ntlm--bignat-add
             (ntlm--bignat-mul s (ntlm--bignat-of-int 10000000))
             us*10)
            ps/1e5)
           to-unix-epoch)))
    (ntlm--bignat-to-int64 tenths-of-us-since-jan-1-1601)))

(defun ntlm-compute-timestamp ()
  "Current time as an NTLMv2 timestamp, as a unibyte string."
  (ntlm--time-to-timestamp (time-convert nil 'list)))

(defun ntlm-generate-nonce ()
  "Generate a random nonce, not to be used more than once.
Return a random eight byte unibyte string."
  (unibyte-string
   (random 256) (random 256) (random 256) (random 256)
   (random 256) (random 256) (random 256) (random 256)))

(defun ntlm-build-auth-response (challenge user password-hashes)
  "Return the response string to a challenge string CHALLENGE given by
the NTLM based server for the user USER and the password hash list
PASSWORD-HASHES.  NTLM uses two hash values which are represented
by PASSWORD-HASHES.  PASSWORD-HASHES should be a return value of
 (list (ntlm-smb-passwd-hash password) (ntlm-md4hash password))"
  (let* ((rchallenge (if (multibyte-string-p challenge)
                         (progn
                           ;; FIXME: Maybe it would be better to
                           ;; signal an error.
                           (message "Incorrect challenge string type in ntlm-build-auth-response")
                           (encode-coding-string challenge 'binary))
                       challenge))
	 ;; get fields within challenge struct
	 ;;(ident (substring rchallenge 0 8))	;ident, 8 bytes
	 ;;(msgType (substring rchallenge 8 12))	;msgType, 4 bytes
	 (uDomain (substring rchallenge 12 20))	;uDomain, 8 bytes
	 ;; match default setting in `ntlm-build-auth-request'
	 (request-flags (unibyte-string #x07 #x82 #x08 #x00))
	 (flags (substring rchallenge 20 24))	;flags, 4 bytes
	 (challengeData (substring rchallenge 24 32)) ;challengeData, 8 bytes
         ;; Extract domain string from challenge string.
	 ;;(uDomain-len (md4-unpack-int16 (substring uDomain 0 2)))
         (uDomain-offs (md4-unpack-int32 (substring uDomain 4 8)))
	 ;; Response struct and its fields.
	 lmRespData			;lmRespData, 24 bytes
	 ntRespData			;ntRespData, variable length
         ;; Match Mozilla behavior, which is to send an empty domain string
	 (domain "")                    ;ascii domain string
         ;; Match Mozilla behavior, which is to send "WORKSTATION".
	 (workstation "WORKSTATION"))    ;ascii workstation string
    ;; overwrite domain in case user is given in <user>@<domain> format
    (when (string-match "@" user)
      (setq domain (substring user (1+ (match-beginning 0))))
      (setq user (substring user 0 (match-beginning 0))))
    (when (and (stringp domain) (> (length domain) 0))
      ;; set "negotiate domain supplied" bit, since presumably domain
      ;; was also set in `ntlm-build-auth-request'
      (aset request-flags 1 (logior (aref request-flags 1) ?\x10)))
    ;; match Mozilla behavior, which is to send the logical and of the
    ;; type 1 and type 2 flags
    (dotimes (index 4)
      (aset flags index (logand (aref flags index)
				(aref request-flags index))))

    (unless (and (integerp ntlm-compatibility-level)
		 (>= ntlm-compatibility-level 0)
		 (<= ntlm-compatibility-level 5))
      (error "Invalid ntlm-compatibility-level value"))
    (if (and (>= ntlm-compatibility-level 3)
	     (<= ntlm-compatibility-level 5))
	;; extract target information block, if it is present
	(if (< (cdr uDomain-offs) 48)
	    (error "Failed to find target information block")
	  (let* ((targetInfo-len (md4-unpack-int16 (substring rchallenge
							      40 42)))
		 (targetInfo-offs (md4-unpack-int32 (substring rchallenge
							       44 48)))
		 (targetInfo (substring rchallenge
					(cdr targetInfo-offs)
					(+ (cdr targetInfo-offs)
					   targetInfo-len)))
		 (upcase-user (upcase (ntlm-ascii2unicode user (length user))))
		 (ntlmv2-hash (hmac-md5 (concat upcase-user
						(ntlm-ascii2unicode
						 domain (length domain)))
					(cadr password-hashes)))
		 (nonce (ntlm-generate-nonce))
		 (blob (concat (make-string 2 1)
			       (make-string 2 0)	;blob signature
			       (make-string 4 0)	;reserved value
			       (ntlm-compute-timestamp)	;timestamp
			       nonce			;client nonce
			       (make-string 4 0)	;unknown
			       targetInfo))		;target info
		 ;; for reference: LMv2 interim calculation
		 (lm-interim (hmac-md5 (concat challengeData nonce)
				       ntlmv2-hash))
		 (nt-interim (hmac-md5 (concat challengeData blob)
				       ntlmv2-hash)))
	    ;; for reference: LMv2 field, but match other clients that
	    ;; send all zeros
	    (setq lmRespData (concat lm-interim nonce))
	    (setq ntRespData (concat nt-interim blob))))
      ;; compatibility level is 2, 1 or 0
      ;; level 2 should be treated specially but it's not clear how,
      ;; so just treat it the same as levels 0 and 1
      ;; check if "negotiate NTLM2 key" flag is set in type 2 message
      (if (not (zerop (logand (aref flags 2) 8)))
	  ;; generate NTLM2 session response data
	  (let* ((randomString (ntlm-generate-nonce))
		 (sessionHash (secure-hash 'md5
					   (concat challengeData randomString)
					   nil nil t)))
	    (setq sessionHash (substring sessionHash 0 8))
	    (setq lmRespData (concat randomString (make-string 16 0)))
	    (setq ntRespData (ntlm-smb-owf-encrypt
			      (cadr password-hashes) sessionHash)))
	;; generate response data
	(setq lmRespData
	      (ntlm-smb-owf-encrypt (car password-hashes) challengeData))
	(setq ntRespData
	      (ntlm-smb-owf-encrypt (cadr password-hashes) challengeData))))

    ;; get offsets to fields to pack the response struct in a string
    (let* ((ll (length lmRespData))
           (ln (length ntRespData))
           (lu (length user))
           (ld (length domain))
           (lw (length workstation))
           (off-u 64)			;offset to string 'uUser
           (off-d (+ off-u (* 2 lu)))	;offset to string 'uDomain
           (off-w (+ off-d (* 2 ld)))	;offset to string 'uWks
           (off-lm (+ off-w (* 2 lw)))	;offset to string 'lmResponse
           (off-nt (+ off-lm ll)))      ;offset to string 'ntResponse
    ;; pack the response struct in a string
    (concat "NTLMSSP\0"				;response ident field, 8 bytes
	    (md4-pack-int32 '(0 . 3))		;response msgType field, 4 bytes

	    ;; lmResponse field, 8 bytes
	    ;;AddBytes(response,lmResponse,lmRespData,24);
	    (md4-pack-int16 ll)			;len field
	    (md4-pack-int16 ll)			;maxlen field
	    (md4-pack-int32 (cons 0 off-lm))	;field offset

	    ;; ntResponse field, 8 bytes
	    ;;AddBytes(response,ntResponse,ntRespData,ln);
	    (md4-pack-int16 ln)			;len field
	    (md4-pack-int16 ln)			;maxlen field
	    (md4-pack-int32 (cons 0 off-nt))	;field offset

	    ;; uDomain field, 8 bytes
	    ;;AddUnicodeString(response,uDomain,domain);
	    ;;AddBytes(response, uDomain, udomain, 2*ld);
	    (md4-pack-int16 (* 2 ld))		;len field
	    (md4-pack-int16 (* 2 ld))		;maxlen field
	    ;; match Mozilla behavior, which is to hard-code the
	    ;; domain offset to 64
	    (md4-pack-int32 (cons 0 64))	;field offset

	    ;; uUser field, 8 bytes
	    ;;AddUnicodeString(response,uUser,u);
	    ;;AddBytes(response, uUser, uuser, 2*lu);
	    (md4-pack-int16 (* 2 lu))		;len field
	    (md4-pack-int16 (* 2 lu))		;maxlen field
	    (md4-pack-int32 (cons 0 off-u))	;field offset

	    ;; uWks field, 8 bytes
	    ;;AddUnicodeString(response,uWks,u);
	    (md4-pack-int16 (* 2 lw))		;len field
	    (md4-pack-int16 (* 2 lw))		;maxlen field
	    (md4-pack-int32 (cons 0 off-w))	;field offset

	    ;; sessionKey field, blank, 8 bytes
	    ;;AddString(response,sessionKey,NULL);
	    (md4-pack-int16 0)			;len field
	    (md4-pack-int16 0)			;maxlen field
	    (md4-pack-int32 (cons 0 0))		;field offset

	    ;; flags field, 4 bytes
	    flags

	    ;; buffer field
	    (ntlm-ascii2unicode user lu)	;Unicode user, 2*lu bytes
	    (ntlm-ascii2unicode domain ld)	;Unicode domain, 2*ld bytes
	    (ntlm-ascii2unicode workstation lw)	;Unicode workstation, 2*lw bytes
	    lmRespData				;lmResponse, 24 bytes
	    ntRespData				;ntResponse, ln bytes
	    ))))

(defun ntlm-get-password-hashes (password)
  "Return a pair of SMB hash and NT MD4 hash of the given password PASSWORD."
  (list (ntlm-smb-passwd-hash password)
	(ntlm-md4hash password)))

(defun ntlm-ascii2unicode (str len)
  "Convert an ASCII string STR of length LEN into a NT Unicode string.
NT Unicode strings are little-endian utf16."
  ;; FIXME: Can't we use encode-coding-string with a `utf-16le' coding system?
  (let ((utf (make-string (* 2 len) 0))
        (i 0)
        val)
    (while (and (< i len)
		(not (zerop (setq val (aref str i)))))
      (aset utf (* 2 i) val)
      (aset utf (1+ (* 2 i)) 0)
      (setq i (1+ i)))
    utf))

(defun ntlm-unicode2ascii (str len)
  "Extract 7 bits ASCII part of a little endian utf16 string STR of length LEN."
  (let ((buf (make-string len 0)) (i 0) (j 0))
    (while (< i len)
      (aset buf i (logand (aref str j) 127)) ;(string-to-number "7f" 16)
      (setq i (1+ i)
	    j (+ 2 j)))
    buf))

(defun ntlm-smb-passwd-hash (passwd)
  "Return SMB password hash string of 16 bytes long for password string PASSWD.
PASSWD is truncated to 14 bytes if longer."
  (let ((len (min (length passwd) 14)))
    (ntlm-smb-des-e-p16
     (concat (substring (upcase passwd) 0 len) ;fill top 14 bytes with passwd
	     (make-string (- 15 len) 0)))))

(defun ntlm-smb-owf-encrypt (passwd c8)
  "Return response string of 24 bytes long for PASSWD based on DES encryption.
PASSWD is of at most 14 bytes long and the challenge string C8 of
8 bytes long."
  (let* ((len (min (length passwd) 16))
         (p22 (concat (substring passwd 0 len) ;Fill top 16 bytes with passwd.
		      (make-string (- 22 len) 0))))
    (ntlm-smb-des-e-p24 p22 c8)))

(defun ntlm-smb-des-e-p24 (p22 c8)
  "Return 24 bytes hashed string for a 21 bytes string P22 and a 8 bytes string C8."
  (concat (ntlm-smb-hash c8 p22 t)		;hash first 8 bytes of p22
	  (ntlm-smb-hash c8 (substring p22 7) t)
	  (ntlm-smb-hash c8 (substring p22 14) t)))

(defconst ntlm-smb-sp8 [75 71 83 33 64 35 36 37])

(defun ntlm-smb-des-e-p16 (p15)
  "Return a 16 bytes hashed string for a 15 bytes string P15."
  (concat (ntlm-smb-hash ntlm-smb-sp8 p15 t)	;hash of first 8 bytes of p15
	  (ntlm-smb-hash ntlm-smb-sp8		;hash of last 8 bytes of p15
			 (substring p15 7) t)))

(defun ntlm-smb-hash (in key forw)
  "Return hash string of length 8 for IN of length 8 and KEY of length 8.
FORW is t or nil."
  (let ((out (make-string 8 0))
	(inb (make-string 64 0))
	(keyb (make-string 64 0))
	(key2 (ntlm-smb-str-to-key key))
	(i 0))
    (while (< i 64)
      (unless (zerop (logand (aref in (/ i 8)) (ash 1 (- 7 (% i 8)))))
	(aset inb i 1))
      (unless (zerop (logand (aref key2 (/ i 8)) (ash 1 (- 7 (% i 8)))))
	(aset keyb i 1))
      (setq i (1+ i)))
    (let ((outb (ntlm-smb-dohash inb keyb forw))
          aa)
      (setq i 0)
      (while (< i 64)
        (unless (zerop (aref outb i))
	  (setq aa (aref out (/ i 8)))
	  (aset out (/ i 8)
	        (logior aa (ash 1 (- 7 (% i 8))))))
        (setq i (1+ i)))
      out)))

(defun ntlm-smb-str-to-key (str)
  "Return a string of length 8 for the given string STR of length 7."
  (let ((key (make-string 8 0))
	(i 7))
    (aset key 0 (ash (aref str 0) -1))
    (aset key 1 (logior
		 (ash (logand (aref str 0) 1) 6)
		 (ash (aref str 1) -2)))
    (aset key 2 (logior
		 (ash (logand (aref str 1) 3) 5)
		 (ash (aref str 2) -3)))
    (aset key 3 (logior
		 (ash (logand (aref str 2) 7) 4)
		 (ash (aref str 3) -4)))
    (aset key 4 (logior
		 (ash (logand (aref str 3) 15) 3)
		 (ash (aref str 4) -5)))
    (aset key 5 (logior
		 (ash (logand (aref str 4) 31) 2)
		 (ash (aref str 5) -6)))
    (aset key 6 (logior
		 (ash (logand (aref str 5) 63) 1)
		 (ash (aref str 6) -7)))
    (aset key 7 (logand (aref str 6) 127))
    (while (>= i 0)
      (aset key i (ash (aref key i) 1))
      (setq i (1- i)))
    key))

(defconst ntlm-smb-perm1 [57 49 41 33 25 17  9
		     1 58 50 42 34 26 18
		     10  2 59 51 43 35 27
		     19 11  3 60 52 44 36
		     63 55 47 39 31 23 15
		     7 62 54 46 38 30 22
		     14  6 61 53 45 37 29
		     21 13  5 28 20 12  4])

(defconst ntlm-smb-perm2 [14 17 11 24  1  5
		     3 28 15  6 21 10
		     23 19 12  4 26  8
		     16  7 27 20 13  2
		     41 52 31 37 47 55
		     30 40 51 45 33 48
		     44 49 39 56 34 53
		     46 42 50 36 29 32])

(defconst ntlm-smb-perm3 [58 50 42 34 26 18 10  2
		     60 52 44 36 28 20 12  4
		     62 54 46 38 30 22 14  6
		     64 56 48 40 32 24 16  8
		     57 49 41 33 25 17  9  1
		     59 51 43 35 27 19 11  3
		     61 53 45 37 29 21 13  5
		     63 55 47 39 31 23 15  7])

(defconst ntlm-smb-perm4 [32  1  2  3  4  5
		     4  5  6  7  8  9
		     8  9 10 11 12 13
		     12 13 14 15 16 17
		     16 17 18 19 20 21
		     20 21 22 23 24 25
		     24 25 26 27 28 29
		     28 29 30 31 32  1])

(defconst ntlm-smb-perm5 [16  7 20 21
		     29 12 28 17
		     1 15 23 26
		     5 18 31 10
		     2  8 24 14
		     32 27  3  9
		     19 13 30  6
		     22 11  4 25])

(defconst ntlm-smb-perm6 [40  8 48 16 56 24 64 32
		     39  7 47 15 55 23 63 31
		     38  6 46 14 54 22 62 30
		     37  5 45 13 53 21 61 29
		     36  4 44 12 52 20 60 28
		     35  3 43 11 51 19 59 27
		     34  2 42 10 50 18 58 26
		     33  1 41  9 49 17 57 25])

(defconst ntlm-smb-sc [1 1 2 2 2 2 2 2 1 2 2 2 2 2 2 1])

(defconst ntlm-smb-sbox [[[14  4 13  1  2 15 11  8  3 10  6 12  5  9  0  7]
		     [ 0 15  7  4 14  2 13  1 10  6 12 11  9  5  3  8]
		     [ 4  1 14  8 13  6  2 11 15 12  9  7  3 10  5  0]
		     [15 12  8  2  4  9  1  7  5 11  3 14 10  0  6 13]]
		    [[15  1  8 14  6 11  3  4  9  7  2 13 12  0  5 10]
		     [ 3 13  4  7 15  2  8 14 12  0  1 10  6  9 11  5]
		     [ 0 14  7 11 10  4 13  1  5  8 12  6  9  3  2 15]
		     [13  8 10  1  3 15  4  2 11  6  7 12  0  5 14  9]]
		    [[10  0  9 14  6  3 15  5  1 13 12  7 11  4  2  8]
		     [13  7  0  9  3  4  6 10  2  8  5 14 12 11 15  1]
		     [13  6  4  9  8 15  3  0 11  1  2 12  5 10 14  7]
		     [ 1 10 13  0  6  9  8  7  4 15 14  3 11  5  2 12]]
		    [[ 7 13 14  3  0  6  9 10  1  2  8  5 11 12  4 15]
		     [13  8 11  5  6 15  0  3  4  7  2 12  1 10 14  9]
		     [10  6  9  0 12 11  7 13 15  1  3 14  5  2  8  4]
		     [ 3 15  0  6 10  1 13  8  9  4  5 11 12  7  2 14]]
		    [[ 2 12  4  1  7 10 11  6  8  5  3 15 13  0 14  9]
		     [14 11  2 12  4  7 13  1  5  0 15 10  3  9  8  6]
		     [ 4  2  1 11 10 13  7  8 15  9 12  5  6  3  0 14]
		     [11  8 12  7  1 14  2 13  6 15  0  9 10  4  5  3]]
		    [[12  1 10 15  9  2  6  8  0 13  3  4 14  7  5 11]
		     [10 15  4  2  7 12  9  5  6  1 13 14  0 11  3  8]
		     [ 9 14 15  5  2  8 12  3  7  0  4 10  1 13 11  6]
		     [ 4  3  2 12  9  5 15 10 11 14  1  7  6  0  8 13]]
		    [[ 4 11  2 14 15  0  8 13  3 12  9  7  5 10  6  1]
		     [13  0 11  7  4  9  1 10 14  3  5 12  2 15  8  6]
		     [ 1  4 11 13 12  3  7 14 10 15  6  8  0  5  9  2]
		     [ 6 11 13  8  1  4 10  7  9  5  0 15 14  2  3 12]]
		    [[13  2  8  4  6 15 11  1 10  9  3 14  5  0 12  7]
		     [ 1 15 13  8 10  3  7  4 12  5  6 11  0 14  9  2]
		     [ 7 11  4  1  9 12 14  2  0  6 10 13 15  3  5  8]
		     [ 2  1 14  7  4 10  8 13 15 12  9  0  3  5  6 11]]])

(defsubst ntlm-string-permute (in perm n)
  "Return string of length N for string IN and permutation vector PERM of size N.
The length of IN should be height of PERM."
  (let ((i 0) (out (make-string n 0)))
    (while (< i n)
      (aset out i (aref in (- (aref perm i) 1)))
      (setq i (1+ i)))
    out))

(defsubst ntlm-string-lshift (str count len)
  "Return a string by circularly shifting a string STR by COUNT to the left.
length of STR is LEN."
  (let ((c (% count len)))
    (concat (substring str c len) (substring str 0 c))))

(defsubst ntlm-string-xor (in1 in2 n)
  "Return exclusive-or of sequences in1 and in2."
  (let ((w (make-string n 0)) (i 0))
    (while (< i n)
      (aset w i (logxor (aref in1 i) (aref in2 i)))
      (setq i (1+ i)))
    w))

(defun ntlm-smb-dohash (in key forw)
  "Return the hash value for a string IN and a string KEY.
Length of IN and KEY are 64.  FORW non-nil means forward, nil means
backward."
  (let* ((pk1 (ntlm-string-permute key ntlm-smb-perm1 56)) ;string of length 56
	 (c (substring pk1 0 28))       ;string of length 28
	 (d (substring pk1 28 56))      ;string of length 28
	 cd				;string of length 56
	 (ki (make-vector 16 0))        ;vector of string of length 48
	 pd1				;string of length 64
	 l				;string of length 32
	 r				;string of length 32
	 rl				;string of length 64
	 (i 0) (j 0) (k 0))

    (dotimes (i 16)
      (setq c (ntlm-string-lshift c (aref ntlm-smb-sc i) 28))
      (setq d (ntlm-string-lshift d (aref ntlm-smb-sc i) 28))
      (setq cd (concat (substring c 0 28) (substring d 0 28)))
      (aset ki i (ntlm-string-permute cd ntlm-smb-perm2 48)))

    (setq pd1 (ntlm-string-permute in ntlm-smb-perm3 64))

    (setq l (substring pd1 0 32))
    (setq r (substring pd1 32 64))

    (setq i 0)
    (let (er				;string of length 48
	  erk				;string of length 48
	  (b (make-vector 8 0))		;vector of strings of length 6
	  cb				;string of length 32
	  pcb				;string of length 32
	  r2				;string of length 32
	  jj m n bj sbox-jmn)
      (while (< i 16)
	(setq er (ntlm-string-permute r ntlm-smb-perm4 48))
	(setq erk (ntlm-string-xor er
		       (aref ki (if forw i (- 15 i)))
		       48))
	(setq j 0)
	(while (< j 8)
	  (setq jj (* 6 j))
	  (aset b j (substring erk jj (+ jj 6)))
	  (setq j (1+ j)))
	(setq j 0)
	(while (< j 8)
	  (setq bj (aref b j))
	  (setq m (logior (ash (aref bj 0) 1) (aref bj 5)))
	  (setq n (logior (ash (aref bj 1) 3)
			  (ash (aref bj 2) 2)
			  (ash (aref bj 3) 1)
			  (aref bj 4)))
	  (setq k 0)
	  (setq sbox-jmn (aref (aref (aref ntlm-smb-sbox j) m) n))
	  (while (< k 4)
	    (aset bj k
		  (if (zerop (logand sbox-jmn (ash 1 (- 3 k))))
		      0 1))
	    (setq k (1+ k)))
	  (setq j (1+ j)))

	(setq j 0)
	(setq cb nil)
	(while (< j 8)
	  (setq cb (concat cb (substring (aref b j) 0 4)))
	  (setq j (1+ j)))

	(setq pcb (ntlm-string-permute cb ntlm-smb-perm5 32))
	(setq r2 (ntlm-string-xor l pcb 32))
	(setq l r)
	(setq r r2)
	(setq i (1+ i))))
    (setq rl (concat r l))
    (ntlm-string-permute rl ntlm-smb-perm6 64)))

(defun ntlm-md4hash (passwd)
  "Return 16 bytes MD4 hash of string PASSWD after converting it to Unicode.
PASSWD is truncated to 128 bytes if longer."
  (let* ((len (min (length passwd) 128)) ;Pwd can't be > than 128 characters.
         ;; Password must be converted to NT Unicode.
         (wpwd (ntlm-ascii2unicode passwd len)))
    (md4 wpwd
         ;; Calculate length in bytes.
         (* len 2))))

(provide 'ntlm)

;;; ntlm.el ends here
