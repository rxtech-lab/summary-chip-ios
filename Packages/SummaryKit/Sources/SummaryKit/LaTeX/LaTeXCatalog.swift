import Foundation

/// The commands, environments and packages offered before anything the paper defines itself,
/// roughly most used first (the order breaks ties between equally good matches), each with the
/// one-line description shown in completions and hover cards.
enum LaTeXCatalog {
    struct Command: Sendable {
        let name: String
        /// Typed after the name: `{}` puts the caret between the braces.
        let arguments: String
        let description: String

        init(_ name: String, _ arguments: String = "", _ description: String) {
            self.name = name
            self.arguments = arguments
            self.description = description
        }

        /// How it's written, for a hover card: `\frac{num}{den}`.
        var signature: String { "\\" + name + arguments.replacingOccurrences(of: "{}", with: "{…}") }
    }

    struct Entry: Sendable {
        let name: String
        let description: String

        init(_ name: String, _ description: String) {
            self.name = name
            self.description = description
        }
    }

    static let commands: [Command] = structure + text + references + floats + math + symbols + preamble

    static func command(_ name: String) -> Command? { commandsByName[name] }
    static func environment(_ name: String) -> Entry? { environmentsByName[name] }
    static func package(_ name: String) -> Entry? { packagesByName[name] }

