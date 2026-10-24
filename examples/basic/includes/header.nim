import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
proc siteHeader*(site: Site): string =
  ui:
    header:
      a(href = site.config.basePath & "/"): text site.config.title
      a(href = site.config.basePath & "/about/"): text "About"
