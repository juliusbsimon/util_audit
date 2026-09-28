/* Util Audit: follow the operating system's light/dark setting.
 *
 * Writes the OS setting to the UA_OS_DARK cookie on every page (the login
 * page too, so the first page after signing in already has it). The app
 * process "Sync Theme" reads the cookie and switches the theme style.
 *
 * In "Match system" mode (#ua-theme-mode data-mode="AUTO", rendered by the
 * global page) the page reloads when it does not match the OS: when the OS
 * setting changes while the app is open, or on a first visit before the
 * cookie existed. A sessionStorage guard stops a reload loop if the server
 * cannot switch the style. A page shown as the result of a form POST
 * (wwv_flow.accept, e.g. a validation error) is never reloaded: that would
 * ask the browser to submit the form again.
 */
(function () {
    "use strict";

    var query = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
    var GUARD = "ua-theme-reload";

    function osDark() {
        return !!(query && query.matches);
    }

    function writeCookie() {
        document.cookie = "UA_OS_DARK=" + (osDark() ? "1" : "0") +
            "; path=/; max-age=31536000; SameSite=Lax";
    }

    function matchSystem() {
        var el = document.getElementById("ua-theme-mode");
        return !!el && el.getAttribute("data-mode") === "AUTO";
    }

    function pageDark() {
        return document.body.classList.contains("apex-theme-vita-dark");
    }

    function isPostResult() {
        // href includes the path (".../wwv_flow.accept?p_context=...")
        return window.location.href.indexOf("wwv_flow.accept") !== -1;
    }

    function syncPage() {
        if (isPostResult()) {
            // Keep the guard as it is; the next normal page view syncs
            return;
        }
        if (!matchSystem() || pageDark() === osDark()) {
            sessionStorage.removeItem(GUARD);
            return;
        }
        // Reload once per OS setting; the server switches the style on the way
        if (sessionStorage.getItem(GUARD) !== String(osDark())) {
            sessionStorage.setItem(GUARD, String(osDark()));
            window.location.reload();
        }
    }

    writeCookie();

    document.addEventListener("DOMContentLoaded", syncPage);
    if (document.readyState !== "loading") {
        syncPage();
    }

    if (query) {
        var onChange = function () {
            writeCookie();
            sessionStorage.removeItem(GUARD);
            syncPage();
        };
        if (query.addEventListener) {
            query.addEventListener("change", onChange);
        } else if (query.addListener) {
            query.addListener(onChange);
        }
    }
})();
