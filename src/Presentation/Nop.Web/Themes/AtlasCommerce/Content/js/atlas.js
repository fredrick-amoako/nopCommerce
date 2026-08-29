/* Atlas Commerce — storefront theme helpers (Buy Now, sticky ATC price, product card carousels).
   NOTE: this file is appended to the END of the footer bundle (AddScriptParts appends),
   so jQuery / public.ajaxcart.js normally exist by the time it runs. The retry loop in
   tryInit() is kept as a safety net for load-order changes; public APIs are registered
   immediately and only reference AjaxCart when invoked. */
(function (window, undefined) {
    'use strict';

    var AtlasCommerce = window.AtlasCommerce = window.AtlasCommerce || {};
    var isInitialized = false;

    function syncStickyPrice() {
        if (window.matchMedia('(min-width: 768px)').matches) return;
        var stickyEl = document.querySelector('[data-atlas-sticky-price-value]');
        if (!stickyEl) return;

        // Read the effective price of the MAIN product. The core _ProductPrice partial
        // renders exactly one span with a "price-value-*" class — the discounted price
        // when on sale, otherwise the regular price. Scoping to .atlas-product-overview
        // keeps related / "also purchased" cards (different markup) from leaking in.
        var source = document.querySelector('.atlas-product-overview .prices [class*="price-value-"]');
        if (!source) return;

        var text = (source.textContent || '').trim();
        if (text) {
            stickyEl.textContent = text;
            stickyEl.classList.remove('is-empty');
        }
    }

    /* ==========================================================
       Product card carousel — full-width image slider used by
       the Atlas product box (replaces Swiper on catalog pages).
       Markup contract:
         [data-atlas-carousel]
           .atlas-card-track   (flex row, translated by index)
             .atlas-card-slide (one per picture)
           .atlas-card-arrow.prev / .next
           .atlas-card-dots    (dots injected here)
       ========================================================== */
    function initCardCarousel($el) {
        if ($el.data('atlasCarouselReady')) return;
        $el.data('atlasCarouselReady', true);

        var $track = $el.find('.atlas-card-track');
        var $slides = $el.find('.atlas-card-slide');
        var count = $slides.length;
        if (count < 2) {
            $el.addClass('is-single');
            return;
        }

        var index = 0;
        var $dotsWrap = $el.find('.atlas-card-dots');

        for (var i = 0; i < count; i++) {
            $('<button type="button" class="atlas-card-dot">')
                .attr('aria-label', 'Show image ' + (i + 1))
                .appendTo($dotsWrap);
        }
        var $dots = $dotsWrap.children('.atlas-card-dot');

        function goTo(i) {
            index = ((i % count) + count) % count;
            $track.css('transform', 'translateX(-' + (index * 100) + '%)');
            $dots.removeClass('is-active').eq(index).addClass('is-active');
        }

        $el.on('click', '.atlas-card-arrow.prev', function (e) { e.preventDefault(); goTo(index - 1); });
        $el.on('click', '.atlas-card-arrow.next', function (e) { e.preventDefault(); goTo(index + 1); });
        $dotsWrap.on('click', '.atlas-card-dot', function () { goTo($(this).index()); });

        // Basic swipe support for touch devices.
        var startX = null;
        $el.on('touchstart', function (e) {
            startX = e.originalEvent.touches[0].clientX;
        }, { passive: true });
        $el.on('touchend', function (e) {
            if (startX === null) return;
            var dx = e.originalEvent.changedTouches[0].clientX - startX;
            if (Math.abs(dx) > 40) goTo(index + (dx < 0 ? 1 : -1));
            startX = null;
        });

        goTo(0);
    }

    function initCardCarousels(root) {
        var $ = window.jQuery;
        if (!$) return;
        $(root || document).find('[data-atlas-carousel]').each(function () {
            initCardCarousel($(this));
        });
    }

    /* ==========================================================
       Home hero slider — enhance the Widgets.Swiper fade slider
       (plugin ships pagination only). Injects glassy arrows, keeps
       them edge-aware, and pauses autoplay while the pointer rests
       on the hero. Waits for the plugin's global instance (swiper6).
       ========================================================== */
    function initHeroSlider() {
        var $ = window.jQuery;
        if (!$) return false;

        var $slider = $(document).find('.nop-slider');
        if (!$slider.length) return true; // no hero on this page — done
        if ($slider.data('atlasHeroReady')) return true;

        var swiper = window.swiper6;
        if (!swiper || typeof swiper.slideNext !== 'function') return false; // plugin script not run yet
        if (swiper.el && !$(swiper.el).is('.nop-slider')) return true; // instance belongs to another slider — don't touch it

        $slider.data('atlasHeroReady', true);

        var prevSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>';
        var nextSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 18l6-6-6-6"/></svg>';

        $('<button type="button" class="atlas-hero-arrow atlas-hero-prev" aria-label="Previous slide">').html(prevSvg).appendTo($slider);
        $('<button type="button" class="atlas-hero-arrow atlas-hero-next" aria-label="Next slide">').html(nextSvg).appendTo($slider);

        function syncEdges() {
            var total = swiper.slides.length;
            var i = swiper.activeIndex;
            $slider.toggleClass('is-at-start', i <= 0);
            $slider.toggleClass('is-at-end', i >= total - 1);
        }

        swiper.on('slideChange', syncEdges);
        syncEdges();

        $slider.on('click', '.atlas-hero-prev', function (e) {
            e.preventDefault();
            e.stopPropagation();
            if (swiper.activeIndex > 0) swiper.slidePrev();
        });
        $slider.on('click', '.atlas-hero-next', function (e) {
            e.preventDefault();
            e.stopPropagation();
            if (swiper.activeIndex < swiper.slides.length - 1) swiper.slideNext();
        });

        // Resting on the hero pauses the rotation; leaving resumes it.
        if (swiper.autoplay && swiper.params && swiper.params.autoplay) {
            $slider.on('mouseenter', function () { swiper.autoplay.stop(); });
            $slider.on('mouseleave', function () { swiper.autoplay.start(); });
        }
        return true;
    }

    var heroRetries = 0;
    function tryInitHero() {
        if (initHeroSlider()) return;
        if (++heroRetries > 100) return; // ~10s cap — plugin may be disabled
        setTimeout(tryInitHero, 100);
    }

    function init() {
        if (isInitialized) return;
        isInitialized = true;

        var $ = window.jQuery;

        // Patch the success path so Buy Now can chain a redirect after the
        // item is added to the cart via the standard AJAX endpoints.
        var originalSuccess = AjaxCart.success_process;
        if (typeof originalSuccess !== 'function') {
            isInitialized = false;
            return;
        }

        AjaxCart.buyNowPending = false;
        AjaxCart.buyNowRedirectUrl = null;

        AjaxCart.success_process = function (response) {
            // Capture + clear the pending state BEFORE running the original
            // handler so a failed add-to-cart can never leak into the next,
            // unrelated cart action.
            var buyNowUrl = AjaxCart.buyNowPending ? AjaxCart.buyNowRedirectUrl : null;
            AjaxCart.buyNowPending = false;
            AjaxCart.buyNowRedirectUrl = null;

            // Honor cart-related housekeeping that's already in the original
            // handler (topcart update, flyout, notifications). Note: with
            // DisplayCartAfterAddingProduct (or ForceRedirectionAfterAddingToCart)
            // the endpoint returns { redirect: cartUrl } — the original handler
            // sets location.href to the cart; our assignment below runs later in
            // the same task and wins, sending the customer to checkout instead.
            originalSuccess(response);

            // The add succeeded if the endpoint reported success OR asked for a
            // redirect (both shapes only occur after a successful add). Failures
            // return warnings/errors with neither field — never go to checkout then.
            var addedOk = response && (response.success === true || !!response.redirect);
            if (buyNowUrl && addedOk) {
                window.location.href = buyNowUrl;
            }
        };

        // Keep the mobile sticky bar's price in sync with the overview panel
        // (which is the source of truth — single-rendered, no duplicate widgets).
        syncStickyPrice();
        $(document).on('product_quantity_changed', syncStickyPrice);
        document.addEventListener('DOMContentLoaded', syncStickyPrice);

        // Initialize any product card carousels already in the DOM.
        initCardCarousels(document);

        // Enhance the home hero slider (waits for the plugin's Swiper instance).
        tryInitHero();
    }

    var initRetries = 0;

    function tryInit() {
        if (isInitialized) return;
        if (typeof window.jQuery === 'undefined' ||
            typeof window.AjaxCart === 'undefined' ||
            typeof AjaxCart.success_process !== 'function') {
            // Bundled scripts after us (jQuery, public.ajaxcart.js) haven't
            // executed yet — keep retrying until they have. Capped so a failed
            // dependency can't cause an infinite polling loop.
            if (++initRetries > 200) {
                window.console && console.warn('[AtlasCommerce] jQuery/AjaxCart never became available; Buy Now is disabled.');
                return;
            }
            setTimeout(tryInit, 50);
            return;
        }
        if (window.document.readyState === 'loading') {
            window.document.addEventListener('DOMContentLoaded', function onReady() {
                window.document.removeEventListener('DOMContentLoaded', onReady);
                init();
            });
        } else {
            init();
        }
    }

    // Buy Now from the product details page. Adds the item to the cart via the
    // standard endpoint, then redirects to checkout. The endpoint URL is built
    // server-side with Url.RouteUrl in the view so it respects PathBase and any
    // custom route templates.
    AtlasCommerce.buyNow = function (detailsUrl, formSelector, checkoutUrl) {
        if (!window.AjaxCart || !AjaxCart.addproducttocart_details) return;

        AjaxCart.buyNowPending = true;
        AjaxCart.buyNowRedirectUrl = checkoutUrl;
        AjaxCart.addproducttocart_details(detailsUrl, formSelector);
    };

    // Buy Now from a product card (catalog pages). Same contract as buyNow, but
    // through the catalog endpoint.
    AtlasCommerce.buyNowCatalog = function (catalogUrl, checkoutUrl) {
        if (!window.AjaxCart || !AjaxCart.addproducttocart_catalog) return;

        AjaxCart.buyNowPending = true;
        AjaxCart.buyNowRedirectUrl = checkoutUrl;
        AjaxCart.addproducttocart_catalog(catalogUrl);
    };

    // (Re)initialize card carousels, e.g. after AJAX content updates.
    AtlasCommerce.refreshProductCards = function (root) {
        initCardCarousels(root);
    };

    tryInit();
})(window);
