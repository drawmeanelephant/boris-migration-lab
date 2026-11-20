---
title: Home
layout: default
---

Welcome to the synthetic mini-Jekyll site.

{% include note.html text="Included from _includes." %}

Read the [welcome post]({% post_url 2024-01-02-welcome-post %}) and the
[first guide]({% link _docs/guide-one.md %}).

This `post_url` is intentionally broken: {% post_url 1999-01-01-ghost-post %}.

Hero image: {{ site.baseurl }}/assets/images/hero.png

{% raw %}{{ not liquid }}{% endraw %}

A Liquid tag inside a fenced code block is not a live tag:

```liquid
{% post_url 2024-01-02-welcome-post %}
```
