;;; Copyright (c) 2012, Lorenz Moesenlechner <moesenle@in.tum.de>
;;;                     Gayane Kazhoyan <kazhoyan@cs.uni-bremen.de>
;;;                     Christopher Pollok <cpollok@cs.uni-bremen.de>
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

(in-package :cram-bullet-reasoning-belief-state)

(defun update-object-designator-location (object-designator location-designator)
  (desig:make-designator
   :object
   `((:location ,location-designator)
     ,@(remove :location (desig:properties object-designator) :key #'car))
   object-designator))

(defun remove-object-designator-location (object-designator)
  (desig:make-designator
   :object
   (remove :location (desig:properties object-designator) :key #'car)
   object-designator))

(defun invalidate-object-designator-pose (object-designator)
  "Removes the LOCATION key of the designator and renames POSE into OLD-POSE."
  (let* ((properties (desig:properties object-designator))
         (pose-pair (find :pose properties :key #'car)))
    (desig:make-designator
     :object
     (append (remove pose-pair
                     (remove :location
                             (remove :old-pose properties :key #'car)
                             :key #'car))
             `((:old-pose ,@(rest pose-pair))))
     object-designator)))



(defmethod cram-occasions-events:on-event object-perceived 2 ((event cpoe:object-perceived-event))
  (if cram-projection:*projection-environment*
      ;; if in projection, only add the object name to perceived designators list
      (let ((object-data (desig:reference (cpoe:event-object-designator event))))
        (or
         (gethash (desig:object-identifier object-data)
                  *object-identifier-to-instance-mappings*)
         (setf (gethash (desig:object-identifier object-data)
                        *object-identifier-to-instance-mappings*)
               (desig:object-identifier object-data))))
      ;; otherwise, spawn a new object in the bullet world
      (progn
        (register-object-designator-data
         (desig:reference (cpoe:event-object-designator event))
         :type (desig:desig-prop-value (cpoe:event-object-designator event) :type))
        ;; after having spawned the object, update the designator to get the
        ;; new simulated pose
        (desig:equate
         (cpoe:event-object-designator event)
         (detect-new-object-pose-from-btr (cpoe:event-object-designator event))))))



(defmethod cram-occasions-events:on-event btr-belief ((event cpoe:object-location-changed))
  ;; update the designator to get the new location
  (update-object-designator-location
   (cpoe:event-object-designator event)
   (cpoe:event-location-designator event)))



(defmethod cram-occasions-events:on-event robot-moved ((event cpoe:robot-state-changed))
  (unless cram-projection:*projection-environment*
    (let ((robot (btr:get-robot-object)))
      (when robot
        (btr:set-robot-state-from-tf
         cram-tf:*transformer*
         robot
         :timestamp (cram-occasions-events:event-timestamp event)))))
  (btr:timeline-advance
   btr:*current-timeline*
   (btr:make-event
    btr:*current-bullet-world*
    `(location-change robot))))



(defmethod cram-occasions-events:on-event btr-attach-object 2 ((event cpoe:object-attached-robot))
  "2 means this method has to be ordered based on integer qualifiers.
It could have been 1 but 1 is reserved in case somebody has to be even more urgently
executed before everyone else.
If there is no other method with 1 as qualifier, this method will be executed always first."
  (let* ((robot-object-name (cpoe:event-other-object-name event))
         (robot-object (btr:object btr:*current-bullet-world*
                                   (or robot-object-name (btr:get-robot-name))))
         (environment-object (btr:get-environment-object))
         (btr-object-name (cpoe:event-object-name event))
         (btr-object (btr:object btr:*current-bullet-world* btr-object-name))
         (arm (cpoe:event-arm event))
         (link (if arm
                   (cut:var-value
                    '?ee-link
                    (car (prolog:prolog
                          `(and (rob-int:robot ?robot)
                                (rob-int:end-effector-link ?robot ,arm ?ee-link)))))
                   (if (cpoe:event-link event)
                       (cpoe:event-link event)
                       (error "[BTR-BELIEF OBJECT-ATTACHED] either link or arm ~
                               in object-attached-robot event had to be given..."))))
         (grasp (cpoe:event-grasp event))
         (object-designator (cpoe:event-object-designator event)))
    (when (cut:is-var link)
      (error "[BTR-BELIEF OBJECT-ATTACHED] Couldn't find robot's EE link."))
    ;; first detach from environment in case it is attached
    (when (and (typep environment-object 'btr:robot-object)
               (btr:object-attached environment-object btr-object))
      (btr:detach-object environment-object btr-object))
    ;; also detach the object from other items in case they are attached,
    ;; but only detach the loose attachments, because those are the attachments
    ;; with the supporting objects. do not destroy the normal attachments,
    ;; as those are attachments to the supported objects and we want the
    ;; supported objects to still stay with our grasped object
    (mapcar (lambda (other-object-name)
              (btr:detach-object
               btr-object (btr:object btr:*current-bullet-world* other-object-name)))
            (btr:get-loose-attached-objects btr-object))
    ;; now attach to the robot-object
    (when btr-object
      ;; if the object is already attached to some other robot link
      ;; make the old attachment loose,
      ;; because the new attachment will take precedence now
      (multiple-value-bind (links grasps)
          (btr:object-attached robot-object btr-object)
        (when links
          (mapc (lambda (attached-link grasp)
                  ;; detach and attach again with loose attachment
                  (btr:detach-object robot-object btr-object :link attached-link)
                  (btr:attach-object robot-object btr-object :link attached-link
                                                             :loose t
                                                             :grasp grasp))
                links grasps)))
      ;; attach
      (btr:attach-object robot-object btr-object :link link :loose nil :grasp grasp)
      ;; invalidate the pose in the designator
      (when object-designator
        (invalidate-object-designator-pose object-designator)))))

