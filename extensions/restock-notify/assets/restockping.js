// RestockPing storefront block. Loaded async from the theme's <head>, so it waits
// for the DOM. Kept dependency-free and small (Shopify suggests <10 KB of JS).
(() => {
  "use strict";

  // Shopify documents no "variant changed" event for app blocks, and each theme
  // updates the product page its own way. What every theme must keep correct is
  // the add-to-cart form's `id` input (it decides what goes in the cart), and most
  // also update ?variant= in the URL. So read those.
  function selectedVariantId(fallback) {
    const cartInput = document.querySelector('form[action*="/cart/add"] [name="id"]');
    if (cartInput && cartInput.value) return String(cartInput.value);
    const fromUrl = new URLSearchParams(window.location.search).get("variant");
    return fromUrl || String(fallback);
  }

  function init(root) {
    if (root.dataset.restockpingReady) return;
    root.dataset.restockpingReady = "true";

    const availability = JSON.parse(root.querySelector("[data-restockping-variants]").textContent);
    const form = root.querySelector("[data-restockping-form]");
    const variantInput = form.querySelector('[name="variant_id"]');
    const emailInput = form.querySelector('[name="email"]');
    const button = form.querySelector('[type="submit"]');
    const message = root.querySelector("[data-restockping-message]");

    const say = (text, isError) => {
      message.textContent = text;
      message.classList.toggle("restockping__message--error", Boolean(isError));
    };

    // Show the form only while the selected variant is sold out.
    let lastVariant = null;
    function sync() {
      const id = selectedVariantId(variantInput.value);
      if (id === lastVariant || !(id in availability)) return;
      lastVariant = id;
      variantInput.value = id;
      root.hidden = availability[id] !== false;
      say("");
    }

    // A theme that sets the input's value in JS doesn't fire `change`, and URL
    // updates use history.replaceState, which fires no event either. So listen
    // for the events that do exist and poll cheaply as a fallback.
    document.addEventListener("change", sync, true);
    window.addEventListener("popstate", sync);
    window.setInterval(sync, 500);
    sync();

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!emailInput.checkValidity()) {
        say(root.dataset.msgInvalidEmail, true);
        emailInput.focus();
        return;
      }

      button.disabled = true;
      say("");
      try {
        // Same origin as the storefront: Shopify proxies /apps/restockping/* to our
        // app and signs the query string. Nothing secret lives in this script.
        const response = await fetch(root.dataset.endpoint, {
          method: "POST",
          headers: { Accept: "application/json" },
          body: new URLSearchParams(new FormData(form)),
        });
        const data = await response.json().catch(() => ({}));

        if (response.ok) {
          say(root.dataset.msgSuccess, false);
          form.reset();
        } else if (data.error === "invalid_email") {
          say(root.dataset.msgInvalidEmail, true);
        } else if (data.error === "in_stock") {
          say(root.dataset.msgInStock, false);
        } else if (response.status === 429) {
          say(root.dataset.msgRateLimited, true);
        } else {
          say(root.dataset.msgError, true);
        }
      } catch (_networkError) {
        say(root.dataset.msgError, true);
      } finally {
        button.disabled = false;
      }
    });
  }

  function boot() {
    document.querySelectorAll("[data-restockping]").forEach(init);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
  // The theme editor re-renders sections in place when a merchant edits them.
  document.addEventListener("shopify:section:load", boot);
})();
