// Safari share-sheet preprocessing for Summary Chip.
// run() receives the page before the extension launches; its results arrive in the extension
// as NSExtensionJavaScriptPreprocessingResultsKey.
var ExtractContent = function () {};

ExtractContent.prototype = {
    MAX_LENGTH: 60000,

    meta: function (selectors) {
        for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && el.getAttribute("content")) {
                return el.getAttribute("content").trim();
            }
        }
        return "";
    },

    textOf: function (root) {
        var clone = root.cloneNode(true);
        var junk = clone.querySelectorAll(
            "nav, header, footer, aside, script, style, noscript, iframe, svg, form, button, " +
            "[role=navigation], [role=banner], [role=contentinfo], [role=complementary], " +
            "[aria-hidden=true], .advertisement, .ads, .share, .social, .comments"
        );
        for (var i = 0; i < junk.length; i++) {
            if (junk[i].parentNode) { junk[i].parentNode.removeChild(junk[i]); }
        }
        var text = clone.innerText || clone.textContent || "";
        return text.replace(/[ \t ]+/g, " ").replace(/\n\s*\n\s*\n+/g, "\n\n").trim();
    },

    // Picks <article>, [role=main] or <main>; otherwise the element with the most paragraph text.
    mainRoot: function () {
        var preferred = ["article", "[role=main]", "main"];
        for (var i = 0; i < preferred.length; i++) {
            var candidates = document.querySelectorAll(preferred[i]);
            var best = null, bestLength = 0;
            for (var j = 0; j < candidates.length; j++) {
                var length = (candidates[j].innerText || "").length;
                if (length > bestLength) { best = candidates[j]; bestLength = length; }
            }
            if (best && bestLength > 500) { return best; }
        }

        var scores = new Map();
        var paragraphs = document.querySelectorAll("p, pre, li, blockquote, h2, h3");
        for (var k = 0; k < paragraphs.length; k++) {
            var p = paragraphs[k];
            var len = (p.innerText || "").trim().length;
            if (len < 40) { continue; }
            var parent = p.parentElement;
            var depth = 0;
            while (parent && depth < 3) {
                scores.set(parent, (scores.get(parent) || 0) + len / (depth + 1));
                parent = parent.parentElement;
                depth++;
            }
        }
        var densest = null, top = 0;
        scores.forEach(function (score, el) {
            if (el === document.body || el === document.documentElement) { return; }
            if (score > top) { top = score; densest = el; }
        });
        return densest || document.body;
    },

    run: function (arguments) {
        var content = "";
        try {
            content = this.textOf(this.mainRoot());
            if (content.length < 200 && document.body) {
                content = this.textOf(document.body);
            }
        } catch (e) {
            content = document.body ? (document.body.innerText || "") : "";
        }
        if (content.length > this.MAX_LENGTH) {
            content = content.substring(0, this.MAX_LENGTH);
        }
        arguments.completionFunction({
            url: document.URL,
            title: this.meta(["meta[property='og:title']", "meta[name='twitter:title']"]) || document.title || "",
            siteName: this.meta(["meta[property='og:site_name']", "meta[name='application-name']"]),
            lang: (document.documentElement.getAttribute("lang") || "").trim(),
            description: this.meta(["meta[property='og:description']", "meta[name='description']"]),
            content: content
        });
    },

    finalize: function (arguments) {}
};

var ExtensionPreprocessingJS = new ExtractContent();
