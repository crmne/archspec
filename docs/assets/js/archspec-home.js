// ArchSpec homepage: cycle the architecture examples in the hero code panel.
(function () {
  function initCycler(cycler) {
    if (cycler.dataset.archBound) return;
    cycler.dataset.archBound = "true";

    var cards = Array.prototype.slice.call(cycler.querySelectorAll("[data-arch-card]"));
    if (cards.length < 2) return;

    var stack = cycler.querySelector(".archspec-card-stack");
    var docLink = cycler.querySelector("[data-arch-doc]");
    var dotsWrap = cycler.querySelector(".archspec-dots");

    var index = cards.findIndex(function (card) { return card.classList.contains("is-active"); });
    if (index < 0) index = 0;

    var dots = cards.map(function (card, i) {
      if (!dotsWrap) return null;
      var dot = document.createElement("button");
      dot.type = "button";
      dot.setAttribute("aria-label", card.dataset.title || "Example " + (i + 1));
      dot.addEventListener("click", function () {
        show(i);
        restart();
      });
      dotsWrap.appendChild(dot);
      return dot;
    });

    // Size the window to the active card so it grows and shrinks with the snippet.
    function resize() {
      if (stack) stack.style.height = cards[index].offsetHeight + "px";
    }

    function show(i) {
      cards[index].classList.remove("is-active");
      if (dots[index]) dots[index].classList.remove("is-active");
      index = i;
      cards[index].classList.add("is-active");
      if (dots[index]) dots[index].classList.add("is-active");
      if (docLink) {
        docLink.textContent = cards[index].dataset.title || "";
        if (cards[index].dataset.href) docLink.setAttribute("href", cards[index].dataset.href);
      }
      resize();
    }

    if (stack) stack.style.minHeight = "0px";
    show(index);

    window.addEventListener("resize", resize);
    window.addEventListener("load", resize);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(resize);

    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    // One interval, never stacked: play() is a no-op while a timer runs or while paused.
    var timer = null;
    var paused = false;

    function play() {
      if (timer || paused) return;
      timer = window.setInterval(function () { show((index + 1) % cards.length); }, 4500);
    }
    function stop() {
      if (timer) {
        window.clearInterval(timer);
        timer = null;
      }
    }
    function restart() {
      stop();
      play();
    }

    cycler.addEventListener("mouseenter", function () { paused = true; stop(); });
    cycler.addEventListener("mouseleave", function () { paused = false; play(); });
    cycler.addEventListener("focusin", function () { paused = true; stop(); });
    cycler.addEventListener("focusout", function () { paused = false; play(); });

    play();
  }

  function init() {
    document.querySelectorAll("[data-arch-cycler]").forEach(initCycler);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  document.addEventListener("turbo:load", init);
})();
