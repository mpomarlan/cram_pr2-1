;;;
;;; Copyright (c) 2011, Lorenz Moesenlechner <moesenle@in.tum.de>
;;;               2017, Gayane Kazhoyan <kazhoyan@cs.uni-bremen.de>
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
;;;     * Neither the name of the Intelligent Autonomous Systems Group/
;;;       Technische Universitaet Muenchen nor the names of its contributors 
;;;       may be used to endorse or promote products derived from this software 
;;;       without specific prior written permission.
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

(in-package :pr2-proj)

;;;;;;;;;;;;;;;;; NAVIGATION ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun drive (target)
  (declare (type cl-transforms-stamped:pose-stamped target))
  (assert
   (prolog:prolog
    `(and (cram-robot-interfaces:robot ?robot)
          (btr:bullet-world ?w)
          (btr:assert ?w (btr:object-pose ?robot ,target)))))
  (cram-occasions-events:on-event
   (make-instance 'cram-plan-occasions-events:robot-state-changed)))

;;;;;;;;;;;;;;;;; TORSO ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun move-torso (joint-angle)
  (declare (type number joint-angle))
  (assert
   (prolog:prolog
    `(and (cram-robot-interfaces:robot ?robot)
          (btr:bullet-world ?w)
          (cram-robot-interfaces:robot-torso-link-joint ?robot ?_ ?joint)
          (btr:assert (btr:joint-state ?w ?robot ((?joint ,joint-angle)))))))
  (cram-occasions-events:on-event
   (make-instance 'cram-plan-occasions-events:robot-state-changed)))

;;;;;;;;;;;;;;;;; PTU ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun look-at-pose-stamped (pose-stamped)
  (declare (type cl-transforms-stamped:pose-stamped pose-stamped))
  (let ((pose-in-world (cram-tf:ensure-pose-in-frame pose-stamped cram-tf:*fixed-frame*)))
    (assert
     (prolog:prolog
      `(and (btr:bullet-world ?world)
            (cram-robot-interfaces:robot ?robot)
            (btr:head-pointing-at ?world ?robot ,pose-in-world))))
    (cram-occasions-events:on-event
     (make-instance 'cram-plan-occasions-events:robot-state-changed))))

(defgeneric look-at (pose-or-frame-or-direction)
  (:method ((pose cl-transforms-stamped:pose-stamped))
    (look-at-pose-stamped pose))
  (:method ((frame string))
    (look-at-pose-stamped
     (cl-transforms-stamped:make-pose-stamped
      frame
      0.0
      (cl-transforms:make-identity-vector)
      (cl-transforms:make-identity-rotation))))
  (:method ((direction symbol))
    (look-at-pose-stamped
     (case direction
       (:forward (cl-transforms-stamped:make-pose-stamped
                  cram-tf:*robot-base-frame*
                  0.0
                  (cl-transforms:make-3d-vector 3.0 0.0 1.5)
                  (cl-transforms:make-quaternion 0.0 0.0 0.0 1.0)))
       (t (error 'simple-error
                 :format-control "~a direction is unknown for PR2 projection PTU"
                 :format-arguments direction))))))

;;;;;;;;;;;;;;;;; PERCEPTION ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun extend-perceived-object-designator (input-designator name-pose-type-list)
  (destructuring-bind (name pose type) name-pose-type-list
    (let* ((pose-stamped (cram-tf:ensure-pose-in-frame pose cram-tf:*fixed-frame*))
           (transform-stamped (cram-tf:pose->transform-stamped
                               cram-tf:*fixed-frame*
                               name
                               (cl-transforms-stamped:stamp pose-stamped)
                               pose-stamped)))
      (let ((output-designator
              (desig:copy-designator
               input-designator
               :new-description
               `((:type ,type)
                 (:pose ((:pose ,pose-stamped)
                         (:transform ,transform-stamped)))
                 (:name ,name)))))
        (setf (slot-value output-designator 'desig:data)
              (make-instance 'desig:object-designator-data
                :object-identifier name
                :pose pose-stamped))
        (desig:equate input-designator output-designator)))))

