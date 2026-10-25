## A post whose layout follows its front matter (`page.extra`): `kind`
## selects the article's class and label, `status` shows a badge, and
## `credits` fills a popover. A two-way switch shows the details layer
## through `:has()` alone.
import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  let kind = page.extra.getStr("kind", "note")
  let status = page.extra.getStr("status")
  let credits = page.extra.getList("credits")
  let popoverId = "credits-" & page.slug
  ui:
    article(class = "post kind-" & kind):
      p(class = "kind-label"): text kind
      h1: text page.title
      if status.len > 0:
        p(class = "status status-" & status): text "Status: " & status
      fieldset(class = "layer-switch"):
        legend: text "Show"
        input(`type` = "radio", name = "layer", id = "layer-overview", checked = "")
        label(`for` = "layer-overview"): text "Overview"
        input(`type` = "radio", name = "layer", id = "layer-details")
        label(`for` = "layer-details"): text "Details"
      tdiv(class = "overview"):
        raw page.excerpt
      tdiv(class = "details"):
        raw content
      if credits.len > 0:
        button(`type` = "button", popovertarget = popoverId): text "Credits"
        tdiv(id = popoverId, popover = "auto", class = "credits"):
          h2: text "Credits"
          ul:
            for credit in credits:
              li: text credit
