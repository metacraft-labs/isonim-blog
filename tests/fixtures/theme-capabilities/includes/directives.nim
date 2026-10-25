## The theme's registered directives (theme.toml `directives`): `:::pullquote`
## renders its Markdown body as a quotation the stylesheet sets apart.
import isonim/content/[markdown, directives]

proc directives*(): seq[DirectiveRegistration] =
  @[DirectiveRegistration(name: "pullquote",
    render: proc(args, body: string): seq[Block] =
      @[Block(kind: bkBlockquote, quoteBlocks: parseMarkdownDoc(body).blocks)])]
