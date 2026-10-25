import isonim_blog/model
import ../includes/parts
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string = listingSection(page)
