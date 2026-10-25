# isonim-blog-theme-minimal as a Nimble package. A theme is not a library:
# Nimble installs its files (theme.toml, tokens, layouts, includes, assets,
# og.svg.nim) so the theme directory can be named to isonim-blog, e.g. by
# adding `nimble path isonim_blog_theme_minimal` to ISONIM_BLOG_THEME_PATH.
version = "0.1.0"
author = "Metacraft Labs"
description = "The default isonim-blog theme: plain, accessible, no JavaScript"
license = "Apache-2.0"
installDirs = @["layouts", "includes", "assets"]
installFiles = @["theme.toml", "tokens.json", "og.svg.nim", "README.md"]

# The layouts import isonim_blog and IsoNim.
requires "nim >= 2.0.0"
requires "isonim_blog >= 0.1.0"
