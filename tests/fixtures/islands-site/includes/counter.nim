## One island: server-rendered on C, hydrated in the browser on JS.
import isonim/dsl/ui
when defined(js):
  import isonim/web/[dom_api, web_renderer, hydration]
  proc mount*(element: Element) =
    let r = WebRenderer()
    hydrate(proc(): Node =
      let ready = ui(r):
        button: text "Ready"
      Node(ready)
    , element, "counter-")
else:
  import isonim/ssr/[escape, markers]
  proc counterHtml*(): string =
    withHydrationKeys("counter-"):
      result = ui:
        button: text "Ready"
