# Markdown

## Links

- In-line links.

```markdown
[Site Document](readme.md)
```

- Reference links.

```
[Google]: https://www.google.com
```

:::info[Docusaurus]
```markdown
[Site Document](readme)
```
```markdown
[Outbound Link](https://url.com)
```
:::

## Anchoring

- Manual anchoring.

```markdown
<a id="custom-anchor"></a> example-destination

<!-- source page  -->
[Go to Advanced Example](./your-file.md#custom-anchor)
```

## Code Block

````markdown
<!-- code block  -->
```
this is a code block
```
````

## Text Emphasis

<mark>mark</mark>  
<strong>strong</strong>  
<em>em</em>  
<code>code</code>  
<kbd>kbd</kbd>  
<del>del</del>  
<s>s</s>  
<ins>ins</ins>  
<span>span</span>

### Text Formatting

```markdown
**bold**

*italic*

***bold and italic***

~~crossed out~~

> blockquote

`inline code`

# Header Title Anchored

## Header Section Anchored

### Header Subsection Anchored

#### Header Paragraph Anchored
```

## Images

```markdown
![Alt text](image_url)
```
:::note[Docusaurus]
```
![Site Image](/img/image_url)
```
:::

## Horizontal Line

```markdown
---
```

## Table

```markdown
| Header 1 | Header 2 |
|----------|----------|
| Cell 1 | Cell 2 |
```

## Resources

- [GitHub Doc - Basic Writing and Formatting Syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax)
- [Prism Supported Languages](https://prismjs.com/#supported-languages)

