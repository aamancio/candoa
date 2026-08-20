import AppKit
import XCTest

@MainActor
final class CandoaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// XCUITest leaves the app under test running (and frontmost) when a
    /// test ends, so local runs would strand a fixture-workspace browser on
    /// the developer's screen. Every test launches its own instance, so
    /// tearing the app down between tests costs nothing.
    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    static let splitFixturePageHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Split Fixture</title>
        <script>document.title = location.pathname.slice(1)</script>
      </head>
      <body><h1>Split pane fixture</h1></body>
    </html>
    """

    /// A solid #00ff00 page so pixel sampling has an unmistakable baseline:
    /// the pane center proves web content rendered, and any chrome drawn
    /// over the page must move a sampled channel away from pure green.
    static let pixelProbeFixturePageHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <script>document.title = location.pathname.slice(1)</script>
        <style>html, body { margin: 0; height: 100%; background: #00ff00; }</style>
      </head>
      <body></body>
    </html>
    """

    /// Hosted web-authentication fixture: the path picks the provider
    /// behavior — an immediate matching-scheme callback, a non-matching
    /// scheme, or an idle page that waits to be dismissed.
    static let webAuthFixturePageHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <script>
          addEventListener("load", () => {
            if (location.pathname === "/auth-success") {
              location.href = "candoa-e2e://auth?code=ok";
            } else if (location.pathname === "/auth-wrong") {
              location.href = "wrong-scheme://auth?code=bad";
            }
          });
        </script>
      </head>
      <body><h1>Web auth fixture</h1></body>
    </html>
    """

    /// A job application: three personal fields the snapshot marks sensitive
    /// (their autocomplete tokens), plus a submit button that is sensitive
    /// because it sends them. The status line reports how many fields are
    /// filled — a count, not labels, so the fixture agent can pick the next
    /// field without depending on how the snapshot happens to label it.
    static let applicationFormFixturePageHTML = """
    <!doctype html>
    <html>
      <head><meta charset="utf-8"><title>Job Application</title></head>
      <body>
        <h1>Job Application</h1>
        <form id="application">
          <label>Full name <input id="name" autocomplete="name"></label>
          <label>Email <input id="email" type="email"></label>
          <label>Phone <input id="phone" type="tel"></label>
          <button type="submit">Submit Application</button>
        </form>
        <p id="status">filled=0</p>
        <script>
          const form = document.getElementById("application");
          const status = document.getElementById("status");
          const render = () => {
            const filled = ["name", "email", "phone"]
              .filter((id) => document.getElementById(id).value.trim() !== "");
            status.textContent = "filled=" + filled.length + " " + filled.map((id) => id + "-ok").join(" ");
          };
          form.addEventListener("input", render);
          form.addEventListener("submit", (event) => {
            event.preventDefault();
            render();
            status.textContent += " submitted";
          });
        </script>
      </body>
    </html>
    """

    static let pageHTMLFixtures: [String: String] = [
        "ask-agent-form-fill": applicationFormFixturePageHTML,
        "split-view": splitFixturePageHTML,
        "tab-switcher-previews": splitFixturePageHTML,
        "split-view-spaces": splitFixturePageHTML,
        "split-view-pixels": pixelProbeFixturePageHTML,
        "web-auth": webAuthFixturePageHTML,
        "download-page": """
        <!doctype html>
        <meta charset="utf-8">
        <title>Download Fixture</title>
        <a href="data:application/octet-stream;base64,Q2FuZG9hIGUyZSBkb3dubG9hZCBmaXh0dXJl"
           download="candoa-e2e-download.bin"
           style="position:fixed;inset:0;font-size:40px">Download</a>
        """,
        "popup-open": """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <script>document.title = location.pathname.slice(1)</script>
          </head>
          <body>
            <script>
              document.addEventListener("click", () => {
                window.open("https://fixture.candoa.test/popup-child");
              });
            </script>
          </body>
        </html>
        """,
        "external-app-link": """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <script>document.title = location.pathname.slice(1)</script>
          </head>
          <body>
            <script>
              document.addEventListener("click", (event) => {
                location.href = event.clientX < window.innerWidth / 2
                  ? "mailto:someone@example.com"
                  : "zoom://join?confno=1";
              });
            </script>
          </body>
        </html>
        """,
        "reader-article": """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="author" content="Fixture Author">
            <script>document.title = location.pathname.slice(1)</script>
          </head>
          <body>
            <nav><a href="https://fixture.candoa.test/elsewhere">Fixture Nav Link</a></nav>
            <article>
              <h1>Reader Fixture Article</h1>
              <p>Reader fixture marker sentence.</p>
              <p>The availability probe needs sustained paragraph text before it will call a page an article, so this fixture carries several sentences of steady filler that read like the body of a feature story and push the character count well past the threshold.</p>
              <p>A second long paragraph keeps the scoring honest by adding more genuine sentence text, the kind that live articles have in abundance and navigation pages never do, which is exactly the distinction the reader probe is built to draw.</p>
              <p>The third paragraph exists so that trimming any single block in extraction cannot drop the fixture below the availability threshold, keeping this test focused on the reader flow instead of the scoring boundary.</p>
            </article>
          </body>
        </html>
        """,
        "history": """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>Candoa History Fixture</title></head>
          <body><h1>Candoa History Fixture</h1><p>Representative browsing history.</p></body>
        </html>
        """,
        "ask-agent-navigation": """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>Membership</title></head>
          <body>
            <main id="content"></main>
            <script>
              const content = document.getElementById("content");
              const render = () => {
                const route = location.hash.slice(1) || "home";
                const next = {
                  home: ["Account", "account"],
                  account: ["Manage Membership", "membership"],
                  membership: ["Cancel Membership", "cancelled"]
                }[route];
                content.replaceChildren();
                if (next) {
                  const button = document.createElement("button");
                  button.textContent = next[0];
                  button.addEventListener("click", () => { location.hash = next[1]; });
                  content.append(button);
                } else {
                  content.textContent = "Membership Cancelled";
                }
              };
              addEventListener("hashchange", render);
              render();
            </script>
          </body>
        </html>
        """,
        "ask-agent-mentioned-tab": """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <script>
              document.title = location.pathname === "/home" ? "Membership Home" : "Reading List";
            </script>
          </head>
          <body>
            <main id="content"></main>
            <script>
              const content = document.getElementById("content");
              const render = () => {
                content.replaceChildren();
                if (location.pathname === "/home" && !location.hash) {
                  const button = document.createElement("button");
                  button.textContent = "Account";
                  button.addEventListener("click", () => { location.hash = "account"; });
                  content.append(button);
                } else if (location.hash === "#account") {
                  content.textContent = "Account Page";
                } else {
                  content.textContent = "Reading list fixture.";
                }
              };
              addEventListener("hashchange", render);
              render();
            </script>
          </body>
        </html>
        """,
        "ask-agent-normalized-navigation": """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>MacBook Air</title></head>
          <body><a href="https://fixture.candoa.test/buy">Buy MacBook Air</a></body>
        </html>
        """,
        "ask-agent-selection": """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Configure MacBook Air</title>
          <style>
            body { font: 16px -apple-system; padding: 40px; }
            #color { width: 20px; height: 20px; }
            label[for="color"] { display: inline-block; margin-left: 8px; padding: 12px 18px; border: 1px solid #888; }
            label[for="color"]::before { content: "Sky Blue"; }
            button { padding: 12px 18px; }
          </style>
        </head>
        <body>
          <main id="content">
            <h1>Choose your color</h1>
            <input id="color" type="radio" name="color" aria-label="Sky Blue">
            <label for="color"></label>
            <button id="add" hidden>Add to Cart</button>
            <section id="cart" hidden>
              <h1>Shopping Cart</h1>
              <p id="cart-status">MacBook Air is in your cart.</p>
              <button id="remove">Remove</button>
            </section>
          </main>
          <script>
            const color = document.getElementById("color");
            const add = document.getElementById("add");
            const cart = document.getElementById("cart");
            const remove = document.getElementById("remove");
            color.addEventListener("click", (event) => event.preventDefault());
            document.querySelector('label[for="color"]').addEventListener("click", (event) => {
              event.preventDefault();
              color.checked = true;
              add.hidden = false;
            });
            add.addEventListener("click", () => {
              add.hidden = true;
              cart.hidden = false;
            });
            remove.addEventListener("click", () => {
              remove.hidden = true;
              document.getElementById("cart-status").textContent = "Your cart is empty.";
            });
          </script>
        </body>
        </html>
        """
    ]

}
