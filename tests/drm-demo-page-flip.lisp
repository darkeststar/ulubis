
(defpackage :drm-demo
  (:use :common-lisp :cffi))

(in-package :drm-demo)

(defvar *device* nil)
(defvar *gbm* nil)
(defvar *context* nil)
(defvar *gbm-surface* nil)
(defvar *width* nil)
(defvar *height* nil)
(defvar *egl-surface* nil)
(defvar *display* nil)
(defvar *previous-bo* nil)
(defvar *previous-fb* nil)
(defvar *connector-id* nil)
(defvar *crtc* nil)
(defvar *start* nil)
(defvar *stop* nil)
(defvar *frames* nil)
(defvar *mode* nil)


(defun setup-opengl ()
  (setf *gbm* (gbm:create-device *device*))
  (setf *display* (egl:get-display *gbm*))
  (egl:initialize *display*)
  (egl:bind-api :opengl-api)
  (let ((egl-config (first (egl:choose-config *display* 1
					      :red-size 8
					      :green-size 8
					      :blue-size 8
					      :none))))
    (setf *context* (egl:create-context *display*
					egl-config
					(null-pointer) ; EGL_NO_CONTEXT
					:context-major-version 3
					:context-minor-version 1
					:none))
    (setf *gbm-surface* (gbm:surface-create *gbm*
					    1920
					    1080
					    0 ; GBM_BO_FORMAT_XRGB8888
					    5 ; SCANOUT | RENDERING
					    ))
    (setf *egl-surface* (egl:create-window-surface *display*
						   egl-config
						   *gbm-surface*
						   (null-pointer)))
    (egl:make-current *display* *egl-surface* *egl-surface* *context*)))

(defun shutdown ()
  (format t "Destroying backend~%")
  ;; Restore previous crtc
  (when *crtc*
    (with-foreign-objects ((connector-id :uint32))
      (setf (mem-aref connector-id :uint32) *connector-id*)
      (drm:mode-set-crtc *device*
			 (foreign-slot-value *crtc* '(:struct drm:mode-crtc) 'drm:crtc-id)
			 (foreign-slot-value *crtc* '(:struct drm:mode-crtc) 'drm:buffer-id)
			 (foreign-slot-value *crtc* '(:struct drm:mode-crtc) 'drm:x)
			 (foreign-slot-value *crtc* '(:struct drm:mode-crtc) 'drm:y)
			 connector-id
			 1
			 (incf-pointer *crtc* (foreign-slot-offset '(:struct drm:mode-crtc) 'drm:mode)))
      (format t "Reset CRTC~%")
      
      ;;(drm:mode-free-crtc crtc)
      ;;(format t "CRTC freed~%")
      ))
  
  
  ;; Remove FB
  (when *previous-bo*
    (drm:mode-remove-framebuffer *device* *previous-fb*)
    (gbm:surface-release-buffer *gbm-surface* *previous-bo*)

    (when *egl-surface*
      (egl:destroy-surface *display* *egl-surface*))
    (when *gbm-surface*
      (gbm:surface-destroy *gbm-surface*))
    (when *context*
      (egl:destroy-context *display* *context*))
    (when *display*
      (egl:terminate *display*))
    (when *gbm*
      (gbm:device-destroy *gbm*))
    (when *device*
      (nix:close *device*))))

(defvar *page-flip-scheduled?* nil)

(defun page-flip ()
  (when (not *page-flip-scheduled?*)
    (egl:swap-buffers *display* *egl-surface*)
    (let* ((new-bo (gbm:surface-lock-front-buffer *gbm-surface*))
	   (handle (gbm:bo-get-handle new-bo))
	   (pitch (gbm:bo-get-stride new-bo)))
      (with-foreign-objects ((fb :uint32) (connector-id :uint32))
	(setf (mem-aref connector-id :uint32) *connector-id*)
	(drm:mode-add-framebuffer *device* 1920 1080 24 32 pitch handle fb)
	(let ((crtc-id (foreign-slot-value *crtc* '(:struct drm:mode-crtc) 'drm:crtc-id)))
	  (drm:mode-page-flip *device* crtc-id (mem-aref fb :uint32) 1 (null-pointer)))
	(setf *page-flip-scheduled?* t)
	;; (format t "Free buffers: ~A~%" (gbm:surface-has-free-buffers? (gbm-surface drm-gbm)))
	(when *previous-bo*
	  (drm:mode-remove-framebuffer *device* *previous-fb*)
	  (gbm:surface-release-buffer *gbm-surface* *previous-bo*))
	(setf *previous-bo* new-bo)
	(setf *previous-fb* (mem-aref fb :uint32))))))

