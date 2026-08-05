// The Stacks — JS entry point
// Compiled by esbuild with esbuild-plugin-elm
import { Elm } from "../elm/src/Main.elm";

// Import CSS so esbuild bundles it
import "../css/main.css";

// ---------------------------------------------------------------------------
// Transparent client-side image compression before /api/upload
//
// Why: phone-camera uploads are typically 2–5 MB at 4000×3000. For book-
// cover recognition (barcode scan or VLM classification) 1024px max side
// at JPEG quality 0.85 is indistinguishable to the pipeline and ~20×
// smaller. Cuts upload transit time from seconds to ~100 ms on typical
// home upload bandwidth. Canvas re-encoding also strips EXIF (GPS, camera
// metadata) as a side effect — no dedicated library needed, and uploads
// no longer leak location.
//
// How: monkey-patch XMLHttpRequest. Elm's Http module uses XHR under the
// hood; by intercepting at the transport layer we avoid touching any
// Elm code. On any compression error we forward the original bytes so
// the upload always succeeds. The patch is installed BEFORE Elm.init so
// the very first upload is covered.
//
// Patched request path (send):
//   1. If this is a POST to /api/upload with a FormData body carrying
//      an image File → run compressImage → rebuild FormData with the
//      compressed File → call origSend.
//   2. Any non-matching request → forward unchanged.
// ---------------------------------------------------------------------------
(function () {
  var MAX_SIDE = 1024;
  var JPEG_QUALITY = 0.85;

  function compressImage(file) {
    return new Promise(function (resolve, reject) {
      if (!/^image\//.test(file.type)) {
        resolve(file);
        return;
      }
      var url = URL.createObjectURL(file);
      var img = new Image();
      img.onload = function () {
        try {
          var scale = Math.min(
            1,
            MAX_SIDE / Math.max(img.width, img.height)
          );
          if (scale >= 1) {
            // Already within target size — skip re-encode to preserve
            // original bytes (user might have carefully compressed).
            URL.revokeObjectURL(url);
            resolve(file);
            return;
          }
          var canvas = document.createElement("canvas");
          canvas.width = Math.round(img.width * scale);
          canvas.height = Math.round(img.height * scale);
          var ctx = canvas.getContext("2d");
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          canvas.toBlob(
            function (blob) {
              URL.revokeObjectURL(url);
              if (!blob) {
                resolve(file);
                return;
              }
              var name = file.name
                ? file.name.replace(/\.[^.]+$/, "") + ".jpg"
                : "upload.jpg";
              resolve(new File([blob], name, { type: "image/jpeg" }));
            },
            "image/jpeg",
            JPEG_QUALITY
          );
        } catch (e) {
          URL.revokeObjectURL(url);
          reject(e);
        }
      };
      img.onerror = function () {
        URL.revokeObjectURL(url);
        reject(new Error("image decode failed"));
      };
      img.src = url;
    });
  }

  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;

  // Match either the legacy `POST /api/upload` flow (multipart body) or
  // the new presigned flow's `PUT https://*.r2.cloudflarestorage.com/...`
  // step, where the body is a raw File.
  function classifyUpload(method, url) {
    if (typeof method !== "string" || typeof url !== "string") return null;
    var m = method.toUpperCase();
    if (m === "POST" && /\/api\/upload(\?|$)/.test(url)) return "legacy_post";
    if (m === "PUT" && /\br2\.cloudflarestorage\.com\b/.test(url))
      return "presigned_put";
    return null;
  }

  XMLHttpRequest.prototype.open = function (method, url) {
    this._stacksUploadKind = classifyUpload(method, url);
    return origOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function (body) {
    var kind = this._stacksUploadKind;

    // Legacy path: multipart body with an "image" field.
    if (
      kind === "legacy_post" &&
      body &&
      typeof FormData !== "undefined" &&
      body instanceof FormData
    ) {
      var file = body.get("image");
      if (file && file instanceof File && /^image\//.test(file.type)) {
        var xhr = this;
        var originalArgs = arguments;
        compressImage(file)
          .then(function (compressed) {
            var newBody = new FormData();
            newBody.set("image", compressed);
            body.forEach(function (value, key) {
              if (key !== "image") newBody.append(key, value);
            });
            origSend.call(xhr, newBody);
          })
          .catch(function () {
            origSend.apply(xhr, originalArgs);
          });
        return;
      }
    }

    // Presigned path: raw File body PUT directly to R2. Compress the
    // File first, then hand it off so R2 receives the smaller payload.
    // On any error, fall back to the original File to keep the upload
    // working — compression is a perf optimization, not a correctness
    // requirement.
    if (kind === "presigned_put" && body instanceof File) {
      var xhr2 = this;
      var originalArgs2 = arguments;
      if (!/^image\//.test(body.type)) {
        return origSend.apply(this, arguments);
      }
      compressImage(body)
        .then(function (compressed) {
          origSend.call(xhr2, compressed);
        })
        .catch(function () {
          origSend.apply(xhr2, originalArgs2);
        });
      return;
    }

    return origSend.apply(this, arguments);
  };
})();

// Read stored auth from localStorage (passed as flags to Elm).
//
// ⛔ A failure here is REPORTED, not swallowed (Issue #360). This `catch` used to
// be empty, so `localStorage` throwing (private browsing, storage disabled by
// policy) and a blob that will not `JSON.parse` both left `storedAuth = null` —
// which reaches Elm as flags with no auth fields, i.e. indistinguishable from a
// reader who simply is not signed in. The app then signed them out in silence
// and discarded the only artefact that explained why.
//
// These two are the failures Elm CANNOT see for itself: it never receives the
// raw string. A blob that parses but has the wrong SHAPE is caught on the Elm
// side by `Main.decodeFlags`. Between them the three outcomes of a boot —
// nothing stored, something unreadable, a valid session — are all distinguished.
var storedAuth = null;
var storedAuthUnreadable = null;
try {
  var raw = localStorage.getItem("stacks-auth");
  if (raw) {
    storedAuth = JSON.parse(raw);
  }
} catch (e) {
  storedAuthUnreadable = String((e && e.message) || e);
}

// Mount the Elm application IMMEDIATELY — no network round-trip may block first
// paint. Flags carry the stored auth (top-level, as written to localStorage)
// PLUS `ageGatingEnabled: false`, the fail-safe production default (all
// age-gating UI hidden). The REAL flag value is fetched in the background right
// after init (see below) and delivered to Elm over the `ageGatingConfig`
// inbound port a beat later, so in test (flag on) the age UI reveals shortly
// after boot without ever delaying render. All the port wiring below lives
// inside `boot` because it needs the `app` handle returned by `Elm.Main.init`.
function boot() {
  var flags = {};
  if (storedAuth && typeof storedAuth === "object") {
    Object.keys(storedAuth).forEach(function (key) {
      flags[key] = storedAuth[key];
    });
  }
  if (storedAuthUnreadable !== null) {
    // Read by `Main.decodeFlags` → `CorruptStoredAuth`, which surfaces a notice
    // on the login card instead of leaving the reader to guess (#360).
    flags.storedAuthUnreadable = storedAuthUnreadable;
  }
  flags.ageGatingEnabled = false;

  var app = Elm.Main.init({
    node: document.getElementById("elm"),
    flags: flags,
  });

// ---------------------------------------------------------------------------
// Port: Persist auth to localStorage on login
// ---------------------------------------------------------------------------
if (app.ports && app.ports.saveAuth) {
  app.ports.saveAuth.subscribe(function (authData) {
    try {
      localStorage.setItem("stacks-auth", JSON.stringify(authData));
    } catch (e) {
      // localStorage may be full or unavailable
    }
  });
}

// ---------------------------------------------------------------------------
// Port: Clear auth from localStorage on logout
// ---------------------------------------------------------------------------
if (app.ports && app.ports.clearAuth) {
  app.ports.clearAuth.subscribe(function () {
    try {
      localStorage.removeItem("stacks-auth");
    } catch (e) {
      // Ignore
    }
  });
}

// ---------------------------------------------------------------------------
// Cross-tab token propagation (Issue #180 Phase 2)
// The `storage` event fires in OTHER tabs of the same origin when this tab
// writes `stacks-auth` (the writing tab never receives its own event, so there
// is no feedback loop). `e.newValue` is the new JSON string (a sibling rotated
// its token → adopt) or `null` (a sibling `clearAuth` → log out). The raw
// string / null is handed to Elm, which decodes it via `adoptExternalAuth`.
// ---------------------------------------------------------------------------
if (app.ports && app.ports.authChanged) {
  window.addEventListener("storage", function (e) {
    if (e.key === "stacks-auth") {
      app.ports.authChanged.send(e.newValue);
    }
  });
}

// ---------------------------------------------------------------------------
// Port: Re-check-before-logout net (Issue #180 Phase 2)
// On request, read the CURRENT stored auth and hand the raw string (or null when
// absent) back to Elm on `gotStoredAuth`. Elm reuses `adoptExternalAuth` to
// decide whether a token another tab refreshed should be adopted instead of
// logging out.
// ---------------------------------------------------------------------------
if (app.ports && app.ports.requestStoredAuth) {
  app.ports.requestStoredAuth.subscribe(function () {
    var current = null;
    try {
      current = localStorage.getItem("stacks-auth");
    } catch (e) {
      // localStorage unavailable — treat as no stored auth
      current = null;
    }
    if (app.ports && app.ports.gotStoredAuth) {
      app.ports.gotStoredAuth.send(current);
    }
  });
}

// ---------------------------------------------------------------------------
// Port: Persist an in-progress marketplace listing draft (Issue #182)
// Mirrors the auth persistence above but under a separate key so a session
// revocation mid-compose doesn't discard the user's work.
// ---------------------------------------------------------------------------
var LISTING_DRAFT_KEY = "stacks-listing-draft";

if (app.ports && app.ports.saveListingDraft) {
  app.ports.saveListingDraft.subscribe(function (data) {
    try {
      localStorage.setItem(LISTING_DRAFT_KEY, JSON.stringify(data));
    } catch (e) {
      // localStorage may be full or unavailable
    }
  });
}

if (app.ports && app.ports.clearListingDraft) {
  app.ports.clearListingDraft.subscribe(function () {
    try {
      localStorage.removeItem(LISTING_DRAFT_KEY);
    } catch (e) {
      // Ignore
    }
  });
}

// Read the stored draft on request and hand it back to Elm. Sends the parsed
// value, or null when absent/corrupt (Elm treats a decode failure as "no draft").
if (app.ports && app.ports.requestListingDraft) {
  app.ports.requestListingDraft.subscribe(function () {
    var draft = null;
    try {
      var rawDraft = localStorage.getItem(LISTING_DRAFT_KEY);
      if (rawDraft) {
        draft = JSON.parse(rawDraft);
      }
    } catch (e) {
      // Corrupted localStorage data — treat as no draft
      draft = null;
    }
    if (app.ports && app.ports.gotListingDraft) {
      app.ports.gotListingDraft.send(draft);
    }
  });
}

// ---------------------------------------------------------------------------
// Port: Swipe gesture detection for bookshelf navigation (mobile)
// ---------------------------------------------------------------------------
(function (app) {
  var startX = 0;
  var startY = 0;

  document.addEventListener(
    "touchstart",
    function (e) {
      startX = e.touches[0].clientX;
      startY = e.touches[0].clientY;
    },
    { passive: true }
  );

  document.addEventListener(
    "touchend",
    function (e) {
      var dx = e.changedTouches[0].clientX - startX;
      var dy = e.changedTouches[0].clientY - startY;
      if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) {
        app.ports.onSwipe.send(dx < 0 ? "left" : "right");
      }
    },
    { passive: true }
  );
})(app);

// ---------------------------------------------------------------------------
// Port: WAAPI login dolly-shot transition (Issue #028)
//
// ⛔ This handler is DECORATION and nothing downstream of it may matter.
//
// It used to be load-bearing: `onLoginTransitionComplete` was the app's cue to
// write the auth token to localStorage, and that cue was `Promise.all(...)` over
// the WAAPI `finished` promises, inside a `requestAnimationFrame`. Neither fires
// while the window is occluded or backgrounded — rAF is not throttled there, it
// is not called at all — so the callback below never ran, the promise never
// settled, and a login that had already returned 200 was silently discarded.
// Driven live 2026-07-30: three logins, three 200s, nothing in localStorage, ten
// frozen 300 ms transitions, zero WAAPI animations, no follow-up request (#359).
//
// Elm now persists the credential on the update that decodes the 200, so the
// completion signal only retires a cosmetic state. Two rules keep it that way:
//
//   1. The signal fires EXACTLY ONCE, from whichever of the animations or the
//      backstop timer gets there first — including the rejection path, because
//      navigating away cancels these animations and `finished` then rejects.
//   2. The backstop is armed OUTSIDE the frame callback. A timer in a background
//      tab is throttled, not cancelled, and fires on wake; rAF is neither. Arming
//      it inside would put it behind the very frame that never comes.
// ---------------------------------------------------------------------------
if (app.ports && app.ports.playLoginTransition) {
  app.ports.playLoginTransition.subscribe(function (config) {
    var dur = (config && config.duration) || 4000;
    var signalled = false;

    function signalComplete() {
      if (signalled) return;
      signalled = true;
      if (app.ports && app.ports.onLoginTransitionComplete) {
        app.ports.onLoginTransitionComplete.send(null);
      }
    }

    // Respect prefers-reduced-motion (#364). The dolly-shot is pure decoration
    // and the credential is already durable, so a reader who asked for no motion
    // gets none: settle immediately so Elm retires `Arriving` and the shell drops
    // the door layers (which CSS also hides under the same query) without playing
    // a single animation. Gating nothing means this path is safe too.
    if (
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      signalComplete();
      return;
    }

    // Rule 2. Elm arms its own backstop as well; this one keeps the JS side from
    // holding a promise nobody will ever settle.
    setTimeout(signalComplete, dur + 1000);

    requestAnimationFrame(function () {
      var ease = "cubic-bezier(0.4, 0, 0.15, 1)";
      var animations = [];

      var overlay = document.getElementById("overlay");
      var bookshelf = document.getElementById("bookshelf");
      var bookshelfDim = document.getElementById("bookshelfDim");
      var vignette = document.getElementById("vignette");
      var passage = document.getElementById("passage");
      var passageBright = document.getElementById("passageBright");
      var wash = document.getElementById("wash");

      if (overlay) {
        animations.push(
          overlay.animate(
            [
              {
                opacity: 1,
                transform: "translateZ(0) translateY(0) scale(1)",
              },
              {
                opacity: 0,
                transform: "translateZ(0) translateY(30px) scale(0.96)",
              },
            ],
            { duration: dur * 0.3, easing: ease, fill: "forwards" }
          )
        );
      }

      if (bookshelf) {
        animations.push(
          bookshelf.animate(
            [
              { transform: "translateZ(0) scale(1)", opacity: 1 },
              {
                transform: "translateZ(0) scale(1.15)",
                opacity: 1,
                offset: 0.2,
              },
              {
                transform: "translateZ(0) scale(1.5)",
                opacity: 0.7,
                offset: 0.45,
              },
              {
                transform: "translateZ(0) scale(2.0)",
                opacity: 0.2,
                offset: 0.65,
              },
              { transform: "translateZ(0) scale(2.8)", opacity: 0 },
            ],
            { duration: dur * 0.75, easing: ease, fill: "forwards" }
          )
        );
      }

      if (bookshelfDim) {
        animations.push(
          bookshelfDim.animate(
            [
              { opacity: 1 },
              { opacity: 0.6, offset: 0.3 },
              { opacity: 0 },
            ],
            { duration: dur * 0.6, easing: ease, fill: "forwards" }
          )
        );
      }

      if (vignette) {
        animations.push(
          vignette.animate([{ opacity: 1 }, { opacity: 0 }], {
            duration: dur * 0.5,
            easing: ease,
            fill: "forwards",
          })
        );
      }

      if (passage) {
        animations.push(
          passage.animate(
            [
              {
                transform: "translateZ(0) scale(1.15)",
                opacity: 0,
              },
              {
                transform: "translateZ(0) scale(1.05)",
                opacity: 1,
                offset: 0.4,
              },
              {
                transform: "translateZ(0) scale(1.0)",
                opacity: 1,
                offset: 0.65,
              },
              {
                transform: "translateZ(0) scale(1.3)",
                opacity: 0.8,
                offset: 0.85,
              },
              { transform: "translateZ(0) scale(1.8)", opacity: 0 },
            ],
            {
              duration: dur * 0.85,
              delay: dur * 0.25,
              easing: ease,
              fill: "forwards",
            }
          )
        );
      }

      if (passageBright) {
        animations.push(
          passageBright.animate(
            [
              { opacity: 0 },
              { opacity: 0, offset: 0.3 },
              { opacity: 0.4, offset: 0.7 },
              { opacity: 0.8 },
            ],
            {
              duration: dur * 0.85,
              delay: dur * 0.25,
              easing: ease,
              fill: "forwards",
            }
          )
        );
      }

      if (wash) {
        animations.push(
          wash.animate(
            [
              { opacity: 0 },
              { opacity: 0, offset: 0.5 },
              { opacity: 1 },
            ],
            {
              duration: dur * 0.4,
              delay: dur * 0.75,
              easing: "ease-in",
              fill: "forwards",
            }
          )
        );
      }

      // Nothing to animate — the login scene has already been unmounted by the
      // navigation the 200 triggered. Settle now rather than wait out the timer.
      if (animations.length === 0) {
        signalComplete();
        return;
      }

      Promise.all(
        animations.map(function (a) {
          return a.finished;
        })
      ).then(signalComplete, signalComplete);
    });
  });
}

// ---------------------------------------------------------------------------
// Port: Upload SSE stream (Issue #159/#160)
// Opens an EventSource to stream upload status from the backend.
// JWT is passed as ?token= query param (browser EventSource cannot set headers).
// ---------------------------------------------------------------------------
if (app.ports && app.ports.openUploadStream) {
  app.ports.openUploadStream.subscribe(function (params) {
    if (window._uploadStream) {
      window._uploadStream.close();
    }
    var es = new EventSource(params.url);
    es.onmessage = function (event) {
      try {
        var parsed = JSON.parse(event.data);
        if (parsed.type === "heartbeat") return;
      } catch (_) {}
      app.ports.uploadStreamEvent.send(event.data);
    };
    es.onerror = function () {
      app.ports.uploadStreamEvent.send(JSON.stringify({ type: "error" }));
      es.close();
    };
    window._uploadStream = es;
  });
}

// ---------------------------------------------------------------------------
// Background server-config fetch (ADR-020). Runs AFTER Elm has already booted,
// so it never blocks first paint. The config is unauthenticated
// (`GET /api/config`) and currently carries a single flag, `ageGatingEnabled`.
// The resolved boolean is delivered to Elm over the `ageGatingConfig` inbound
// port. On ANY failure (network error, non-2xx, malformed JSON, or a missing
// field) we send nothing — Elm keeps its fail-safe boot default (`false`,
// age-gating UI hidden).
// ---------------------------------------------------------------------------
if (app.ports && app.ports.ageGatingConfig) {
  fetch("/api/config", { headers: { Accept: "application/json" } })
    .then(function (response) {
      return response.ok ? response.json() : null;
    })
    .then(function (config) {
      if (config) {
        app.ports.ageGatingConfig.send(Boolean(config.ageGatingEnabled));
      }
    })
    .catch(function () {
      // Stay false — do nothing.
    });
}

// ---------------------------------------------------------------------------
// Port: browser connectivity (Issue #362)
//
// The `online`/`offline` window events are the browser telling us its own
// answer to a question the app otherwise has to guess at from a failed request
// — and a guess arrives only AFTER something has already gone wrong, and only
// on a page that happened to be fetching. Elm holds a `Connectivity` value fed
// solely from here.
//
// `navigator.onLine` rather than the event's identity, because the two events
// are just edges on that one value and reading it keeps this a single source.
// One send at boot too: a tab OPENED while offline fires no event at all, so
// without it the banner would stay hidden until connectivity next changed.
// ---------------------------------------------------------------------------
if (app.ports && app.ports.connectivityChanged) {
  var sendConnectivity = function () {
    app.ports.connectivityChanged.send(navigator.onLine !== false);
  };
  window.addEventListener("online", sendConnectivity);
  window.addEventListener("offline", sendConnectivity);
  sendConnectivity();
}
}

// Boot immediately — the server config arrives asynchronously (see boot()).
boot();
