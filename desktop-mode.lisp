
(in-package :ulubis)

(defparameter *default-mode* nil)
(defparameter *ortho* (m4:identity))

(defmode desktop-mode ()
  ((clear-color :accessor clear-color
		:initarg :clear-color
		:initform (list (random 1.0)
				(random 1.0)
				(random 1.0) 0.0))
   (projection :accessor projection
	       :initarg :projection
	       :initform (m4:identity))
   (focus-follows-mouse :accessor focus-follows-mouse
			:initarg :focus-follows-mouse
			:initform nil)))

(defmethod init-mode ((mode desktop-mode))
  (setf *ortho* (ortho 0 (screen-width *compositor*) (screen-height *compositor*) 0 1 -1))
  (cepl:map-g #'mapping-pipeline nil)
  (setf (render-needed *compositor*) t))

(defun pointer-changed-surface (mode x y old-surface new-surface)
  (setf (cursor-surface *compositor*) nil)
  (when (focus-follows-mouse mode)
    (deactivate old-surface)) 
  (send-leave old-surface)
  (setf (pointer-surface *compositor*) new-surface)
  (when (focus-follows-mouse mode)
    (activate-surface new-surface mode))
  (send-enter new-surface x y))

(defmethod mouse-motion-handler ((mode desktop-mode) time delta-x delta-y)
  (with-slots (pointer-x pointer-y) *compositor*
    (update-pointer delta-x delta-y)
    (when (cursor-surface *compositor*)
      (setf (render-needed *compositor*) t))
    (let ((old-surface (pointer-surface *compositor*))
	  (current-surface (surface-under-pointer pointer-x pointer-y (view mode))))
      (cond
	;; 1. If we are dragging a window...
	((moving-surface *compositor*)
	 (move-surface pointer-x pointer-y (moving-surface *compositor*)))
	;; 2. If we are resizing a window...
	((resizing-surface *compositor*)
	 (resize-surface pointer-x pointer-y (view mode) (resizing-surface *compositor*)))
	;; 3. The pointer has left the current surface
	((not (equalp old-surface current-surface))
	 (setf (cursor-surface *compositor*) nil)
	 (pointer-changed-surface mode pointer-x pointer-y old-surface current-surface))
	;; 4. Pointer is over previous surface
	((equalp old-surface current-surface)
	 (send-surface-pointer-motion pointer-x pointer-y time current-surface))))))

(defun pulse-animation (surface)
  (setf (origin-x surface) (/ (width (wl-surface surface)) 2))
  (setf (origin-y surface) (/ (height (wl-surface surface)) 2))
  (sequential-animation
   nil
   (parallel-animation
    nil
    (animation :duration 100
	       :easing-fn 'easing:linear
	       :to 1.05
	       :target surface
	       :property 'scale-x)
    (animation :duration 100
	       :easing-fn 'easing:linear
	       :to 1.05
	       :target surface
	       :property 'scale-y))
   (parallel-animation
    nil
    (animation :duration 100
	       :easing-fn 'easing:linear
	       :to 1.0
	       :target surface
	       :property 'scale-x)
    (animation :duration 100
	       :easing-fn 'easing:linear
	       :to 1.0
	       :target surface
	       :property 'scale-y))))

(defmethod mouse-button-handler ((mode desktop-mode) time button state)
  ;; 1. Change (possibly) the active surface
  (when (and (= button #x110) (= state 1) (= 0 (mods-depressed *compositor*)))
    (let ((surface (surface-under-pointer (pointer-x *compositor*) (pointer-y *compositor*) (view mode))))
      ;; When we click on a client which isn't the first client
      (when (and surface (not (equalp surface (active-surface (view mode)))))
	(start-animation (pulse-animation surface) :finished-fn (lambda ()
								  (setf (origin-x surface) 0.0)
								  (setf (origin-y surface) 0.0))))
      (activate-surface surface mode)
      (when surface
	(raise-surface surface (view mode))
	(setf (render-needed *compositor*) t))))
  
  ;; Drag window
  (when (and (= button #x110) (= state 1) (= Gui (mods-depressed *compositor*)))
    (let ((surface (surface-under-pointer (pointer-x *compositor*) (pointer-y *compositor*) (view mode))))
      (when surface
	(setf (moving-surface *compositor*) ;;surface))))
	      (make-move-op :surface surface
			    :surface-x (x surface)
			    :surface-y (y surface)
			    :pointer-x (pointer-x *compositor*)
			    :pointer-y (pointer-y *compositor*))))))
	      
  ;; stop drag
  (when (and (moving-surface *compositor*) (= button #x110) (= state 0))
    (setf (moving-surface *compositor*) nil))

  ;; Resize window
  (when (and (= button #x110) (= state 1) (= (+ Gui Shift) (mods-depressed *compositor*)))
    (let ((surface (surface-under-pointer (pointer-x *compositor*) (pointer-y *compositor*) (view mode))))
      (when surface
	(let ((width (effective-width surface))
	      (height (effective-height surface)))
	  (setf (resizing-surface *compositor*)
		(make-resize-op :surface surface
				:pointer-x (pointer-x *compositor*)
				:pointer-y (pointer-y *compositor*)
				:surface-width width
				:surface-height height
				:direction 10))))))

  (when (and (resizing-surface *compositor*) (= button #x110) (= state 0))
    (setf (resizing-surface *compositor*) nil))
  
  ;; 2. Send active surface mouse button
  (when (surface-under-pointer (pointer-x *compositor*)
			       (pointer-y *compositor*)
			       (view mode)) 
    (let ((surface (surface-under-pointer (pointer-x *compositor*)
			       (pointer-y *compositor*)
			       (view mode))))
      (send-button surface time button state))))
	

(defkeybinding (:pressed "q" Ctrl Shift) () (desktop-mode)
  (uiop:quit))

(defkeybinding (:pressed "s" Ctrl Shift) () (desktop-mode)
  (screenshot))

(defkeybinding (:pressed "T" Ctrl Shift) () (desktop-mode)
  (run-program "/usr/bin/weston-terminal"))

(defkeybinding (:pressed "Tab" Gui) (mode) (desktop-mode)
  (push-mode (view mode) (make-instance 'alt-tab-mode)))

(defmethod first-commit ((mode desktop-mode) (surface isurface))
  (let ((animation (sequential-animation
		    (lambda ()
		      (setf (origin-x surface) 0.0)
		      (setf (origin-y surface) 0.0))
		    (animation :target surface
			       :property 'scale-x
			       :easing-fn 'easing:out-exp
			       :from 0
			       :to 1.0
			       :duration 250)
		    (animation :target surface
			       :property 'scale-y
			       :easing-fn 'easing:out-exp
			       :to 1.0
			       :duration 250))))
    (setf (origin-x surface) (/ (width (wl-surface surface)) 2))
    (setf (origin-y surface) (/ (height (wl-surface surface)) 2))
    (setf (scale-y surface) (/ 6 (height (wl-surface surface))))
    (setf (first-commit-animation surface) animation)
    (start-animation animation)))

(cepl:defun-g desktop-mode-vertex-shader ((vert cepl:g-pt) &uniform (origin :mat4) (origin-inverse :mat4) (surface-scale :mat4) (surface-translate :mat4))
  (values (* *ortho* surface-translate origin-inverse surface-scale origin (rtg-math:v! (cepl:pos vert) 1))
	  (:smooth (cepl:tex vert))))

(cepl:defpipeline-g mapping-pipeline ()
  (desktop-mode-vertex-shader cepl:g-pt) (default-fragment-shader :vec2))

(defmethod render ((surface isurface) &optional view-fbo)
  (when (texture (wl-surface surface))
    (with-rect (vertex-stream (width (wl-surface surface)) (height (wl-surface surface)))
      (let ((texture (texture-of surface)))
	(gl:viewport 0 0 (screen-width *compositor*) (screen-height *compositor*))
	(map-g-default/fbo view-fbo #'mapping-pipeline vertex-stream
			   :origin (m4:translation (rtg-math:v! (- (origin-x surface)) (- (origin-y surface)) 0))
			   :origin-inverse (m4:translation (rtg-math:v! (origin-x surface) (origin-y surface) 0))
			   :surface-scale (m4:scale (rtg-math:v! (scale-x surface) (scale-y surface) 1.0))
			   :surface-translate (m4:translation (rtg-math:v! (x surface) (y surface) 0.0))
			   :texture texture
			   :alpha (opacity surface))))
    (loop :for subsurface :in (reverse (subsurfaces (wl-surface surface)))
       :do (render subsurface view-fbo))))

(defmethod render ((surface wl-subsurface) &optional view-fbo)
  (when (texture (wl-surface surface))
    (with-rect (vertex-stream (width (wl-surface surface)) (height (wl-surface surface)))
      (let ((texture (texture-of surface)))
	(gl:viewport 0 0 (screen-width *compositor*) (screen-height *compositor*))
	(map-g-default/fbo view-fbo #'mapping-pipeline vertex-stream
			   :origin (m4:translation (rtg-math:v! (+ (x surface) (- (origin-x (role (parent surface)))))
								(+ (y surface) (- (origin-y (role (parent surface)))))
								0))
			   :origin-inverse (m4:translation (rtg-math:v! (+ (- (x surface)) (origin-x (role (parent surface))))
									(+ (- (y surface)) (origin-y (role (parent surface))))
									0))
			   :surface-scale (m4:scale (rtg-math:v! (scale-x (role (parent surface)))
								 (scale-y (role (parent surface)))
								 1.0))
			   :surface-translate (m4:translation (rtg-math:v! (+ (x (role (parent surface))) (x surface))
									   (+ (y (role (parent surface))) (y surface))
									   0.0))
			   :texture texture
			   :alpha (opacity surface))))
    (loop :for subsurface :in (reverse (subsurfaces (wl-surface surface)))
       :do (render subsurface view-fbo))))

(defmethod render ((mode desktop-mode) &optional view-fbo)
  (apply #'gl:clear-color (clear-color mode))
  (when view-fbo
    (cepl:clear view-fbo))
  (cepl:with-blending (blending-parameters mode)
    (mapcar (lambda (surface)
	      (cepl:with-blending (blending-parameters mode)
		(render surface view-fbo)))
	    (reverse (surfaces (view mode))))))