    private static let commandsByName = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    private static let environmentsByName = Dictionary(environments.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    private static let packagesByName = Dictionary(packages.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    private static let structure: [Command] = [
        Command("begin", "{}", "Starts an environment, ended by the matching \\end."),
        Command("end", "{}", "Ends the innermost open environment."),
        Command("item", " ", "An entry of an itemize, enumerate or description list."),
        Command("section", "{}", "A numbered section heading."),
        Command("subsection", "{}", "A numbered subsection heading."),
        Command("subsubsection", "{}", "A numbered sub-subsection heading."),
        Command("paragraph", "{}", "A run-in paragraph heading."),
        Command("chapter", "{}", "A chapter heading (book and report classes)."),
        Command("part", "{}", "A part heading, above chapters and sections."),
        Command("section*", "{}", "A section heading without a number or a contents entry."),
        Command("subsection*", "{}", "A subsection heading without a number or a contents entry."),
        Command("input", "{}", "Reads another .tex file in place."),
        Command("include", "{}", "Reads another .tex file on a new page."),
        Command("appendix", "", "Starts the appendices: sections are lettered from here on."),
        Command("maketitle", "", "Typesets the title block from \\title, \\author and \\date."),
        Command("tableofcontents", "", "Typesets the table of contents."),
        Command("title", "{}", "Sets the document title used by \\maketitle."),
        Command("author", "{}", "Sets the authors used by \\maketitle; separate them with \\and."),
        Command("date", "{}", "Sets the date used by \\maketitle; empty for none."),
        Command("thanks", "{}", "A footnote in the title block, e.g. for affiliations or funding."),
        Command("newpage", "", "Ends the current page."),
        Command("clearpage", "", "Ends the page and places all pending figures and tables."),
        Command("noindent", "", "Starts the paragraph without indentation."),
        Command("par", "", "Ends the paragraph, like a blank line."),
        Command("vspace", "{}", "Adds vertical space, e.g. \\vspace{1em}."),
        Command("hspace", "{}", "Adds horizontal space, e.g. \\hspace{2mm}."),
        Command("medskip", "", "Adds a medium vertical space."),
        Command("bigskip", "", "Adds a large vertical space."),
        Command("smallskip", "", "Adds a small vertical space."),
        Command("centering", "", "Centers the rest of the current group, e.g. inside a figure."),
        Command("linewidth", "", "The width of a line in the current context."),
        Command("textwidth", "", "The width of the text block on the page."),
        Command("columnwidth", "", "The width of a column in multi-column layouts."),
    ]

    private static let text: [Command] = [
        Command("textbf", "{}", "Bold text."),
        Command("textit", "{}", "Italic text."),
        Command("emph", "{}", "Emphasized text: italic, or upright inside italics."),
        Command("underline", "{}", "Underlined text."),
        Command("texttt", "{}", "Monospaced (typewriter) text."),
        Command("textsc", "{}", "Small capitals."),
        Command("textrm", "{}", "Roman (serif) text."),
        Command("textsf", "{}", "Sans-serif text."),
        Command("footnote", "{}", "A numbered footnote."),
        Command("url", "{}", "A URL in monospace that breaks across lines (url or hyperref)."),
        Command("href", "{}{}", "A link: \\href{url}{text} (hyperref)."),
        Command("small", "", "Switches to a small font size."),
        Command("footnotesize", "", "Switches to the footnote font size."),
        Command("large", "", "Switches to a large font size."),
        Command("Large", "", "Switches to a larger font size."),
        Command("tiny", "", "Switches to the smallest font size."),
        Command("normalsize", "", "Switches back to the normal font size."),
        Command("bfseries", "", "Switches to bold for the rest of the group."),
        Command("itshape", "", "Switches to italics for the rest of the group."),
        Command("ttfamily", "", "Switches to monospace for the rest of the group."),
        Command("ldots", "", "An ellipsis: …"),
        Command("dots", "", "An ellipsis that adapts to its context (amsmath)."),
        Command("today", "", "Today's date."),
        Command("LaTeX", "", "The LaTeX logo."),
        Command("TeX", "", "The TeX logo."),
        Command("quad", "", "A space one em wide."),
        Command("qquad", "", "A space two ems wide."),
    ]

    private static let references: [Command] = [
        Command("cite", "{}", "Cites one or more .bib entries by key."),
        Command("citep", "{}", "A parenthetical citation: (Knuth, 1984) (natbib)."),
        Command("citet", "{}", "A textual citation: Knuth (1984) (natbib)."),
        Command("parencite", "{}", "A parenthetical citation (biblatex)."),
        Command("textcite", "{}", "A textual citation (biblatex)."),
        Command("autocite", "{}", "A citation in the style's preferred form (biblatex)."),
        Command("nocite", "{}", "Lists entries in the bibliography without citing them; {*} lists all."),
        Command("label", "{}", "Names the current section, figure, table or equation for \\ref."),
        Command("ref", "{}", "The number of a \\label."),
        Command("eqref", "{}", "An equation number in parentheses (amsmath)."),
        Command("autoref", "{}", "A reference with its kind: “Figure 3” (hyperref)."),
        Command("cref", "{}", "A reference with its kind: “fig. 3” (cleveref)."),
        Command("Cref", "{}", "A capitalized reference with its kind: “Figure 3” (cleveref)."),
        Command("pageref", "{}", "The page number of a \\label."),
        Command("bibliography", "{}", "Prints the bibliography from the named .bib files (BibTeX)."),
        Command("bibliographystyle", "{}", "Sets the BibTeX style, e.g. plain or abbrvnat."),
        Command("addbibresource", "{}", "Adds a .bib file to the bibliography (biblatex)."),
        Command("printbibliography", "", "Prints the bibliography (biblatex)."),
    ]

    private static let floats: [Command] = [
        Command("includegraphics", "[width=\\linewidth]{}", "Places an image file (graphicx)."),
        Command("caption", "{}", "The caption of a figure or table."),
        Command("toprule", "", "The top rule of a table (booktabs)."),
        Command("midrule", "", "The rule under a table's header (booktabs)."),
        Command("bottomrule", "", "The bottom rule of a table (booktabs)."),
        Command("hline", "", "A horizontal line across a table."),
        Command("cline", "{}", "A horizontal line across some columns: \\cline{2-3}."),
        Command("multicolumn", "{}{}{}", "A cell spanning columns: \\multicolumn{n}{align}{text}."),
        Command("multirow", "{}{}{}", "A cell spanning rows: \\multirow{n}{width}{text} (multirow)."),
    ]

    private static let math: [Command] = [
        Command("frac", "{}{}", "A fraction: \\frac{numerator}{denominator}."),
        Command("sqrt", "{}", "A square root; \\sqrt[n]{x} for the nth root."),
        Command("sum", "", "A summation sign ∑; limits with _ and ^."),
        Command("prod", "", "A product sign ∏."),
        Command("int", "", "An integral sign ∫."),
        Command("lim", "", "The limit operator."),
        Command("infty", "", "Infinity: ∞"),
        Command("partial", "", "The partial derivative sign: ∂"),
        Command("nabla", "", "Nabla: ∇"),
        Command("cdot", "", "A centered dot: ·"),
        Command("times", "", "The multiplication sign: ×"),
        Command("left", "", "A delimiter that grows to fit, paired with \\right."),
        Command("right", "", "Closes a \\left delimiter."),
        Command("mathbf", "{}", "Bold upright math letters."),
        Command("mathrm", "{}", "Upright (roman) math letters."),
        Command("mathcal", "{}", "Calligraphic capitals: 𝒜."),
        Command("mathbb", "{}", "Blackboard bold capitals: ℝ (amssymb)."),
        Command("mathit", "{}", "Italic math letters."),
        Command("boldsymbol", "{}", "A bold math symbol, including Greek (amsmath)."),
        Command("text", "{}", "Normal text inside math (amsmath)."),
        Command("operatorname", "{}", "An upright operator name with operator spacing (amsmath)."),
        Command("hat", "{}", "A hat accent: x̂"),
        Command("bar", "{}", "A bar accent: x̄"),
        Command("tilde", "{}", "A tilde accent: x̃"),
        Command("vec", "{}", "A vector arrow accent."),
        Command("dot", "{}", "A dot accent, e.g. a time derivative."),
        Command("overline", "{}", "A line over the argument."),
        Command("underbrace", "{}", "A brace under the argument; label it with _{…}."),
        Command("leq", "", "Less than or equal: ≤"),
        Command("geq", "", "Greater than or equal: ≥"),
        Command("neq", "", "Not equal: ≠"),
        Command("approx", "", "Approximately: ≈"),
        Command("equiv", "", "Equivalent: ≡"),
        Command("sim", "", "Similar: ∼"),
        Command("in", "", "Element of: ∈"),
        Command("notin", "", "Not an element of: ∉"),
        Command("subset", "", "Subset: ⊂"),
        Command("subseteq", "", "Subset or equal: ⊆"),
        Command("cup", "", "Union: ∪"),
        Command("cap", "", "Intersection: ∩"),
        Command("forall", "", "For all: ∀"),
        Command("exists", "", "There exists: ∃"),
        Command("to", "", "An arrow: →"),
        Command("rightarrow", "", "Right arrow: →"),
        Command("Rightarrow", "", "Implies: ⇒"),
        Command("leftarrow", "", "Left arrow: ←"),
        Command("Leftrightarrow", "", "If and only if: ⇔"),
        Command("mapsto", "", "Maps to: ↦"),
        Command("pm", "", "Plus or minus: ±"),
        Command("mp", "", "Minus or plus: ∓"),
        Command("log", "", "The logarithm operator."),
        Command("exp", "", "The exponential operator."),
        Command("sin", "", "The sine operator."),
        Command("cos", "", "The cosine operator."),
        Command("tan", "", "The tangent operator."),
        Command("max", "", "The maximum operator."),
        Command("min", "", "The minimum operator."),
        Command("arg", "", "The argument operator."),
        Command("det", "", "The determinant operator."),
        Command("nonumber", "", "Leaves this line of an align unnumbered."),
        Command("notag", "", "Leaves this equation unnumbered (amsmath)."),
        Command("tag", "{}", "Gives the equation a custom tag (amsmath)."),
    ]

    private static let symbols: [Command] = [
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ϵ"), ("varepsilon", "ε"),
        ("zeta", "ζ"), ("eta", "η"), ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"),
        ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"), ("pi", "π"), ("rho", "ρ"), ("sigma", "σ"),
        ("tau", "τ"), ("upsilon", "υ"), ("phi", "ϕ"), ("varphi", "φ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"),
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"), ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"),
        ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
    ].map { Command($0.0, "", "Greek letter \($0.1)") }

    private static let preamble: [Command] = [
        Command("documentclass", "{}", "The document class: article, report, book, beamer…"),
        Command("usepackage", "{}", "Loads one or more packages."),
        Command("newcommand", "{}{}", "Defines a command: \\newcommand{\\name}[args]{definition}."),
        Command("renewcommand", "{}{}", "Redefines an existing command."),
        Command("newenvironment", "{}{}{}", "Defines an environment: {name}{begin code}{end code}."),
        Command("DeclareMathOperator", "{}{}", "Defines an upright math operator (amsmath)."),
        Command("newtheorem", "{}{}", "Defines a theorem-like environment: {name}{Heading}."),
        Command("graphicspath", "{}", "Folders \\includegraphics searches: {{figures/}}."),
        Command("setlength", "{}{}", "Sets a length: \\setlength{\\parindent}{0pt}."),
    ]

    static let environments: [Entry] = [
        Entry("itemize", "A bulleted list of \\item entries."),
        Entry("enumerate", "A numbered list of \\item entries."),
        Entry("description", "A list of \\item[term] definitions."),
        Entry("figure", "A floating figure with a \\caption."),
        Entry("figure*", "A figure spanning both columns."),
        Entry("table", "A floating table with a \\caption."),
        Entry("table*", "A table spanning both columns."),
        Entry("tabular", "A table: {lcr} sets the column alignment, & separates cells, \\\\ ends rows."),
        Entry("equation", "A numbered displayed equation."),
        Entry("equation*", "An unnumbered displayed equation (amsmath)."),
        Entry("align", "Numbered equations aligned at & (amsmath)."),
        Entry("align*", "Unnumbered equations aligned at & (amsmath)."),
        Entry("gather", "Centered equations, each numbered (amsmath)."),
        Entry("multline", "One long equation split over lines (amsmath)."),
        Entry("split", "Splits one equation over aligned lines inside equation (amsmath)."),
        Entry("cases", "Cases of a piecewise definition with a left brace (amsmath)."),
        Entry("matrix", "A matrix without delimiters (amsmath)."),
        Entry("pmatrix", "A matrix in parentheses (amsmath)."),
        Entry("bmatrix", "A matrix in square brackets (amsmath)."),
        Entry("abstract", "The paper's abstract."),
        Entry("center", "Centered lines."),
        Entry("quote", "An indented short quotation."),
        Entry("quotation", "An indented quotation of several paragraphs."),
        Entry("verbatim", "Text printed exactly as typed, in monospace."),
        Entry("minipage", "A box with its own text width: {0.5\\linewidth}."),
        Entry("theorem", "A theorem (define it with \\newtheorem or amsthm)."),
        Entry("lemma", "A lemma (define it with \\newtheorem)."),
        Entry("proof", "A proof ending with a QED box (amsthm)."),
        Entry("definition", "A definition (define it with \\newtheorem)."),
        Entry("corollary", "A corollary (define it with \\newtheorem)."),
        Entry("proposition", "A proposition (define it with \\newtheorem)."),
        Entry("example", "An example (define it with \\newtheorem)."),
        Entry("remark", "A remark (define it with \\newtheorem)."),
        Entry("algorithm", "A floating algorithm with a caption (algorithm)."),
        Entry("algorithmic", "Pseudocode steps (algpseudocode)."),
        Entry("lstlisting", "A source code listing (listings)."),
        Entry("tikzpicture", "A TikZ drawing (tikz)."),
        Entry("subfigure", "One panel of a figure: {0.48\\linewidth} (subcaption)."),
        Entry("thebibliography", "A hand-written bibliography of \\bibitem entries."),
        Entry("document", "The body of the document."),
        Entry("array", "A table inside math."),
        Entry("flushleft", "Left-aligned lines."),
        Entry("flushright", "Right-aligned lines."),
    ]

    /// Environments whose body is a list: a new one starts with an `\item`.
    static let listEnvironments: Set<String> = ["itemize", "enumerate", "description"]

    static let packages: [Entry] = [
        Entry("amsmath", "Displayed equations, alignment and math commands."),
        Entry("amssymb", "Extra math symbols and fonts, such as \\mathbb."),
        Entry("amsthm", "Theorem styles and the proof environment."),
        Entry("graphicx", "\\includegraphics for images."),
        Entry("hyperref", "Clickable links, references and PDF bookmarks."),
        Entry("cleveref", "\\cref: references that name their kind."),
        Entry("booktabs", "Professional table rules: \\toprule, \\midrule, \\bottomrule."),
        Entry("geometry", "Page size and margins."),
        Entry("xcolor", "Colors for text and drawings."),
        Entry("natbib", "Author–year citations: \\citep, \\citet."),
        Entry("biblatex", "Bibliographies with biber: \\addbibresource, \\printbibliography."),
        Entry("inputenc", "Source file encoding (UTF-8 is the default today)."),
        Entry("fontenc", "Font encoding; T1 for accented characters."),
        Entry("babel", "Language-specific hyphenation and labels."),
        Entry("microtype", "Subtle spacing refinements for nicer text."),
        Entry("tikz", "Drawing graphics in LaTeX."),
        Entry("pgfplots", "Plots built on TikZ."),
        Entry("subcaption", "Subfigures and subtables with their own captions."),
        Entry("caption", "Customizes captions."),
        Entry("float", "The [H] placement: exactly here."),
        Entry("multirow", "Table cells spanning rows."),
        Entry("array", "Extended column types for tabular."),
        Entry("tabularx", "Tables with stretching X columns."),
        Entry("siunitx", "Numbers and units: \\SI{3}{\\meter}."),
        Entry("enumitem", "Customizes lists."),
        Entry("listings", "Source code listings."),
        Entry("algorithm", "Floating algorithms."),
        Entry("algpseudocode", "Pseudocode commands for algorithmic."),
        Entry("mathtools", "Fixes and extras for amsmath."),
        Entry("bm", "Bold math symbols with \\bm."),
        Entry("url", "\\url for typesetting URLs."),
        Entry("lipsum", "Placeholder text: \\lipsum."),
        Entry("times", "Times-like text font."),
        Entry("lmodern", "Latin Modern fonts."),
        Entry("fontspec", "System fonts with XeLaTeX or LuaLaTeX."),
        Entry("setspace", "Line spacing: \\onehalfspacing, \\doublespacing."),
    ]
}
