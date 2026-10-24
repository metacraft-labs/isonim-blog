## One path policy for direct Nim, Reprobuild and sandboxed Nix compiles.
## Development uses real sibling checkouts; the package explicitly selects
## its locked Nix inputs. Missing explicit inputs fail rather than falling back.
import std/os

let root = currentSourcePath().parentDir()
switch("path", root / "src")

proc dependency(name, envName, define: string) =
  let sibling = root.parentDir() / name
  let pinned = getEnv(envName)
  let usePinned = getEnv("ISONIM_BLOG_PINNED_SOURCES") == "1"
  let selected =
    if not usePinned and dirExists(sibling / "src"): sibling
    else: pinned
  if selected.len == 0 or not dirExists(selected / "src"):
    raise newException(ValueError, "Missing " & name & " sources: enter nix develop or provide a sibling checkout")
  switch("path", selected / "src")
  # Tests compile site programs; they must use the very trees chosen here.
  switch("define", define & "=" & selected)

# Repro compiles its tool-only recipe before activating the project's environment.
# Library dependencies belong to the resulting source/test compiles, not that
# provider executable. Requiring them here would prevent standalone activation.
if projectName() != "repro":
  dependency("isonim", "ISONIM_BLOG_ISONIM_SRC", "isonimBlogIsonimSrc")
  dependency("nim-everywhere", "ISONIM_BLOG_NIM_EVERYWHERE_SRC", "isonimBlogNimEverywhereSrc")

if getCommand() == "js":
  # NimScript itself runs in the VM, so `defined(js)` is not the target test.
  # Node must propagate unittest failures through process.exit.
  switch("define", "nodejs")

# Direct compiler invocations also keep intermediates inside this checkout.
# Explicit per-edge cache flags on the command line take precedence.
switch("nimcache", root / "build" / "nimcache" / (getCommand() & "-" & projectName()))
