(function () {
  var boxes = Array.prototype.slice.call(document.querySelectorAll(".claim-check"));
  var choices = Array.prototype.slice.call(document.querySelectorAll(".licence-choice"));
  var approve = document.getElementById("approve-btn");
  if (!approve) { return; }
  function sync() {
    approve.disabled = !boxes.every(function (b) { return b.checked; }) ||
      (choices.length > 0 && !choices.some(function (c) { return c.checked; }));
  }
  boxes.concat(choices).forEach(function (b) { b.addEventListener("change", sync); });
  sync();
})();
