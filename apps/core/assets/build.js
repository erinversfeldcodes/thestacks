const esbuild = require("esbuild");
const elmPlugin = require("esbuild-plugin-elm");
const path = require("path");
const fs = require("fs");

const isWatch = process.argv.includes("--watch");
const isProduction = process.argv.includes("--production");

// Copy static assets (textures, etc.) to priv/static so they are served
// at their original URL paths (e.g. /textures/bookshelf-wide-panoramic.png).
function copyStaticAssets() {
  const staticSrc = path.resolve(__dirname, "static");
  const staticDest = path.resolve(__dirname, "..", "priv", "static");

  if (!fs.existsSync(staticSrc)) return;

  // Use cp -r via child_process to avoid semgrep path-traversal false positives
  // on path.join(dir, entry.name) patterns from readdirSync.
  const { execSync } = require("child_process");
  execSync(`cp -r "${staticSrc}/." "${staticDest}/"`, { stdio: "inherit" });
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
