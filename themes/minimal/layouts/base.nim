## The page frame: a skip link, the site header, the main landmark and the
## footer. Every other layout of the theme has `parent = "base"`.
import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
import ../includes/minimal

proc layout*(page: Page; site: Site; content: string): string =
  let header = siteHeader(site, page)
  let footer = siteFooter(site)
  let mainClasses = mainClass(site)
  ui:
    a(class = "skip-link", href = "#content"): text "Skip to content"
    raw header
    main(id = "content", class = mainClasses):
      # A child layout's output is already generated IsoNim markup.
      raw content
    raw footer
