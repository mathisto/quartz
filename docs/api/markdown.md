# markdown

## Functions

### `html_escape(): String` *(std/markdown.qz:19)*

Escape &, <, >, " for safe HTML embedding.

---

### `inline_format(): String` *(std/markdown.qz:46)*

Format inline elements: `code`, **bold**, *italic*, [links](url).

---

### `split_table_row(): Vec<String>` *(std/markdown.qz:160)*

Split a markdown table row (|col1|col2|) into trimmed cell strings.

---

### `make_anchor(): String` *(std/markdown.qz:183)*

Generate a URL-safe anchor ID from heading text.

---

### `_is_ordered_list_item(): Bool` *(std/markdown.qz:211)*

Check if a line starts with a digit followed by ". " (e.g. "1. item").

---

### `_ordered_list_text(): String` *(std/markdown.qz:235)*

Extract the text after "N. " from an ordered list line.

---

### `md_to_html(): String` *(std/markdown.qz:255)*

Convert a Markdown string to an HTML fragment.

---

### `md_to_html_page(): String` *(std/markdown.qz:527)*

Convert Markdown to a complete HTML page with minimal, tasteful CSS.

---

### `_md_page_css(): String` *(std/markdown.qz:540)*

---

