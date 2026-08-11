const esbuild = require("esbuild");
const elmPlugin = require("esbuild-plugin-elm");
const path = require("path");
const fs = require("fs");

const isWatch = process.argv.includes("--watch");
const isProduction = process.argv.includes("--production");

function copyStaticAssets() {
  const staticDest = path.resolve(__dirname, "..", "priv", "static");
  const { execSync } = require("child_process");

  fs.mkdirSync(staticDest, { recursive: true });

  const staticSrc = path.resolve(__dirname, "static");
  if (fs.existsSync(staticSrc)) {
    execSync(`cp -rL "${staticSrc}/." "${staticDest}/"`, { stdio: "inherit" });
  }

  const indexSrc = path.resolve(__dirname, "index.html");
  if (fs.existsSync(indexSrc)) {
    fs.copyFileSync(indexSrc, path.join(staticDest, "index.html"));
  }
}

async function build() {
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
