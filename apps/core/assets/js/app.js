// The Stacks — JS entry point
// Compiled by esbuild with esbuild-plugin-elm
import { Elm } from "../elm/src/Main.elm";

// Import CSS so esbuild bundles it
import "../css/main.css";

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