(defun detect (input-designator)
  (declare (type desig:object-designator input-designator))

  (let* ((object-name (desig:desig-prop-value input-designator :name))
         (object-type (desig:desig-prop-value input-designator :type))
         (quantifier (desig:quantifier input-designator))

         ;; find all visible objects with name `object-name' and of type `object-type'
         (name-pose-type-lists ; e.g.: ((mondamin-1 :mondamin <pose-1>) (mug-2 :mug <pose-2>))
           (cut:force-ll
            (cut:lazy-mapcar
             (lambda (solution-bindings)
               (cut:with-vars-strictly-bound (?object-name ?object-pose ?object-type)
                   solution-bindings
                 (list ?object-name ?object-pose ?object-type)))
             (prolog:prolog `(and (cram-robot-interfaces:robot ?robot)
                                  (btr:bullet-world ?world)
                                  ,@(when object-name
                                      `((prolog:== ?object-name ,object-name)))
                                  (btr:object ?world ?object-name)
                                  ,@(when object-type
                                      `((prolog:== ?object-type ,object-type)))
                                  (btr:item-type ?world ?object-name ?object-type)
                                  (btr:visible ?world ?robot ?object-name)
                                  (btr:pose ?world ?object-name ?object-pose)))))))

    ;; check if objects were found
    (unless name-pose-type-lists
      (cpl:fail 'common-fail:perception-object-not-found :object input-designator
                :description (format nil "Could not find object ~a." input-designator)))

    ;; Extend the input-designator with the information found through visibility check:
    ;; name & pose & type of the object,
    ;; equate the input-designator to the new output-designator.
    ;; If multiple objects are visible, return multiple equated objects,
    ;; otherwise only take first found object. I.e. need to find :an object (not :all objects)
    (case quantifier
      (:all (mapcar (alexandria:curry #'extend-perceived-object-designator input-designator)
                    name-pose-type-lists))
      ((:a :an) (extend-perceived-object-designator
                 input-designator
                 (first name-pose-type-lists)))
      (t (error "[PROJECTION DETECT]: Quantifier can only be a/an or all.")))))

;;;;;;;;;;;;;;;;; GRIPPERS ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun gripper-action (action-type arm &optional maximum-effort)
  (declare (ignore maximum-effort))
  "Opens or closes the specific gripper."
  (mapc

   (lambda (solution-bindings)
     (prolog:prolog
      `(and
        (btr:bullet-world ?world)
        (assert ?world (btr:joint-state ?robot ((?joint ,(case action-type
                                                           (:open '?max-limit)
                                                           ((:close :grip) '?min-limit)
                                                           (t (if (numberp action-type)
                                                                  action-type
                                                                  (error "[PROJ GRIP] failed")))))))))
      solution-bindings))

   (cut:force-ll
    (prolog:prolog
     `(and (cram-robot-interfaces:robot ?robot)
           (cram-robot-interfaces:gripper-joint ?robot ,arm ?joint)
           (cram-robot-interfaces:joint-lower-limit ?robot ?joint ?min-limit)
           (cram-robot-interfaces:joint-upper-limit ?robot ?joint ?max-limit)))))

  ;; robot-state-changed event
  (cram-occasions-events:on-event
   (make-instance 'cram-plan-occasions-events:robot-state-changed))

  ;; object-attached event
  (when (eql action-type :grip) ; if action was gripping check if gripper collided with an item
    (mapc ; for all items colliding with gripper of `arm' emit the event

     (lambda (solution-bindings)
       (cut:with-vars-bound (?object-name ?ee-link)
           solution-bindings
         (if (cut:is-var ?object-name)
             (cpl:fail 'common-fail:gripping-failed :description "There was no object to grip")
             (if (cut:is-var ?ee-link)
                 (error "[GRIPPER LOW-LEVEL] Couldn't find robot's EE link.")
                 (cram-occasions-events:on-event
                  (make-instance 'cpoe:object-attached
                    :object-name ?object-name :link ?ee-link :arm arm))))))

     (cut:force-ll
      (prolog:prolog
       `(and (btr:bullet-world ?world)
             (cram-robot-interfaces:robot ?robot)
             (prolog:setof
              ?on
              (and (btr:contact ?world ?robot ?on ?link)
                   (cram-robot-interfaces:gripper-link ?robot ,arm ?link))
              ?object-names)
             (member ?object-name ?object-names)
             (btr:%object ?world ?object-name ?object-instance)
             (prolog:lisp-type ?object-instance btr:item)
             (cram-robot-interfaces:end-effector-link ?robot ,arm ?ee-link))))))

  ;; object-detached event
  (when (eql action-type :open) ; if action is opening, check if there was an object in gripper
    (let ((link (cut:var-value
                 '?ee-link
                 (car (prolog:prolog
                       `(and (cram-robot-interfaces:robot ?robot)
                             (cram-robot-interfaces:end-effector-link ?robot ,arm ?ee-link)))))))
      (when (cut:is-var link) (error "[GRIPPER LOW-LEVEL] Couldn't find robot's EE link."))
      (mapc (lambda (attachment-data)
              (mapc (lambda (attachment)
                      (when (string-equal (btr::attachment-link attachment) link)
                        (cram-occasions-events:on-event
                         (make-instance 'cpoe:object-detached
                           :object-name (btr::attachment-object attachment)
                           :link link
                           :arm arm))))
                    (second attachment-data)))
            (btr:attached-objects (btr:get-robot-object))))))

;;;;;;;;;;;;;;;;; ARMS ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun move-joints (left-configuration right-configuration)
  (declare (type list left-configuration right-configuration))
  (flet ((set-configuration (arm joint-values)
           (when joint-values
             (let ((joint-names
                     (cut:var-value
                      '?joints
                      (car (prolog:prolog
                            `(and (cram-robot-interfaces:robot ?robot)
                                  (cram-robot-interfaces:arm-joints ?robot ,arm ?joints)))))))
               (unless (= (length joint-values) (length joint-names))
                 (error "[PROJECTION MOVE-JOINTS] length of joints list is incorrect."))
               (let ((joint-name-value-list (mapcar (lambda (name value)
                                                      (list name (* value 1.0d0)))
                                                    joint-names joint-values)))
                 (assert
                  (prolog:prolog
                   `(and
                     (btr:bullet-world ?world)
                     (cram-robot-interfaces:robot ?robot)
                     (assert ?world (btr:joint-state ?robot ,joint-name-value-list))))))))))
    (set-configuration :left left-configuration)
    (set-configuration :right right-configuration)
    (cram-occasions-events:on-event
     (make-instance 'cram-plan-occasions-events:robot-state-changed))))

(defparameter *gripper-length* 0.2 "PR2's gripper length in meters, for calculating TCP -> EE")

(defun move-tcp (left-tcp-pose right-tcp-pose)
  (declare (type (or cl-transforms-stamped:pose-stamped null) left-tcp-pose right-tcp-pose))
  (flet ((tcp-pose->ee-pose (tcp-pose)
           (when tcp-pose
             (cl-transforms-stamped:pose->pose-stamped
              (cl-transforms-stamped:frame-id tcp-pose)
              (cl-transforms-stamped:stamp tcp-pose)
              (cl-transforms:transform-pose
               (cl-transforms:pose->transform tcp-pose)
               (cl-transforms:make-pose
                (cl-transforms:make-3d-vector (- *gripper-length*) 0 0)
                (cl-transforms:make-identity-rotation))))))
         (get-ik-joint-positions (arm ee-pose)
           (when ee-pose
             (let ((ik-solution-msg (call-ik-service arm ee-pose ; seed-state ; is todo
                                                     )))
               (unless ik-solution-msg
                 (cpl:fail 'common-fail:manipulation-pose-unreachable
                           :description (format nil "~a is unreachable for EE." ee-pose)))
               (map 'list #'identity
                    (roslisp:msg-slot-value ik-solution-msg 'sensor_msgs-msg:position))))))
    (move-joints (get-ik-joint-positions :left (tcp-pose->ee-pose left-tcp-pose))
                 (get-ik-joint-positions :right (tcp-pose->ee-pose right-tcp-pose)))))

(defun move-with-constraints (constraints-string)
  (declare (ignore constraints-string))
  (warn "Moving with constraints is not supported in projection! Ignoring."))




