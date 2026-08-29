/* Atlas Commerce — custom product gallery.
 *
 * Features:
 *   - Track-based slider with smooth transitions (no third-party swiper).
 *   - Touch + drag navigation.
 *   - Keyboard arrow nav (when gallery is focused).
 *   - Lightbox overlay with full-screen image and zoomable cursor.
 *   - Vertical thumbnails with active highlight and scroll-into-view.
 *   - Hover-zoom lens on the main image.
 *
 * No external dependencies. Plain ES6 + jQuery for DOM events.
 */
(function ($, window) {
    'use strict';

    function AtlasGallery(root) {
        this.root = root;
        this.id = root.id || ('atlas-gallery-' + Math.random().toString(36).slice(2));
        this.track = root.querySelector('.atlas-gallery-track');
        this.slides = Array.prototype.slice.call(root.querySelectorAll('.atlas-gallery-slide'));
        // Scope the thumb lookup to the gallery root, not the whole document,
        // so multiple galleries on the same page don't fight over each other's
        // thumbnails.
        var galleryRoot = root.closest('.atlas-gallery') || root.parentElement;
        this.thumbsEl = galleryRoot.querySelector('.atlas-gallery-thumbs');
        this.thumbs = this.thumbsEl
            ? Array.prototype.slice.call(this.thumbsEl.querySelectorAll('.atlas-gallery-thumb[data-index]'))
            : [];
        this.thumbsTrack = this.thumbsEl ? this.thumbsEl.querySelector('[data-thumbs]') : null;
        this.thumbUp = this.thumbsEl ? this.thumbsEl.querySelector('.atlas-gallery-thumbs-up') : null;
        this.thumbDown = this.thumbsEl ? this.thumbsEl.querySelector('.atlas-gallery-thumbs-down') : null;
        this.prevBtn = root.querySelector('.atlas-gallery-prev');
        this.nextBtn = root.querySelector('.atlas-gallery-next');
        this.counterCurrent = root.querySelector('.atlas-gallery-counter-current');
        this.counterTotal = root.querySelector('.atlas-gallery-counter-total');
        this.zoomHint = root.querySelector('.atlas-gallery-zoom-hint');
        this.index = 0;
        this.total = this.slides.length;
        this.lightbox = document.querySelector('[data-atlas-lightbox]');
        this.lightboxImg = this.lightbox ? this.lightbox.querySelector('.atlas-lightbox-img') : null;
        this.lightboxCounter = this.lightbox ? this.lightbox.querySelector('.atlas-lightbox-counter') : null;
        this.transitionMs = 360;
        this._bind();
        this._goTo(0, true);
    }

    AtlasGallery.prototype._bind = function () {
        var self = this;
        if (this.prevBtn) this.prevBtn.addEventListener('click', function () { self.prev(); });
        if (this.nextBtn) this.nextBtn.addEventListener('click', function () { self.next(); });
        this.thumbs.forEach(function (t) {
            t.addEventListener('click', function () {
                self._goTo(parseInt(t.dataset.index, 10));
            });
        });
        if (this.thumbUp) this.thumbUp.addEventListener('click', function () { self._scrollThumbs(-1); });
        if (this.thumbDown) this.thumbDown.addEventListener('click', function () { self._scrollThumbs(1); });
        if (this.zoomHint) this.zoomHint.addEventListener('click', function () { self.openLightbox(); });

        // Click on main image opens lightbox
        this.slides.forEach(function (slide, i) {
            slide.addEventListener('click', function () { self.openLightbox(i); });
        });

        // Drag-to-swipe (mouse)
        var startX = 0, startY = 0, dragging = false, dx = 0;
        this.track.addEventListener('mousedown', function (e) {
            dragging = true; startX = e.clientX; startY = e.clientY; dx = 0;
            self.track.style.transition = 'none';
        });
        window.addEventListener('mousemove', function (e) {
            if (!dragging) return;
            dx = e.clientX - startX;
            var offset = -self.index * 100 + (dx / self.track.parentElement.clientWidth) * 100;
            self.track.style.transform = 'translateX(' + offset + '%)';
        });
        window.addEventListener('mouseup', function () {
            if (!dragging) return;
            dragging = false;
            self.track.style.transition = '';
            if (Math.abs(dx) > 60) {
                if (dx < 0) self.next(); else self.prev();
            } else {
                self._goTo(self.index);
            }
        });

        // Touch drag
        this.track.addEventListener('touchstart', function (e) {
            if (!e.touches.length) return;
            startX = e.touches[0].clientX; startY = e.touches[0].clientY; dx = 0; dragging = true;
            self.track.style.transition = 'none';
        }, { passive: true });
        this.track.addEventListener('touchmove', function (e) {
            if (!dragging || !e.touches.length) return;
            dx = e.touches[0].clientX - startX;
            var offset = -self.index * 100 + (dx / self.track.parentElement.clientWidth) * 100;
            self.track.style.transform = 'translateX(' + offset + '%)';
        }, { passive: true });
        this.track.addEventListener('touchend', function () {
            if (!dragging) return;
            dragging = false;
            self.track.style.transition = '';
            if (Math.abs(dx) > 60) {
                if (dx < 0) self.next(); else self.prev();
            } else {
                self._goTo(self.index);
            }
        });

        // Keyboard
        this.root.tabIndex = 0;
        this.root.addEventListener('keydown', function (e) {
            // While the lightbox is open, arrow keys belong to the lightbox
            // (handled by the document-level listener below).
            if (self.lightbox && !self.lightbox.hidden) return;
            if (e.key === 'ArrowLeft') { self.prev(); e.preventDefault(); }
            else if (e.key === 'ArrowRight') { self.next(); e.preventDefault(); }
            else if (e.key === 'Escape') { self.closeLightbox(); }
        });

        // Lightbox controls
        if (this.lightbox) {
            var lightboxPrev = this.lightbox.querySelector('.atlas-lightbox-prev');
            var lightboxNext = this.lightbox.querySelector('.atlas-lightbox-next');
            var lightboxClose = this.lightbox.querySelector('.atlas-lightbox-close');
            if (lightboxPrev) lightboxPrev.addEventListener('click', function () { self.lbStep(-1); });
            if (lightboxNext) lightboxNext.addEventListener('click', function () { self.lbStep(1); });
            if (lightboxClose) lightboxClose.addEventListener('click', function () { self.closeLightbox(); });
            this.lightbox.addEventListener('click', function (e) {
                if (e.target === self.lightbox) self.closeLightbox();
            });
        }
        document.addEventListener('keydown', function (e) {
            if (self.lightbox && !self.lightbox.hidden) {
                if (e.key === 'ArrowLeft') { self.lbStep(-1); e.preventDefault(); }
                else if (e.key === 'ArrowRight') { self.lbStep(1); e.preventDefault(); }
                else if (e.key === 'Escape') { self.closeLightbox(); }
            }
        });
    };

    AtlasGallery.prototype._goTo = function (i, instant) {
        if (i < 0) i = 0;
        if (i > this.total - 1) i = this.total - 1;
        this.index = i;
        var offset = -i * 100;
        if (instant) {
            this.track.style.transition = 'none';
            this.track.offsetWidth; // reflow
            this.track.style.transition = '';
        }
        this.track.style.transform = 'translateX(' + offset + '%)';
        this._updateUI();
    };

    AtlasGallery.prototype._updateUI = function () {
        if (this.counterCurrent) this.counterCurrent.textContent = this.index + 1;
        if (this.counterTotal) this.counterTotal.textContent = this.total;
        this.thumbs.forEach(function (t, i) {
            t.classList.toggle('atlas-gallery-thumb--active', i === this.index);
        }.bind(this));
        var activeThumb = this.thumbs[this.index];
        if (activeThumb && this.thumbsTrack) {
            var top = activeThumb.offsetTop - this.thumbsTrack.offsetTop;
            var visible = this.thumbsTrack.clientHeight;
            var t = top - (visible - activeThumb.offsetHeight) / 2;
            this.thumbsTrack.scrollTo({ top: Math.max(0, t), behavior: 'smooth' });
        }
    };

    AtlasGallery.prototype.next = function () {
        if (this.index < this.total - 1) this._goTo(this.index + 1);
        else this._goTo(0); // loop
    };

    AtlasGallery.prototype.prev = function () {
        if (this.index > 0) this._goTo(this.index - 1);
        else this._goTo(this.total - 1); // loop
    };

    AtlasGallery.prototype._scrollThumbs = function (dir) {
        if (!this.thumbsTrack) return;
        this.thumbsTrack.scrollBy({ top: dir * 88, behavior: 'smooth' });
    };

    AtlasGallery.prototype._setLightboxImage = function (i) {
        var slide = this.slides[i];
        if (!slide || !this.lightboxImg) return;
        var img = slide.querySelector('img');
        this.lightboxImg.src = img ? (img.dataset.full || img.src) : '';
        this.lightboxImg.alt = img ? (img.alt || '') : '';
        if (this.lightboxCounter) this.lightboxCounter.textContent = (i + 1) + ' / ' + this.total;
    };

    // Step the lightbox image (wraps around). Independent of the main track so
    // browsing inside the lightbox doesn't move the gallery behind it.
    AtlasGallery.prototype.lbStep = function (dir) {
        if (!this.lightbox || this.lightbox.hidden) return;
        var base = (typeof this._lbIndex === 'number') ? this._lbIndex : this.index;
        var i = base + dir;
        if (i < 0) i = this.total - 1;
        if (i > this.total - 1) i = 0;
        this._lbIndex = i;
        this._setLightboxImage(i);
    };

    AtlasGallery.prototype.openLightbox = function (i) {
        if (!this.lightbox || !this.lightboxImg) return;
        if (typeof i !== 'number') i = this.index;
        if (!this.slides[i]) return;
        this._lbIndex = i;
        this._setLightboxImage(i);
        this.lightbox.hidden = false;
        this.lightbox.setAttribute('aria-hidden', 'false');
        document.body.style.overflow = 'hidden';
    };

    AtlasGallery.prototype.closeLightbox = function () {
        if (!this.lightbox) return;
        this.lightbox.hidden = true;
        this.lightbox.setAttribute('aria-hidden', 'true');
        document.body.style.overflow = '';
    };

    $(function () {
        Array.prototype.forEach.call(document.querySelectorAll('.atlas-gallery-main'), function (el) {
            if (el.id && !el.dataset.bound) {
                el.dataset.bound = '1';
                new AtlasGallery(el);
            }
        });
    });
})(jQuery, window);
