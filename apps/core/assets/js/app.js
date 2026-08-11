import { Elm } from "../elm/src/Main.elm";

import "../css/main.css";

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

function boot() {
  var flags = {};
  if (storedAuth && typeof storedAuth === "object") {
    Object.keys(storedAuth).forEach(function (key) {
      flags[key] = storedAuth[key];
    });
  }
  if (storedAuthUnreadable !== null) {
    flags.storedAuthUnreadable = storedAuthUnreadable;
  }
  flags.ageGatingEnabled = false;
  // Fail CLOSED: registration stays invite-gated until the real
  // config arrives; a fetch failure must not reopen public sign-ups.
  flags.inviteOnly = true;

  var app = Elm.Main.init({
    node: document.getElementById("elm"),
    flags: flags,
  });

if (app.ports && app.ports.saveAuth) {
  app.ports.saveAuth.subscribe(function (authData) {
    try {
      localStorage.setItem("stacks-auth", JSON.stringify(authData));
    } catch (e) {
    }
  });
}

if (app.ports && app.ports.clearAuth) {
  app.ports.clearAuth.subscribe(function () {
    try {
      localStorage.removeItem("stacks-auth");
    } catch (e) {
    }
  });
}

var ONBOARDING_DONE_KEY = "stacks-onboarding-completed";

if (app.ports && app.ports.saveOnboardingCompleted) {
  app.ports.saveOnboardingCompleted.subscribe(function () {
    try {
      localStorage.setItem(ONBOARDING_DONE_KEY, "true");
    } catch (e) {
    }
  });
}

if (app.ports && app.ports.onOnboardingStatus) {
  var onboardingDone = false;
  try {
    onboardingDone = localStorage.getItem(ONBOARDING_DONE_KEY) === "true";
  } catch (e) {
    onboardingDone = false;
  }
  app.ports.onOnboardingStatus.send(onboardingDone);
}

if (app.ports && app.ports.authChanged) {
  window.addEventListener("storage", function (e) {
    if (e.key === "stacks-auth") {
      app.ports.authChanged.send(e.newValue);
    }
  });
}

if (app.ports && app.ports.requestStoredAuth) {
  app.ports.requestStoredAuth.subscribe(function () {
    var current = null;
    try {
      current = localStorage.getItem("stacks-auth");
    } catch (e) {
      current = null;
    }
    if (app.ports && app.ports.gotStoredAuth) {
      app.ports.gotStoredAuth.send(current);
    }
  });
}

var LISTING_DRAFT_KEY = "stacks-listing-draft";

if (app.ports && app.ports.saveListingDraft) {
  app.ports.saveListingDraft.subscribe(function (data) {
    try {
      localStorage.setItem(LISTING_DRAFT_KEY, JSON.stringify(data));
    } catch (e) {
    }
  });
}

if (app.ports && app.ports.clearListingDraft) {
  app.ports.clearListingDraft.subscribe(function () {
    try {
      localStorage.removeItem(LISTING_DRAFT_KEY);
    } catch (e) {
    }
  });
}

if (app.ports && app.ports.requestListingDraft) {
  app.ports.requestListingDraft.subscribe(function () {
    var draft = null;
    try {
      var rawDraft = localStorage.getItem(LISTING_DRAFT_KEY);
      if (rawDraft) {
        draft = JSON.parse(rawDraft);
      }
    } catch (e) {
      draft = null;
    }
    if (app.ports && app.ports.gotListingDraft) {
      app.ports.gotListingDraft.send(draft);
    }
  });
}

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

    if (
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      signalComplete();
      return;
    }

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

if (app.ports && app.ports.ageGatingConfig) {
  fetch("/api/config", { headers: { Accept: "application/json" } })
    .then(function (response) {
      return response.ok ? response.json() : null;
    })
    .then(function (config) {
      if (config) {
        app.ports.ageGatingConfig.send(Boolean(config.ageGatingEnabled));
        if (app.ports.inviteOnlyConfig && typeof config.inviteOnly === "boolean") {
          app.ports.inviteOnlyConfig.send(config.inviteOnly);
        }
      }
    })
    .catch(function () {
    });
}

// ---------------------------------------------------------------------------
// Port: browser connectivity
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

if (app.ports && app.ports.copyToClipboard) {
  app.ports.copyToClipboard.subscribe(function (text) {
    var answer = function (ok) {
      if (app.ports.copyResult) {
        app.ports.copyResult.send(ok);
      }
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () {
          answer(true);
        },
        function () {
          answer(false);
        }
      );
    } else {
      answer(false);
    }
  });
}
}

boot();
