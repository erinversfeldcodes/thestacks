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

  XMLHttpRequest.prototype.open = function (method, url) {
    this._stacksIsUploadXhr =
      typeof method === "string" &&
      method.toUpperCase() === "POST" &&
      typeof url === "string" &&
      /\/api\/upload(\?|$)/.test(url);
    return origOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function (body) {
    if (
      this._stacksIsUploadXhr &&
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
            // Preserve any other multipart fields the client set.
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
    return origSend.apply(this, arguments);
  };
})();

// Read stored auth from localStorage (passed as flags to Elm)
var storedAuth = null;
try {
  var raw = localStorage.getItem("stacks-auth");
  if (raw) {
    storedAuth = JSON.parse(raw);
  }
} catch (e) {
  // Ignore corrupted localStorage data
}

// Mount the Elm application with auth flags
var app = Elm.Main.init({
  node: document.getElementById("elm"),
  flags: storedAuth,
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
// ---------------------------------------------------------------------------
if (app.ports && app.ports.playLoginTransition) {
  app.ports.playLoginTransition.subscribe(function (config) {
    requestAnimationFrame(function () {
      var dur = (config && config.duration) || 4000;
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

      Promise.all(
        animations.map(function (a) {
          return a.finished;
        })
      ).then(function () {
        if (app.ports && app.ports.onLoginTransitionComplete) {
          app.ports.onLoginTransitionComplete.send(null);
        }
      });
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
