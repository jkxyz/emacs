;;; delim-col.el --- prettify all columns in a region or rectangle  -*- lexical-binding: t; -*-

;; Copyright (C) 1999-2025 Free Software Foundation, Inc.

;; Author: Vinicius Jose Latorre <viniciusjl.gnu@gmail.com>
;; Old-Version: 2.1
;; Keywords: convenience text
;; URL: https://www.emacswiki.org/emacs/ViniciusJoseLatorre

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

;; delim-col helps to prettify columns in a text region or rectangle.
;;
;; If you have, for example, the following columns:
;;
;;	a	b	c	d
;;	aaaa	bb	ccc	ddddd
;;	aaa	bbb	cccc	dddd
;;	aa	bb	ccccccc	ddd
;;
;; And the following settings:
;;
;;    (setq delimit-columns-str-before "[ ")
;;    (setq delimit-columns-str-after " ]")
;;    (setq delimit-columns-str-separator ", ")
;;    (setq delimit-columns-before "")
;;    (setq delimit-columns-after "")
;;    (setq delimit-columns-separator "\t")
;;    (setq delimit-columns-format 'separator)
;;    (setq delimit-columns-extra t)
;;
;; If you select the lines above and type:
;;
;;    M-x delimit-columns-region RET
;;
;; You obtain the following result:
;;
;;	[ a   , b  , c      , d     ]
;;	[ aaaa, bb , ccc    , ddddd ]
;;	[ aaa , bbb, cccc   , dddd  ]
;;	[ aa  , bb , ccccccc, ddd   ]
;;
;; But if you select start from the very first b to the very last c and type:
;;
;;    M-x delimit-columns-rectangle RET
;;
;; You obtain the following result:
;;
;;	a	[ b  , c       ]	d
;;	aaaa	[ bb , ccc     ]	ddddd
;;	aaa	[ bbb, cccc    ]	dddd
;;	aa	[ bb , ccccccc ]	ddd
;;
;; Now, if we change settings to:
;;
;;    (setq delimit-columns-before "<")
;;    (setq delimit-columns-after ">")
;;
;; For the `delimit-columns-region' example above, the result is:
;;
;;	[ <a>   , <b>  , <c>      , <d>     ]
;;	[ <aaaa>, <bb> , <ccc>    , <ddddd> ]
;;	[ <aaa> , <bbb>, <cccc>   , <dddd>  ]
;;	[ <aa>  , <bb> , <ccccccc>, <ddd>   ]
;;
;; And for the `delimit-columns-rectangle' example above, the result is:
;;
;;	a	[ <b>  , <c>       ]	d
;;	aaaa	[ <bb> , <ccc>     ]	ddddd
;;	aaa	[ <bbb>, <cccc>    ]	dddd
;;	aa	[ <bb> , <ccccccc> ]	ddd
;;
;; Note that `delimit-columns-region' operates over the entire selected
;; text region, extending the region start to the beginning of line and
;; the region end to the end of line.  While `delimit-columns-rectangle'
;; operates over the text rectangle selected which rectangle diagonal is
;; given by the region start and end.
;;
;; See `delimit-columns-format' variable documentation for column formatting.
;;
;; `delimit-columns-region' is useful when you have columns of text that
;; are not well aligned, like:
;;
;;	horse	apple	bus
;;	dog	pineapple	car
;;	porcupine	strawberry	airplane
;;
;; `delimit-columns-region' and `delimit-columns-rectangle' handle lines
;; with different number of columns, like:
;;
;;	horse	apple	bus
;;	dog	pineapple	car	EXTRA
;;	porcupine	strawberry	airplane
;;
;; Use `delimit-columns-customize' to customize delim-col package variables.

;;; Code:

(require 'rect)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User Options:

(defgroup columns nil
  "Prettify columns."
  :link '(emacs-library-link :tag "Source Lisp File" "delim-col.el")
  :prefix "delimit-columns-"
  :group 'convenience
  :group 'text)

(defcustom delimit-columns-str-before ""
  "Specify a string to be inserted before all columns."
  :type '(string :tag "Before All Columns")
  :group 'columns)

(defcustom delimit-columns-str-separator ", "
  "Specify a string to be inserted between each column."
  :type '(string :tag "Between Each Column")
  :group 'columns)

(defcustom delimit-columns-str-after ""
  "Specify a string to be inserted after all columns."
  :type '(string :tag "After All Columns")
  :group 'columns)

(defcustom delimit-columns-before ""
  "Specify a string to be inserted before each column."
  :type '(string :tag "Before Each Column")
  :group 'columns)

(defcustom delimit-columns-after ""
  "Specify a string to be inserted after each column."
  :type '(string :tag "After Each Column")
  :group 'columns)

(defcustom delimit-columns-separator "\t"
  "Specify a regexp which separates each column."
  :type '(regexp :tag "Column Separator")
  :group 'columns)

(defcustom delimit-columns-format t
  "Specify how to format columns.

For examples below, consider:

   + columns `ccc' and `dddd',
   + the maximum column length for each column is 6,
   + and the following settings:
      (setq delimit-columns-before \"<\")
      (setq delimit-columns-after \">\")
      (setq delimit-columns-separator \":\")

Valid values are:

   nil		no formatting.  That is, `delimit-columns-after' is followed by
		`delimit-columns-separator'.
		For example, the result is: \"<ccc>:<dddd>:\"

   t		align columns.  That is, `delimit-columns-after' is followed by
		`delimit-columns-separator' and then followed by spaces.
		For example, the result is: \"<ccc>:   <dddd>:  \"

   `separator'	align separators.  That is, `delimit-columns-after' is followed
		by spaces and then followed by `delimit-columns-separator'.
		For example, the result is: \"<ccc>   :<dddd>  :\"

   `padding'	format column by filling with spaces before
		`delimit-columns-after'.  That is, spaces are followed by
		`delimit-columns-after' and then followed by
		`delimit-columns-separator'.
		For example, the result is: \"<ccc   >:<dddd  >:\"

Any other value is treated as t."
  :type '(choice :menu-tag "Column Formatting"
		 :tag "Column Formatting"
		 (const :tag "No Formatting" nil)
		 (const :tag "Column Alignment" t)
		 (const :tag "Separator Alignment" separator)
		 (const :tag "Column Padding" padding))
  :group 'columns)

(defcustom delimit-columns-extra t
  "Non-nil means that lines will have the same number of columns.

This has effect only when there are lines with different number of columns."
  :type '(boolean :tag "Lines With Same Number Of Column")
  :group 'columns)

(defcustom delimit-columns-start 0
  "Specify column number to start prettifying.

See also `delimit-columns-end' for documentation.

The following relation must hold:
   0 <= delimit-columns-start <= delimit-columns-end

The column number starts at 0 and is relative to the beginning of
the selected region.  So if you select a text region, the first
column (column 0) is located at the beginning of line.  If you
select a text rectangle, the first column (column 0) is located
at the left corner."
  :type '(integer :tag "Column Start")
  :group 'columns)

(defcustom delimit-columns-end 1000000
  "Specify column number to end prettifying.

See also `delimit-columns-start' for documentation.

The following relation must hold:
   0 <= delimit-columns-start <= delimit-columns-end

The column number starts at 0 and is relative to the beginning of
the selected region.  So if you select a text region, the first
column (column 0) is located at the beginning of line.  If you
select a text rectangle, the first column (column 0) is located
at the left corner."
  :type '(integer :tag "Column End")
  :group 'columns)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User Commands:


;; to avoid compilation gripes
(defvar delimit-columns-max nil)
(defvar delimit-columns-limit nil)


;;;###autoload
(defun delimit-columns-customize ()
  "Customize the `columns' group."
  (interactive)
  (customize-group 'columns))


(defun delimit-columns-str (str)
  (if (stringp str) str ""))


;;;###autoload
(defun delimit-columns-region (start end)
  "Prettify all columns in a text region.

START and END delimit the text region.

If you have, for example, the following columns:

       a       b       c       d
       aaaa    bb      ccc     ddddd

Depending on your settings (see below), you then obtain the
following result:

       [ a   , b  , c      , d     ]
       [ aaaa, bb , ccc    , ddddd ]

See the `delimit-columns-str-before',
`delimit-columns-str-after', `delimit-columns-str-separator',
`delimit-columns-before', `delimit-columns-after',
`delimit-columns-separator', `delimit-columns-format' and
`delimit-columns-extra' variables for customization of the
look."
  (interactive "*r")
  (if rectangle-mark-mode
      ;; Delegate to delimit-columns-rectangle when called with a
      ;; rectangular region.
      (delimit-columns-rectangle start end)
    (let ((delimit-columns-str-before
           (delimit-columns-str delimit-columns-str-before))
          (delimit-columns-str-separator
           (delimit-columns-str delimit-columns-str-separator))
          (delimit-columns-str-after
           (delimit-columns-str delimit-columns-str-after))
          (delimit-columns-before
           (delimit-columns-str delimit-columns-before))
          (delimit-columns-after
           (delimit-columns-str delimit-columns-after))
          (delimit-columns-start
           (if (natnump delimit-columns-start)
               delimit-columns-start
             0))
          (delimit-columns-end
           (if (integerp delimit-columns-end)
               delimit-columns-end
             1000000))
          (delimit-columns-limit (make-marker))
          (the-end (copy-marker end))
          delimit-columns-max)
      (when (<= delimit-columns-start delimit-columns-end)
        (save-excursion
          (goto-char start)
          (beginning-of-line)
          ;; get maximum length for each column
          (and delimit-columns-format
               (save-excursion
                 (while (< (point) the-end)
                   (delimit-columns-rectangle-max
                    (prog1
                        (point)
                      (end-of-line)))
                   (forward-char 1))))
          ;; prettify columns
          (while (< (point) the-end)
            (delimit-columns-rectangle-line
             (prog1
                 (point)
               (end-of-line)))
            (forward-char 1))
          ;; nullify markers
          (set-marker delimit-columns-limit nil)
          (set-marker the-end nil))))))


;;;###autoload
(defun delimit-columns-rectangle (start end)
  "Prettify all columns in a text rectangle.

See `delimit-columns-region' for what this entails.

START and END delimit the corners of the text rectangle."
  (interactive "*r")
  (let ((delimit-columns-str-before
	 (delimit-columns-str delimit-columns-str-before))
	(delimit-columns-str-separator
	 (delimit-columns-str delimit-columns-str-separator))
	(delimit-columns-str-after
	 (delimit-columns-str delimit-columns-str-after))
	(delimit-columns-before
	 (delimit-columns-str delimit-columns-before))
	(delimit-columns-after
	 (delimit-columns-str delimit-columns-after))
	(delimit-columns-start
         (if (natnump delimit-columns-start)
	     delimit-columns-start
	   0))
	(delimit-columns-end
	 (if (integerp delimit-columns-end)
	     delimit-columns-end
	   1000000))
	(delimit-columns-limit (make-marker))
	(the-end (copy-marker end))
	delimit-columns-max)
    (when (<= delimit-columns-start delimit-columns-end)
      ;; get maximum length for each column
      (and delimit-columns-format
	   (save-excursion
             (operate-on-rectangle #'delimit-columns-rectangle-max
				   start the-end nil)))
      ;; prettify columns
      (save-excursion
        (operate-on-rectangle #'delimit-columns-rectangle-line
			      start the-end nil))
      ;; nullify markers
      (set-marker delimit-columns-limit nil)
      (set-marker the-end nil))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Variables and Functions:


(defun delimit-columns-rectangle-max (startpos &optional _begextra _endextra)
  (set-marker delimit-columns-limit (point))
  (goto-char startpos)
  (let ((ncol 1)
	origin values)
    ;; get current column length
    (while (progn
	     (setq origin (current-column))
	     (re-search-forward delimit-columns-separator
				delimit-columns-limit 'move))
      (save-excursion
	(goto-char (match-beginning 0))
	(setq values (cons (- (current-column) origin)
			   values)))
      (setq ncol (1+ ncol)))
    (setq values (cons (- (current-column) origin)
		       values))
    ;; extend delimit-columns-max, if needed
    (let ((index (length delimit-columns-max)))
      (and (> ncol index)
	   (let ((extend (make-vector ncol 0)))
	     (while (> index 0)
	       (setq index (1- index))
	       (aset extend index (aref delimit-columns-max index)))
	     (setq delimit-columns-max extend))))
    ;; get maximum column length
    (while values
      (setq ncol (1- ncol))
      (aset delimit-columns-max ncol (max (aref delimit-columns-max ncol)
					  (car values)))
      (setq values (cdr values)))))


(defun delimit-columns-rectangle-line (startpos &optional _begextra _endextra)
  (let ((len  (length delimit-columns-max))
	(ncol 0)
	origin)
    (set-marker delimit-columns-limit (point))
    (goto-char startpos)
    ;; skip initial columns
    (while (and (< ncol delimit-columns-start)
		(< (point) delimit-columns-limit)
		(re-search-forward delimit-columns-separator
				   delimit-columns-limit 'move))
      (setq ncol (1+ ncol)))
    ;; insert first formatting
    (insert delimit-columns-str-before delimit-columns-before)
    ;; Adjust all columns but last one
    (while (progn
	     (setq origin (current-column))
	     (and (< (point) delimit-columns-limit)
		  (re-search-forward delimit-columns-separator
				     delimit-columns-limit 'move)
		  (or (< ncol delimit-columns-end)
		      (progn
			(goto-char (match-beginning 0))
			nil))))
      (delete-region (match-beginning 0) (point))
      (delimit-columns-format
       (and delimit-columns-format
	    (make-string (- (aref delimit-columns-max ncol)
			    (- (current-column) origin))
			 ?\s)))
      (setq ncol (1+ ncol)))
    ;; Prepare last column spaces
    (let ((spaces (and delimit-columns-format
		       (make-string (- (aref delimit-columns-max ncol)
				       (- (current-column) origin))
				    ?\s))))
      ;; Adjust extra columns, if needed
      (and delimit-columns-extra
	   (while (and (< (setq ncol (1+ ncol)) len)
		       (<= ncol delimit-columns-end))
	     (delimit-columns-format spaces)
	     (setq spaces (and delimit-columns-format
			       (make-string (aref delimit-columns-max ncol)
					    ?\s)))))
      ;; insert last formatting
      (cond ((null delimit-columns-format)
	     (insert delimit-columns-after delimit-columns-str-after))
	    ((eq delimit-columns-format 'padding)
	     (insert spaces delimit-columns-after delimit-columns-str-after))
	    (t
             (insert delimit-columns-after spaces delimit-columns-str-after))))
    (goto-char (max (point) delimit-columns-limit))))


(defun delimit-columns-format (spaces)
  (cond ((null delimit-columns-format)
	 (insert delimit-columns-after
		 delimit-columns-str-separator
		 delimit-columns-before))
	((eq delimit-columns-format 'separator)
	 (insert delimit-columns-after
		 spaces
		 delimit-columns-str-separator
		 delimit-columns-before))
	((eq delimit-columns-format 'padding)
	 (insert spaces
		 delimit-columns-after
		 delimit-columns-str-separator
		 delimit-columns-before))
	(t
	 (insert delimit-columns-after
		 delimit-columns-str-separator
		 spaces
                 delimit-columns-before))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(provide 'delim-col)


;;; delim-col.el ends here
