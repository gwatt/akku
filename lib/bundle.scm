;; -*- mode: scheme; coding: utf-8 -*-
;; Copyright © 2017-2018 Göran Weinholt <goran@weinholt.se>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
#!r6rs

;; All forms of distributable bundles and analysis go through here.

(library (akku lib bundle)
  (export
    dependency-scan
    license-scan)
  (import
    (rnrs (6))
    (only (srfi :1 lists) append-map filter-map delete-duplicates)
    (srfi :115 regexp)
    (industria strings)
    (xitomatl AS-match)
    (akku lib file-parser)
    (only (akku lib install) make-r6rs-library-filenames libraries-directory
          file-list-filename)
    (akku lib repo-scanner)
    (akku lib schemedb)
    (only (akku lib utils) print path-join))

;; Trace the dependencies of `files`, returning a subset of
;; filename->artifact.
(define (trace-dependencies filenames files lib-dir implementations
                            filename->artifact r6rs-lib-name->artifact*
                            only-first?)
  (define used-files (make-hashtable string-hash string=?))
  (define (trace filename file)
    (unless (or (hashtable-ref filename->artifact filename #f)
                (member filename filenames))
      (error 'trace-dependencies "Accidentally added a non-artifact" filename))
    (unless (hashtable-ref used-files filename #f)
      (hashtable-set! used-files filename file)
      ;; Add included files.
      (for-each
       (lambda (asset)
         ;; XXX: Is the artifact really needed?
         (hashtable-set! used-files
                         (include-reference-realpath asset)
                         (hashtable-ref filename->artifact
                                        (include-reference-realpath asset)
                                        #f)))
       (artifact-assets file))
      ;; Add imported files.
      (for-each
       (lambda (import)
         (let* ((lib-name (library-reference-name import))
                (candidate-filenames
                 (map (match-lambda
                       ((dir . fn) (path-join lib-dir (path-join dir fn))))
                      (append-map (lambda (impl)
                                    (make-r6rs-library-filenames lib-name impl))
                                  (append implementations '(#f))))))
           ;; FIXME: if only-first?, then stop on the first hit.
           ;; Otherwise keep going.
           (unless (find (lambda (fn)
                           (cond ((hashtable-ref filename->artifact fn #f)
                                  => (lambda (library-artifact)
                                       ;; lib-name was mapped to an artifact.
                                       (trace fn library-artifact)))
                                 (else #f)))
                         candidate-filenames)
             (unless (r6rs-builtin-library? lib-name (artifact-implementation file))
               (print ";; WARNING: can not import " lib-name)))))
       (artifact-imports file))))
  (for-each trace filenames files)
  used-files)

;; Scan the directory for all artifacts (libraries, included files)
;; and create hashtables for them.
(define (scan-installed-artifacts dir)
  (define filename->artifact (make-hashtable string-hash string=?))
  (define r6rs-lib-name->artifact* (make-hashtable equal-hash equal?)) ;XXX: not needed?
  (for-each
   (lambda (artifact)
     (hashtable-set! filename->artifact
                     (path-join dir (artifact-path artifact))
                     artifact)
     (when (r6rs-library? artifact)
       (hashtable-update! r6rs-lib-name->artifact* (r6rs-library-name artifact)
                          (lambda (acc) (cons artifact acc))
                          '())))
   (find-artifacts dir #f))
  (values filename->artifact r6rs-lib-name->artifact*))

;; Get a list of filenames for all source needed to compile the files.
(define (find-used-source filenames implementations only-first?)
  (assert (for-all file-exists? filenames))
  (let ((files-to-scan (append-map (lambda (filename)
                                     (examine-source-file filename filename '()))
                                   filenames)))
    (let-values (((filename->artifact r6rs-lib-name->artifact*)
                  (scan-installed-artifacts (libraries-directory))))
      (trace-dependencies filenames files-to-scan (libraries-directory)
                          implementations filename->artifact
                          r6rs-lib-name->artifact* only-first?))))

;; Each file's dependencies is traced by searching through the
;; libraries directory.
(define (dependency-scan filenames implementations)
  (for-each (lambda (x)
              (display x)
              (newline))
            (list-sort string<?
                       (vector->list
                        (hashtable-keys
                         (find-used-source filenames implementations #f))))))

(define (latin-1-filter str)
  ;; Filter out non-ascii characters since the srif-14 implementation
  ;; in chez-srfi (in turned used by srfi-115) does not handle unicode.
  (call-with-string-output-port
    (lambda (p)
      (string-for-each (lambda (c)
                         (unless (fx>? (char->integer c) #x7f)
                           (put-char p c)))
                       str))))

;; Gather dependencies (as above) and notices and summarize them. It
;; would be great if this printed SPDX documents.
(define (license-scan filenames implementations)
  (define rx-copyright-start
    (rx (w/nocase bow (or "copyright" "(c)" "©" "public domain")
                  eow)))
  (define rx-code-start
    (rx (* space)
        (or "(" "#!"
            ";;; Commentary:"
            ";;; Code:"
            ";;; Exported:"
            ";;; Exports:"
            ";; --"
            "; --"
            ";;@"
            "\f")
        (* any)))
  (define rx-code-line
    (rx (* space) (or "(" "\"") (* any) (or ")" "\"") (* any)))
  (let ((used-source-files (find-used-source filenames implementations 'only-first))
        (filename->project-name (make-hashtable string-hash string=?))
        (project->file* (make-hashtable string-hash string=?)))
    ;; Read the file list.
    (call-with-input-file (file-list-filename)
      (lambda (p)
        (let lp ()
          (unless (port-eof? p)
            (match (string-split (get-line p) #\tab)
              [(filename project-name type . _)
               (hashtable-set! filename->project-name filename project-name)
               (hashtable-update! project->file* project-name
                                  (lambda (acc) (cons (cons filename type) acc))
                                  '())
               (lp)])))))
    ;; Find the projects where files were used.
    (let ((used-project*
           (delete-duplicates
            (vector->list
             (vector-map (lambda (fn)
                           (cond
                             ((member fn filenames) "-")
                             ((hashtable-ref filename->project-name fn #f))
                             (else
                              (error 'license-scan "Could not find file's project name" fn))))
                         (hashtable-keys used-source-files))))))
      (display "Notices automatically gathered by Akku.scm for these files:\n")
      (for-each (lambda (fn) (display " ") (display fn) (newline)) filenames)
      (display "Some files might not have been used in the final binary.\n")
      (for-each
       (lambda (project-name)
         (display (make-string 76 #\=))
         (newline)
         (display "Project: ")
         (display project-name)
         (newline)
         (for-each
          (match-lambda
           [(fn . type)
            (define printed-header #f)
            (define (print-header)
              (unless printed-header
                (set! printed-header #t)
                (newline)
                (display fn)
                (newline)
                (display "--8<---------------cut here---------------start------------->8---\n")))
            (define (print-footer)
              (when printed-header
                (display "--8<---------------cut here---------------end--------------->8---\n")))
            (cond
              ((equal? type "legal-notice-file")
               (print-header)
               (call-with-input-file fn
                 (lambda (p)
                   (display (get-string-all p))))
               (print-footer))
              ((hashtable-ref used-source-files fn #f)
               (call-with-input-file fn
                 (lambda (p)
                   ;; This is weak, but working for everything used by
                   ;; Akku.scm itself. Sometimes more than is needed
                   ;; is copied over.
                   (let lp ()
                     (unless (port-eof? p)
                       (let lp-restart ((line0 (get-line p)))
                         (when (let ((l (latin-1-filter line0)))
                                 (and (regexp-search rx-copyright-start l)
                                      (not (regexp-matches rx-code-line l))))
                           (print-header)
                           (display line0)
                           (newline)
                           (let lp-copy ()
                             (let ((line (get-line p)))
                               (cond ((eof-object? line)
                                      (lp))
                                     ((regexp-matches rx-code-start (latin-1-filter line))
                                      (lp-restart line)) ;end of comment
                                     (else
                                      (display line)
                                      (newline)
                                      (lp-copy)))))))
                       (lp)))
                   (print-footer)))
               (unless printed-header
                 (print ";; INFO: No copyright notice in used file " fn))))])
          (list-sort (lambda (x y) (string<? (car x) (car y)))
                     (hashtable-ref project->file* project-name '()))))
       (list-sort string<? used-project*))
      (newline)
      (display (make-string 76 #\=))
      (newline)))))