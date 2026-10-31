## Backend-independent site metadata built from a rendered site: the RSS
## and Atom feeds (written by `isonim/static/feeds`), the per-page feed
## discovery links, and the schema.org JSON-LD (`BlogPosting`, `WebSite`,
## `WebPage`, with the author as a `Person`; https://schema.org/BlogPosting).
import std/[json, strutils, tables]
import isonim/static/feeds
import ./[model, archives]
export feeds

proc siteRoot*(site: Site): string =
  ## The absolute URL of the site's root (origin plus base path, with a
  ## trailing slash).
  site.config.url & site.config.basePath & "/"

proc absoluteUrl*(site: Site; path: string): string =
  ## A site path or reference made absolute against the site root. A
  ## root-relative path keeps its own path (it already includes the base
  ## path when it came from a permalink).
  if path.len == 0: "" else: resolveUrl(siteRoot(site), path)

proc configuredUrl*(site: Site; reference: string): string =
  ## A URL written in site.toml, made absolute. A root-relative reference
  ## there names a path of the site, so it is placed under the base path
  ## (`/about/` is `<origin><base_path>/about/`); an absolute or a
  ## protocol-relative URL is kept as written.
  if reference.len > 0 and reference[0] == '/' and not reference.startsWith("//"):
    absoluteUrl(site, site.config.basePath & reference)
  else: absoluteUrl(site, reference)

proc feedPosts*(site: Site): seq[Page] =
  ## The posts a feed may carry: never a draft (even in a `--drafts`
  ## preview) and never a post dated after the build date (even with
  ## `--future`), in site order.
  for post in site.posts:
    if post.draft or post.future: continue
    result.add post

proc authorPerson(site: Site): FeedPerson =
  ## The site author; the site title stands in when none is configured,
  ## because Atom requires an author (RFC 4287 section 4.1.1).
  let author = site.config.author
  result.name = author.stringValue("name")
  if result.name.len == 0: result.name = site.config.title
  let url = author.stringValue("url")
  if url.len > 0: result.uri = configuredUrl(site, url)
  result.email = author.stringValue("email")

proc feedEntry(site: Site; post: Page): FeedEntry =
  let url = absoluteUrl(site, post.url)
  result = FeedEntry(title: post.title, url: url, published: post.date,
    updated: post.updated, categories: post.tags & post.categories)
  if site.config.fullContentFeeds: result.contentHtml = absoluteHtmlUrls(post.content, url)
  else:
    # The summary is read on its own, so its endnote links lead to the
    # post page's endnotes, not to the excerpt's own (`withoutExcerptAnchors`).
    result.summary = absoluteHtmlUrls(withoutExcerptAnchors(post.excerpt,
      excerptAnchorPrefix(post.url)), url)

proc buildFeed(site: Site; posts: openArray[Page]; title, homeUrl, feedUrl: string): Feed =
  result = Feed(title: title, subtitle: site.config.description, siteUrl: homeUrl,
    feedUrl: feedUrl, language: site.config.language, authors: @[authorPerson(site)],
    generator: "isonim-blog")
  for post in posts: result.entries.add feedEntry(site, post)
  if result.entries.len == 0:
    # An empty feed is still dated: by the build date, never the clock.
    result.updated = site.buildDate

proc siteFeeds*(site: Site): seq[tuple[path, content: string]] =
  ## Every feed file of `site`, as site paths (with the base path) and
  ## bytes: the RSS and Atom feeds of all posts, and an Atom feed per tag.
  ## Raises `BlogError` when feeds are on but the site has no `url`.
  let config = site.config
  if config.rssPath.len == 0 and config.atomPath.len == 0: return
  if config.url.len == 0:
    fail("feeds need an absolute site url: set url in site.toml or pass --url")
  let posts = feedPosts(site)
  let home = siteRoot(site)
  if config.rssPath.len > 0:
    let path = config.basePath & config.rssPath
    result.add (path, renderRss(buildFeed(site, posts, config.title, home, absoluteUrl(site, path))))
  if config.atomPath.len > 0:
    let path = config.basePath & config.atomPath
    result.add (path, renderAtom(buildFeed(site, posts, config.title, home, absoluteUrl(site, path))))
    for tag, tagged in site.tags:
      let path = tagFeedUrl(site, tag)
      if path.len == 0: continue
      var entries: seq[Page]
      for post in tagged:
        if not post.draft and not post.future: entries.add post
      result.add (path, renderAtom(buildFeed(site, entries,
        config.title & " — " & termTitle(site, "tags", tag),
        absoluteUrl(site, tagUrl(site, tag)), absoluteUrl(site, path))))

proc feedLinksHtml*(site: Site; page: Page): string =
  ## The `<link rel="alternate">` discovery links a page carries: the site
  ## feeds, and on a tag page that tag's Atom feed.
  let config = site.config
  if config.url.len == 0: return
  if config.rssPath.len > 0:
    result.add feedLinkHtml(absoluteUrl(site, config.basePath & config.rssPath),
      rssMediaType, config.title & " (RSS)")
  if config.atomPath.len > 0:
    result.add feedLinkHtml(absoluteUrl(site, config.basePath & config.atomPath),
      atomMediaType, config.title & " (Atom)")
  if page.kind == pkTag:
    let path = tagFeedUrl(site, page.term)
    if path.len > 0:
      result.add feedLinkHtml(absoluteUrl(site, path), atomMediaType,
        config.title & " — " & termTitle(site, "tags", page.term) & " (Atom)")

proc personJson(site: Site): JsonNode =
  let person = authorPerson(site)
  result = %*{"@type": "Person", "name": person.name}
  if person.uri.len > 0: result["url"] = %person.uri

proc jsonLdFor*(site: Site; page: Page; canonicalUrl: string): string =
  ## The page's JSON-LD: `BlogPosting` for a post, `WebSite` for the site
  ## root, `WebPage` (part of the `WebSite`) for any other page. Keys are in
  ## a fixed order and `<` is escaped, so the block is deterministic and
  ## cannot close its `<script>` element.
  let website = %*{"@type": "WebSite", "name": site.config.title, "url": siteRoot(site)}
  var node: JsonNode
  if page.kind == pkContent and page.collection == "posts":
    node = %*{"@context": "https://schema.org", "@type": "BlogPosting",
      "headline": page.title, "description": page.description, "url": canonicalUrl,
      "mainEntityOfPage": canonicalUrl, "datePublished": page.date,
      "dateModified": (if page.updated.len > 0: page.updated else: page.date),
      "author": personJson(site), "publisher": personJson(site), "isPartOf": website}
    if page.tags.len > 0: node["keywords"] = %page.tags
    if page.image.len > 0: node["image"] = %absoluteUrl(site, page.image)
  elif page.url == cleanRoute(site.config.basePath & "/"):
    node = %*{"@context": "https://schema.org", "@type": "WebSite",
      "name": site.config.title, "description": site.config.description,
      "url": siteRoot(site), "inLanguage": site.config.language,
      "author": personJson(site), "publisher": personJson(site)}
  else:
    node = %*{"@context": "https://schema.org", "@type": "WebPage",
      "name": page.title, "description": page.description, "url": canonicalUrl,
      "inLanguage": site.config.language, "isPartOf": website}
  ($node).replace("<", "\\u003c")
