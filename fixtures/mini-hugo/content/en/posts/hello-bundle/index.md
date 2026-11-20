+++
title = "Hello Bundle"
slug = "hello-custom-slug"
date = 2024-02-10
draft = false
weight = 5
aliases = ["/old/hello-bundle/", "/legacy/hb"]
tags = ["demo", "bundle"]
categories = ["posts"]
+++

A **leaf bundle**: `index.md` inside a directory that also holds a page
resource (`banner.png`). The `figure` shortcode references that
resource:

{{< figure src="banner.png" alt="Synthetic banner" title="Banner" >}}

Plain Markdown image of the same resource:

![Banner again](banner.png)
