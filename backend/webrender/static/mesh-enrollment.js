// Completes a one-time enrollment on the original joining device without retaining its payload or member
// bearer token. Session changes and page retirement fence every signing, request and persistence step.
(function () {
  "use strict";
  var input = document.getElementById("mesh-link");
  var status = document.getElementById("mesh-status");
  var button = document.getElementById("mesh-redeem");
  var epoch = 0;
  var pending = false;
  if (window.__ASTRAL_ENROLLMENT__) input.value = location.origin + "/enroll#" + window.__ASTRAL_ENROLLMENT__;
  delete window.__ASTRAL_ENROLLMENT__;
  window.addEventListener("pagehide", function () { epoch++; input.value = ""; });
  button.addEventListener("click", async function () {
    if (pending) return;
    pending = true; button.disabled = true;
    var generation = ++epoch;
    var current = function () { return generation === epoch; };
    var link = input.value;
    input.value = "";
    try {
      var identity = await window.AstralMeshCustody.identityFromSession();
      var member = await window.AstralMeshCustody.redeem(identity, link, current);
      var latest = await window.AstralMeshCustody.identityFromSession();
      if (latest.subject !== identity.subject || latest.issuer !== identity.issuer || !current()) {
        await window.AstralMeshCustody.purge(identity);
        throw new Error("Session changed.");
      }
      status.textContent = "This device is enrolled. Open Mesh devices to check its access and identity: " + member.member_id;
    } catch (_error) {
      if (current()) status.textContent = "Enrollment refused. Sign in as the owner, confirm the request on another device, then paste the link again on the original joining device.";
    } finally {
      link = ""; pending = false; button.disabled = false;
    }
  });
}());
