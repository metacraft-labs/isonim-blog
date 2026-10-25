---
title: Code with long lines
description: Code lines longer than the column must not widen the page
tags: [code, reference]
categories: [guides]
---

A code block with lines longer than any phone screen:

```sh
nix build --print-build-logs --out-link result-with-a-long-name .#packages.x86_64-linux.default --rebuild --keep-going
```

```json
{
  "name": "conformance",
  "description": "A JSON document on one line that is much wider than the reading column",
  "values": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
}
```
