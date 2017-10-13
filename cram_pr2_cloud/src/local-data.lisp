;;;
;;; Copyright (c) 2017, Gayane Kazhoyan <kazhoyan@cs.uni-bremen.de>
;;; All rights reserved.
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions are met:
;;;
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;     * Redistributions in binary form must reproduce the above copyright
;;;       notice, this list of conditions and the following disclaimer in the
;;;       documentation and/or other materials provided with the distribution.
;;;     * Neither the name of the Institute for Artificial Intelligence/
;;;       Universitaet Bremen nor the names of its contributors may be used to
;;;       endorse or promote products derived from this software without
;;;       specific prior written permission.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
;;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
;;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;; POSSIBILITY OF SUCH DAMAGE.

(in-package :pr2-cloud)

(defvar *local-handle-transform* nil)
(defvar *local-joint-transform* nil)

(defparameter *offset* 0.0d0)

(defun local-handle-transform ()
  (or *local-handle-transform*
      (multiple-value-bind (handle joint)
          (robust-local-handle-and-joint-transform)
        (setf *local-joint-transform* joint)
        (setf *local-handle-transform* (translate-transform-stamped
                                        handle :x-offset *offset*)))))

(defun local-joint-transform ()
  (or *local-joint-transform*
      (multiple-value-bind (handle joint)
          (robust-local-handle-and-joint-transform)
        (setf *local-handle-transform* (translate-transform-stamped
                                        handle :x-offset *offset*))
        (setf *local-joint-transform* joint))))

(defun robust-local-handle-and-joint-transform ()
  (calculate-robust-handle-and-joint-transform
   (kr-cloud:local-semantic-map-object-transform "IAIFridgeDoorHandle")
   (kr-cloud:local-semantic-map-object-transform "HingedJoint")))

;; direct robot pose

(defun local-robot-pose-in-map-from-joint (&optional (before-action "MoveFridgeHandle"))
  (let ((local-map-to-joint (local-joint-transform))
        (cloud-joint-to-robot (cloud-joint-to-robot-transform before-action)))
    (apply-transform local-map-to-joint cloud-joint-to-robot)))

(defun local-robot-pose-in-map-from-handle (&optional (before-action "MoveFridgeHandle"))
  (let ((local-map-to-handle (local-handle-transform))
        (cloud-handle-to-robot (cloud-handle-to-robot-transform before-action)))
    (apply-transform local-map-to-handle cloud-handle-to-robot)))

;; trajectory

(defun local-gripper-trajectory-in-map (&optional (action "MoveFridgeHandle"))
  (let ((local-map-to-handle (local-handle-transform))
        (cloud-handle-to-gripper-list (cloud-handle-to-gripper-transforms action)))
    (mapcar (lambda (cloud-handle-to-gripper)
              (apply-transform local-map-to-handle cloud-handle-to-gripper))
            cloud-handle-to-gripper-list)))

(defun gripper-trajectory-in-map->in-base (trajectory-in-map)
  (let ((local-map-to-gripper-list trajectory-in-map)
        (local-map-to-robot (current-robot-transform)))
    (visualize-trajectory (subseq (mapcar #'strip-transform-stamped local-map-to-gripper-list)
                                  26 42))
    (mapcar (lambda (local-map-to-gripper)
              (apply-transform (cram-tf:transform-stamped-inv local-map-to-robot)
                               local-map-to-gripper))
            local-map-to-gripper-list)))

(defun filter-trajectory-in-base (trajectory-in-base)
  (filter-trajectory-of-big-rotations
   (subseq trajectory-in-base 26 42)
   0.1))

(defun original-trajectory-in-base-filtered ()
  (filter-trajectory-in-base
   (gripper-trajectory-in-map->in-base
    (local-gripper-trajectory-in-map))))

;; projected trajectory

(defun local-gripper-projected-trajectory-in-map (&optional (action "MoveFridgeHandle"))
  (let ((local-map-to-joint (local-joint-transform))
        (cloud-joint-to-gripper-list (cloud-joint-to-gripper-transforms action)))
    (mapcar (lambda (cloud-joint-to-gripper)
              (translate-transform-stamped
               (apply-transform local-map-to-joint cloud-joint-to-gripper)
               :z-offset 0.1))
            cloud-joint-to-gripper-list)))

(defun local-gripper-projected-trajectory-in-base (&optional (action "MoveFridgeHandle"))
  (let ((local-map-to-gripper-list (local-gripper-projected-trajectory-in-map action))
        (local-map-to-robot (current-robot-transform)))
    (visualize-trajectory (subseq (mapcar (lambda (trans)
                                            (strip-transform-stamped
                                             (translate-transform-stamped trans :z-offset 0.1)))
                                          local-map-to-gripper-list)
                                  26 42))
    (mapcar (lambda (local-map-to-gripper)
              (apply-transform (cram-tf:transform-stamped-inv local-map-to-robot)
                               local-map-to-gripper))
            local-map-to-gripper-list)))

(defun local-gripper-projected-trajectory-in-base-filtered (&optional (action "MoveFridgeHandle"))
  (filter-trajectory-in-base
   (local-gripper-projected-trajectory-in-base)))

;; distribution

(defun local-handle-to-robot-transform-distribution ()
  (let ((local-map-to-handle (local-handle-transform)))
    (multiple-value-bind (cloud-handle-to-robot-transform-mean covariance)
        (cloud-handle-to-robot-transform-distribution)
      (list (apply-transform local-map-to-handle cloud-handle-to-robot-transform-mean)
            (apply-transform-to-covariance-matrix local-map-to-handle covariance)))))
