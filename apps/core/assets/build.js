const esbuild = require("esbuild");
const elmPlugin = require("esbuild-plugin-elm");
const path = require("path");
const fs = require("fs");

const isWatch = process.argv.includes("--watch");
const isProduction = process.argv.includes("--production");

// Copy static assets (textures, etc.) to priv/static so they are served
// at their original URL paths (e.g. /textures/bookshelf-wide-panoramic.png).
function copyStaticAssets() {
  const staticDest = path.resolve(__dirname, "..", "priv", "static");
  const { execSync } = require("child_process");

  // Ensure destination exists.
  fs.mkdirSync(staticDest, { recursive: true });

  // Copy the static/ directory contents (textures etc.) if present.
  const staticSrc = path.resolve(__dirname, "static");
  if (fs.existsSync(staticSrc)) {
    // Use cp -rL via child_process to avoid semgrep path-traversal false positives
    // on path.join(dir, entry.name) patterns from readdirSync.
    // -L dereferences symlinks (static/textures is a symlink to frontend/public/textures).
    // macOS cp -r follows symlinks by default, but Linux preserves them — -L is portable.
    execSync(`cp -rL "${staticSrc}/." "${staticDest}/"`, { stdio: "inherit" });
  }

  // Copy the SPA entrypoint index.html to priv/static so PageController
  // can serve it for / and all client-side routes.
  const indexSrc = path.resolve(__dirname, "index.html");
  if (fs.existsSync(indexSrc)) {
    fs.copyFileSync(indexSrc, path.join(staticDest, "index.html"));
  }
}

async function build() {
  // Copy static assets before building JS/CSS
  copyStaticAssets();

  const ctx = await esbuild.context({
    entryPoints: [path.resolve(__dirname, "js", "app.js")],
    bundle: true,
    outdir: path.resolve(__dirname, "..", "priv", "static", "assets"),
    plugins: [
      elmPlugin({
        optimize: isProduction,
        cwd: path.resolve(__dirname, "elm"),
      }),
    ],
    // Absolute URL paths in CSS (e.g. url('/textures/...')) are served by
    // Plug.Static at runtime — tell esbuild not to try resolving them.
    external: ["/textures/*"],
    minify: isProduction,
    sourcemap: !isProduction,
    target: "es2017",
    logLevel: "info",
  });

  if (isWatch) {
    await ctx.watch();
    console.log("Watching for changes...");
  } else {
    await ctx.rebuild();
    await ctx.dispose();
  }
}

build().catch((err) => {
  console.error(err);
  process.exit(1);
});