(defmethod cram-occasions-events:on-event btr-detach-object 2 ((event cpoe:object-detached-robot))
  (let* ((robot-object (btr:get-robot-object))
         (environment-object (btr:get-environment-object))
         (btr-object-name (cpoe:event-object-name event))
         (arm (cpoe:event-arm event))
         (link (if arm
                   (cut:var-value
                    '?ee-link
                    (car (prolog:prolog
                          `(and (cram-robot-interfaces:robot ?robot)
                                (cram-robot-interfaces:end-effector-link ?robot ,arm
                                                                         ?ee-link)))))
                   (if (cpoe:event-link event)
                       (cpoe:event-link event)
                       (error "[BTR-BELIEF OBJECT-DETACHED] either link or arm ~
                               in object-attached-robot even had to be given...")))))
    (when (cut:is-var link) (error "[BTR-BELIEF OBJECT-DETACHED] Couldn't find robot's EE link."))
    (if btr-object-name
        ;; if btr-object-name was given, detach it from the robot link
        (let ((btr-object (btr:object btr:*current-bullet-world* btr-object-name)))
          (when btr-object
            (btr:detach-object robot-object btr-object :link link)
            (btr:simulate btr:*current-bullet-world* 10)
            ;; find the links and items that support the object
            ;; and attach the object to them.
            ;; links get proper attachments and items loose attachments
            (let ((contacting-links
                    (remove-duplicates
                     (mapcar
                      #'cdr
                      (remove-if-not
                       ;; filter all the links contacting items to our specific item
                       (lambda (item-and-link-name-cons)
                         (equal
                          (btr:name (car item-and-link-name-cons))
                          btr-object-name))
                       ;; get all links contacting items in the environment
                       (btr:link-contacts environment-object)))
                     :test #'equal))
                  (contacting-items
                    (remove-if-not
                     (lambda (c) (typep c 'btr:item))
                     (btr:find-objects-in-contact btr:*current-bullet-world* btr-object))))
              ;; If a link contacting btr-object was found, btr-object
              ;; will be attached to it
              ;; also, if btr-object is in contact with an item,
              ;; it will be attached loose.
              (mapcar (lambda (link-name)
                        (btr:attach-object environment-object btr-object :link link-name))
                      contacting-links)
              (mapcar (lambda (item-object)
                        (when item-object
                          (btr:attach-object item-object btr-object :loose T)))
                      contacting-items))))
        ;; if btr-object-name was not given, detach all objects from the robot link
        (progn
          (btr:detach-all-from-link robot-object link)
          (btr:simulate btr:*current-bullet-world* 10)))))

(defmethod cram-occasions-events:on-event btr-attach-two-objs ((event cpoe:object-attached-object))
  (let* ((btr-object-name (cpoe:event-object-name event))
         (btr-object (btr:object btr:*current-bullet-world* btr-object-name))
         (btr-other-object-name (cpoe:event-other-object-name event))
         (btr-other-object (btr:object btr:*current-bullet-world* btr-other-object-name))
         (attachment-type (cpoe:event-attachment-type event)))
    (when (and btr-object btr-other-object attachment-type)
      (let* ((btr-object-type
               (car (slot-value btr-object 'btr::types)))
             (btr-other-object-type
               (car (slot-value btr-other-object 'btr::types)))
             (other-object-to-object-transform ; ooTo
               (man-int:get-object-type-in-other-object-transform
                btr-object-type btr-object-name
                btr-other-object-type btr-other-object-name
                attachment-type))
             (ros-other-object-name
               (roslisp-utilities:rosify-underscores-lisp-name
                btr-other-object-name))
             (map-to-other-object-transform
               (cram-tf:pose->transform-stamped
                cram-tf:*fixed-frame*
                ros-other-object-name
                0.0
                (btr:pose btr-other-object)))
             (ros-object-name
               (roslisp-utilities:rosify-underscores-lisp-name btr-object-name))
             (map-to-object-transform
               (cram-tf:multiply-transform-stampeds
                cram-tf:*fixed-frame*
                ros-object-name
                map-to-other-object-transform
                other-object-to-object-transform))
             (object-in-map-pose
               (cram-tf:strip-transform-stamped
                map-to-object-transform)))
        (setf (btr:pose btr-object) object-in-map-pose))
      (if (prolog `(man-int:unidirectional-attachment ,attachment-type))
          (btr:attach-object btr-other-object btr-object :loose T)
          (btr:attach-object btr-other-object btr-object)))))



(defun move-joint-by-event (event open-or-close)
  (let* ((joint-name (cpoe:environment-event-joint-name event))
         (object (cpoe:environment-event-object event))
         (distance (cpoe:environment-event-distance event))
         (current-opening (gethash joint-name (btr:joint-states object)))
         (new-joint-angle
           (funcall
            (case open-or-close
              (:open #'+)
              (:close #'-))
            current-opening
            distance))
         ;; sometimes there is a tiny floating point inaccuracy,
         ;; which can cause out of joint limits exception, so we round the number.
         (new-joint-angle-rounded
           (/ (funcall
               (case open-or-close
                 (:open #'ffloor)
                 (:close #'fceiling))
               new-joint-angle
               0.0001)
              10000)))
    (btr:set-robot-state-from-joints
     `((,joint-name
        ,new-joint-angle-rounded))
     object)))

(defmethod cram-occasions-events:on-event open-container ((event cpoe:container-opening-event))
  (move-joint-by-event event :open)
  (unless cram-projection:*projection-environment*
    (publish-environment-joint-state (btr:joint-states (cpoe:environment-event-object event)))))

(defmethod cram-occasions-events:on-event close-container ((event cpoe:container-closing-event))
  (move-joint-by-event event :close)
  (unless cram-projection:*projection-environment*
    (publish-environment-joint-state (btr:joint-states (cpoe:environment-event-object event)))))



#+old-Lorenzs-stuff-currently-not-used-but-maybe-in-the-future
(
 ;; Utility functions
 (defun get-supporting-object-bounding-box (object-name)
   (cut:with-vars-bound (?supporting-name ?supporting-link)
       (cut:lazy-car (prolog
                      `(or (btr:supported-by ?_ ,object-name ?supporting-name ?supporting-link)
                           (btr:supported-by ?_ ,object-name ?supporting-name))))
     (unless (cut:is-var ?supporting-name)
       (if (cut:is-var ?supporting-link)
           (btr:aabb (btr:object btr:*current-bullet-world* ?supporting-name))
           (btr:aabb (gethash
                      ?supporting-link
                      (btr:links (btr:object btr:*current-bullet-world* ?supporting-name))))))))

 (defun make-object-location (object-name)
   (let ((object (btr:object btr:*current-bullet-world* object-name)))
     (assert object)
     (desig:make-designator
      :location
      `((:pose ,(cl-transforms-stamped:pose->pose-stamped
                 cram-tf:*fixed-frame*
                 (cut:current-timestamp)
                 (cl-bullet:pose object)))))))

 (defun make-object-location-in-gripper (object gripper-link)
   "Returns a new location designator that indicates a location in the
  robot's gripper."
   (declare (type btr:object object))
   (let* ((object-pose (cl-transforms-stamped:pose->pose-stamped
                        cram-tf:*fixed-frame*
                        0.0
                        (btr:pose object)))
          (robot (btr:get-robot-object)))
     (assert (member gripper-link (btr:object-attached robot object) :test #'equal))
     (let ((supporting-bounding-box (get-supporting-object-bounding-box (btr:name object))))
       (desig:make-designator
        :location
        `((:in :gripper) (:pose ,(object-pose-in-frame object gripper-link))
          (:z-offset ,(cond (supporting-bounding-box
                             (- (cl-transforms:z (cl-transforms:origin object-pose))
                                (+ (cl-transforms:z
                                    (cl-bullet:bounding-box-center supporting-bounding-box))
                                   (/ (cl-transforms:z
                                       (cl-bullet:bounding-box-dimensions
                                        supporting-bounding-box))
                                      2))))
                            (t 0.0))))))))

 (defun object-pose-in-frame (object frame)
   (declare (type btr:object object)
            (type string frame))
   (cl-transforms-stamped:copy-pose-stamped
    (cl-transforms-stamped:transform-pose-stamped
     cram-tf:*transformer*
     :pose (cl-transforms-stamped:pose->pose-stamped
            cram-tf:*fixed-frame*
            0.0
            (btr:pose object))
     :target-frame frame
     :timeout cram-tf:*tf-default-timeout*)
    :stamp 0.0))



 ;; Additionally changing the object designator of the object
 (defmethod cram-occasions-events:on-event attach-objects ((event cpoe:object-attached))
   (let* ((robot (btr:get-robot-object))
          (current-event-object (desig:current-desig (cpoe:event-object event)))
          (object (get-designator-object current-event-object)))
     (when object
       (cond ((btr:object-attached robot object)
              ;; If the object is already attached, it is already in
              ;; the gripper. In that case, we update the designator
              ;; location designator by extending the current location
              ;; by a second pose in the gripper.
              (btr:attach-object robot object :link (cpoe:event-link event) :loose t)
              (desig:with-desig-props (at) current-event-object
                (assert (eql (desig:desig-prop-value at :in) :gripper))
                (update-object-designator-location
                 current-event-object
                 (desig:extend-designator-properties
                  at `((:pose ,(object-pose-in-frame object (cpoe:event-link event))))))))
             (t
              (btr:attach-object robot object :link (cpoe:event-link event) :loose nil)
              (update-object-designator-location
               current-event-object
               (desig:extend-designator-properties
                (make-object-location-in-gripper object (cpoe:event-link event))
                `((:pose ,(object-pose-in-frame object cram-tf:*robot-base-frame*))))))))
     (btr:timeline-advance
      btr:*current-timeline*
      (btr:make-event
       btr:*current-bullet-world*
       `(pick-up ,(cpoe:event-object event) ,(cpoe:event-side event))))))
 (defmethod cram-occasions-events:on-event detach-objects ((event cpoe:object-detached-robot))
   (let ((robot (btr:get-robot-object))
         (object (get-designator-object (cpoe:event-object event))))
     (when object
       (btr:detach-object robot object :link (cpoe:event-link event))
       (btr:simulate btr:*current-bullet-world* 10)
       (update-object-designator-location
        (desig:current-desig (cpoe:event-object event))
        (make-object-location (get-designator-object-name (cpoe:event-object event)))))
     (btr:timeline-advance
      btr:*current-timeline*
      (btr:make-event
       btr:*current-bullet-world*
       `(put-down ,(cpoe:event-object event) ,(cpoe:event-side event))))
     (btr:timeline-advance
      btr:*current-timeline*
      (btr:make-event
       btr:*current-bullet-world*
       `(location-change ,(cpoe:event-object event))))))


 ;; Additionally updating the semantic map
 (defmethod cram-occasions-events:on-event open-or-close-object
     ((event cpoe:object-articulation-event))
   (with-slots (cpoe:object-designator cpoe:opening-distance) event
     (let ((perceived-object (desig:reference
                              (desig:newest-effective-designator cpoe:object-designator)))
           (semantic-map-object
             (cut:with-vars-strictly-bound (?semantic-map)
                 (cut:lazy-car
                  (prolog `(and
                            (btr:bullet-world ?world)
                            (btr:semantic-map ?world ?semantic-map-name)
                            (btr:%object ?world ?semantic-map-name ?semantic-map))))
               ?semantic-map)))
       (btr:set-articulated-object-joint-position
        semantic-map-object
        (desig:object-identifier perceived-object)
        cpoe:opening-distance))))
)