;; (defun set-mode ()
;;   (egl:swap-buffers *display* *egl-surface*)
;;   (let* ((new-bo (gbm:surface-lock-front-buffer *gbm-surface*))
;; 	 (handle (gbm:bo-get-handle new-bo))
;; 	 (pitch (gbm:bo-get-stride new-bo)))
;;     (with-foreign-objects ((fb :uint32) (connector-id :uint32))
;;       (setf (mem-aref connector-id :uint32) *connector-id*)
;;       (drm:mode-add-framebuffer *device*
;; 				1920 1080
;; 				24 32 pitch handle fb)
;;       (drm:mode-set-crtc *device*
;; 			 (foreign-slot-value *crtc* '(:struct drm:mode-crtc) 'drm:crtc-id)
;; 			 (mem-aref fb :uint32)
;; 			 0
;; 			 0
;; 			 connector-id
;; 			 1
;; 			 *mode*)
;;       (when *previous-bo*
;; 	(drm:mode-remove-framebuffer *device* *previous-fb*)
;; 	(gbm:surface-release-buffer *gbm-surface* *previous-bo*))
;;       (setf *previous-bo* new-bo)
;;       (setf *previous-fb* (mem-aref fb :uint32)))))

(defun swap ()
  (page-flip))

(defun draw (i)
  (gl:clear-color (- 1.0 i) 0.0 1.0 0.5)
  (gl:clear :color-buffer-bit)
  (swap))

(defvar *display-config* nil)

(defun make-drm-event-context (vblank-callback page-flip-callback)
  (let ((context (foreign-alloc '(:struct drm:event-context))))
    (with-foreign-slots ((drm:version drm:vblank-handler drm:page-flip-handler) context (:struct drm:event-context))
      (setf drm:version 2)
      (setf drm:vblank-handler vblank-callback)
      (setf drm:page-flip-handler page-flip-callback)
      context)))

(defcallback on-page-flip :void ((fd :int)
				 (sequence :uint)
				 (tv-sec :uint)
				 (tv-usec :uint)
				 (user-data :pointer))
	     (setf *page-flip-scheduled?* nil))

(defvar *event-context* nil)

(defun run ()
  (unwind-protect
       (block main-handler
	 (handler-bind ((error #'(lambda (e)
				   (trivial-backtrace:print-backtrace e)
				   (return-from main-handler))))
	   (setf *device* (nix:open "/dev/dri/card0" nix:o-rdwr))
	   (setf *display-config* (drm:find-display-configuration *device*))
	   (setf *mode* (drm:mode-info *display-config*))
	   (setf *connector-id* (drm:connector-id *display-config*))
	   (setf *crtc* (drm:crtc *display-config*))
	   (setup-opengl)
	   (setf *frames* 0)
	   (setf *start* (get-internal-real-time))
	   (setf *event-context* (make-drm-event-context (null-pointer) (callback on-page-flip)))
	   (format t "Event context: ~A~%" *event-context*)
	   (nix:with-pollfds (pollfds (drm-fd *device* nix:pollin))
	     (loop :for i :from 0 :to 18000
		:do (progn
		      (incf *frames*)
		      (setf *stop* (get-internal-real-time))
		      (when (not *page-flip-scheduled?*)
			(draw (/ i 18000.0)))
		      (when (> (- *stop* *start*) 5000.0)
			(setf *start* (get-internal-real-time))
			(format t "FPS: ~A~%" (/ *frames* 5.0))
			(setf *frames* 0))
		      (let ((event (nix:poll pollfds 1 -1)))
			(when event
			  (when (= (nix:poll-return-event drm-fd) nix:pollin)
			    (drm:handle-event *device* *event-context*)))))))))
    (shutdown)))