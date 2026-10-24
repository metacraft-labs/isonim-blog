import isonim_blog/model
import isonim/dsl/ui
import ../includes/header
proc layout*(page: Page; site: Site; content: string): string =
  ui:
    raw siteHeader(site)
    main:
      # A child layout is already generated IsoNim markup.
      raw content
