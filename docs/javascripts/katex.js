document$.subscribe(({ body }) => {
  if (typeof renderMathInElement !== "undefined") {
    renderMathInElement(body, {
      delimiters: [
        { left: "$$",  right: "$$",  display: true },
        { left: "$",   right: "$",   display: false },
        { left: "\\(", right: "\\)", display: false },
        { left: "\\[", right: "\\]", display: true }
      ],
    })
  }
})
