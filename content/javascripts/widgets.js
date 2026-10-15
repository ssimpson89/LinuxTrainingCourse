/* Interactive course widgets.
 *
 * Every widget is authored in Markdown as an HTML container (md_in_html), so
 * the page still reads sensibly with JavaScript disabled. See STYLE.md for the
 * authoring syntax of each widget.
 *
 *   .stepper   – walk through ordered steps (Prev / Next, progress bar)
 *   .quiz      – multiple-choice checkpoint with retry and explanation
 *   .layers    – clickable stack diagram (pick a layer, read its detail)
 *   .decision  – branching troubleshooting tree
 *   .widget-chmod  – permission bits <-> octal <-> symbolic calculator
 *   .widget-subnet – IPv4 CIDR calculator
 *   .terminal-sim  – guided practice terminal that checks typed commands
 *   .flashcards    – flip cards for recall practice
 *   module progress – "mark complete" button on module pages, ticks on home
 */

(function () {
  "use strict";

  var PROGRESS_KEY = "rocky-course-progress";

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function children(root, selector) {
    return Array.prototype.filter.call(root.children, function (c) {
      return c.matches(selector);
    });
  }

  function once(root, name) {
    if (root.dataset.ready === name) return false;
    root.dataset.ready = name;
    return true;
  }

  /* ---------------------------------------------------------------- stepper */

  function initStepper(root) {
    if (!once(root, "stepper")) return;
    var steps = children(root, ".step");
    if (!steps.length) return;
    var current = 0;

    var nav = el("div", "stepper__nav");
    var stage = el("div", "stepper__stage");
    var bar = el("div", "stepper__bar");
    var fill = el("span");
    bar.appendChild(fill);
    var controls = el("div", "stepper__controls");
    var prev = el("button", "stepper__btn", "← Back");
    var count = el("span", "stepper__count");
    var next = el("button", "stepper__btn stepper__btn--primary", "Next →");
    prev.type = next.type = "button";
    controls.append(prev, count, next);

    steps.forEach(function (step, i) {
      var b = el("button", "stepper__pill");
      b.type = "button";
      b.append(el("span", "stepper__num", String(i + 1)));
      b.append(el("span", "stepper__label", step.dataset.title || "Step " + (i + 1)));
      b.addEventListener("click", function () { show(i); });
      nav.appendChild(b);
      if (step.dataset.title && !step.querySelector(".step__title")) {
        var h = el("p", "step__title", step.dataset.title);
        step.insertBefore(h, step.firstChild);
      }
      stage.appendChild(step);
    });

    root.append(nav, bar, stage, controls);

    function show(i) {
      current = Math.max(0, Math.min(steps.length - 1, i));
      steps.forEach(function (s, j) {
        s.classList.toggle("is-active", j === current);
        s.setAttribute("aria-hidden", j === current ? "false" : "true");
      });
      Array.prototype.forEach.call(nav.querySelectorAll(".stepper__pill"), function (p, j) {
        p.classList.toggle("is-active", j === current);
        p.classList.toggle("is-done", j < current);
        p.setAttribute("aria-current", j === current ? "step" : "false");
      });
      fill.style.width = ((current + 1) / steps.length) * 100 + "%";
      count.textContent = current + 1 + " / " + steps.length;
      prev.disabled = current === 0;
      next.disabled = current === steps.length - 1;
    }

    prev.addEventListener("click", function () { show(current - 1); });
    next.addEventListener("click", function () { show(current + 1); });
    root.tabIndex = 0;
    root.addEventListener("keydown", function (e) {
      if (e.target.closest("input, textarea")) return;
      if (e.key === "ArrowRight") { show(current + 1); e.preventDefault(); }
      if (e.key === "ArrowLeft") { show(current - 1); e.preventDefault(); }
    });
    show(0);
  }

  /* ------------------------------------------------------------------- quiz */

  function initQuiz(root) {
    if (!once(root, "quiz")) return;
    var list = root.querySelector(":scope > ul, :scope > ol");
    if (!list) return;
    var answer = parseInt(root.dataset.answer, 10) - 1;
    var options = children(list, "li");

    var badge = el("span", "quiz__badge", root.dataset.title || "Checkpoint");
    root.insertBefore(badge, root.firstChild);

    // Everything after the option list is the explanation, revealed on success.
    var explain = el("div", "quiz__explain");
    var node = list.nextSibling;
    while (node) {
      var following = node.nextSibling;
      explain.appendChild(node);
      node = following;
    }
    var feedback = el("p", "quiz__feedback");
    feedback.setAttribute("aria-live", "polite");

    var choices = el("div", "quiz__choices");
    options.forEach(function (li, i) {
      var b = el("button", "quiz__choice");
      b.type = "button";
      b.append(el("span", "quiz__letter", String.fromCharCode(65 + i)));
      var body = el("span", "quiz__text");
      while (li.firstChild) body.appendChild(li.firstChild);
      b.append(body);
      b.addEventListener("click", function () { pick(i, b); });
      choices.appendChild(b);
    });
    list.replaceWith(choices);
    root.append(feedback, explain);

    function pick(i, button) {
      if (root.classList.contains("is-solved")) return;
      if (i === answer) {
        button.classList.add("is-correct");
        root.classList.add("is-solved");
        feedback.textContent = "Correct!";
      } else {
        button.classList.add("is-wrong");
        button.disabled = true;
        feedback.textContent = "Not quite. Have another look and try again.";
      }
    }
  }

  /* ----------------------------------------------------------------- layers */

  function initLayers(root) {
    if (!once(root, "layers")) return;
    var layers = children(root, ".layer");
    if (!layers.length) return;

    var wrap = el("div", "layers__wrap");
    var stack = el("div", "layers__stack");
    stack.setAttribute("role", "tablist");
    var panel = el("div", "layers__panel");
    var hint = el("p", "layers__hint", root.dataset.hint || "Click a layer to see what it does.");

    layers.forEach(function (layer, i) {
      var b = el("button", "layers__bar");
      b.type = "button";
      b.setAttribute("role", "tab");
      b.style.setProperty("--layer-i", i);
      b.style.setProperty("--layer-n", layers.length);
      b.append(el("span", "layers__label", layer.dataset.label || "Layer " + (i + 1)));
      if (layer.dataset.tag) b.append(el("span", "layers__tag", layer.dataset.tag));
      b.addEventListener("click", function () { show(i); });
      stack.appendChild(b);
      panel.appendChild(layer);
    });

    panel.insertBefore(hint, panel.firstChild);
    wrap.append(stack, panel);
    root.appendChild(wrap);

    function show(i) {
      hint.hidden = true;
      layers.forEach(function (l, j) { l.classList.toggle("is-active", j === i); });
      Array.prototype.forEach.call(stack.children, function (b, j) {
        b.classList.toggle("is-active", j === i);
        b.setAttribute("aria-selected", j === i ? "true" : "false");
      });
    }

    if (root.dataset.open != null) show(parseInt(root.dataset.open, 10) || 0);
  }

  /* --------------------------------------------------------------- decision */

  function initDecision(root) {
    if (!once(root, "decision")) return;
    var nodes = children(root, ".node");
    if (!nodes.length) return;
    var byId = {};
    nodes.forEach(function (n, i) { byId[n.dataset.id || "n" + i] = n; });
    var start = nodes[0].dataset.id || "n0";
    var history = [];

    var trail = el("div", "decision__trail");
    var stage = el("div", "decision__stage");
    var controls = el("div", "decision__controls");
    var back = el("button", "stepper__btn", "← Back");
    var reset = el("button", "stepper__btn", "Start over");
    back.type = reset.type = "button";
    controls.append(back, reset);
    nodes.forEach(function (n) { stage.appendChild(n); });
    root.append(trail, stage, controls);

    root.addEventListener("click", function (e) {
      var target = e.target.closest("[data-goto]");
      if (!target || !root.contains(target)) return;
      e.preventDefault();
      go(target.dataset.goto, target.textContent.trim());
    });
    back.addEventListener("click", function () {
      if (history.length) {
        history.pop();
        render(history.length ? history[history.length - 1].id : start);
      }
    });
    reset.addEventListener("click", function () { history = []; render(start); });

    function go(id, label) {
      if (!byId[id]) return;
      history.push({ id: id, label: label });
      render(id);
    }

    function render(id) {
      nodes.forEach(function (n) { n.classList.toggle("is-active", n === byId[id]); });
      trail.textContent = "";
      trail.appendChild(el("span", "decision__crumb", "Start"));
      history.forEach(function (h) { trail.appendChild(el("span", "decision__crumb", h.label)); });
      back.disabled = history.length === 0;
      var node = byId[id];
      node.classList.toggle("is-leaf", !node.querySelector("[data-goto]"));
    }

    Array.prototype.forEach.call(root.querySelectorAll("[data-goto]"), function (b) {
      if (b.tagName === "BUTTON") b.type = "button";
      b.classList.add("decision__choice");
    });
    render(start);
  }

  /* ------------------------------------------------------------------ chmod */

  function initChmod(root) {
    if (!once(root, "chmod")) return;
    var who = [["u", "Owner (u)"], ["g", "Group (g)"], ["o", "Others (o)"]];
    var bits = [["r", 4, "read"], ["w", 2, "write"], ["x", 1, "execute"]];
    var specials = [["setuid", 4, "setuid"], ["setgid", 2, "setgid"], ["sticky", 1, "sticky"]];
    var state = { u: 6, g: 4, o: 4, s: 0 };
    var isDir = false;

    var grid = el("div", "chmod__grid");
    grid.append(el("span"));
    bits.forEach(function (b) { grid.append(el("span", "chmod__head", b[2] + " (" + b[1] + ")")); });
    who.forEach(function (w) {
      grid.append(el("span", "chmod__who", w[1]));
      bits.forEach(function (b) {
        var label = el("label", "chmod__cell");
        var box = el("input");
        box.type = "checkbox";
        box.dataset.who = w[0];
        box.dataset.val = b[1];
        box.setAttribute("aria-label", w[1] + " " + b[2]);
        label.append(box, el("span", "chmod__bit", b[0]));
        grid.append(label);
      });
    });

    var special = el("div", "chmod__special");
    specials.forEach(function (sp) {
      var label = el("label", "chmod__toggle");
      var box = el("input");
      box.type = "checkbox";
      box.dataset.special = sp[1];
      label.append(box, document.createTextNode(" " + sp[2]));
      special.append(label);
    });
    var dirLabel = el("label", "chmod__toggle");
    var dirBox = el("input");
    dirBox.type = "checkbox";
    dirLabel.append(dirBox, document.createTextNode(" it's a directory"));
    special.append(dirLabel);

    var out = el("div", "chmod__out");
    var octalIn = el("input", "chmod__octal");
    octalIn.setAttribute("aria-label", "Octal mode");
    octalIn.maxLength = 4;
    octalIn.inputMode = "numeric";
    var symbolic = el("code", "chmod__symbolic");
    var command = el("code", "chmod__command");
    var meaning = el("p", "chmod__meaning");
    var row1 = el("div", "chmod__row");
    row1.append(el("span", "chmod__k", "Octal"), octalIn);
    var row2 = el("div", "chmod__row");
    row2.append(el("span", "chmod__k", "ls -l shows"), symbolic);
    var row3 = el("div", "chmod__row");
    row3.append(el("span", "chmod__k", "Command"), command);
    out.append(row1, row2, row3, meaning);

    root.append(grid, special, out);

    root.addEventListener("change", function (e) {
      var t = e.target;
      if (t === dirBox) { isDir = t.checked; return render(); }
      if (t.dataset.who) {
        var v = parseInt(t.dataset.val, 10);
        state[t.dataset.who] = t.checked ? state[t.dataset.who] | v : state[t.dataset.who] & ~v;
      } else if (t.dataset.special) {
        var s = parseInt(t.dataset.special, 10);
        state.s = t.checked ? state.s | s : state.s & ~s;
      }
      render();
    });
    octalIn.addEventListener("input", function () {
      var v = octalIn.value.trim();
      if (!/^[0-7]{3,4}$/.test(v)) { octalIn.classList.add("is-bad"); return; }
      octalIn.classList.remove("is-bad");
      if (v.length === 3) v = "0" + v;
      state = { s: +v[0], u: +v[1], g: +v[2], o: +v[3] };
      render(true);
    });

    function sym(v, exec, special, upper, lower) {
      var s = (v & 4 ? "r" : "-") + (v & 2 ? "w" : "-");
      var x = v & 1;
      if (special) return s + (x ? lower : upper);
      return s + (x ? "x" : "-");
    }

    function describe(v, isDirectory) {
      var parts = [];
      if (isDirectory) {
        if (v & 4) parts.push("list names");
        if (v & 2) parts.push("create/delete entries" + (v & 1 ? "" : " (useless without x)"));
        if (v & 1) parts.push("enter / traverse");
      } else {
        if (v & 4) parts.push("read");
        if (v & 2) parts.push("modify");
        if (v & 1) parts.push("run it");
      }
      return parts.length ? parts.join(", ") : "nothing";
    }

    function render(fromOctal) {
      Array.prototype.forEach.call(root.querySelectorAll("input[data-who]"), function (b) {
        b.checked = !!(state[b.dataset.who] & parseInt(b.dataset.val, 10));
      });
      Array.prototype.forEach.call(root.querySelectorAll("input[data-special]"), function (b) {
        b.checked = !!(state.s & parseInt(b.dataset.special, 10));
      });
      var octal = (state.s ? String(state.s) : "") + state.u + state.g + state.o;
      if (!fromOctal) octalIn.value = octal;
      symbolic.textContent =
        (isDir ? "d" : "-") +
        sym(state.u, 0, state.s & 4, "S", "s") +
        sym(state.g, 0, state.s & 2, "S", "s") +
        sym(state.o, 0, state.s & 1, "T", "t");
      command.textContent = "chmod " + octal + (isDir ? " mydir/" : " myfile");
      meaning.textContent = "";
      [["Owner", state.u], ["Group", state.g], ["Others", state.o]].forEach(function (p) {
        var line = el("span", "chmod__line");
        line.append(el("strong", null, p[0] + ": "), document.createTextNode(describe(p[1], isDir)));
        meaning.append(line);
      });
      var notes = [];
      if (state.s & 4) notes.push(isDir ? "setuid on a directory is ignored on Linux." : "setuid: runs with the file owner's identity.");
      if (state.s & 2) notes.push(isDir ? "setgid: new files inherit the directory's group." : "setgid: runs with the file's group.");
      if (state.s & 1) notes.push(isDir ? "sticky: only a file's owner can delete it (like /tmp)." : "sticky on a regular file is ignored on Linux.");
      if (state.o & 2) notes.push("⚠ world-writable: anyone can change this.");
      notes.forEach(function (n) { meaning.append(el("span", "chmod__line chmod__note", n)); });
    }
    render();
  }

  /* ----------------------------------------------------------------- subnet */

  function initSubnet(root) {
    if (!once(root, "subnet")) return;
    var input = el("input", "subnet__input");
    input.value = root.dataset.cidr || "192.168.10.37/24";
    input.setAttribute("aria-label", "IPv4 address with prefix, for example 10.0.0.5/24");
    input.spellcheck = false;
    var table = el("dl", "subnet__table");
    var bitsRow = el("div", "subnet__bits");
    root.append(el("label", "subnet__label", "Address / prefix"), input, bitsRow, table);
    input.addEventListener("input", render);

    function toInt(ip) {
      var p = ip.split(".");
      if (p.length !== 4) return null;
      var n = 0;
      for (var i = 0; i < 4; i++) {
        if (!/^\d{1,3}$/.test(p[i]) || +p[i] > 255) return null;
        n = n * 256 + +p[i];
      }
      return n;
    }
    function toIp(n) {
      return [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(".");
    }

    function render() {
      var m = input.value.trim().match(/^([\d.]+)\/(\d{1,2})$/);
      var ip = m && toInt(m[1]);
      var prefix = m && +m[2];
      table.textContent = "";
      bitsRow.textContent = "";
      if (ip == null || prefix > 32) {
        input.classList.add("is-bad");
        table.append(el("dd", "subnet__err", "Type an address like 10.0.0.5/24"));
        return;
      }
      input.classList.remove("is-bad");
      var mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
      var net = (ip & mask) >>> 0;
      var bcast = (net | (~mask >>> 0)) >>> 0;
      var total = Math.pow(2, 32 - prefix);
      var usable = prefix >= 31 ? total : total - 2;
      var first = prefix >= 31 ? net : net + 1;
      var last = prefix >= 31 ? bcast : bcast - 1;
      var rows = [
        ["Netmask", toIp(mask)],
        ["Network", toIp(net) + "/" + prefix],
        ["Broadcast", prefix >= 31 ? "(none)" : toIp(bcast)],
        ["Usable hosts", toIp(first) + " – " + toIp(last)],
        ["Host count", usable.toLocaleString()],
      ];
      rows.forEach(function (r) { table.append(el("dt", null, r[0]), el("dd", null, r[1])); });
      for (var i = 31; i >= 0; i--) {
        var b = el("span", (31 - i) < prefix ? "is-net" : "is-host", String((ip >>> i) & 1));
        bitsRow.append(b);
        if (i % 8 === 0 && i) bitsRow.append(el("span", "subnet__dot", "."));
      }
      var legend = el("span", "subnet__legend");
      legend.append(el("span", "is-net", "network bits"), el("span", "is-host", "host bits"));
      bitsRow.append(legend);
    }
    render();
  }


  /* ----------------------------------------------------------- terminal sim */

  // Guided practice terminal. Each .task holds instructions, an expected
  // command (data-expect, alternatives separated by "||", or data-match as a
  // regular expression) and a code block with the output to print.
  function initTerminal(root) {
    if (!once(root, "terminal")) return;
    var tasks = children(root, ".task");
    if (!tasks.length) return;
    var promptText = root.dataset.prompt || "[alex@rocky-lab ~]$ ";
    var current = 0;

    var head = el("div", "term__head");
    var dots = el("span", "term__dots");
    dots.append(el("i"), el("i"), el("i"));
    head.append(dots, el("span", "term__title", root.dataset.title || "Practice terminal"));
    var progress = el("span", "term__progress");
    head.append(progress);

    var brief = el("div", "term__brief");
    var screen = el("div", "term__screen");
    screen.setAttribute("aria-live", "polite");
    var line = el("label", "term__line");
    var ps1 = el("span", "term__ps1", promptText);
    var input = el("input", "term__input");
    input.setAttribute("autocomplete", "off");
    input.setAttribute("autocapitalize", "off");
    input.setAttribute("spellcheck", "false");
    input.setAttribute("aria-label", "Type a command and press Enter");
    line.append(ps1, input);
    var screenWrap = el("div", "term__body");
    screenWrap.append(screen, line);

    var bar = el("div", "term__controls");
    var hintBtn = el("button", "stepper__btn", "Hint");
    var showBtn = el("button", "stepper__btn", "Show me");
    var resetBtn = el("button", "stepper__btn", "Restart");
    hintBtn.type = showBtn.type = resetBtn.type = "button";
    bar.append(hintBtn, showBtn, resetBtn);

    tasks.forEach(function (t) { brief.appendChild(t); });
    root.append(head, brief, screenWrap, bar);

    function expected(t) {
      return (t.dataset.expect || "").split("||").map(function (c) { return norm(c); }).filter(Boolean);
    }
    function norm(c) { return c.trim().replace(/\s+/g, " "); }
    function outputOf(t) {
      var code = t.querySelector("pre code, code.output");
      return code ? code.textContent.replace(/\n$/, "") : "";
    }

    function print(text, cls) {
      var row = el("div", "term__row" + (cls ? " " + cls : ""));
      row.textContent = text;
      screen.appendChild(row);
      screenWrap.scrollTop = screenWrap.scrollHeight;
    }

    function show(i) {
      current = i;
      tasks.forEach(function (t, j) {
        t.classList.toggle("is-active", j === i);
        t.classList.toggle("is-done", j < i);
      });
      var finished = i >= tasks.length;
      root.classList.toggle("is-finished", finished);
      progress.textContent = finished ? "✓ done" : (i + 1) + " / " + tasks.length;
      input.disabled = finished;
      hintBtn.disabled = showBtn.disabled = finished;
      if (finished) print(root.dataset.done || "All done. Nice work!", "term__ok");
    }

    function run(cmd) {
      var t = tasks[current];
      print(promptText + cmd, "term__cmd");
      if (!t) return;
      var c = norm(cmd);
      if (!c) return;
      if (c === "clear") { screen.textContent = ""; return; }
      var ok = expected(t).indexOf(c) !== -1;
      if (!ok && t.dataset.match) {
        try { ok = new RegExp("^(?:" + t.dataset.match + ")$").test(c); } catch (e) { ok = false; }
      }
      if (ok) {
        var out = outputOf(t);
        if (out) print(out);
        show(current + 1);
      } else {
        print(t.dataset.wrong || "Not quite what this step needs. Try again, or click Hint.", "term__err");
      }
    }

    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        e.preventDefault();
        var v = input.value;
        input.value = "";
        run(v);
      }
    });
    screenWrap.addEventListener("click", function () { if (!input.disabled) input.focus({ preventScroll: true }); });
    hintBtn.addEventListener("click", function () {
      var t = tasks[current];
      if (t) print("hint: " + (t.dataset.hint || "Read the step above carefully."), "term__hint");
    });
    showBtn.addEventListener("click", function () {
      var t = tasks[current];
      if (!t) return;
      var answer = (t.dataset.expect || "").split("||")[0].trim();
      input.value = answer;
      input.focus({ preventScroll: true });
    });
    resetBtn.addEventListener("click", function () {
      screen.textContent = "";
      show(0);
    });
    show(0);
  }

  /* ------------------------------------------------------------- flashcards */

  // Each .card: the first child is the front, everything else is the back.
  function initFlashcards(root) {
    if (!once(root, "flashcards")) return;
    var cards = children(root, ".card");
    cards.forEach(function (card) {
      var front = el("div", "card__face card__front");
      var back = el("div", "card__face card__back");
      var first = card.firstElementChild;
      if (!first) return;
      front.appendChild(first);
      while (card.firstChild) back.appendChild(card.firstChild);
      var inner = el("div", "card__inner");
      inner.append(front, back);
      card.appendChild(inner);
      card.tabIndex = 0;
      card.setAttribute("role", "button");
      card.setAttribute("aria-pressed", "false");
      var flip = function () {
        var on = card.classList.toggle("is-flipped");
        card.setAttribute("aria-pressed", on ? "true" : "false");
      };
      card.addEventListener("click", function (e) {
        if (e.target.closest("a")) return;
        flip();
      });
      card.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); flip(); }
      });
    });
    var hint = el("p", "flashcards__hint", "Click a card to flip it.");
    root.insertBefore(hint, root.firstChild);
  }

  /* ---------------------------------------------------------- reading bar */

  var readingBar;
  function initReadingBar() {
    if (!readingBar) {
      readingBar = el("div", "reading-bar");
      document.body.appendChild(readingBar);
      var update = function () {
        var h = document.documentElement;
        var max = h.scrollHeight - h.clientHeight;
        readingBar.style.transform = "scaleX(" + (max > 0 ? h.scrollTop / max : 0) + ")";
      };
      window.addEventListener("scroll", update, { passive: true });
      window.addEventListener("resize", update);
      readingBar.update = update;
    }
    readingBar.hidden = !moduleSlug();
    readingBar.update();
  }

  /* --------------------------------------------------------------- progress */

  function readProgress() {
    try { return JSON.parse(localStorage.getItem(PROGRESS_KEY)) || {}; } catch (e) { return {}; }
  }
  function writeProgress(p) {
    try { localStorage.setItem(PROGRESS_KEY, JSON.stringify(p)); } catch (e) { /* private mode */ }
  }

  function moduleSlug() {
    var m = location.pathname.match(/\/(\d{2}-[a-z0-9-]+)\/?$/);
    return m ? m[1] : null;
  }

  function initProgress() {
    var progress = readProgress();
    var slug = moduleSlug();
    var content = document.querySelector(".md-content__inner");
    if (slug && content && !content.querySelector(".module-complete")) {
      var box = el("div", "module-complete");
      var btn = el("button", "module-complete__btn");
      btn.type = "button";
      var sync = function () {
        var done = !!readProgress()[slug];
        btn.textContent = done ? "✓ Module complete. Click to undo" : "Mark this module complete";
        btn.classList.toggle("is-done", done);
      };
      btn.addEventListener("click", function () {
        var p = readProgress();
        if (p[slug]) delete p[slug]; else p[slug] = Date.now();
        writeProgress(p);
        sync();
      });
      box.append(btn);
      content.appendChild(box);
      sync();
    }
    var cards = Array.prototype.filter.call(
      document.querySelectorAll(".syllabus-card[href]"),
      function (card) { return /\d{2}-[a-z0-9-]+/.test(card.getAttribute("href")); }
    );
    var done = 0;
    cards.forEach(function (card) {
      var m = card.getAttribute("href").match(/(\d{2}-[a-z0-9-]+)/);
      var isDone = !!progress[m[1]];
      card.classList.toggle("is-done", isDone);
      if (isDone) done++;
    });
    var meter = document.querySelector(".course-progress");
    if (meter && cards.length) {
      meter.hidden = false;
      meter.querySelector(".course-progress__fill").style.width = (done / cards.length) * 100 + "%";
      meter.querySelector(".course-progress__text").textContent =
        done + " of " + cards.length + " modules complete";
    }
  }

  /* ------------------------------------------------------------------- boot */

  function init() {
    document.querySelectorAll(".stepper").forEach(initStepper);
    document.querySelectorAll(".quiz").forEach(initQuiz);
    document.querySelectorAll(".layers").forEach(initLayers);
    document.querySelectorAll(".decision").forEach(initDecision);
    document.querySelectorAll(".widget-chmod").forEach(initChmod);
    document.querySelectorAll(".widget-subnet").forEach(initSubnet);
    document.querySelectorAll(".terminal-sim").forEach(initTerminal);
    document.querySelectorAll(".flashcards").forEach(initFlashcards);
    initProgress();
    initReadingBar();
  }

  if (typeof window.document$ !== "undefined" && window.document$.subscribe) {
    window.document$.subscribe(init);
  } else if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
